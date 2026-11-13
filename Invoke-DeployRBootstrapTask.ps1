#Requires -Version 5.1

<#
.SYNOPSIS
    Stages itself and the DeployR bootstrap on one or more devices and registers a scheduled task that runs it as SYSTEM.

.DESCRIPTION
    Starting a DeployR task sequence in an existing operating system is documented as an elevated PowerShell call to the
    Bootstrap endpoint of the DeployR server, with an optional hashtable of task sequence variables set first:

        $DeployRBootstrap = @{ MyRole = 'Accounting' }
        iex (irm 'https://server:7281/v1/Service/Bootstrap?tsid=<GUID>:<Version>')

    This script turns that call into something that runs on a device unattended, for example a task sequence that
    pre-stages content ahead of a deployment. It works in three modes:

    Create (the default)
        1. Creates the destination directory on each device if it does not exist, restricted to SYSTEM and Administrators
           because task sequence variables can carry secrets.
        2. Copies itself there.
        3. Writes the task sequence variables next to it as DeployRBootstrap.json.
        4. Builds the scheduled task definition from a fixed template, setting every value with XPath, so the task runs
           the staged copy of this script with -Bootstrap as SYSTEM through Windows PowerShell.
        5. Registers the task and, optionally, starts it.

    Bootstrap (run by the scheduled task)
        Reads DeployRBootstrap.json into $DeployRBootstrap, downloads the bootstrap from the DeployR server and runs it.
        The bootstrap installs .NET and PowerShell 7 from the DeployR server when they are missing.

    Remove
        Removes the task and the destination directory.

    Remote devices are reached through their administrative share and schtasks.exe /S, using the current credentials.

    Intune platform scripts and remediations cannot pass parameters. For those, set the values in the
    "Default parameter values" region below the parameter block. A parameter given on the command line always wins.

    The task runs as SYSTEM with nobody to answer a prompt, so a task sequence ID is required: without one the DeployR
    client waits for someone to choose a task sequence. The task sequence must not restart the device.

.PARAMETER DeployRServer
    The DeployR server, with scheme, for example https://deployr.contoso.com:7281. When no port is given, 7281 is used.

.PARAMETER TaskSequenceID
    The task sequence to run, as <GUID>:<Version>, for example 00000002-0000-0000-0000-000000000001:1.

.PARAMETER Variables
    Optional task sequence variables, as a JSON object of names and values, for example
    {"PRESTAGEONLY":"True","SITE":"NYC01"}. Values are passed to DeployR as strings. The bootstrap on the device turns
    them into the $DeployRBootstrap hashtable. Variable names are written to the logs, values never are.

.PARAMETER ComputerName
    The devices to stage and register the task on. Defaults to the local device.

.PARAMETER Destination
    The local path on each device that receives this script and the variables. Defaults to
    %ProgramData%\2Pint\DeployRBootstrap. Remote devices are reached through the administrative share of the same drive.

.PARAMETER TaskFolder
    The Task Scheduler folder for the task. Defaults to \2Pint.

.PARAMETER TaskName
    The scheduled task name. Defaults to DeployR Bootstrap.

.PARAMETER Trigger
    When the task runs on its own: None (on demand only, the default), AtStartup (5 minutes after boot), or Once at
    StartTime.

.PARAMETER StartTime
    The local date and time for the Once trigger.

.PARAMETER ExecutionTimeLimit
    How long the task may run before Task Scheduler stops it. Defaults to 8 hours, to allow for large content.

.PARAMETER RemoveVariablesAfterUse
    Deletes the variables file from the device as soon as the bootstrap has read it. Use it when the variables carry
    secrets and the task is only meant to run once.

.PARAMETER Execute
    Starts the task once it is registered, or when it exists already.

.PARAMETER Force
    Replaces an existing task and restages the files. Without it, a device that already has the task is left as it is
    and reported as successful.

.PARAMETER StageOnly
    Stages this script, the variables and the task definition (DeployRBootstrapTask.xml) without registering the task,
    for packaging with another tool.

.PARAMETER Remove
    Removes the task and the destination directory from each device.

.PARAMETER Bootstrap
    Runs the DeployR bootstrap. Used by the scheduled task; not normally run by hand.

.PARAMETER BootstrapUri
    The full bootstrap URL, used with -Bootstrap. Set by the scheduled task.

.PARAMETER LogDirectory
    Where this script writes its transcript. Defaults to %SystemRoot%\Logs\Software\<script name>.

.EXAMPLE
    .\Invoke-DeployRBootstrapTask.ps1 -DeployRServer 'https://deployr.contoso.com:7281' -TaskSequenceID '00000002-0000-0000-0000-000000000001:1' -Variables '{"PRESTAGEONLY":"True","SITE":"NYC01"}' -Execute -Force

    Stages the bootstrap with two task sequence variables on this device, registers the task and starts it.

.EXAMPLE
    $InvokeDeployRBootstrapTaskParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
        $InvokeDeployRBootstrapTaskParameters.DeployRServer = 'https://deployr.contoso.com:7281'
        $InvokeDeployRBootstrapTaskParameters.TaskSequenceID = '00000002-0000-0000-0000-000000000001:1'
        $InvokeDeployRBootstrapTaskParameters.Variables = '{"PRESTAGEONLY":"True"}'
        $InvokeDeployRBootstrapTaskParameters.ComputerName = @('NYC-WS-0101', 'NYC-WS-0102')
        $InvokeDeployRBootstrapTaskParameters.Trigger = 'Once'
        $InvokeDeployRBootstrapTaskParameters.StartTime = (Get-Date).Date.AddDays(1).AddHours(1)
        $InvokeDeployRBootstrapTaskParameters.Force = $True

    .\Invoke-DeployRBootstrapTask.ps1 @InvokeDeployRBootstrapTaskParameters

    Stages two remote devices and schedules the pre-stage task sequence for 01:00 tomorrow, device local time.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Invoke-DeployRBootstrapTask.ps1 -DeployRServer https://deployr.contoso.com:7281 -TaskSequenceID 00000002-0000-0000-0000-000000000001:1 -Variables "{\"PRESTAGEONLY\":\"True\"}" -Execute -Force

    The same from a command line, such as a ConfigMgr program. Inside a command line, escape the JSON quotes as \".

