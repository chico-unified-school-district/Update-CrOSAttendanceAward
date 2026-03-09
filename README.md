# Update-CrOSAttendanceAward

Automates Chromebook OU assignment based on student tardy streaks.

The script:

- reads active students from SIS (SQL Server)
- matches students to assigned Chromebook serials in SIS
- matches SIS serials to Google Admin ChromeOS devices (via GAM)
- calculates attendance award eligibility windows (including weekends and no-student days)
- moves each device into the correct award OU (or default OU)
- logs all OU changes to a dated CSV

---

## Repository Layout

- `Update-CrOSAttendanceAward.ps1` main process script
- `params.ps1` local/CI parameter hashtable and helper setup
- `jenkins.ps1` Jenkins entry script placeholder
- `csv/awardTable.csv` award tiers (`days,ou`)
- `sql/` SQL queries used by the process
- `data/` cached GAM exports (`GSuite-Export-yyyy-MM-dd.csv`)
- `log/` OU-change logs (`award-log-yyyy-MM-dd.csv`)

---

## Prerequisites

### 1) PowerShell + Modules

Required modules:

- `dbatools` (uses `Invoke-DbaQuery`, `Connect-DbaInstance`, etc.)
- `CommonScriptFunctions` (environment-specific shared functions used by this script)

### 2) GAM7

This script expects GAM at:

- `C:\GAM7\gam.exe`

It uses GAM to read/update ChromeOS device org units.

### 3) SQL Access

You need:

- SQL Server name
- Database name
- credential with permission to run the queries in `sql/`

### 4) Google Admin Permissions

The GAM account must be able to:

- list ChromeOS devices
- move ChromeOS devices between OUs

---

## Configuration

### Award Tiers

Edit `csv/awardTable.csv`:

```csv
days,ou
05,/Chromebooks/1:1/AttStreak/5-day
10,/Chromebooks/1:1/AttStreak/10-day
30,/Chromebooks/1:1/AttStreak/30-day
50,/Chromebooks/1:1/AttStreak/50-day
80,/Chromebooks/1:1/AttStreak/80-day
```

Rules:

- sort order is handled in script (`days` descending)
- `ou` must match a valid Google Admin OU path

### Runtime Parameters

`Update-CrOSAttendanceAward.ps1` parameters:

- `-Server` (required)
- `-Database` (required)
- `-Credential` (required, `PSCredential`)
- `-ValidSiteCodes` (`int[]`)
- `-DefaultCrosOrgUnit` (fallback OU)
- `-WhatIf` / `-wi` (dry run mode)

### Example `params.ps1`

```powershell
$global:params = @{
 Server             = $SISServer
 Database           = $SISDB
 Credential         = $AeriesCloudJenkins
 ValidSiteCodes     = 5
 DefaultCrosOrgUnit = '/Chromebooks/1:1'
}
Get-ChildItem -Path .\*.ps1 | Unblock-File -Confirm:$false
$params
```

---

## Run the Process

From repo root:

### Dry Run (recommended first)

```powershell
.\params.ps1
.\Update-CrOSAttendanceAward.ps1 @params -wi -ErrorAction Stop
```

### Live Run (applies OU updates)

```powershell
.\params.ps1
.\Update-CrOSAttendanceAward.ps1 @params -ErrorAction Stop
```

`-wi` shows intended changes but does **not** run:

- `gam update cros <deviceId> ou <targetOU>`

---

## Process Logic Summary

1. Load award tiers from `csv/awardTable.csv`
2. For each tier, calculate effective window:
   - configured award days
   - plus no-student weekdays from SIS day table
   - plus weekend days
3. Determine each tier cutoff date from today
4. Pull:
   - school start date
   - SIS student list (filtered by `ValidSiteCodes`)
   - SIS Chromebook assignments
   - Google ChromeOS device export (cached daily in `data/`)
5. For each student/device:
   - select tardy lookup SQL by site code (`SC`)
   - find latest tardy date
   - set default OU by site code (`SC`) with fallback to `-DefaultCrosOrgUnit`
   - choose highest eligible award OU, else default OU
6. Update ChromeOS OU when current OU differs from target OU
7. Write change log to `log/award-log-yyyy-MM-dd.csv`

---

## Outputs

## Data Cache

- `data/GSuite-Export-yyyy-MM-dd.csv`
  - reused if it already exists for the day
   - old files older than 1 day are removed at runtime

## Update Log

- `log/award-log-yyyy-MM-dd.csv`
  - columns: `id,sn,ou`
  - only created when at least one OU change is detected
   - old log files older than 1 day are removed at runtime

---

## SQL Files in Use

Current main script references:

- `sql/sis-select-first-day-of-school.sql`
- `sql/sis-get-cros.sql`
- `sql/sis-active-students.sql`
- `sql/sis-select-no-student-days.sql`
- `sql/sis-tardy-lookup-middle-school.sql`

The tardy lookup SQL is selected in-script per student site code (`SC`) via `Set-LatestTardyLookupSql`.
Current mapping in script:

- `SC = 5` -> `sql/sis-tardy-lookup-middle-school.sql`
- other `SC` values currently throw an error until mapped

---

## Jenkins Notes

`jenkins.ps1` is currently empty. Common pattern is:

```powershell
.\params.ps1
.\Update-CrOSAttendanceAward.ps1 @params -wi -ErrorAction Stop
```

Then remove `-wi` once validated.

---

## Troubleshooting

- **No SIS/GSuite matches**: verify serial number formats align between SIS and Google Admin.
- **No updates happen**: run with `-wi` and check whether current OU already equals target OU.
- **GAM errors**: confirm `C:\GAM7\gam.exe` exists and auth is valid.
- **SQL errors**: verify server/database/credential and query permissions.
- **Unexpected tiering**: verify `awardTable.csv` values and OU paths.
- **Unknown site code error**: add a mapping in `Set-LatestTardyLookupSql` and `Set-DefaultOU` for that `SC`.

---

## Safety Recommendations

- Always run dry-run (`-wi`) first in each environment.
- Limit `ValidSiteCodes` during testing.
- Keep SQL query files version-controlled and reviewed.
- Keep a rollback strategy for OU updates (using `log/` output).
