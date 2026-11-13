#Requires -Version 5.1

<#
.SYNOPSIS
    Intune remediation detection for Invoke-DeployRBootstrapTask.ps1.

.DESCRIPTION
    Reports whether the DeployR bootstrap task is registered and its staged script is present.

    Exit code 0: compliant, nothing to do.
    Exit code 1: not compliant, so Intune runs the remediation script (Invoke-DeployRBootstrapTask.ps1).

    Keep the values below the same as the Destination, TaskFolder and TaskName used by the remediation script.

.NOTES
    Version: 2026.11.13.1530

.LINK
    https://github.com/Grace-Solutions/Invoke-DeployRBootstrapTask
#>

[CmdletBinding()]
Param
    (
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrEmpty()]
        [System.IO.DirectoryInfo]$Destination = [System.IO.Path]::Combine("$($Env:ProgramData)", '2Pint', 'DeployRBootstrap'),

        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({$_.StartsWith('\')})]
        [String]$TaskFolder = '\2Pint',

        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrEmpty()]
        [String]$TaskName = 'DeployR Bootstrap'
    )

$ErrorActionPreference = 'Stop'
[System.Environment]::ExitCode = 1

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

Try
    {
        $LogDirectory = [System.IO.DirectoryInfo][System.IO.Path]::Combine("$($Env:SystemRoot)", 'Logs', 'Software', 'Invoke-DeployRBootstrapTask')

        Switch ([System.IO.Directory]::Exists($LogDirectory.FullName))
            {
                {($_ -eq $False)}
                    {
                        $Null = [System.IO.Directory]::CreateDirectory($LogDirectory.FullName)
                    }
            }

        $TranscriptFileList = New-Object -TypeName 'System.Collections.Generic.List[System.IO.FileInfo]'
            $LogDirectory.Refresh()
            $LogDirectory.GetFiles("$($ScriptFileInfo.BaseName)_*.log") | Sort-Object -Property @('CreationTimeUtc') -Descending | ForEach-Object {$TranscriptFileList.Add($_)}

        For ($TranscriptFileIndex = 2; $TranscriptFileIndex -lt $TranscriptFileList.Count; $TranscriptFileIndex++)
            {
                $Null = Try {$TranscriptFileList[$TranscriptFileIndex].Delete()} Catch {}
            }

        $TranscriptPath = [System.IO.FileInfo][System.IO.Path]::Combine($LogDirectory.FullName, "$($ScriptFileInfo.BaseName)_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).log")

        $Null = Start-Transcript -Path $TranscriptPath.FullName -Force
    }
Catch
    {
        Write-Warning -Message ("Unable to start the transcript: $($_.Exception.Message)")
    }

Try
    {
        $TaskFolderPath = Switch ($TaskFolder.TrimEnd('\').Length -eq 0)
            {
                {($_ -eq $True)}
                    {
                        '\'
                    }

                {($_ -eq $False)}
                    {
                        $TaskFolder.TrimEnd('\')
                    }
            }

        $ScheduleService = New-Object -ComObject 'Schedule.Service'
            $ScheduleService.Connect()

        $RegisteredTask = Try {$ScheduleService.GetFolder($TaskFolderPath).GetTask($TaskName)} Catch {$Null}

        $StagedScriptPath = [System.IO.FileInfo][System.IO.Path]::Combine($Destination.FullName, 'Invoke-DeployRBootstrapTask.ps1')

        $CheckProperties = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
            $CheckProperties.TaskRegistered = $Null -ine $RegisteredTask
            $CheckProperties.ScriptStaged = [System.IO.File]::Exists($StagedScriptPath.FullName)

        $LogMessage.Invoke("Task $($TaskFolderPath.TrimEnd('\'))\$($TaskName) registered: $($CheckProperties.TaskRegistered)", 'INFO')
        $LogMessage.Invoke("Script staged at $($StagedScriptPath.FullName): $($CheckProperties.ScriptStaged)", 'INFO')

        Switch (($CheckProperties.TaskRegistered -eq $True) -and ($CheckProperties.ScriptStaged -eq $True))
            {
                {($_ -eq $True)}
                    {
                        [System.Environment]::ExitCode = 0

                        Write-Output -InputObject ('Compliant: the DeployR bootstrap task is registered and staged.')
                    }

                {($_ -eq $False)}
                    {
                        [System.Environment]::ExitCode = 1

                        Write-Output -InputObject ("Not compliant: task registered $($CheckProperties.TaskRegistered), script staged $($CheckProperties.ScriptStaged).")
                    }
            }
    }
Catch
    {
        $LogMessage.Invoke("Detection failed: $($_.Exception.Message)", 'ERROR')

        [System.Environment]::ExitCode = 1

        Write-Output -InputObject ("Not compliant: detection failed. $($_.Exception.Message)")
    }
Finally
    {
        $Null = Try {Stop-Transcript} Catch {}

        Switch ([System.Diagnostics.Process]::GetCurrentProcess().ProcessName -imatch '^(powershell|pwsh)(\.exe)?$')
            {
                {($_ -eq $True)}
                    {
                        [System.Environment]::Exit([System.Environment]::ExitCode)
                    }
            }
    }
