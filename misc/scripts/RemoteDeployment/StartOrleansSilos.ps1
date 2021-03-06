# Deploys the silos defined in the OrleansRuntime.dll.config file.
#requires -version 2.0

param([string]$deploymentConfigFile)

$scriptDir = Split-Path -parent $MyInvocation.MyCommand.Definition
. $scriptDir\UtilityFunctions.ps1

$configXml = New-Object XML

if (($deploymentConfigFile -eq "/?") -or 
	($args[0] -eq "-?") -or
	($deploymentConfigFile -eq "/help") -or
	($args[0] -eq "-help") -or
	($deploymentConfigFile -eq "help") )
{
	WriteHostSafe Green -text ""
	WriteHostSafe Green -text "`tUsage:`t.\StartOrleansSilos [deploymentConfigFile]"
	WriteHostSafe Green -text ""
	WriteHostSafe Green -text "`t`tdeploymentConfigFile::`t[Optional] The path to the deployment configuration file. "
	WriteHostSafe Green -text "`t`t`t`t`t(i.e. ""Deployment.xml"")  Use quotes if the path has a spaces." 
	WriteHostSafe Green -text "`t`t`t`t`tDefault is Deployment.xml. "
	WriteHostSafe Green -text ""
	WriteHostSafe Green -text "`tExample:`t.\DeployOrleansSilos "
	WriteHostSafe Green -text "`tExample:`t.\DeployOrleansSilos OrleansConfig1\Deployment.xml"
	WriteHostSafe Green -text ""
	return
}


# Change the path to where we think it should be (see http://huddledmasses.org/powershell-power-user-tips-current-directory/).
[Environment]::CurrentDirectory=(Get-Location -PSProvider FileSystem).ProviderPath

$configXml = Get-DeploymentConfiguration ([ref]$deploymentConfigFile) $scriptDir


# if we couldn't load the config file, the script cannot contiune.
if (!$configXml -or $configXml -eq "")
{
	WriteHostSafe -foregroundColor Red -text "     Deployment configuration file required to continue."
	WriteHostSafe -foregroundColor Red -text "          Please supply the name of the configuration file, or ensure that the default"
	WriteHostSafe -foregroundColor Red -text "          Deployment.xml file is available in the script directory."
	return
}

if (!$deploymentConfigFile.Length)
{
	WriteHostSafe -foregroundColor Red -text "     Deployment configuration file name not returned from Get-DeploymentConfiguration()."
	WriteHostSafe -foregroundColor Red -text "          Please report this error to the Orleans team."
	WriteHostSafe -foregroundColor Red -text "          Specifying Deployment.xml on the command line may work around this issue."
	return
}

$configValidationError = $false

#$machineNames = @($configXml.Deployment.Nodes.Node | ForEach-Object {$_.HostName} | select-object -unique)
$machineNames = Get-UniqueMachineNames $configXml $deploymentConfigFile

$deployFileName = Split-Path -Path $deploymentConfigFile -Leaf

if(!$machineNames)
{
	WriteHostSafe -foregroundColor Red -text "     At least one target machine is required to continue."
	WriteHostSafe -foregroundColor Red -text ("")
	$configValidationError = $true
}

# Try to get the $localTargetPath from the target location node in the config file.
$localTargetPath = $configXml.Deployment.TargetLocation.Path

if (!$localTargetPath)
{
	$localTargetPath = "C:\Orleans"
	WriteHostSafe -foregroundColor Yellow -text ("     TargetLocation not found in config file; defaulting to ""{0}""." -f $localTargetPath)
	WriteHostSafe -foregroundColor Yellow -text ("")
}

## If target path is relative, convert it to absolute so it can be used by robocopy to remote machines.
#$localTargetPath = (Resolve-Path $localTargetPath).Path

# Set the remote path by changing the drive designation to a remote admin share.
$remoteTargetPath = $localTargetPath.Replace(":", "$");

