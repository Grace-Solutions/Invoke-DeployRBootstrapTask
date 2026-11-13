#Requires -Version 5.1

<#
.SYNOPSIS
    Stages a DeployR bootstrap on one or more devices and registers a scheduled task that runs it as SYSTEM.

.DESCRIPTION
    Starting a DeployR task sequence in an existing operating system is documented as an elevated PowerShell call to the
    Bootstrap endpoint of the DeployR server, with an optional hashtable of task sequence variables set first:

        $DeployRBootstrap = @{ MyRole = 'Accounting' }
        iex (irm 'https://server:7281/v1/Service/Bootstrap?tsid=<GUID>:<Version>')

    This script turns that call into something that can be placed on a device and run unattended, for example to run a
    task sequence that pre-stages content ahead of a deployment:

    1. A launcher script (Start-DeployRBootstrap.ps1) is generated with the bootstrap URL baked in.
    2. The optional hashtable is written next to it as JSON (DeployRBootstrap.json).
    3. Both are copied to the destination directory on each device, which is restricted to SYSTEM and Administrators
       because task sequence variables can carry secrets.
    4. A scheduled task is registered that runs the launcher as SYSTEM through Windows PowerShell, which is always
       present. The bootstrap installs .NET and PowerShell 7 from the DeployR server when they are missing.
    5. Optionally, the task is started straight away.

    Remote devices are reached through their administrative share and schtasks.exe /S, using the current credentials.

    The task runs as SYSTEM with nobody to answer a prompt, so a task sequence ID is required: without one the DeployR
    client waits for someone to choose a task sequence. The task sequence must not restart the device.

.PARAMETER DeployRServer
    The DeployR server, with scheme, for example https://deployr.contoso.com:7281. When no port is given, 7281 is used.

.PARAMETER TaskSequenceID
    The task sequence to run, as <GUID>:<Version>, for example 00000002-0000-0000-0000-000000000001:1.

.PARAMETER Variables
    Optional task sequence variables, as a hashtable of names and values. Values are passed to DeployR as strings.
    Variable names are written to the logs, values never are.

.PARAMETER ComputerName
    The devices to stage and register the task on. Defaults to the local device.

.PARAMETER Destination
    The local path on each device that receives the launcher and the variables. Defaults to
    %ProgramData%\2Pint\DeployRBootstrap. Remote devices are reached through the administrative share of the same drive.

.PARAMETER TaskFolder
    The Task Scheduler folder for the task. Defaults to \2Pint.

.PARAMETER TaskName
    The scheduled task name. Defaults to DeployR Bootstrap.

.PARAMETER Trigger
    When the task runs on its own: None (on demand only, the default), AtStartup, or Once at StartTime.

.PARAMETER StartTime
    The local date and time for the Once trigger.

.PARAMETER ExecutionTimeLimit
    How long the task may run before Task Scheduler stops it. Defaults to 8 hours, to allow for large content.

.PARAMETER RemoveVariablesAfterUse
    Deletes the variables file from the device as soon as the launcher has read it. Use it when the variables carry
    secrets and the task is only meant to run once.

.PARAMETER Execute
    Starts the task as soon as it is registered.

.PARAMETER Force
    Replaces an existing task with the same name. Without it, a device that already has the task is skipped.

.PARAMETER StageOnly
    Stages the launcher, the variables and the task definition (DeployRBootstrapTask.xml) without registering the task,
    for packaging with another tool.

.PARAMETER Remove
    Removes the task and the destination directory from each device.

.PARAMETER LogDirectory
    Where this script writes its transcript. Defaults to %SystemRoot%\Logs\Software\<script name>.

.EXAMPLE
    $Variables = @{ PRESTAGEONLY = 'True'; SITE = 'NYC01' }

    .\Invoke-DeployRBootstrapTask.ps1 -DeployRServer 'https://deployr.contoso.com:7281' -TaskSequenceID '00000002-0000-0000-0000-000000000001:1' -Variables $Variables -Execute -Force

    Stages the bootstrap with two task sequence variables on this device, registers the task and starts it.

