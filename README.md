# FSLShrinker – FSLogix Profile Container VHDX Shrinker

A PowerShell script that shrinks FSLogix VHDX profile containers to reclaim unused disk space.

## Requirements

- Windows Server or Windows 10/11 with administrative privileges
- PowerShell 5.1 or PowerShell 7+
- The `defragsvc` (Disk Defragmenter) and `vds` (Virtual Disk Service) services must be startable
- VHDX files must not be in active use by FSLogix when the script runs

### Optional: VHDX Filesystem Health Check and Repair

- **Administrative privileges are required** for `Mount-DiskImage`, `Repair-Volume`, and `Dismount-DiskImage`
- No additional modules beyond standard Windows Storage cmdlets are needed; there is no Hyper-V dependency
- **Important limitation:** `-CheckVhdHealth` and `-RepairVhd` validate and repair the *filesystem inside* the VHDX container. They mount the disk image using the built-in Windows Storage cmdlets (`Mount-DiskImage`/`Dismount-DiskImage`) and run `Repair-Volume`. This does **not** inspect or repair VHDX container metadata or format-level corruption. If a VHDX cannot be mounted at all, this is reported as an image/container access failure; no VHDX-level structural repair is attempted.

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

### Shrink with VHDX filesystem health check (no repair)

Use `-CheckVhdHealth` to non-destructively scan each VHDX's filesystem and report healthy/unhealthy status.
The VHDX is mounted read-only, scanned with `Repair-Volume -Scan`, and immediately dismounted.
No modifications are ever made. Issues produce a warning but processing continues for other containers.

```powershell
Start-DiskShrinker -Path "D:\Public\User\*" -CheckVhdHealth
```

### Shrink with VHDX filesystem health check **and** repair

Use `-RepairVhd` to opt into automatic filesystem repair of any VHDX that fails the health check.
`-RepairVhd` implies the health check; you do not need to pass `-CheckVhdHealth` as well.
**The VHDX must not be in active use during repair** — ensure all user sessions are logged off.
If the VHDX is already mounted (active FSLogix session), it is skipped and a warning is written.

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
| `-CheckVhdHealth` | Switch | `$false` | Non-destructively mount and scan the filesystem inside each VHDX; report status, never modify |
| `-RepairVhd` | Switch | `$false` | **Check health then repair** the filesystem inside unhealthy VHDXs using `Repair-Volume -OfflineScanAndFix`; implies the health check |

## VHDX Filesystem Check and Repair – Behavior and Caveats

- **`-CheckVhdHealth`** is read-only: it mounts each VHDX read-only, runs `Repair-Volume -Scan` on its volume(s), reports the result, and dismounts. It never alters any file.
- **`-RepairVhd`** implies the health check: it scans first and runs `Repair-Volume -OfflineScanAndFix` only for VHDXs that have filesystem errors. You do not need to pass both switches.
- **Neither switch is active by default.** Normal runs are unaffected.
- **Filesystem-vs-container limitation:** These switches check and repair the NTFS/ReFS filesystem *hosted inside* the VHDX. They do not inspect or repair VHDX container metadata corruption. If a VHDX cannot be mounted, the failure is reported as a container access error and that disk is skipped.
- **Already-mounted images are skipped:** If a VHDX is currently attached (active FSLogix session), a warning is written and the disk is not touched.
- **The VHDX must not be in active use** during repair. Ensure the user's FSLogix session is logged off and the container is not mounted before running with `-RepairVhd`.
- If mounting fails (e.g., file locked or container inaccessible), a per-file warning is written and the remaining containers continue to be processed.
- If `Repair-Volume` fails for a specific container, an error is recorded for that file but other containers continue unaffected.
- The disk image is always dismounted in a `finally` block, even if an error occurs during the check or repair.
- After repair, normal shrinking proceeds. If the repair did not fully fix the container, subsequent operations may still fail and will be logged accordingly.

## Logging

- **Transcript**: `$LogPath\Output.txt`
- **CSV results**: `$LogPath\Log.csv` (one row per processed VHDX)

## License

See repository for license details.