# Get the path to the source files for the system
$sourceXpath = "descendant::xcg:Package[@Type=""System""]" 

$packagesNode = $configXml.Deployment.Packages
if ($packagesNode.Package) 
{
	$sourceConfig = $packagesNode | Select-Xml -Namespace @{xcg="urn:xcg-deployment"} -XPath $sourceXpath
}

if ($sourceConfig -and $sourceConfig.Node -and $sourceConfig.Node.Path)
{
	$sourcePath = $sourceConfig.Node.Path
}

if (!$sourcePath)
{
	WriteHostSafe -foregroundColor Red -text ("     *** Error: The system <Package> element was not found in $deployFileName.")
	WriteHostSafe -foregroundColor Red -text "        Please supply an element for the System package, as well as additional Application packages."
	WriteHostSafe -foregroundColor Red -text ("        Format: <Packages>")
	WriteHostSafe -foregroundColor Red -text ("                    <Package Name=""Orleans Runtime"" Type=""System"" Path=""."" />"	)
	WriteHostSafe -foregroundColor Red -text ("                    <Package Name=""Chirper"" Type=""Application"" Path=""..\Applications\Chirper"" Filter=""Chirper*"" />"	)
	WriteHostSafe -foregroundColor Red -text ("                <Packages>")
	WriteHostSafe -foregroundColor Red -text ("")
	WriteHostSafe -foregroundColor Red -text "     A System Package is required to continue."
	WriteHostSafe -foregroundColor Red -text ("")
	$configValidationError = $true
}

# Expand out the relative directory.
if ($sourcePath -eq ".")
{
	$sourcePath = $scriptDir
}

# Convert relative path to absolute so it can be passed to jobs.
$fullBaseCfgPath = Split-Path -Parent -Resolve "$deploymentConfigFile"

# All relative paths should be relative to the directory where the deployment config file is located.
if ($sourcePath -and !(Split-Path $sourcePath -IsAbsolute))
{
	$sourcePath = Join-Path -Path $fullBaseCfgPath -ChildPath $sourcePath
}

# Get the configuration file path from the deployment configuration file.
$orleansConfigFilePath = $configXml.Deployment.RuntimeConfiguration.Path

if(!$orleansConfigFilePath) 
{
	$orleansConfigFilePath = "{0}\{1}" -f $fullBaseCfgPath, "OrleansConfiguration.xml"
}

if (!(Test-Path $orleansConfigFilePath))
{
	WriteHostSafe -foregroundColor Red -text ("     *** Error: The Orleans Configuration file ""$orleansConfigFilePath""")
	WriteHostSafe -foregroundColor Red -text ("         specified in $deployFileName cannot be found.")
	WriteHostSafe -foregroundColor Red -text ("")
	WriteHostSafe -foregroundColor Red -text ("         Confirm that the file name is correct in the Path attribute")
	WriteHostSafe -foregroundColor Red -text ("         of the <RuntimeConfiguration> element and that the file exists ") 
	WriteHostSafe -foregroundColor Red -text ("         at the specified location"	)
	WriteHostSafe -foregroundColor Red -text ("")
	$configValidationError = $true
}
else 
{
	if (!(Split-Path $orleansConfigFilePath  -IsAbsolute))
	{
		$orleansConfigFilePath = "{0}\{1}" -f $fullBaseCfgPath, $orleansConfigFilePath
	}
}

if ($configValidationError)
{
	WriteHostSafe -foregroundColor Red -text "      Deployment cannot proceed with invalid configuration."
	return
}


# Create an array of objects that holds the information about each machine.
$machines = @()