.EXAMPLE
    $InvokeDeployRBootstrapTaskParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
        $InvokeDeployRBootstrapTaskParameters.DeployRServer = 'https://deployr.contoso.com:7281'
        $InvokeDeployRBootstrapTaskParameters.TaskSequenceID = '00000002-0000-0000-0000-000000000001:1'
        $InvokeDeployRBootstrapTaskParameters.Variables = @{ PRESTAGEONLY = 'True' }
        $InvokeDeployRBootstrapTaskParameters.ComputerName = @('NYC-WS-0101', 'NYC-WS-0102')
        $InvokeDeployRBootstrapTaskParameters.Trigger = 'Once'
        $InvokeDeployRBootstrapTaskParameters.StartTime = (Get-Date).Date.AddDays(1).AddHours(1)
        $InvokeDeployRBootstrapTaskParameters.Force = $True

    .\Invoke-DeployRBootstrapTask.ps1 @InvokeDeployRBootstrapTaskParameters

    Stages two remote devices and schedules the pre-stage task sequence for 01:00 tomorrow, device local time.

.EXAMPLE
    .\Invoke-DeployRBootstrapTask.ps1 -Remove -ComputerName 'NYC-WS-0101'

    Removes the task and the staged files from a remote device.

.NOTES
    Exit codes: 0 every device succeeded, 1 the script failed, 2 one or more devices failed.

    The task runs Windows PowerShell with -ExecutionPolicy Bypass. An execution policy forced by Group Policy
    (MachinePolicy) takes precedence over the command line; the launcher then has to be signed.

    The device must trust the DeployR server certificate. With the 2Pint self-signed certificate, its root CA has to
    be in the device's Trusted Root Certification Authorities store first.

    The bootstrap writes its own log to %SystemRoot%\Temp; DeployR logs go to C:\_2P\Logs once the task sequence starts.
    The launcher writes its transcript to %SystemRoot%\Logs\Software\Start-DeployRBootstrap.

.LINK
    https://documentation.2pintsoftware.com/deployr/deployment-methods/starting-a-task-sequence-in-an-existing-os
#>

