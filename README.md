# Update-CrOSAttendanceAward

Automates ChromeOS device OU assignment based on student attendance/tardy data from SIS.

## What This Process Does

The main script:

- pulls assigned Chromebook data from SIS
- pulls active students filtered by site code
- exports ChromeOS devices from Google Admin (GAM), with daily CSV caching
- determines each student's latest tardy date
- maps each student/device to a target OU based on tier cutoffs
- applies OU updates in Google Admin (unless running in WhatIf mode)
- writes a dated CSV log of evaluated records

## Repository Layout

- Update-CrOSAttendanceAward.ps1: main process script
- params.ps1: local/CI parameter hashtable setup
- jenkins.ps1: Jenkins entry script
- csv/awardTable.csv: attendance tiers (days, ou)
- csv/special-ous.csv: optional OU suffix rules
- sql/: SQL files (active and historical)
- sql/unused/: archived SQL not used by main process
- data/: cached GAM exports
- log/: run logs

## Prerequisites

### 1) PowerShell Modules

Required modules:

- dbatools
- CommonScriptFunctions

### 2) GAM7

Expected path in script:

- C:\GAM7\gam.exe

The GAM account must be authorized to read and update ChromeOS devices.

### 3) SQL Access

You need:

- SQL Server name
- database name
- credential with permission to run the SQL in sql/

## Parameters

Update-CrOSAttendanceAward.ps1 parameters:

- Server (required)
- Database (required)
- Credential (required PSCredential)
- ValidSiteCodes (required int[])
- DefaultCrosOrgUnit (required)
- NoTardiesOrgUnit (required)
- CheckEachLoop (switch)
- WhatIf / wi (switch)

Example params.ps1:

```powershell
$global:params = @{
 Server             = $SISServer
 Database           = $SISDB
 Credential         = $AeriesCloudJenkins
 ValidSiteCodes     = 1,2,3
 DefaultCrosOrgUnit = '/Chromebooks'
 NoTardiesOrgUnit   = '/NoTardies'
}
Get-ChildItem -Path .\*.ps1 | Unblock-File -Confirm:$false
$params
```

## Run

Dry run first:

```powershell
.\params.ps1
.\Update-CrOSAttendanceAward.ps1 @params -wi -ErrorAction Stop
```

Live run:

```powershell
.\params.ps1
.\Update-CrOSAttendanceAward.ps1 @params -ErrorAction Stop
```

## Main Pipeline

1. Connect to SIS SQL instance.
2. Load tier rules from csv/awardTable.csv and compute per-tier cutoff days using sql/sis-select-cutoff-date.sql.
3. Pull SIS device assignments (sql/sis-get-cros.sql).
4. Pull SIS active students (sql/sis-active-students.sql, with VALID_SITE_CODES replaced at runtime).
5. Pull Google ChromeOS devices through GAM (or reuse same-day CSV in WhatIf mode).
6. For each student record:
   - match SIS device assignment to Google serial number
   - pick tardy lookup SQL by site code (currently SC 5 only)
   - query latest tardy date and compute days since tardy
   - build root OU from DefaultCrosOrgUnit plus optional suffix from csv/special-ous.csv
   - if no tardy date is found, assign NoTardiesOrgUnit under the root
   - otherwise assign tier OU based on cutoff comparison
7. Update OU only when current OU differs from target OU (skipped in WhatIf mode).
8. Write log/award-log-yyyy-MM-dd.csv.

## SQL Files Used By Main Process

- sql/sis-get-cros.sql
- sql/sis-active-students.sql
- sql/sis-select-cutoff-date.sql
- sql/sis-tardy-lookup-middle-school-full-day.sql (selected for SC = 5)

## SQL Files Not Used By Main Process

In sql/:

- sql/sis-select-first-day-of-school.sql
- sql/sis-select-no-student-days.sql
- sql/sis-tardy-lookup-middle-school-all-tardies.sql

Archived in sql/unused/:

- sql/unused/sis-active-students-old.sql
- sql/unused/sis-all-data.sql
- sql/unused/sis-select-no-student-days copy.sql
- sql/unused/sis-tardy-middle-school-students-not-used.sql
- sql/unused/student_return_cb.sq.sql

## Outputs

### Data Cache

- data/GSuite-Export-yyyy-MM-dd.csv
- old data CSV files older than 1 day are removed at run start

### Run Log

- log/award-log-yyyy-MM-dd.csv
- columns: id,sn,srcOU,targOU,daysSinceTardy
- existing files in log/ are removed at run start

## Troubleshooting

- Unknown SC error: add mapping in Set-LatestTardyLookupSql for that site code.
- No SIS to Google match: verify serial number formatting in both systems.
- No changes applied: expected in WhatIf mode, or when source OU already equals target OU.
- SQL errors: verify connectivity, permissions, and parameter values.
- GAM errors: verify C:\GAM7\gam.exe and GAM auth.

## Safety

- Always run with -wi before live updates.
- Test with a limited ValidSiteCodes set first.
- Keep SQL files and csv tier config under version control.
- Keep logs for rollback/reference before broad OU moves.
