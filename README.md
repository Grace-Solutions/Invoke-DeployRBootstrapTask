# Invoke-DeployRBootstrapTask

Stages a DeployR bootstrap on one or more devices and registers a scheduled task that runs it as SYSTEM. You can pass an optional hashtable of task sequence variables. The main use is running a task sequence unattended in the full operating system, for example to pre-stage content before a deployment.

## How it works

DeployR documents starting a task sequence in an existing operating system as one elevated PowerShell call to the server's Bootstrap endpoint, with task sequence variables in a hashtable set first:

```powershell
$DeployRBootstrap = @{ MyRole = 'Accounting' }
iex (irm 'https://deployr.contoso.com:7281/v1/Service/Bootstrap?tsid=00000002-0000-0000-0000-000000000001:1')
```

This script turns that call into something you can place on a device and run with nobody at the keyboard. For each device it:

1. **Generates a launcher**, `Start-DeployRBootstrap.ps1`, with the bootstrap URL written into it.
2. **Writes the hashtable** next to the launcher as `DeployRBootstrap.json`.
3. **Restricts the destination folder** to SYSTEM and Administrators before writing anything to it, because task sequence variables can contain secrets.
4. **Registers a scheduled task** that runs the launcher as SYSTEM with the highest privileges, through Windows PowerShell 5.1, which every device has. The bootstrap installs .NET and PowerShell 7 from the DeployR server if they are missing.
5. **Starts the task**, if you ask it to.

When the task runs, the launcher:
- reads the JSON back into `$DeployRBootstrap`;
- turns off the PowerShell progress display, which otherwise slows downloads badly;
- enables TLS 1.2;
- downloads and runs the bootstrap;
- returns exit code 0 on success and 1 on failure.

Remote devices are reached through their administrative share (`\\Device\C$`) and `schtasks.exe /S`, using your current credentials.

## Files

| File | Where | What |
|---|---|---|
| `Invoke-DeployRBootstrapTask.ps1` | Here | The script you run |
| `Start-DeployRBootstrap.ps1` | Destination on each device | Generated launcher; run the main script again to change it, rather than editing it |
| `DeployRBootstrap.json` | Destination on each device | The task sequence variables, only when you pass some |
| `DeployRBootstrapTask.xml` | Destination on each device | The task definition, only with `-StageOnly` |

## Requirements

- **PowerShell:** Windows PowerShell 5.1 or PowerShell 7, on the machine that runs the script and on the devices.
- **Rights:** an elevated session to register a task on the local device, and administrator rights on remote devices.
- **Certificate:** each device must trust the DeployR server certificate. With the 2Pint self-signed certificate, its root CA has to be in the device's Trusted Root Certification Authorities store first.
- **Task sequence:** it must not restart the device.

## Parameters

| Parameter | Default | What |
|---|---|---|
| `-DeployRServer` | Required | The DeployR server URL with scheme, for example `https://deployr.contoso.com:7281`. If no port is given, 7281 is used |
| `-TaskSequenceID` | Required | `<GUID>:<Version>`. Required because the task runs as SYSTEM, so nobody can see or answer the task sequence selection |
| `-Variables` | None | A hashtable of task sequence variables. Alias `-DeployRBootstrap`. Values are passed as strings, and must be single values, not collections |
| `-ComputerName` | This device | One or more devices |
| `-Destination` | `%ProgramData%\2Pint\DeployRBootstrap` | A local path on each device, with a drive letter |
| `-TaskFolder` | `\2Pint` | Task Scheduler folder |
| `-TaskName` | `DeployR Bootstrap` | Task name |
| `-Trigger` | `None` | `None` (on demand only), `AtStartup` (5 minutes after boot), or `Once` |
| `-StartTime` | None | Local date and time for the `Once` trigger |
| `-ExecutionTimeLimit` | 8 hours | How long the task may run before Task Scheduler stops it |
| `-RemoveVariablesAfterUse` | Off | Deletes the JSON as soon as the launcher has read it |
| `-Execute` | Off | Starts the task as soon as it is registered |
| `-Force` | Off | Replaces an existing task. Without it, a device that already has the task is skipped and counted as failed |
| `-StageOnly` | Off | Writes the files and the task XML without registering anything, for packaging with Intune or ConfigMgr |
| `-Remove` | Off | Removes the task and the destination folder |
| `-LogDirectory` | `%SystemRoot%\Logs\Software\Invoke-DeployRBootstrapTask` | Where the script writes its transcript |

