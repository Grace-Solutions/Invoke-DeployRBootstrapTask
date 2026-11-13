# Invoke-DeployRBootstrapTask

Runs a DeployR task sequence unattended in the full operating system, from a scheduled task running as SYSTEM, with optional task sequence variables passed as JSON. The main use is pre-staging task sequence content ahead of a deployment.

The script stages itself on each device, writes the variables next to it, builds the task definition with XPath and registers the task. When the task runs, the staged copy calls the DeployR bootstrap, the same call DeployR documents for interactive use:

```powershell
$DeployRBootstrap = @{ PRESTAGEONLY = 'True' }
iex (irm 'https://deployr.contoso.com:7281/v1/Service/Bootstrap?tsid=00000002-0000-0000-0000-000000000001:1')
```

Download the latest release from [Releases](https://github.com/Grace-Solutions/Invoke-DeployRBootstrapTask/releases).

## Examples

Pre-stage on this device now:

```powershell
.\Invoke-DeployRBootstrapTask.ps1 -DeployRServer 'https://deployr.contoso.com:7281' -TaskSequenceID '00000002-0000-0000-0000-000000000001:1' -Variables '{"PRESTAGEONLY":"True","SITE":"NYC01"}' -Execute -Force
```

Schedule two remote devices for 01:00 tomorrow, device local time:

```powershell
$InvokeDeployRBootstrapTaskParameters = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
    $InvokeDeployRBootstrapTaskParameters.DeployRServer = 'https://deployr.contoso.com:7281'
    $InvokeDeployRBootstrapTaskParameters.TaskSequenceID = '00000002-0000-0000-0000-000000000001:1'
    $InvokeDeployRBootstrapTaskParameters.Variables = '{"PRESTAGEONLY":"True"}'
    $InvokeDeployRBootstrapTaskParameters.ComputerName = @('NYC-WS-0101', 'NYC-WS-0102')
    $InvokeDeployRBootstrapTaskParameters.Trigger = 'Once'
    $InvokeDeployRBootstrapTaskParameters.StartTime = (Get-Date).Date.AddDays(1).AddHours(1)
    $InvokeDeployRBootstrapTaskParameters.Force = $True

.\Invoke-DeployRBootstrapTask.ps1 @InvokeDeployRBootstrapTaskParameters
```

From a command line, for example a ConfigMgr program. Inside the command line, escape the JSON quotes as `\"`:

```cmd
powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Invoke-DeployRBootstrapTask.ps1 -DeployRServer https://deployr.contoso.com:7281 -TaskSequenceID 00000002-0000-0000-0000-000000000001:1 -Variables "{\"PRESTAGEONLY\":\"True\"}" -Execute -Force
```

Stage the files for packaging without registering a task:

```powershell
.\Invoke-DeployRBootstrapTask.ps1 -DeployRServer 'https://deployr.contoso.com:7281' -TaskSequenceID '00000002-0000-0000-0000-000000000001:1' -StageOnly
```

Remove from a device:

```powershell
.\Invoke-DeployRBootstrapTask.ps1 -Remove -ComputerName 'NYC-WS-0101'
```

## Running from Intune

Intune platform scripts and remediations cannot pass parameters, so set the values in the **Default parameter values** region, just below the parameter block, in your copy of the script:

```powershell
#region Default parameter values
    $DefaultParameterValues = New-Object -TypeName 'System.Collections.Specialized.OrderedDictionary'
        $DefaultParameterValues.DeployRServer = 'https://deployr.contoso.com:7281'
        $DefaultParameterValues.TaskSequenceID = '00000002-0000-0000-0000-000000000001:1'
        $DefaultParameterValues.Variables = '{"PRESTAGEONLY":"True"}'
        $DefaultParameterValues.Trigger = ''
        $DefaultParameterValues.Execute = $True
        $DefaultParameterValues.Force = $False
        $DefaultParameterValues.RemoveVariablesAfterUse = $False
#endregion
```

A default applies only when the parameter is not given on the command line. Empty values and `$False` are ignored.

Intune runs scripts from a temporary location, which is why the script copies itself to the destination before registering the task.

### Platform script

Use a platform script when the task sequence should run once per device.

1. **Create the script:** in the Intune admin center, go to **Devices > Scripts and remediations > Platform scripts > Add > Windows 10 and later**.
2. **Upload** your copy of `Invoke-DeployRBootstrapTask.ps1` with the defaults set.
3. **Set the options:**

   | Setting | Value |
   |---|---|
   | Run this script using the logged on credentials | No (runs as SYSTEM) |
   | Enforce script signature check | No, unless you sign the script |
   | Run script in 64 bit PowerShell Host | Yes |

4. **Assign** it to device groups.

Intune runs a platform script once. It runs it again only if the script changes, and retries a failure up to three times. The script exits with 0 when every device succeeded, so a successful run is not repeated.

### Remediation

Use a remediation when the task should be put back if it goes missing, or registered on a schedule.

1. **Create the remediation:** go to **Devices > Scripts and remediations > Remediations > Create**.
2. **Detection script:** `Detect-DeployRBootstrapTask.ps1`. It exits with 1 when the task is not registered or the staged script is missing. If you change `-Destination`, `-TaskFolder` or `-TaskName` in the defaults, change them in the detection script's parameter defaults too.
3. **Remediation script:** your copy of `Invoke-DeployRBootstrapTask.ps1` with the defaults set.
4. **Set the options:**

   | Setting | Value |
   |---|---|
   | Run this script using the logged-on credentials | No (runs as SYSTEM) |
   | Enforce script signature check | No, unless you sign the scripts |
   | Run script in 64-bit PowerShell | Yes |

5. **Assign** it to device groups, with a schedule.

With `Execute = $True`, the task sequence runs each time the remediation registers the task, which is only when detection finds the task missing. Remediations need the licensing Microsoft requires for the feature.

## Running from ConfigMgr

The client runs everything below as SYSTEM.

### Package and program

1. **Create a package** with `Invoke-DeployRBootstrapTask.ps1` as its source.
2. **Create a program** with this command line:

   ```cmd
   powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Invoke-DeployRBootstrapTask.ps1 -DeployRServer https://deployr.contoso.com:7281 -TaskSequenceID 00000002-0000-0000-0000-000000000001:1 -Variables "{\"PRESTAGEONLY\":\"True\"}" -Execute -Force
   ```

3. **Set the program to run** with administrative rights, whether or not a user is logged on.

### Application

| Setting | Value |
|---|---|
| Installation program | The command line from the program above |
| Uninstall program | `powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\Invoke-DeployRBootstrapTask.ps1 -Remove` |
| Detection method | File `Invoke-DeployRBootstrapTask.ps1` exists in `%ProgramData%\2Pint\DeployRBootstrap` |
| Installation behaviour | Install for system |

### Run Scripts

1. **Import** `Invoke-DeployRBootstrapTask.ps1` under **Software Library > Scripts**, then approve it.
2. **Run it** against a collection. Each parameter is offered as a string: set `DeployRServer`, `TaskSequenceID`, `Variables` as plain JSON with no escaping (for example `{"PRESTAGEONLY":"True"}`), and `Execute` and `Force` to `True`.

### From an administrator's workstation

`-ComputerName` stages and registers the task on remote devices over the administrative share (`\\Device\C$`) and `schtasks.exe /S`, using your current credentials. You need administrator rights on each device.

## How it works

The script has three modes.

**Create**, the default. On each device it:
1. **Creates the destination directory** if it does not exist, and restricts it to SYSTEM and Administrators before writing anything, because task sequence variables can carry secrets.
2. **Copies itself there.**
3. **Writes the variables** next to it as `DeployRBootstrap.json`.
4. **Builds the task definition** from a fixed template, setting every value through XPath: author, description, URI, run time limit, command, arguments, working directory and trigger.
5. **Registers the task.** It runs as SYSTEM with the highest privileges, through Windows PowerShell 5.1, which every device has.
6. **Starts the task**, with `-Execute`.

**Bootstrap**, run by the task. The staged copy:
- reads `DeployRBootstrap.json` into `$DeployRBootstrap`;
- turns off the PowerShell progress display, which otherwise slows downloads badly;
- enables TLS 1.2;
- downloads and runs the bootstrap from the DeployR server.

The bootstrap installs .NET and PowerShell 7 from the DeployR server when they are missing.

**Remove** deletes the task and the destination directory.

### Files on each device

| File | What |
|---|---|
| `Invoke-DeployRBootstrapTask.ps1` | The staged copy of the script, run by the task with `-Bootstrap` |
| `DeployRBootstrap.json` | The task sequence variables, only when given |
| `DeployRBootstrapTask.xml` | The task definition, only with `-StageOnly` |

The default destination is `%ProgramData%\2Pint\DeployRBootstrap`. The task's command is:

```cmd
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -NoLogo -WindowStyle Hidden -File "C:\ProgramData\2Pint\DeployRBootstrap\Invoke-DeployRBootstrapTask.ps1" -Bootstrap -BootstrapUri "https://deployr.contoso.com:7281/v1/Service/Bootstrap?tsid=00000002-0000-0000-0000-000000000001:1"
```

## Requirements

- **PowerShell:** Windows PowerShell 5.1 or PowerShell 7.
- **Rights:** an elevated session to register a task on the local device, and administrator rights on remote devices.
- **Certificate:** each device must trust the DeployR server certificate. With the 2Pint self-signed certificate, its root CA has to be in the device's Trusted Root Certification Authorities store first.
- **Task sequence:** it must not restart the device. A task sequence ID is required, because the task runs as SYSTEM and nobody can see or answer the task sequence selection.

## Parameters

| Parameter | Default | What |
|---|---|---|
| `-DeployRServer` | None | The DeployR server URL with scheme, for example `https://deployr.contoso.com:7281`. If no port is given, 7281 is used |
| `-TaskSequenceID` | None | `<GUID>:<Version>` |
| `-Variables` | None | Task sequence variables as a JSON object, for example `{"PRESTAGEONLY":"True"}`. Values are passed as strings and must be single values |
| `-ComputerName` | This device | One or more devices |
| `-Destination` | `%ProgramData%\2Pint\DeployRBootstrap` | A local path on each device, with a drive letter |
| `-TaskFolder` | `\2Pint` | Task Scheduler folder |
| `-TaskName` | `DeployR Bootstrap` | Task name |
| `-Trigger` | `None` | `None` (on demand only), `AtStartup` (5 minutes after boot), or `Once` |
| `-StartTime` | None | Local date and time for the `Once` trigger |
| `-ExecutionTimeLimit` | 8 hours | How long the task may run before Task Scheduler stops it |
| `-RemoveVariablesAfterUse` | Off | Deletes the JSON as soon as the bootstrap has read it |
| `-Execute` | Off | Starts the task once it is registered, or when it exists already |
| `-Force` | Off | Replaces an existing task and restages the files. Without it, an existing task is left as it is and reported as successful |
| `-StageOnly` | Off | Writes the files and the task XML without registering anything |
| `-Remove` | Off | Removes the task and the destination directory |
| `-LogDirectory` | `%SystemRoot%\Logs\Software\Invoke-DeployRBootstrapTask` | Where the transcript goes |

`-DeployRServer` and `-TaskSequenceID` are required, either on the command line or in the Default parameter values region. `-Bootstrap` and `-BootstrapUri` are set by the task and are not for running by hand.

## Output and exit codes

The script outputs one object per device, with these properties:
- `ComputerName`, `Action`, `TaskPath`, `Destination`;
- `Staged`, `Registered`, `Started`, `Removed`, `Successful`;
- `Message`.

| Exit code | Meaning |
|---|---|
| 0 | Every device succeeded, or, in Bootstrap mode, the bootstrap ran |
| 1 | The script failed, or the bootstrap could not be downloaded or run |
| 2 | One or more devices failed |

Task Scheduler shows the Bootstrap mode's exit code as the task's last run result.

## Logs

All transcripts go to `%SystemRoot%\Logs\Software\Invoke-DeployRBootstrapTask`, with the last three of each kept.

| Log | Transcript name |
|---|---|
| Create and Remove | `Invoke-DeployRBootstrapTask-Create_*.log`, `Invoke-DeployRBootstrapTask-Remove_*.log` |
| Bootstrap, on each device | `Invoke-DeployRBootstrapTask-Bootstrap_*.log` |
| Intune detection | `Detect-DeployRBootstrapTask_*.log` |

The DeployR bootstrap writes its own log to `%SystemRoot%\Temp`. DeployR logs go to `C:\_2P\Logs` once the task sequence starts.

Variable names are logged. Their values never are.

## Known limits

- **Execution policy:** the task runs with `-ExecutionPolicy Bypass`, but an execution policy forced by Group Policy (MachinePolicy) takes precedence. Where one is enforced, the script must be signed.
- **Non-English Windows:** the check for a missing task relies on the English `schtasks.exe` message ("cannot find" or "does not exist"). The Intune detection script uses the Task Scheduler API instead and does not depend on language.
- **Packaging with `-StageOnly`:** the task XML points at the staged script's path, so stage with the `-Destination` the package will install to.
- **Remote devices:** the destination must be on the same drive letter on each device, and the administrative share must be reachable.
- **Variables file:** it stays on the device unless you use `-RemoveVariablesAfterUse`, and only SYSTEM and Administrators can read it. Running the script again without variables deletes any variables file left from an earlier run.

## Reference

[Starting a task sequence in an existing OS](https://documentation.2pintsoftware.com/deployr/deployment-methods/starting-a-task-sequence-in-an-existing-os) (2Pint documentation)
