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
- `csv/awardTable.csv` award tiers (`days,ou`) — `ou` is a relative path appended to the root OU
- `csv/special-ous.csv` special-case OU suffixes applied to specific devices before award tiering
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
00,/AttStreak/0day
05,/AttStreak/5day
10,/AttStreak/10day
30,/AttStreak/30day
50,/AttStreak/50day
80,/AttStreak/80day
```

Rules:

- sort order is handled in script (`days` descending)
- `ou` is a **relative path** — it is appended to the root OU at runtime (see `Set-RootOU` and `-DefaultCrosOrgUnit`)
- `ou` must correspond to a valid child OU under the root OU in Google Admin

### Special OUs

Edit `csv/special-ous.csv` to define OU suffixes that are inserted between the root OU and the award tier OU for qualifying devices:

```csv
ou,description
/Student - Unrestricted WiFi Access,used for students living in close proximity to a school campus who require access to the school's WiFi network
```

At runtime, `Set-RootOU` checks each device's current `orgUnitPath` against every entry in this file. If a match is found, the special OU suffix is appended to `-DefaultCrosOrgUnit` to form the root OU for that device. This ensures special-case devices retain their sub-OU prefix when award tiers are applied.

### Runtime Parameters

`Update-CrOSAttendanceAward.ps1` parameters:

- `-Server` (required)
- `-Database` (required)
- `-Credential` (required, `PSCredential`)
- `-ValidSiteCodes` (`int[]`)
- `-DefaultCrosOrgUnit` (root OU base path; award tier and special-OU suffixes are appended to this)
- `-RootCrosOrgUnit` (reserved parameter, defined but not yet wired into the pipeline)
- `-CheckEachLoop` (switch; pauses execution with `Read-Host` after each student object for step-through debugging)
- `-WhatIf` / `-wi` (dry run mode)

### Example `params.ps1`

```powershell
$global:params = @{
 Server             = $SISServer
 Database           = $SISDB
 Credential         = $SiSCred
 ValidSiteCodes     = 1,2,3,4,5
 DefaultCrosOrgUnit = '/Chromebooks/'
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
2. For each tier, calculate the cutoff date by calling `sql/sis-select-cutoff-date.sql` with the tier's day count (handles no-student days and weekends inside the query)
3. Result: each tier has a resolved cutoff `[datetime]`
4. Pull:
   - school start date
   - SIS student list (filtered by `ValidSiteCodes`)
   - SIS Chromebook assignments
   - Google ChromeOS device export (cached daily in `data/`)
5. For each student/device:
   - select tardy lookup SQL by site code (`SC`) via `Set-LatestTardyLookupSql`
   - find latest tardy date via `Set-LatestTardyDate`
   - determine root OU via `Set-RootOU`: starts from `-DefaultCrosOrgUnit`, then appends any matching suffix from `csv/special-ous.csv` based on the device's current `orgUnitPath`
   - choose highest eligible award tier OU (appended to root OU), else root OU
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
  - columns: `id,sn,srcOU,targOU`
  - only created when at least one OU change is detected
  - **all existing log files are removed at the start of each run** before the new log is written

---

## SQL Files in Use

Current main script references:

- `sql/sis-select-first-day-of-school.sql`
- `sql/sis-get-cros.sql`
- `sql/sis-active-students.sql`
- `sql/sis-select-cutoff-date.sql` (calculates each tier's cutoff date; replaces manual no-student-day logic)
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