.EXAMPLE
    .\Invoke-DeployRBootstrapTask.ps1 -Remove -ComputerName 'NYC-WS-0101'

    Removes the task and the staged files from a remote device.

.NOTES
    Version: 2026.11.13.1530

    Exit codes: 0 every device succeeded (or the bootstrap ran), 1 the script failed, 2 one or more devices failed.

    The task runs Windows PowerShell with -ExecutionPolicy Bypass. An execution policy forced by Group Policy
    (MachinePolicy) takes precedence over the command line; the script then has to be signed.

    The device must trust the DeployR server certificate. With the 2Pint self-signed certificate, its root CA has to
    be in the device's Trusted Root Certification Authorities store first.

    The bootstrap writes its own log to %SystemRoot%\Temp; DeployR logs go to C:\_2P\Logs once the task sequence starts.

.LINK
    https://github.com/Grace-Solutions/Invoke-DeployRBootstrapTask

.LINK
    https://documentation.2pintsoftware.com/deployr/deployment-methods/starting-a-task-sequence-in-an-existing-os
#>

[CmdletBinding(DefaultParameterSetName = 'Create')]
Param
    (
        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [ValidateScript({($_.IsAbsoluteUri -eq $True) -and ($_.Scheme -iin @('https', 'http'))})]
        [System.Uri]$DeployRServer,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}:\d+$')]
        [String]$TaskSequenceID,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [AllowNull()]
        [AllowEmptyString()]
        [String]$Variables,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Parameter(Mandatory = $False, ParameterSetName = 'Remove')]
        [ValidateNotNullOrEmpty()]
        [String[]]$ComputerName = @("$($Env:ComputerName)"),

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Parameter(Mandatory = $False, ParameterSetName = 'Remove')]
        [ValidateNotNullOrEmpty()]
        [System.IO.DirectoryInfo]$Destination = [System.IO.Path]::Combine("$($Env:ProgramData)", '2Pint', 'DeployRBootstrap'),

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Parameter(Mandatory = $False, ParameterSetName = 'Remove')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({$_.StartsWith('\')})]
        [String]$TaskFolder = '\2Pint',

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Parameter(Mandatory = $False, ParameterSetName = 'Remove')]
        [ValidateNotNullOrEmpty()]
        [String]$TaskName = 'DeployR Bootstrap',

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [ValidateSet('None', 'AtStartup', 'Once')]
        [String]$Trigger = 'None',

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [DateTime]$StartTime,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [ValidateScript({$_ -gt [System.TimeSpan]::Zero})]
        [System.TimeSpan]$ExecutionTimeLimit = [System.TimeSpan]::FromHours(8),

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Parameter(Mandatory = $False, ParameterSetName = 'Bootstrap')]
        [Switch]$RemoveVariablesAfterUse,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Switch]$Execute,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Switch]$Force,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Switch]$StageOnly,

        [Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
        [Switch]$Remove,

        [Parameter(Mandatory = $True, ParameterSetName = 'Bootstrap')]
        [Switch]$Bootstrap,

        [Parameter(Mandatory = $True, ParameterSetName = 'Bootstrap')]
        [ValidateScript({($_.IsAbsoluteUri -eq $True) -and ($_.Scheme -iin @('https', 'http'))})]
        [System.Uri]$BootstrapUri,

        [Parameter(Mandatory = $False)]
        [System.IO.DirectoryInfo]$LogDirectory
    )

#region Default parameter values
  #For Intune platform scripts, remediations and other tools that cannot pass parameters.
  #A value applies only when the parameter was not given on the command line. Empty values and $False are ignored.
    $DefaultParameterValues = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
        $DefaultParameterValues.DeployRServer = ''
        $DefaultParameterValues.TaskSequenceID = ''
        $DefaultParameterValues.Variables = ''
          #$DefaultParameterValues.Variables = '{"PRESTAGEONLY":"True","SITE":"NYC01"}'
        $DefaultParameterValues.Trigger = ''
        $DefaultParameterValues.Execute = $False
        $DefaultParameterValues.Force = $False
        $DefaultParameterValues.RemoveVariablesAfterUse = $False
#endregion

$ErrorActionPreference = 'Stop'
[System.Environment]::ExitCode = 0

$ScriptFileInfo = [System.IO.FileInfo]$MyInvocation.MyCommand.Path
$ParameterSetName = $PSCmdlet.ParameterSetName

Switch ($ParameterSetName)
    {
        {($_ -iin @('Bootstrap'))}
            {
                #Progress output slows Invoke-RestMethod and Invoke-WebRequest considerably in Windows PowerShell
                  $ProgressPreference = 'SilentlyContinue'
            }

        {($_ -iin @('Create'))}
            {
                $ProgressPreference = 'Continue'

                ForEach ($DefaultParameterValue In $DefaultParameterValues.GetEnumerator())
                    {
                        $DefaultValue = $DefaultParameterValue.Value

                        $IsEmptyDefault = Switch ($True)
                            {
                                {($Null -ieq $DefaultValue)}
                                    {
                                        $True
                                        Break
                                    }

                                {($DefaultValue -is [String]) -and ([String]::IsNullOrWhiteSpace($DefaultValue) -eq $True)}
                                    {
                                        $True
                                        Break
                                    }

                                {($DefaultValue -is [System.Collections.ICollection]) -and ($DefaultValue.Count -eq 0)}
                                    {
                                        $True
                                        Break
                                    }

                                {($DefaultValue -is [Boolean]) -and ($DefaultValue -eq $False)}
                                    {
                                        $True
                                        Break
                                    }

                                Default
                                    {
                                        $False
                                    }
                            }

                        Switch (($IsEmptyDefault -eq $False) -and ($PSBoundParameters.ContainsKey($DefaultParameterValue.Key) -eq $False))
                            {
                                {($_ -eq $True)}
                                    {
                                        Set-Variable -Name ($DefaultParameterValue.Key) -Value ($DefaultValue)
                                    }
                            }
                    }
            }

        Default
            {
                $ProgressPreference = 'Continue'
            }
    }

Switch ($Null -ieq $LogDirectory)
    {
        {($_ -eq $True)}
            {
                $LogDirectory = [System.IO.DirectoryInfo][System.IO.Path]::Combine("$($Env:SystemRoot)", 'Logs', 'Software', "$($ScriptFileInfo.BaseName)")
            }
    }