foreach ($machineName in $machineNames) 
{
	$machine = "" | Select-Object name,processId;
	$machine.name = $machineName

	# TODO: Test to see if the machine is accessible.

	#Create an XmlNamespaceManager to resolve the default namespace.
	$ns = New-Object Xml.XmlNamespaceManager $configXml.NameTable
	$ns.AddNamespace( "xcg", "urn:xcg-deployment" )
	
	# We have to build the XPath string this way because $machine.name doesn't unpack 
	#	correctly inside the string.
	$xpath = ("descendant::xcg:Node[@HostName=""{0}""]" -f $machineName)

	#Start each silo on the machine.
	$silos = $configXml.SelectNodes($xpath, $ns)
	$siloCount = 0;
	foreach($silo in $silos)
	{
		# TODO: Add code determine if the copy job completed successfully and abort or retry if not.
		if ($machine.processId.Length -gt 0)
		{
			$machine.processId += ";"
		}
		$command = "$localTargetPath\OrleansHost.exe ""{0}"" ""{1}""" -f $silo.NodeName, (Split-Path $orleansConfigFilePath -Leaf)
		$process = Invoke-WmiMethod -path win32_process -name create -argumentlist $command, $localTargetPath -ComputerName $machineName
		WriteHostSafe Green -text ("`tStarted OrleansHost process {0} on machine {1}." -f $process.ProcessId, $machineName)
		
		if ($process.ProcessId)
		{
			$machine.processId += $process.ProcessId.ToString()
		}
		else 
		{
			WriteHostSafe Red -text ("`tError: OrleansHost not started for silo {0} on machine {1}" -f $silo.NodeName, $machineName)
		}
		if (($siloCount -eq 0) -and
			($silos.Count -gt 1))
		{
			WriteHostSafe -foregroundColor Yellow -text "`t`tPausing for Primary silo to complete start-up" -noNewline $true 
			$pauseLength = 5
			$pauseIteration = 0
			while ($pauseIteration -lt $pauseLength)
			{
				Start-Sleep -Seconds 1
				WriteHostSafe -foregroundColor Yellow -text "." -noNewline $true 
				$pauseIteration += 1
			}
			WriteHostSafe -text " " 
		}
		
		$siloCount += 1
	}

	$machines = $machines + $machine
}


# This will automatically reset the file.
$logFile = "SiloStartResults.log"
Get-Date | Out-File $logFile

Echo " "
WriteHostSafe -foregroundColor DarkCyan -text ("Collecting Start-up results and saving in ""{0}""" -f $logFile) -noNewline $true 
# Pause for Start-up jobs to settle out.
$pauseLength = 5
$pauseIteration = 0
while ($pauseIteration -lt $pauseLength)
{
	Start-Sleep -Seconds 1
	WriteHostSafe -foregroundColor DarkCyan -text "." -noNewline $true 
	$pauseIteration += 1
}
Echo " " 
WriteHostSafe -foregroundColor Cyan -text "Preparing Start-up Results Log"
foreach ($machine in $machines) 
{
	$processIds = $machine.processId -split ";"
	foreach ($id in $processIds) 
	{
		"Machine: {0}" -f $machine.name | Out-File $logFile -Append 
		$remoteProcess = Get-Process -ComputerName $machine.name -Id $id -ErrorAction SilentlyContinue
		if (!$remoteProcess)
		{
			$remoteProcess =  ("    Error!  Could not find process {0} on machine {1}`n`r." -f $id, $machine.name)
		}
		$remoteProcess | Out-File $logFile -Append 
	}
} 
Echo " "

Get-Content $logFile
Echo ""
echo 'End of Start-up Results'

WriteHostSafe Green -text ""
WriteHostSafe Green -text "Checking for active processes"
$numProcesses = 0
foreach ($machine in $machines) 
{
	$process = Get-Process -ComputerName $machine.name -Name "OrleansHost" -ErrorAction SilentlyContinue
	
	if ($process)
	{
		if ($process.Count)
		{
			foreach($instance in $process)
			{
				$numProcesses++
			}
		}
		else
		{
			$numProcesses++
		}
	}
	else
	{
		WriteHostSafe -foregroundColor Red -text ("OrleansHost is not running on {0}" -f $machine.name)
	}
}
WriteHostSafe Green -text ("{0} processes running" -f $numProcesses)