## Examples

Pre-stage on this device now:

```powershell
$Variables = @{ PRESTAGEONLY = 'True'; SITE = 'NYC01' }

.\Invoke-DeployRBootstrapTask.ps1 -DeployRServer 'https://deployr.contoso.com:7281' -TaskSequenceID '00000002-0000-0000-0000-000000000001:1' -Variables $Variables -Execute -Force
```

Schedule two remote devices for 01:00 tomorrow, device local time:

```powershell
$InvokeDeployRBootstrapTaskParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
    $InvokeDeployRBootstrapTaskParameters.DeployRServer = 'https://deployr.contoso.com:7281'
    $InvokeDeployRBootstrapTaskParameters.TaskSequenceID = '00000002-0000-0000-0000-000000000001:1'
    $InvokeDeployRBootstrapTaskParameters.Variables = @{ PRESTAGEONLY = 'True' }
    $InvokeDeployRBootstrapTaskParameters.ComputerName = @('NYC-WS-0101', 'NYC-WS-0102')
    $InvokeDeployRBootstrapTaskParameters.Trigger = 'Once'
    $InvokeDeployRBootstrapTaskParameters.StartTime = (Get-Date).Date.AddDays(1).AddHours(1)
    $InvokeDeployRBootstrapTaskParameters.Force = $True

.\Invoke-DeployRBootstrapTask.ps1 @InvokeDeployRBootstrapTaskParameters
```

Stage files for packaging without registering a task:

```powershell
.\Invoke-DeployRBootstrapTask.ps1 -DeployRServer 'https://deployr.contoso.com:7281' -TaskSequenceID '00000002-0000-0000-0000-000000000001:1' -Destination 'C:\Temp\DeployRBootstrapPackage' -StageOnly
```

The XML in the package expects the launcher at the same path on the device, so stage with the `-Destination` the package will install to.

Remove from a device:

```powershell
.\Invoke-DeployRBootstrapTask.ps1 -Remove -ComputerName 'NYC-WS-0101'
```

## Output and exit codes

The script outputs one object per device, with these properties:
- `ComputerName`, `Action`, `TaskPath`, `Destination`;
- `Staged`, `Registered`, `Started`, `Removed`, `Successful`;
- `Message`.

| Exit code | Meaning |
|---|---|
| 0 | Every device succeeded |
| 1 | The script itself failed |
| 2 | One or more devices failed or were skipped |

## Logs

| Log | Where |
|---|---|
| This script | `%SystemRoot%\Logs\Software\Invoke-DeployRBootstrapTask`, last three kept |
| The launcher, on each device | `%SystemRoot%\Logs\Software\Start-DeployRBootstrap`, last three kept |
| The DeployR bootstrap | `%SystemRoot%\Temp` |
| DeployR, once the task sequence starts | `C:\_2P\Logs` |

Variable names are logged. Their values never are.

## Known limits

- **Execution policy:** the task runs Windows PowerShell with `-ExecutionPolicy Bypass`, but an execution policy forced by Group Policy (MachinePolicy) takes precedence. Where one is enforced, the launcher must be signed.
- **Non-English Windows:** the check for a missing task relies on the English `schtasks.exe` message ("cannot find" or "does not exist"). On other languages that check may report an error instead.
- **Remote devices:** the destination is assumed to be on the same drive letter on each device, and the administrative share must be reachable.
- **Variables file:** it stays on the device unless you use `-RemoveVariablesAfterUse`. It is readable only by SYSTEM and Administrators. Running the script again without variables deletes any variables file left from an earlier run.

## Reference

[Starting a task sequence in an existing OS](https://documentation.2pintsoftware.com/deployr/deployment-methods/starting-a-task-sequence-in-an-existing-os) (2Pint documentation)