$LogMessage = {
    Param
        (
            [String]$Message,
            [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
            [String]$Level = 'INFO'
        )

    $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss.fff')
    $LogEntry = "[$($Timestamp)] - [$($Level)] - $($Message)"

    Switch ($Level)
        {
            {($_ -iin @('INFO'))}
                {
                    Write-Verbose -Message ($LogEntry) -Verbose
                }

            {($_ -iin @('WARN', 'ERROR'))}
                {
                    Write-Warning -Message ($LogEntry)
                }

            {($_ -iin @('DEBUG'))}
                {
                    Write-Verbose -Message ($LogEntry)
                }
        }
}

$HandleError = {
    Param
        (
            [System.Exception]$Exception,
            [String]$Context = 'Unknown'
        )

    $ErrorMessage = "Error in $($Context): $($Exception.Message)"

    Switch ($Null -ine $Exception.InnerException)
        {
            {($_ -eq $True)}
                {
                    $ErrorMessage = "$($ErrorMessage) Inner: $($Exception.InnerException.Message)"
                }
        }

    $LogMessage.Invoke($ErrorMessage, 'ERROR')
    $LogMessage.Invoke("Stack Trace: $($Exception.StackTrace)", 'DEBUG')
}

$InvokeProcess = {
    Param
        (
            [System.IO.FileInfo]$FilePath,
            [System.Collections.Generic.List[String]]$ArgumentList,
            [Int[]]$AcceptableExitCodes = @(0)
        )

    $Process = New-Object -TypeName 'System.Diagnostics.Process'
        $Process.StartInfo.FileName = $FilePath.FullName
        $Process.StartInfo.Arguments = $ArgumentList -Join ' '
        $Process.StartInfo.UseShellExecute = $False
        $Process.StartInfo.RedirectStandardOutput = $True
        $Process.StartInfo.RedirectStandardError = $True
        $Process.StartInfo.CreateNoWindow = $True

    $LogMessage.Invoke("Running: `"$($Process.StartInfo.FileName)`" $($Process.StartInfo.Arguments)", 'DEBUG')

    $Null = $Process.Start()

    $StandardOutputTask = $Process.StandardOutput.ReadToEndAsync()
    $StandardErrorTask = $Process.StandardError.ReadToEndAsync()

    $Null = $Process.WaitForExit()

    $ProcessResultProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
        $ProcessResultProperties.ExitCode = $Process.ExitCode
        $ProcessResultProperties.Successful = $Process.ExitCode -in $AcceptableExitCodes
        $ProcessResultProperties.StandardOutput = "$($StandardOutputTask.Result)".Trim()
        $ProcessResultProperties.StandardError = "$($StandardErrorTask.Result)".Trim()

    $Process.Dispose()

    New-Object -TypeName 'System.Management.Automation.PSObject' -Property ($ProcessResultProperties)
}

$SetXmlNodeText = {
    Param
        (
            [System.Xml.XmlDocument]$Document,
            [System.Xml.XmlNamespaceManager]$NamespaceManager,
            [String]$XPath,
            [String]$Value
        )

    $XmlNode = $Document.SelectSingleNode($XPath, $NamespaceManager)

    Switch ($Null -ieq $XmlNode)
        {
            {($_ -eq $True)}
                {
                    Throw "The task definition template has no node at `"$($XPath)`"."
                }
        }

    $XmlNode.InnerText = $Value
}

$AddXmlElement = {
    Param
        (
            [System.Xml.XmlDocument]$Document,
            [System.Xml.XmlNode]$Parent,
            [String]$Name,
            [String]$Value
        )

    $XmlElement = $Document.CreateElement($Name, $Document.DocumentElement.NamespaceURI)

    Switch ([String]::IsNullOrEmpty($Value))
        {
            {($_ -eq $False)}
                {
                    $XmlElement.InnerText = $Value
                }
        }

    $Parent.AppendChild($XmlElement)
}

