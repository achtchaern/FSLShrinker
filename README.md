# FSLShrinker – FSLogix Profile Container VHDX Shrinker

A PowerShell script that shrinks FSLogix VHDX profile containers to reclaim unused disk space.

## Requirements

- Windows Server or Windows 10/11 with administrative privileges
- PowerShell 5.1 or PowerShell 7+
- The `defragsvc` (Disk Defragmenter) and `vds` (Virtual Disk Service) services must be startable
- VHDX files must not be in active use by FSLogix when the script runs

### Optional: VHDX Integrity Check and Repair

- The **Hyper-V PowerShell module** must be installed (`Install-WindowsFeature Hyper-V-PowerShell` on Server, or enable the Hyper-V Management Tools optional feature on Windows client)
- Provides the `Test-VHD` and `Repair-VHD` cmdlets used by the `-CheckVhdHealth` and `-RepairVhd` switches

## Configuration

Edit the top of the script to match your environment:

```powershell
$VHDXLocations = @("F:\Public\User\*\CsProfiles.VHDX", "D:\Public\User\*\CsProfiles.VHDX")
$LogPath = ".\FSLogix-Shrinking-Logs"
```

- **`$VHDXLocations`** – Wildcard paths to your FSLogix profile VHDX files.
- **`$LogPath`** – Directory for transcript and CSV log output.

## Usage

Run the script directly (it calls `Start-DiskShrinker` at the bottom), or import and call the function manually.

### Basic shrink (default behavior)

```powershell
.\FSLogix-Profildatenträger\ shrinken.ps1
```

Or invoke the function explicitly:

```powershell
Start-DiskShrinker -Path "D:\Public\User\*"
```

### Shrink with VHDX health check (no repair)

Use `-CheckVhdHealth` to non-destructively check each VHDX with `Test-VHD` and report healthy/unhealthy status.
No modifications are ever made to the VHDX. Unhealthy files produce a warning but the shrink continues.

```powershell
Start-DiskShrinker -Path "D:\Public\User\*" -CheckVhdHealth
```

### Shrink with VHDX health check **and** repair

Use `-RepairVhd` to opt into automatic repair of any VHDX that fails the health check.
`-RepairVhd` implies the health check; you do not need to pass `-CheckVhdHealth` as well.
**The VHDX must not be in active use during repair** — ensure all user sessions are logged off.

```powershell
Start-DiskShrinker -Path "D:\Public\User\*" -RepairVhd
```

To enable repair in the default bottom-of-script invocation, edit the last `Start-DiskShrinker` call:

```powershell
$VHDXLocations | ? {gci $_ -EA 0} | Start-DiskShrinker -LogFilePath "$((gi $LogPath).FullName)\Log.csv" -Verbose -RepairVhd
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Path` | String | *(Mandatory)* | Wildcard path to VHDX files |
| `-IgnoreLessThanGB` | Double | `0` | Skip disks smaller than this size |
| `-DeleteOlderThanDays` | Int | — | Delete disks not accessed for this many days |
| `-RollingLog` | Switch | `$false` | Append timestamp to log filename |
| `-LogFilePath` | String | `%TEMP%\FslShrinkDisk …csv` | Path for the CSV results log |
| `-PassThru` | Switch | `$false` | Output result objects to the pipeline |
| `-ThrottleLimit` | Int | `4` | Maximum parallel threads |
| `-RatioFreeSpace` | Double | `0.05` | Minimum free-space ratio to trigger shrink |
| `-CheckVhdHealth` | Switch | `$false` | Non-destructively check VHDX health with `Test-VHD`; report status, never modify |
| `-RepairVhd` | Switch | `$false` | **Check health then repair** unhealthy VHDXs with `Repair-VHD`; implies the health check |

## VHDX Integrity Check and Repair – Behavior and Caveats

- **`-CheckVhdHealth`** is read-only: it runs `Test-VHD` on each VHDX and logs the result; it never alters any file.
- **`-RepairVhd`** implies the health check: it runs `Test-VHD` first and calls `Repair-VHD` only for VHDXs that are unhealthy. You do not need to pass both switches.
- **Neither switch is active by default.** Normal runs are unaffected.
- **The VHDX must not be in active use** during the repair. Ensure the user's FSLogix session is logged off and the container is not mounted before running with `-RepairVhd`.
- If `Test-VHD` or `Repair-VHD` is unavailable (Hyper-V module not installed), a warning is emitted and processing continues normally—no error is thrown.
- If `Test-VHD` cannot access a file (e.g., locked), a per-file warning is written and the remaining containers continue to be processed.
- If `Repair-VHD` fails for a specific container, an error is recorded for that file but other containers continue unaffected.
- After repair, normal shrinking proceeds. If the repair did not fully fix the container, subsequent operations may still fail and will be logged accordingly.

## Logging

- **Transcript**: `$LogPath\Output.txt`
- **CSV results**: `$LogPath\Log.csv` (one row per processed VHDX)

## License

See repository for license details.