[CmdletBinding(DefaultParameterSetName = 'Create')]
Param
    (
        [Parameter(Mandatory = $True, ParameterSetName = 'Create')]
        [ValidateScript({($_.IsAbsoluteUri -eq $True) -and ($_.Scheme -iin @('https', 'http'))})]
        [System.Uri]$DeployRServer,

        [Parameter(Mandatory = $True, ParameterSetName = 'Create')]
        [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}:\d+$')]
        [String]$TaskSequenceID,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [AllowNull()]
        [Alias('DeployRBootstrap')]
        [System.Collections.Hashtable]$Variables,

        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrEmpty()]
        [String[]]$ComputerName = @("$($Env:ComputerName)"),

        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrEmpty()]
        [System.IO.DirectoryInfo]$Destination = [System.IO.Path]::Combine("$($Env:ProgramData)", '2Pint', 'DeployRBootstrap'),

        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({$_.StartsWith('\')})]
        [String]$TaskFolder = '\2Pint',

        [Parameter(Mandatory = $False)]
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
        [Switch]$RemoveVariablesAfterUse,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Switch]$Execute,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Switch]$Force,

        [Parameter(Mandatory = $False, ParameterSetName = 'Create')]
        [Switch]$StageOnly,

        [Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
        [Switch]$Remove,

        [Parameter(Mandatory = $False)]
        [System.IO.DirectoryInfo]$LogDirectory
    )

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
[System.Environment]::ExitCode = 0

$ScriptFileInfo = [System.IO.FileInfo]$MyInvocation.MyCommand.Path

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

$EscapeSingleQuoted = {
    Param
        (
            [String]$Value
        )

    "$($Value)".Replace("'", "''")
}

$EscapeXml = {
    Param
        (
            [String]$Value
        )

    [System.Security.SecurityElement]::Escape("$($Value)")
}

Try
    {
        Switch ([System.IO.Directory]::Exists($LogDirectory.FullName))
            {
                {($_ -eq $False)}
                    {
                        $Null = [System.IO.Directory]::CreateDirectory($LogDirectory.FullName)
                    }
            }

        $TranscriptFileList = New-Object -TypeName 'System.Collections.Generic.List[System.IO.FileInfo]'
            $LogDirectory.Refresh()
            $LogDirectory.GetFiles("$($ScriptFileInfo.BaseName)*.log") | Sort-Object -Property @('CreationTimeUtc') -Descending | ForEach-Object {$TranscriptFileList.Add($_)}

        For ($TranscriptFileIndex = 2; $TranscriptFileIndex -lt $TranscriptFileList.Count; $TranscriptFileIndex++)
            {
                $Null = Try {$TranscriptFileList[$TranscriptFileIndex].Delete()} Catch {}
            }

        $TranscriptPath = [System.IO.FileInfo][System.IO.Path]::Combine($LogDirectory.FullName, "$($ScriptFileInfo.BaseName)_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).log")

        $Null = Start-Transcript -Path $TranscriptPath.FullName -Force
    }
Catch
    {
        Write-Warning -Message ("Unable to start the transcript in `"$($LogDirectory.FullName)`": $($_.Exception.Message)")
    }

Try
    {
        $LogMessage.Invoke("$($ScriptFileInfo.Name) started. Parameter set: $($PSCmdlet.ParameterSetName)", 'INFO')
        $LogMessage.Invoke("PowerShell $($PSVersionTable.PSVersion.ToString()) ($($PSVersionTable.PSEdition)) on $($Env:ComputerName)", 'INFO')

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

        #Files staged on each device
          $LauncherFileName = 'Start-DeployRBootstrap.ps1'
          $VariablesFileName = 'DeployRBootstrap.json'
          $TaskDefinitionFileName = 'DeployRBootstrapTask.xml'

        $LauncherDevicePath = [System.IO.FileInfo][System.IO.Path]::Combine($Destination.FullName, $LauncherFileName)
        $VariablesDevicePath = [System.IO.FileInfo][System.IO.Path]::Combine($Destination.FullName, $VariablesFileName)

        $Utf8NoBom = New-Object -TypeName 'System.Text.UTF8Encoding' -ArgumentList @($False)

        Switch ($PSCmdlet.ParameterSetName)
            {
                {($_ -iin @('Create'))}
                    {
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

                          $BootstrapUri = $DeployRServerBuilder.Uri

                        $LogMessage.Invoke("Bootstrap URL: $($BootstrapUri.AbsoluteUri)", 'INFO')

                        #Trigger
                          $TriggerXml = Switch ($Trigger)
                              {
                                  {($_ -iin @('None'))}
                                      {
                                          '<Triggers />'
                                      }

                                  {($_ -iin @('AtStartup'))}
                                      {
                                          '<Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT5M</Delay></BootTrigger></Triggers>'
                                      }

                                  {($_ -iin @('Once'))}
                                      {
                                          Switch ($PSBoundParameters.ContainsKey('StartTime'))
                                              {
                                                  {($_ -eq $False)}
                                                      {
                                                          Throw 'The Once trigger needs -StartTime.'
                                                      }
                                              }

                                          "<Triggers><TimeTrigger><StartBoundary>$($StartTime.ToString('yyyy-MM-ddTHH:mm:ss'))</StartBoundary><Enabled>true</Enabled></TimeTrigger></Triggers>"
                                      }
                              }

                        #Variables, as strings, in name order
                          $VariableDictionary = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'

                          Switch (($Null -ine $Variables) -and ($Variables.Count -gt 0))
                              {
                                  {($_ -eq $True)}
                                      {
                                          $VariableNameList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                              $Variables.Keys | ForEach-Object {$VariableNameList.Add("$($_)")}
                                              $VariableNameList.Sort([System.StringComparer]::OrdinalIgnoreCase)

                                          For ($VariableIndex = 0; $VariableIndex -lt $VariableNameList.Count; $VariableIndex++)
                                              {
                                                  $VariableName = $VariableNameList[$VariableIndex]
                                                  $VariableValue = $Variables[$VariableName]

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

                                                  $VariableDictionary[$VariableName] = Switch ($Null -ieq $VariableValue)
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

                                          $LogMessage.Invoke("Task sequence variables ($($VariableDictionary.Count)): $($VariableNameList -Join ', '). Values are not logged.", 'INFO')
                                      }

                                  {($_ -eq $False)}
                                      {
                                          $LogMessage.Invoke('No task sequence variables were given.', 'INFO')
                                      }
                              }

                        #Launcher: the values are baked into the parameter defaults, the body is fixed
                          $LauncherParameterBlock = @"
#Requires -Version 5.1

<#
.SYNOPSIS
    Starts the DeployR bootstrap with the staged task sequence variables.

.DESCRIPTION
    Generated by $($ScriptFileInfo.Name) on $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC.
    Run $($ScriptFileInfo.Name) again to change it, rather than editing this file.
#>

[CmdletBinding()]
Param
    (
        [System.Uri]`$BootstrapUri = '$($EscapeSingleQuoted.Invoke($BootstrapUri.AbsoluteUri))',

        [System.IO.FileInfo]`$VariablesPath = '$($EscapeSingleQuoted.Invoke($VariablesDevicePath.FullName))',

        [System.IO.DirectoryInfo]`$LogDirectory = [System.IO.Path]::Combine("`$(`$Env:SystemRoot)", 'Logs', 'Software', 'Start-DeployRBootstrap'),

        [Boolean]`$RemoveVariablesAfterUse = `$$($RemoveVariablesAfterUse.IsPresent)
    )

"@

                          $LauncherBody = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[System.Environment]::ExitCode = 0

$ScriptFileInfo = [System.IO.FileInfo]$MyInvocation.MyCommand.Path

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

Try
    {
        Switch ([System.IO.Directory]::Exists($LogDirectory.FullName))
            {
                {($_ -eq $False)}
                    {
                        $Null = [System.IO.Directory]::CreateDirectory($LogDirectory.FullName)
                    }
            }

        $TranscriptFileList = New-Object -TypeName 'System.Collections.Generic.List[System.IO.FileInfo]'
            $LogDirectory.Refresh()
            $LogDirectory.GetFiles("$($ScriptFileInfo.BaseName)*.log") | Sort-Object -Property @('CreationTimeUtc') -Descending | ForEach-Object {$TranscriptFileList.Add($_)}

        For ($TranscriptFileIndex = 2; $TranscriptFileIndex -lt $TranscriptFileList.Count; $TranscriptFileIndex++)
            {
                $Null = Try {$TranscriptFileList[$TranscriptFileIndex].Delete()} Catch {}
            }

        $TranscriptPath = [System.IO.FileInfo][System.IO.Path]::Combine($LogDirectory.FullName, "$($ScriptFileInfo.BaseName)_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).log")

        $Null = Start-Transcript -Path $TranscriptPath.FullName -Force
    }
Catch
    {
        Write-Warning -Message ("Unable to start the transcript in `"$($LogDirectory.FullName)`": $($_.Exception.Message)")
    }

Try
    {
        $LogMessage.Invoke("$($ScriptFileInfo.Name) started as $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) on PowerShell $($PSVersionTable.PSVersion.ToString())", 'INFO')

        #Windows PowerShell does not offer TLS 1.2 by default
          [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        #The documented name for the task sequence variables passed to the bootstrap
          $DeployRBootstrap = New-Object -TypeName 'System.Collections.Hashtable' -ArgumentList @([System.StringComparer]::OrdinalIgnoreCase)

        Switch ([System.IO.File]::Exists($VariablesPath.FullName))
            {
                {($_ -eq $True)}
                    {
                        $VariablesContent = [System.IO.File]::ReadAllText($VariablesPath.FullName)

                        $VariablesObject = ConvertFrom-Json -InputObject ($VariablesContent)

                        ForEach ($VariableProperty In $VariablesObject.PSObject.Properties)
                            {
                                $DeployRBootstrap[$VariableProperty.Name] = "$($VariableProperty.Value)"
                            }

                        $LogMessage.Invoke("Loaded $($DeployRBootstrap.Count) task sequence variable(s) from `"$($VariablesPath.FullName)`": $(($DeployRBootstrap.Keys | Sort-Object) -Join ', '). Values are not logged.", 'INFO')

                        Switch ($RemoveVariablesAfterUse)
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

        $LogMessage.Invoke("Requesting the bootstrap from $($BootstrapUri.AbsoluteUri)", 'INFO')

        $BootstrapContent = Invoke-RestMethod -Uri ($BootstrapUri.AbsoluteUri) -Method Get -UseBasicParsing

        Switch ([String]::IsNullOrWhiteSpace("$($BootstrapContent)"))
            {
                {($_ -eq $True)}
                    {
                        Throw "The DeployR server returned an empty bootstrap from $($BootstrapUri.AbsoluteUri)."
                    }
            }

        $LogMessage.Invoke('Running the bootstrap. Its own log is written to the Windows Temp directory; DeployR logs to C:\_2P\Logs once the task sequence starts.', 'INFO')

        Invoke-Expression -Command ("$($BootstrapContent)")

        $LogMessage.Invoke('The bootstrap returned.', 'INFO')
    }
Catch
    {
        $HandleError.Invoke($_.Exception, 'DeployR bootstrap')

        [System.Environment]::ExitCode = 1
    }
Finally
    {
        $LogMessage.Invoke("Finished with exit code $([System.Environment]::ExitCode)", 'INFO')

        $Null = Try {Stop-Transcript} Catch {}

        Switch ([System.Diagnostics.Process]::GetCurrentProcess().ProcessName -imatch '^(powershell|pwsh)(\.exe)?$')
            {
                {($_ -eq $True)}
                    {
                        [System.Environment]::Exit([System.Environment]::ExitCode)
                    }
            }
    }
'@

                          $LauncherContent = "$($LauncherParameterBlock)$([System.Environment]::NewLine)$([System.Environment]::NewLine)$($LauncherBody)$([System.Environment]::NewLine)"

                        $VariablesContent = Switch ($VariableDictionary.Count -gt 0)
                            {
                                {($_ -eq $True)}
                                    {
                                        ConvertTo-Json -InputObject ($VariableDictionary) -Depth 2
                                    }

                                {($_ -eq $False)}
                                    {
                                        $Null
                                    }
                            }

                        #Task definition
                          $PowerShellPath = [System.IO.FileInfo][System.IO.Path]::Combine('%SystemRoot%', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')

                          $TaskArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                              $TaskArgumentList.Add('-ExecutionPolicy Bypass')
                              $TaskArgumentList.Add('-NoProfile')
                              $TaskArgumentList.Add('-NonInteractive')
                              $TaskArgumentList.Add('-NoLogo')
                              $TaskArgumentList.Add('-WindowStyle Hidden')
                              $TaskArgumentList.Add("-File `"$($LauncherDevicePath.FullName)`"")

                          $TaskDefinition = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>$($EscapeXml.Invoke($ScriptFileInfo.Name))</Author>
    <Description>$($EscapeXml.Invoke("Runs the DeployR bootstrap for task sequence $($TaskSequenceID) from $($DeployRServerBuilder.Host). Staged in $($Destination.FullName) by $($ScriptFileInfo.Name)."))</Description>
    <URI>$($EscapeXml.Invoke($TaskPath))</URI>
  </RegistrationInfo>
  $($TriggerXml)
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
    <ExecutionTimeLimit>$([System.Xml.XmlConvert]::ToString($ExecutionTimeLimit))</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$($EscapeXml.Invoke($PowerShellPath.ToString()))</Command>
      <Arguments>$($EscapeXml.Invoke(($TaskArgumentList -Join ' ')))</Arguments>
      <WorkingDirectory>$($EscapeXml.Invoke($Destination.FullName))</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

                          #Fail here, once, rather than on every device
                            $TaskDefinitionDocument = New-Object -TypeName 'System.Xml.XmlDocument'
                                $TaskDefinitionDocument.LoadXml($TaskDefinition.Substring($TaskDefinition.IndexOf('<Task ')))

                          $TaskDefinitionTemporaryPath = [System.IO.FileInfo][System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$($ScriptFileInfo.BaseName)_$([System.Guid]::NewGuid().ToString('N')).xml")

                          #schtasks.exe /XML expects UTF-16
                            [System.IO.File]::WriteAllText($TaskDefinitionTemporaryPath.FullName, $TaskDefinition, [System.Text.Encoding]::Unicode)
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
                    $DeviceResultProperties.Action = $PSCmdlet.ParameterSetName
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

                        Switch ($True)
                            {
                                {($IsLocalComputer -eq $True) -and ($IsElevated -eq $False) -and (($PSCmdlet.ParameterSetName -iin @('Remove')) -or ($StageOnly.IsPresent -eq $False))}
                                    {
                                        Throw 'Registering or removing a SYSTEM task on this device needs an elevated session.'
                                    }
                            }

                        #Does the task exist already?
                          $QueryArgumentList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                              $QueryArgumentList.AddRange($SchtasksTargetArgumentList)
                              $QueryArgumentList.Add('/Query')
                              $QueryArgumentList.Add('/TN')
                              $QueryArgumentList.Add("`"$($TaskPath)`"")

                          $TaskExists = $False

                          Switch (($PSCmdlet.ParameterSetName -iin @('Remove')) -or ($StageOnly.IsPresent -eq $False))
                              {
                                  {($_ -eq $True)}
                                      {
                                          $QueryResult = $InvokeProcess.Invoke($SchtasksPath, $QueryArgumentList, @(0, 1))[0]

                                          Switch ($QueryResult.Successful)
                                              {
                                                  {($_ -eq $False)}
                                                      {
                                                          Throw "Unable to query scheduled tasks. schtasks.exe exit code $($QueryResult.ExitCode): $($QueryResult.StandardError)"
                                                      }
                                              }

                                          $TaskExists = $QueryResult.ExitCode -eq 0

                                          Switch (($QueryResult.ExitCode -ne 0) -and ($QueryResult.StandardError -inotmatch '(cannot find|does not exist)'))
                                              {
                                                  {($_ -eq $True)}
                                                      {
                                                          Throw "Unable to query scheduled tasks. schtasks.exe exit code $($QueryResult.ExitCode): $($QueryResult.StandardError)"
                                                      }
                                              }

                                          $LogMessage.Invoke("[$($Computer)] Task exists: $($TaskExists)", 'INFO')
                                      }
                              }

                        Switch ($PSCmdlet.ParameterSetName)
                            {
                                {($_ -iin @('Create'))}
                                    {
                                        Switch (($TaskExists -eq $True) -and ($Force.IsPresent -eq $False))
                                            {
                                                {($_ -eq $True)}
                                                    {
                                                        $DeviceResultProperties.Message = 'The task exists already. Use -Force to replace it.'

                                                        $LogMessage.Invoke("[$($Computer)] $($DeviceResultProperties.Message)", 'WARN')
                                                    }

                                                {($_ -eq $False)}
                                                    {
                                                        Switch ([System.IO.Directory]::Exists($StagingDirectory.FullName))
                                                            {
                                                                {($_ -eq $False)}
                                                                    {
                                                                        $Null = [System.IO.Directory]::CreateDirectory($StagingDirectory.FullName)
                                                                    }
                                                            }

                                                        $LauncherStagingPath = [System.IO.FileInfo][System.IO.Path]::Combine($StagingDirectory.FullName, $LauncherFileName)
                                                        $VariablesStagingPath = [System.IO.FileInfo][System.IO.Path]::Combine($StagingDirectory.FullName, $VariablesFileName)
                                                        $TaskDefinitionStagingPath = [System.IO.FileInfo][System.IO.Path]::Combine($StagingDirectory.FullName, $TaskDefinitionFileName)

                                                        #Restrict the directory before anything sensitive is written to it
                                                          $Null = Set-Acl -LiteralPath ($StagingDirectory.FullName) -AclObject ($DirectorySecurity)

                                                        [System.IO.File]::WriteAllText($LauncherStagingPath.FullName, $LauncherContent, $Utf8NoBom)

                                                        Switch ($Null -ine $VariablesContent)
                                                            {
                                                                {($_ -eq $True)}
                                                                    {
                                                                        [System.IO.File]::WriteAllText($VariablesStagingPath.FullName, $VariablesContent, $Utf8NoBom)
                                                                    }

                                                                {($_ -eq $False) -and ([System.IO.File]::Exists($VariablesStagingPath.FullName) -eq $True)}
                                                                    {
                                                                        #No variables this time: do not leave the previous ones for the next run
                                                                          [System.IO.File]::Delete($VariablesStagingPath.FullName)
                                                                    }
                                                            }

                                                        Switch ($StageOnly.IsPresent)
                                                            {
                                                                {($_ -eq $True)}
                                                                    {
                                                                        [System.IO.File]::WriteAllText($TaskDefinitionStagingPath.FullName, $TaskDefinition, [System.Text.Encoding]::Unicode)
                                                                    }

                                                                {($_ -eq $False) -and ([System.IO.File]::Exists($TaskDefinitionStagingPath.FullName) -eq $True)}
                                                                    {
                                                                        [System.IO.File]::Delete($TaskDefinitionStagingPath.FullName)
                                                                    }
                                                            }

                                                        $DeviceResultProperties.Staged = $True

                                                        $StagedFileList = New-Object -TypeName 'System.Collections.Generic.List[String]'
                                                            $StagedFileList.Add($LauncherFileName)

                                                        Switch ($True)
                                                            {
                                                                {($Null -ine $VariablesContent)}
                                                                    {
                                                                        $StagedFileList.Add($VariablesFileName)
                                                                    }

                                                                {($StageOnly.IsPresent -eq $True)}
                                                                    {
                                                                        $StagedFileList.Add($TaskDefinitionFileName)
                                                                    }
                                                            }

                                                        $LogMessage.Invoke("[$($Computer)] Staged: $($StagedFileList -Join ', ')", 'INFO')

                                                        Switch ($StageOnly.IsPresent)
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

                                                                        Switch ($Execute.IsPresent)
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
                                                                                                        Throw "The task was registered but could not be started. schtasks.exe exit code $($RunResult.ExitCode): $($RunResult.StandardError)"
                                                                                                    }
                                                                                            }

                                                                                        $DeviceResultProperties.Started = $True

                                                                                        $LogMessage.Invoke("[$($Computer)] Started $($TaskPath)", 'INFO')
                                                                                    }
                                                                            }
                                                                    }
                                                            }

                                                        $DeviceResultProperties.Successful = $True
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

                                        Switch ([System.IO.Directory]::Exists($StagingDirectory.FullName))
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
Catch
    {
        $HandleError.Invoke($_.Exception, 'Main script execution')

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