$ConvertToVariableTable = {
    Param
        (
            [Object]$InputObject
        )

    $VariableTable = New-Object -TypeName 'System.Collections.Hashtable' -ArgumentList @([System.StringComparer]::OrdinalIgnoreCase)

    $PropertyList = New-Object -TypeName 'System.Collections.Generic.List[PSObject]'

    Switch ($True)
        {
            {($Null -ine $InputObject)}
                {
                    ForEach ($Property In $InputObject.PSObject.Properties)
                        {
                            $EntryProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                $EntryProperties.Name = "$($Property.Name)"
                                $EntryProperties.Value = $Property.Value

                            $PropertyList.Add((New-Object -TypeName 'System.Management.Automation.PSObject' -Property ($EntryProperties)))
                        }
                }
        }

    For ($PropertyIndex = 0; $PropertyIndex -lt $PropertyList.Count; $PropertyIndex++)
        {
            $VariableName = $PropertyList[$PropertyIndex].Name
            $VariableValue = $PropertyList[$PropertyIndex].Value

            Switch ($True)
                {
                    {([String]::IsNullOrWhiteSpace($VariableName) -eq $True)}
                        {
                            Throw 'A task sequence variable has an empty name.'
                        }

                    {($Null -ine $VariableValue) -and ($VariableValue -is [System.Collections.IEnumerable]) -and ($VariableValue -isnot [String])}
                        {
                            Throw "The task sequence variable `"$($VariableName)`" has a collection as its value. Task sequence variables are single values."
                        }
                }

            $VariableTable[$VariableName] = Switch ($Null -ieq $VariableValue)
                {
                    {($_ -eq $True)}
                        {
                            ''
                        }

                    {($_ -eq $False)}
                        {
                            [System.Convert]::ToString($VariableValue, [System.Globalization.CultureInfo]::InvariantCulture)
                        }
                }
        }

    ,$VariableTable
}

#Fixed task definition. Every value is set with XPath before the task is registered.
  $TaskDefinitionTemplate = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author />
    <Description />
    <URI />
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit />
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command />
      <Arguments />
      <WorkingDirectory />
    </Exec>
  </Actions>
</Task>
'@

Try
    {
        Switch ([System.IO.Directory]::Exists($LogDirectory.FullName))
            {
                {($_ -eq $False)}
                    {
                        $Null = [System.IO.Directory]::CreateDirectory($LogDirectory.FullName)
                    }
            }

        $TranscriptBaseName = "$($ScriptFileInfo.BaseName)-$($ParameterSetName)"

        $TranscriptFileList = New-Object -TypeName 'System.Collections.Generic.List[System.IO.FileInfo]'
            $LogDirectory.Refresh()
            $LogDirectory.GetFiles("$($TranscriptBaseName)_*.log") | Sort-Object -Property @('CreationTimeUtc') -Descending | ForEach-Object {$TranscriptFileList.Add($_)}

        For ($TranscriptFileIndex = 2; $TranscriptFileIndex -lt $TranscriptFileList.Count; $TranscriptFileIndex++)
            {
                $Null = Try {$TranscriptFileList[$TranscriptFileIndex].Delete()} Catch {}
            }

        $TranscriptPath = [System.IO.FileInfo][System.IO.Path]::Combine($LogDirectory.FullName, "$($TranscriptBaseName)_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).log")

        $Null = Start-Transcript -Path $TranscriptPath.FullName -Force
    }
Catch
    {
        Write-Warning -Message ("Unable to start the transcript in `"$($LogDirectory.FullName)`": $($_.Exception.Message)")
    }

Try
    {
        $LogMessage.Invoke("$($ScriptFileInfo.Name) started in $($ParameterSetName) mode as $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)", 'INFO')
        $LogMessage.Invoke("PowerShell $($PSVersionTable.PSVersion.ToString()) ($($PSVersionTable.PSEdition)), $([System.IntPtr]::Size * 8)-bit, on $($Env:ComputerName)", 'INFO')

        $VariablesFileName = 'DeployRBootstrap.json'
        $TaskDefinitionFileName = 'DeployRBootstrapTask.xml'

        Switch ($ParameterSetName)
            {
                {($_ -iin @('Bootstrap'))}
                    {
                        #Windows PowerShell does not offer TLS 1.2 by default
                          [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

                        $VariablesPath = [System.IO.FileInfo][System.IO.Path]::Combine($ScriptFileInfo.Directory.FullName, $VariablesFileName)

                        #The documented name for the task sequence variables passed to the bootstrap
                          $DeployRBootstrap = New-Object -TypeName 'System.Collections.Hashtable' -ArgumentList @([System.StringComparer]::OrdinalIgnoreCase)

                        Switch ([System.IO.File]::Exists($VariablesPath.FullName))
                            {
                                {($_ -eq $True)}
                                    {
                                        $VariablesObject = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($VariablesPath.FullName))

                                        $DeployRBootstrap = $ConvertToVariableTable.Invoke($VariablesObject)[0]

                                        $LogMessage.Invoke("Loaded $($DeployRBootstrap.Count) task sequence variable(s) from `"$($VariablesPath.FullName)`": $(($DeployRBootstrap.Keys | Sort-Object) -Join ', '). Values are not logged.", 'INFO')

                                        Switch ($RemoveVariablesAfterUse -eq $True)
                                            {
                                                {($_ -eq $True)}
                                                    {
                                                        [System.IO.File]::Delete($VariablesPath.FullName)

                                                        $LogMessage.Invoke("Deleted `"$($VariablesPath.FullName)`" after reading it.", 'INFO')
                                                    }
                                            }
                                    }

                                {($_ -eq $False)}
                                    {
                                        $LogMessage.Invoke("No variables file at `"$($VariablesPath.FullName)`". The bootstrap runs without task sequence variables.", 'INFO')
                                    }
                            }

                        $LogMessage.Invoke("Requesting the bootstrap from $($BootstrapUri.OriginalString)", 'INFO')

                        $BootstrapContent = Invoke-RestMethod -Uri ($BootstrapUri.OriginalString) -Method Get -UseBasicParsing

                        Switch ([String]::IsNullOrWhiteSpace("$($BootstrapContent)"))
                            {
                                {($_ -eq $True)}
                                    {
                                        Throw "The DeployR server returned an empty bootstrap from $($BootstrapUri.OriginalString)."
                                    }
                            }

                        $LogMessage.Invoke('Running the bootstrap. Its own log is written to the Windows Temp directory; DeployR logs to C:\_2P\Logs once the task sequence starts.', 'INFO')

                        Invoke-Expression -Command ("$($BootstrapContent)")

                        $LogMessage.Invoke('The bootstrap returned.', 'INFO')
                    }

                {($_ -iin @('Create', 'Remove'))}
                    {
                        $SchtasksPath = [System.IO.FileInfo][System.IO.Path]::Combine([System.Environment]::SystemDirectory, 'schtasks.exe')

                        $TaskPath = Switch ($TaskFolder.TrimEnd('\').Length -eq 0)
                            {
                                {($_ -eq $True)}
                                    {
                                        "\$($TaskName)"
                                    }

                                {($_ -eq $False)}
                                    {
                                        "$($TaskFolder.TrimEnd('\'))\$($TaskName)"
                                    }
                            }

                        $LogMessage.Invoke("Scheduled task: $($TaskPath)", 'INFO')
                        $LogMessage.Invoke("Destination on each device: $($Destination.FullName)", 'INFO')

                        Switch ([System.IO.Path]::IsPathRooted($Destination.FullName) -and ($Destination.Root.FullName -imatch '^[A-Za-z]:\\$'))
                            {
                                {($_ -eq $False)}
                                    {
                                        Throw "The destination `"$($Destination.FullName)`" must be a local path with a drive letter, as seen from each device."
                                    }
                            }

                        $DestinationDriveLetter = $Destination.Root.FullName.Substring(0, 1)
                        $DestinationRelativePath = $Destination.FullName.Substring($Destination.Root.FullName.Length)

                        $ScriptDevicePath = [System.IO.FileInfo][System.IO.Path]::Combine($Destination.FullName, $ScriptFileInfo.Name)

                        $LocalComputerNameList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                            $LocalComputerNameList.Add('.')
                            $LocalComputerNameList.Add('localhost')
                            $LocalComputerNameList.Add("$($Env:ComputerName)")

                        Switch ([String]::IsNullOrEmpty($Env:UserDnsDomain))
                            {
                                {($_ -eq $False)}
                                    {
                                        $LocalComputerNameList.Add("$($Env:ComputerName).$($Env:UserDnsDomain)")
                                    }
                            }

                        $CurrentPrincipal = New-Object -TypeName 'System.Security.Principal.WindowsPrincipal' -ArgumentList @([System.Security.Principal.WindowsIdentity]::GetCurrent())
                        $IsElevated = $CurrentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

                        $Utf8NoBom = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($False)

                        Switch ($ParameterSetName)
                            {
                                {($_ -iin @('Create'))}
                                    {
                                        Switch ($True)
                                            {
                                                {($Null -ieq $DeployRServer)}
                                                    {
                                                        Throw 'No DeployR server was given. Pass -DeployRServer, or set its value in the Default parameter values region of the script.'
                                                    }

                                                {([String]::IsNullOrWhiteSpace($TaskSequenceID) -eq $True)}
                                                    {
                                                        Throw 'No task sequence ID was given. Pass -TaskSequenceID, or set its value in the Default parameter values region of the script.'
                                                    }


                                                {($Trigger -iin @('Once')) -and ($StartTime -eq [DateTime]::MinValue)}
                                                    {
                                                        Throw 'The Once trigger needs -StartTime.'
                                                    }
                                            }

                                        #Bootstrap URL, defaulting to the DeployR port when none was given
                                          $DeployRServerBuilder = New-Object -TypeName 'System.UriBuilder' -ArgumentList @($DeployRServer)

                                          Switch ($DeployRServer.IsDefaultPort)
                                              {
                                                  {($_ -eq $True)}
                                                      {
                                                          $DeployRServerBuilder.Port = 7281

                                                          $LogMessage.Invoke('No port was given for the DeployR server, so 7281 is used.', 'WARN')
                                                      }
                                              }

                                          $DeployRServerBuilder.Path = '/v1/Service/Bootstrap'

                                          #The ID is validated as <GUID>:<Version>, so it is safe in the query as documented, colon included
                                            $DeployRServerBuilder.Query = "tsid=$($TaskSequenceID)"

                                          $ResolvedBootstrapUri = $DeployRServerBuilder.Uri

                                        $LogMessage.Invoke("Bootstrap URL: $($ResolvedBootstrapUri.OriginalString)", 'INFO')

                                        #Variables
                                          $VariableTable = Switch ([String]::IsNullOrWhiteSpace($Variables))
                                              {
                                                  {($_ -eq $False)}
                                                      {
                                                          $VariablesObject = Try {ConvertFrom-Json -InputObject ($Variables)} Catch {Throw "-Variables is not valid JSON: $($_.Exception.Message)"}

                                                          Switch (($Null -ieq $VariablesObject) -or ($VariablesObject -isnot [System.Management.Automation.PSCustomObject]))
                                                              {
                                                                  {($_ -eq $True)}
                                                                      {
                                                                          Throw '-Variables must be a JSON object of names and values, for example {"PRESTAGEONLY":"True"}.'
                                                                      }
                                                              }

                                                          $ConvertToVariableTable.Invoke($VariablesObject)[0]
                                                      }

                                                  {($_ -eq $True)}
                                                      {
                                                          $ConvertToVariableTable.Invoke($Null)[0]
                                                      }
                                              }

                                          $VariablesContent = $Null

                                          Switch ($VariableTable.Count -gt 0)
                                              {
                                                  {($_ -eq $True)}
                                                      {
                                                          $VariableNameList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                              $VariableTable.Keys | ForEach-Object {$VariableNameList.Add("$($_)")}
                                                              $VariableNameList.Sort([System.StringComparer]::OrdinalIgnoreCase)

                                                          $VariableDictionary = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'

                                                          For ($VariableIndex = 0; $VariableIndex -lt $VariableNameList.Count; $VariableIndex++)
                                                              {
                                                                  $VariableDictionary[$VariableNameList[$VariableIndex]] = $VariableTable[$VariableNameList[$VariableIndex]]
                                                              }

                                                          $VariablesContent = ConvertTo-Json -InputObject ($VariableDictionary) -Depth 2

                                                          $LogMessage.Invoke("Task sequence variables ($($VariableNameList.Count)): $($VariableNameList -Join ', '). Values are not logged.", 'INFO')
                                                      }

                                                  {($_ -eq $False)}
                                                      {
                                                          $LogMessage.Invoke('No task sequence variables were given.', 'INFO')
                                                      }
                                              }

                                        #Task definition: load the template and set every value with XPath
                                          $TaskDefinitionDocument = New-Object -TypeName 'System.Xml.XmlDocument'
                                              $TaskDefinitionDocument.LoadXml($TaskDefinitionTemplate)

                                          $TaskNamespaceManager = New-Object -TypeName 'System.Xml.XmlNamespaceManager' -ArgumentList @($TaskDefinitionDocument.NameTable)
                                              $TaskNamespaceManager.AddNamespace('t', $TaskDefinitionDocument.DocumentElement.NamespaceURI)

                                          $TaskArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                              $TaskArgumentList.Add('-ExecutionPolicy Bypass')
                                              $TaskArgumentList.Add('-NoProfile')
                                              $TaskArgumentList.Add('-NonInteractive')
                                              $TaskArgumentList.Add('-NoLogo')
                                              $TaskArgumentList.Add('-WindowStyle Hidden')
                                              $TaskArgumentList.Add("-File `"$($ScriptDevicePath.FullName)`"")
                                              $TaskArgumentList.Add('-Bootstrap')
                                              $TaskArgumentList.Add("-BootstrapUri `"$($ResolvedBootstrapUri.OriginalString)`"")

                                          Switch ($RemoveVariablesAfterUse -eq $True)
                                              {
                                                  {($_ -eq $True)}
                                                      {
                                                          $TaskArgumentList.Add('-RemoveVariablesAfterUse')
                                                      }
                                              }

                                          $TaskNodeValueTable = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                              $TaskNodeValueTable['/t:Task/t:RegistrationInfo/t:Author'] = "$($ScriptFileInfo.Name)"
                                              $TaskNodeValueTable['/t:Task/t:RegistrationInfo/t:Description'] = "Runs the DeployR bootstrap for task sequence $($TaskSequenceID) from $($DeployRServerBuilder.Host). Staged in $($Destination.FullName) by $($ScriptFileInfo.Name)."
                                              $TaskNodeValueTable['/t:Task/t:RegistrationInfo/t:URI'] = $TaskPath
                                              $TaskNodeValueTable['/t:Task/t:Settings/t:ExecutionTimeLimit'] = [System.Xml.XmlConvert]::ToString($ExecutionTimeLimit)
                                              $TaskNodeValueTable['/t:Task/t:Actions/t:Exec/t:Command'] = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
                                              $TaskNodeValueTable['/t:Task/t:Actions/t:Exec/t:Arguments'] = $TaskArgumentList -Join ' '
                                              $TaskNodeValueTable['/t:Task/t:Actions/t:Exec/t:WorkingDirectory'] = $Destination.FullName

                                          ForEach ($TaskNodeValue In $TaskNodeValueTable.GetEnumerator())
                                              {
                                                  $SetXmlNodeText.Invoke($TaskDefinitionDocument, $TaskNamespaceManager, $TaskNodeValue.Key, $TaskNodeValue.Value)
                                              }

                                          $TriggersNode = $TaskDefinitionDocument.SelectSingleNode('/t:Task/t:Triggers', $TaskNamespaceManager)

                                          Switch ($Trigger)
                                              {
                                                  {($_ -iin @('AtStartup'))}
                                                      {
                                                          $TriggerNode = $AddXmlElement.Invoke($TaskDefinitionDocument, $TriggersNode, 'BootTrigger', $Null)[0]
                                                          $Null = $AddXmlElement.Invoke($TaskDefinitionDocument, $TriggerNode, 'Enabled', 'true')
                                                          $Null = $AddXmlElement.Invoke($TaskDefinitionDocument, $TriggerNode, 'Delay', 'PT5M')
                                                      }

                                                  {($_ -iin @('Once'))}
                                                      {
                                                          $TriggerNode = $AddXmlElement.Invoke($TaskDefinitionDocument, $TriggersNode, 'TimeTrigger', $Null)[0]
                                                          $Null = $AddXmlElement.Invoke($TaskDefinitionDocument, $TriggerNode, 'StartBoundary', $StartTime.ToString('yyyy-MM-ddTHH:mm:ss'))
                                                          $Null = $AddXmlElement.Invoke($TaskDefinitionDocument, $TriggerNode, 'Enabled', 'true')
                                                      }
                                              }

                                          $LogMessage.Invoke("Task action: $($TaskNodeValueTable['/t:Task/t:Actions/t:Exec/t:Command']) $($TaskNodeValueTable['/t:Task/t:Actions/t:Exec/t:Arguments'])", 'INFO')

                                          #schtasks.exe /XML expects UTF-16, which the declaration in the template gives on save
                                            $TaskDefinitionTemporaryPath = [System.IO.FileInfo][System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$($ScriptFileInfo.BaseName)_$([System.Guid]::NewGuid().ToString('N')).xml")

                                            $TaskDefinitionDocument.Save($TaskDefinitionTemporaryPath.FullName)
                                    }
                            }

                        #Access to the destination: SYSTEM and Administrators only, because the variables can carry secrets
                          $DirectorySecurity = New-Object -TypeName 'System.Security.AccessControl.DirectorySecurity'
                              $DirectorySecurity.SetAccessRuleProtection($True, $False)

                          $TrustedSidList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                              $TrustedSidList.Add('S-1-5-18')
                              $TrustedSidList.Add('S-1-5-32-544')

                          For ($TrustedSidIndex = 0; $TrustedSidIndex -lt $TrustedSidList.Count; $TrustedSidIndex++)
                              {
                                  $TrustedIdentity = New-Object -TypeName 'System.Security.Principal.SecurityIdentifier' -ArgumentList @($TrustedSidList[$TrustedSidIndex])

                                  $AccessRule = New-Object -TypeName 'System.Security.AccessControl.FileSystemAccessRule' -ArgumentList @($TrustedIdentity, [System.Security.AccessControl.FileSystemRights]::FullControl, ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit), [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)

                                  $DirectorySecurity.AddAccessRule($AccessRule)
                              }

                        $DeviceResultList = New-Object -TypeName 'System.Collections.Generic.List[PSObject]'

                        For ($ComputerIndex = 0; $ComputerIndex -lt $ComputerName.Count; $ComputerIndex++)
                            {
                                $Computer = $ComputerName[$ComputerIndex].Trim()

                                Write-Progress -Activity 'DeployR bootstrap task' -Status "$($Computer) ($($ComputerIndex + 1) of $($ComputerName.Count))" -PercentComplete ((($ComputerIndex) / $ComputerName.Count) * 100)

                                $DeviceResultProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
                                    $DeviceResultProperties.ComputerName = $Computer
                                    $DeviceResultProperties.Action = $ParameterSetName
                                    $DeviceResultProperties.TaskPath = $TaskPath
                                    $DeviceResultProperties.Destination = $Destination.FullName
                                    $DeviceResultProperties.Staged = $False
                                    $DeviceResultProperties.Registered = $False
                                    $DeviceResultProperties.Started = $False
                                    $DeviceResultProperties.Removed = $False
                                    $DeviceResultProperties.Successful = $False
                                    $DeviceResultProperties.Message = $Null

                                Try
                                    {
                                        $IsLocalComputer = $Computer -iin $LocalComputerNameList

                                        $SchtasksTargetArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'

                                        Switch ($IsLocalComputer)
                                            {
                                                {($_ -eq $True)}
                                                    {
                                                        $StagingDirectory = [System.IO.DirectoryInfo]$Destination.FullName
                                                    }

                                                {($_ -eq $False)}
                                                    {
                                                        $StagingDirectory = [System.IO.DirectoryInfo][System.IO.Path]::Combine("\\$($Computer)\$($DestinationDriveLetter)`$", $DestinationRelativePath)

                                                        $SchtasksTargetArgumentList.Add('/S')
                                                        $SchtasksTargetArgumentList.Add("`"$($Computer)`"")
                                                    }
                                            }

                                        $LogMessage.Invoke("[$($Computer)] Staging directory: $($StagingDirectory.FullName)", 'INFO')

                                        Switch (($IsLocalComputer -eq $True) -and ($IsElevated -eq $False) -and (($ParameterSetName -iin @('Remove')) -or ($StageOnly -eq $False)))
                                            {
                                                {($_ -eq $True)}
                                                    {
                                                        Throw 'Registering or removing a SYSTEM task on this device needs an elevated session.'
                                                    }
                                            }

                                        #Does the task exist already?
                                          $TaskExists = $False

                                          Switch (($ParameterSetName -iin @('Remove')) -or ($StageOnly -eq $False))
                                              {
                                                  {($_ -eq $True)}
                                                      {
                                                          $QueryArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                              $QueryArgumentList.AddRange($SchtasksTargetArgumentList)
                                                              $QueryArgumentList.Add('/Query')
                                                              $QueryArgumentList.Add('/TN')
                                                              $QueryArgumentList.Add("`"$($TaskPath)`"")

                                                          $QueryResult = $InvokeProcess.Invoke($SchtasksPath, $QueryArgumentList, @(0, 1))[0]

                                                          Switch (($QueryResult.Successful -eq $False) -or (($QueryResult.ExitCode -ne 0) -and ($QueryResult.StandardError -inotmatch '(cannot find|does not exist)')))
                                                              {
                                                                  {($_ -eq $True)}
                                                                      {
                                                                          Throw "Unable to query scheduled tasks. schtasks.exe exit code $($QueryResult.ExitCode): $($QueryResult.StandardError)"
                                                                      }
                                                              }

                                                          $TaskExists = $QueryResult.ExitCode -eq 0

                                                          $LogMessage.Invoke("[$($Computer)] Task exists: $($TaskExists)", 'INFO')
                                                      }
                                              }

                                        Switch ($ParameterSetName)
                                            {
                                                {($_ -iin @('Create'))}
                                                    {
                                                        Switch (($TaskExists -eq $True) -and ($Force -eq $False))
                                                            {
                                                                {($_ -eq $True)}
                                                                    {
                                                                        $DeviceResultProperties.Registered = $True
                                                                        $DeviceResultProperties.Successful = $True
                                                                        $DeviceResultProperties.Message = 'The task exists already and was left as it is. Use -Force to replace it.'

                                                                        $LogMessage.Invoke("[$($Computer)] $($DeviceResultProperties.Message)", 'INFO')
                                                                    }

                                                                {($_ -eq $False)}
                                                                    {
                                                                        #Create the destination when it does not exist, and restrict it before anything sensitive is written to it
                                                                          Switch ([System.IO.Directory]::Exists($StagingDirectory.FullName))
                                                                              {
                                                                                  {($_ -eq $False)}
                                                                                      {
                                                                                          $Null = [System.IO.Directory]::CreateDirectory($StagingDirectory.FullName)

                                                                                          $LogMessage.Invoke("[$($Computer)] Created $($StagingDirectory.FullName)", 'INFO')
                                                                                      }
                                                                              }

                                                                          $Null = Set-Acl -LiteralPath ($StagingDirectory.FullName) -AclObject ($DirectorySecurity)

                                                                        $ScriptStagingPath = [System.IO.FileInfo][System.IO.Path]::Combine($StagingDirectory.FullName, $ScriptFileInfo.Name)
                                                                        $VariablesStagingPath = [System.IO.FileInfo][System.IO.Path]::Combine($StagingDirectory.FullName, $VariablesFileName)
                                                                        $TaskDefinitionStagingPath = [System.IO.FileInfo][System.IO.Path]::Combine($StagingDirectory.FullName, $TaskDefinitionFileName)

                                                                        $StagedFileList = New-Object -TypeName 'System.Collections.Generic.List[String]'

                                                                        #Copy this script, unless it is already running from the destination
                                                                          Switch ([System.String]::Equals($ScriptFileInfo.FullName, $ScriptStagingPath.FullName, [System.StringComparison]::OrdinalIgnoreCase))
                                                                              {
                                                                                  {($_ -eq $False)}
                                                                                      {
                                                                                          [System.IO.File]::Copy($ScriptFileInfo.FullName, $ScriptStagingPath.FullName, $True)

                                                                                          $StagedFileList.Add($ScriptFileInfo.Name)
                                                                                      }
                                                                              }

                                                                        Switch ($Null -ine $VariablesContent)
                                                                            {
                                                                                {($_ -eq $True)}
                                                                                    {
                                                                                        [System.IO.File]::WriteAllText($VariablesStagingPath.FullName, $VariablesContent, $Utf8NoBom)

                                                                                        $StagedFileList.Add($VariablesFileName)
                                                                                    }

                                                                                {($_ -eq $False) -and ([System.IO.File]::Exists($VariablesStagingPath.FullName) -eq $True)}
                                                                                    {
                                                                                        #No variables this time: do not leave the previous ones for the next run
                                                                                          [System.IO.File]::Delete($VariablesStagingPath.FullName)
                                                                                    }
                                                                            }

                                                                        Switch ($StageOnly -eq $True)
                                                                            {
                                                                                {($_ -eq $True)}
                                                                                    {
                                                                                        [System.IO.File]::Copy($TaskDefinitionTemporaryPath.FullName, $TaskDefinitionStagingPath.FullName, $True)

                                                                                        $StagedFileList.Add($TaskDefinitionFileName)
                                                                                    }

                                                                                {($_ -eq $False) -and ([System.IO.File]::Exists($TaskDefinitionStagingPath.FullName) -eq $True)}
                                                                                    {
                                                                                        [System.IO.File]::Delete($TaskDefinitionStagingPath.FullName)
                                                                                    }
                                                                            }

                                                                        $DeviceResultProperties.Staged = $True

                                                                        $LogMessage.Invoke("[$($Computer)] Staged: $($StagedFileList -Join ', ')", 'INFO')

                                                                        Switch ($StageOnly -eq $True)
                                                                            {
                                                                                {($_ -eq $False)}
                                                                                    {
                                                                                        $CreateArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                                                            $CreateArgumentList.AddRange($SchtasksTargetArgumentList)
                                                                                            $CreateArgumentList.Add('/Create')
                                                                                            $CreateArgumentList.Add('/XML')
                                                                                            $CreateArgumentList.Add("`"$($TaskDefinitionTemporaryPath.FullName)`"")
                                                                                            $CreateArgumentList.Add('/TN')
                                                                                            $CreateArgumentList.Add("`"$($TaskPath)`"")
                                                                                            $CreateArgumentList.Add('/F')

                                                                                        $CreateResult = $InvokeProcess.Invoke($SchtasksPath, $CreateArgumentList, @(0))[0]

                                                                                        Switch ($CreateResult.Successful)
                                                                                            {
                                                                                                {($_ -eq $False)}
                                                                                                    {
                                                                                                        Throw "Unable to register the task. schtasks.exe exit code $($CreateResult.ExitCode): $($CreateResult.StandardError)"
                                                                                                    }
                                                                                            }

                                                                                        $DeviceResultProperties.Registered = $True

                                                                                        $LogMessage.Invoke("[$($Computer)] Registered $($TaskPath) ($($Trigger) trigger)", 'INFO')
                                                                                    }
                                                                            }

                                                                        $DeviceResultProperties.Successful = $True
                                                                    }
                                                            }

                                                        Switch (($Execute -eq $True) -and ($StageOnly -eq $False))
                                                            {
                                                                {($_ -eq $True)}
                                                                    {
                                                                        $RunArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                                            $RunArgumentList.AddRange($SchtasksTargetArgumentList)
                                                                            $RunArgumentList.Add('/Run')
                                                                            $RunArgumentList.Add('/TN')
                                                                            $RunArgumentList.Add("`"$($TaskPath)`"")

                                                                        $RunResult = $InvokeProcess.Invoke($SchtasksPath, $RunArgumentList, @(0))[0]

                                                                        Switch ($RunResult.Successful)
                                                                            {
                                                                                {($_ -eq $False)}
                                                                                    {
                                                                                        Throw "The task is registered but could not be started. schtasks.exe exit code $($RunResult.ExitCode): $($RunResult.StandardError)"
                                                                                    }
                                                                            }

                                                                        $DeviceResultProperties.Started = $True

                                                                        $LogMessage.Invoke("[$($Computer)] Started $($TaskPath)", 'INFO')
                                                                    }
                                                            }
                                                    }

                                                {($_ -iin @('Remove'))}
                                                    {
                                                        Switch ($TaskExists)
                                                            {
                                                                {($_ -eq $True)}
                                                                    {
                                                                        $DeleteArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                                            $DeleteArgumentList.AddRange($SchtasksTargetArgumentList)
                                                                            $DeleteArgumentList.Add('/Delete')
                                                                            $DeleteArgumentList.Add('/TN')
                                                                            $DeleteArgumentList.Add("`"$($TaskPath)`"")
                                                                            $DeleteArgumentList.Add('/F')

                                                                        $DeleteResult = $InvokeProcess.Invoke($SchtasksPath, $DeleteArgumentList, @(0))[0]

                                                                        Switch ($DeleteResult.Successful)
                                                                            {
                                                                                {($_ -eq $False)}
                                                                                    {
                                                                                        Throw "Unable to remove the task. schtasks.exe exit code $($DeleteResult.ExitCode): $($DeleteResult.StandardError)"
                                                                                    }
                                                                            }

                                                                        $LogMessage.Invoke("[$($Computer)] Removed $($TaskPath)", 'INFO')
                                                                    }
                                                            }

                                                        #Never delete the directory this script is running from
                                                          Switch (([System.IO.Directory]::Exists($StagingDirectory.FullName) -eq $True) -and ([System.String]::Equals($ScriptFileInfo.Directory.FullName.TrimEnd('\'), $StagingDirectory.FullName.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -eq $False))
                                                              {
                                                                  {($_ -eq $True)}
                                                                      {
                                                                          [System.IO.Directory]::Delete($StagingDirectory.FullName, $True)

                                                                          $LogMessage.Invoke("[$($Computer)] Removed $($StagingDirectory.FullName)", 'INFO')
                                                                      }
                                                              }

                                                        $DeviceResultProperties.Removed = $True
                                                        $DeviceResultProperties.Successful = $True
                                                    }
                                            }
                                    }
                                Catch
                                    {
                                        $HandleError.Invoke($_.Exception, "Device $($Computer)")

                                        $DeviceResultProperties.Successful = $False
                                        $DeviceResultProperties.Message = $_.Exception.Message
                                    }

                                $DeviceResultList.Add((New-Object -TypeName 'System.Management.Automation.PSObject' -Property ($DeviceResultProperties)))
                            }

                        Write-Progress -Activity 'DeployR bootstrap task' -Completed

                        $FailedDeviceList = New-Object -TypeName 'System.Collections.Generic.List[PSObject]'
                            $DeviceResultList | Where-Object {($_.Successful -eq $False)} | ForEach-Object {$FailedDeviceList.Add($_)}

                        Switch ($FailedDeviceList.Count -gt 0)
                            {
                                {($_ -eq $True)}
                                    {
                                        [System.Environment]::ExitCode = 2

                                        $LogMessage.Invoke("$($FailedDeviceList.Count) of $($DeviceResultList.Count) device(s) did not complete: $(($FailedDeviceList | ForEach-Object {$_.ComputerName}) -Join ', ')", 'WARN')
                                    }

                                {($_ -eq $False)}
                                    {
                                        $LogMessage.Invoke("All $($DeviceResultList.Count) device(s) completed.", 'INFO')
                                    }
                            }

                        Write-Output -InputObject ($DeviceResultList)
                    }
            }
    }
Catch
    {
        $HandleError.Invoke($_.Exception, "$($ParameterSetName) mode")

        [System.Environment]::ExitCode = 1
    }
Finally
    {
        Switch (($Null -ine $TaskDefinitionTemporaryPath) -and ([System.IO.File]::Exists($TaskDefinitionTemporaryPath.FullName) -eq $True))
            {
                {($_ -eq $True)}
                    {
                        $Null = Try {[System.IO.File]::Delete($TaskDefinitionTemporaryPath.FullName)} Catch {}
                    }
            }

        $LogMessage.Invoke("$($ScriptFileInfo.Name) finished with exit code $([System.Environment]::ExitCode)", 'INFO')

        $Null = Try {Stop-Transcript} Catch {}

        Switch ([System.Diagnostics.Process]::GetCurrentProcess().ProcessName -imatch '^(powershell|pwsh)(\.exe)?$')
            {
                {($_ -eq $True)}
                    {
                        [System.Environment]::Exit([System.Environment]::ExitCode)
                    }
            }
    }
