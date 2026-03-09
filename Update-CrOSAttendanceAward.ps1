[cmdletbinding()]
param (
 [Parameter(Mandatory = $True)][string]$Server,
 [Parameter(Mandatory = $True)][string]$Database,
 [Parameter(Mandatory = $True)][System.Management.Automation.PSCredential]$Credential,
 [int[]]$ValidSiteCodes,
 [string]$DefaultCrosOrgUnit,
 [Alias('wi')]
 [switch]$WhatIf
)

function Format-StudentObject {
 process {
  [PSCustomObject]@{
   cros            = $null
   defaultOU       = $null
   latestTardyDate = $null
   sis             = $_
   tardyLookupSql  = $null
   targetOU        = $null
  }
 }
}

function Format-TierObject {
 process {
  # Write-Verbose ($_ | Out-String)
  [PSCustomObject]@{
   awardData       = $_
   daysBack        = $null
   studentFreeDays = $null
   weekEndDays     = $null
   cutOffDate      = $null
  }
 }
}

function Get-GSuiteCrosDevices {

 Write-Host ('{0},Removing old .csv (gSuite data) files...' -f $MyInvocation.MyCommand.Name) -F Cyan
 $deleteOlderThanDate = (Get-Date).AddDays(-1)
 $oldCSVs = Get-ChildItem -Path .\data\*.csv | Where-Object { ($_.LastWriteTime -le $deleteOlderThanDate) }
 $oldCSVs | Remove-Item -Force -Confirm:$false

 $exportPath = ".\data\GSuite-Export-$(Get-Date -f yyyy-MM-dd).csv"
 if (Test-Path -Path $exportPath) {
  $results = Import-Csv -Path $exportPath
 }
 else {
  # $fields = 'deviceId,serialNumber,orgUnitPath,recentUsers,lastsync'
  $fields = 'deviceId,serialNumber,orgUnitPath'
  $backDate = Get-Date (Get-Date 12:00AM).AddMonths(-6) -f yyyy-MM-dd
  Write-Host ('{0}' -f $MyInvocation.MyCommand.Name) -F Green
  $ErrorActionPreference = 'Continue'
  ($results = & $gam print cros fields $fields query "sync:$backDate.." | ConvertFrom-Csv )*>$null
  $ErrorActionPreference = 'Stop'
  $results | Export-Csv -Path $exportPath -NoTypeInformation
 }
 Write-Host ('{0},Count: {1}' -f $MyInvocation.MyCommand.Name, @($results).Count) -F Green
 $results
}

function Get-SchoolStartDate ($instance) {
 $sql = Get-Content -Path .\sql\sis-select-first-day-of-school.sql -Raw
 $result = New-SqlOperation -Server $instance -Query $sql
 if ($result.date -notmatch '\d{4}') {
  Write-Error ('{0},School start date lookup error. Exiting.' -f $MyInvocation.MyCommand.Name)
  exit
 }
 $startDate = Get-Date $result.date
 if ($startDate -isnot [datetime]) {
  Write-Error ('{0}' -f $MyInvocation.MyCommand.Name)
  exit
 }
 Write-Host ('{0},{1}' -f $MyInvocation.MyCommand.Name, $startDate) -F Green
 $startDate
}

function Get-SiSCrosDevices ($instance) {
 $sql = Get-Content -Path '.\sql\sis-get-cros.sql' -Raw
 $results = New-SqlOperation -Server $instance -Query $sql
 Write-Host ('{0},Count: {1}' -f $MyInvocation.MyCommand.Name, @($results).Count) -F Green
 $results | ConvertTo-Csv | ConvertFrom-Csv
}

function Get-SiSStudents ($instance, $siteCodes) {
 $siteCodeList = $siteCodes -join ','
 $studentQuery = (Get-Content -Path .\sql\sis-active-students.sql -Raw) -replace 'VALID_SITE_CODES', $siteCodeList
 $sisStudentData = Invoke-DbaQuery -SqlInstance $instance -Query $studentQuery
 Write-Host ('{0},Count: {1}' -f $MyInvocation.MyCommand.Name, $sisStudentData.Count) -F Green
 $sisStudentData | ConvertTo-Csv | ConvertFrom-Csv
}

function Set-AwardZone ($tierArray, $startDate) {
 begin {
  $firstDaySchoolDate = Get-Date $startDate
 }
 process {
  <# Start of school year - No tardies gets the highest award for which they might be eligible.
  Evaluated based the on the first day of school. Tiers being ordered highest to lowest makes this work.#>
  if ($_.latestTardyDate -isnot [datetime]) {
   foreach ($tier in $tierArray) {
    if ($tier.cutOffDate -gt $firstDaySchoolDate) {
     Write-Host ('{0},{1},{2},No Tardy Date Detected' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $tier.awardData.ou) -F Blue
     $_.targetOU = $tier.awardData.ou
     return $_
    }
    else { $_.defaultOU }
   }
  }
  # tiers need to be by sorted from most to least number of days for proper function.
  foreach ($tier in $tierArray) {
   if ($_.latestTardyDate -lt $tier.cutOffDate) {
    $_.targetOU = $tier.AwardData.ou
    Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $tier.awardData.ou)
    return $_
   }
  }
  $_.targetOU = $_.defaultOU # Catch-all
  $_
 }
}

function Set-CrosDevice ($sisData, $gSuiteData) {
 process {
  $permId = $_.sis.ID
  # Match SiS data with GSuite data
  $siSCros = $sisData | Where-Object { $_.ID -eq $permId } | Select-Object -First 1
  if (!$siSCros) {
   $msg = $MyInvocation.MyCommand.Name, $_.sis.ID
   Write-Host ('{0},{1},No assigned Cros device found in SIS. No OU assignment possible. Skipping...' -f $msg) -F Red
   return
  }
  $_.cros = $gSuiteData | Where-Object { $_.serialNumber -eq $siSCros.SerialNumber } | Select-Object -First 1
  if (!$_.cros) {
   #TODO Maybe do a full lookup if no match found
   $msg = $MyInvocation.MyCommand.Name, $_.sis.ID, $siSCros.SerialNumber
   Write-Host ('{0},{1},{2},No matching Cros device found in GSuite' -f $msg) -F Red
   return
  }
  Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.name, $_.sis.ID, $_.cros.deviceId)
  $_
 }
}

function Set-DaysBack {
 process {
  $_.daysBack = [int]$_.awardData.days + [int]$_.studentFreeDays + [int]$_.weekendDays
  $_
 }
}

function Set-DefaultOU ($defaultOU) {
 process {
  $_.defaultOU = switch ($_.sis.SC) {
   { $_ -in 5 } { '/Chromebooks/1:1' }
   default { $defaultOU }
  }
  Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.defaultOU)
  $_
 }
}

function Set-LatestTardyDate($instance) {
 process {
  $sql = Get-Content -Path $_.tardyLookupSql -Raw
  $data = New-SqlOperation -Server $instance -Query $sql -Parameters "permId=$($_.sis.ID)"
  $_.latestTardyDate = if ($data.DT -match '\d{4}') { Get-Date $data.DT } else { $null }
  Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.latestTardyDate)
  $_
 }
}

function Set-LatestTardyLookupSql {
 process {
  $_.tardyLookupSql = switch ($_.sis.SC) {
   { $_ -in 5 } { '.\sql\sis-tardy-lookup-middle-school.sql' }
   default { throw ('{0},{1},Unknown SC: [{2}]' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.sis.SC) }
  }
  if (!$_.tardyLookupSql) { return }
  $_
 }
}

function Set-StudentFreeDays ($instance) {
 begin {
  $sql = Get-Content -Path .\sql\sis-select-no-student-days.sql -Raw
 }
 process {
  $days = [int]$_.awardData.days * -1
  $sqlVars = "days=$days"
  # Write-Verbose ('{0},Days: {1}' -f $MyInvocation.MyCommand.Name, $sqlVars)
  $results = New-SqlOperation -Server $instance -Query $sql -Parameters $sqlVars
  # Write-Verbose ($results | Out-String)
  # Write-Host ('{0},Count: {1}' -f $MyInvocation.MyCommand.Name, @($results).Count) -F DarkBlue
  $_.studentFreeDays = if ($results) { $results.count } else { 0 }
  $_
 }
}

function Set-TierCutOffDate {
 process {
  [int]$days = $_.daysBack * -1
  $_.cutOffDate = (Get-Date 12:00AM).AddDays($days)
  Write-Host ('{0},{1},{2:yyyy-MM-dd}' -f $MyInvocation.MyCommand.Name, $_.awardData.ou, $_.cutOffDate) -F Green
  $_
 }
}

function Set-WeekendDays {
 process {
  $weekendCount = 0
  for ($i = 0; $i -lt $_.awardData.days; $i++) {
   # Subtract $i days from the current date
   $date = (Get-Date).AddDays(-$i)
   # Check if the DayOfWeek is Saturday or Sunday
   if ($date.DayOfWeek -eq 'Saturday' -or $date.DayOfWeek -eq 'Sunday') {
    $weekendCount++
   }
  }
  # Write-Host ('{0},Count: {1}' -f $MyInvocation.MyCommand.Name, $weekendCount) -F Blue
  $_.weekendDays = $weekendCount
  $_
 }
}

function Show-Object {
 process {
  Write-Verbose ($MyInvocation.MyCommand.Name, $_ | Out-String)
  # Read-Host 'eh!'
 }
}

function Update-CrosOU {
 begin {
  Write-Host ('{0},Removing old log files...' -f $MyInvocation.MyCommand.Name) -F Cyan
  $deleteOlderThanDate = (Get-Date).AddDays(-1)
  if (!(Test-Path -Path .\log)) { New-Item -Path .\log -ItemType Directory | Out-Null }
  $oldLogs = Get-ChildItem -Path .\log\*.log | Where-Object { ($_.LastWriteTime -le $deleteOlderThanDate) }
  $oldLogs | Remove-Item -Force -Confirm:$false

  $awardLog = ".\log\award-log-$(Get-Date -f yyyy-MM-dd).csv"
  $list = New-Object System.Collections.Generic.List[string]
  $list.Add('id,sn,ou')
 }
 process {
  $msg = $MyInvocation.MyCommand.Name, $_.sis.ID, $_.cros.serialNumber, $_.cros.orgUnitPath, $_.targetOU
  if ($_.cros.orgUnitPath.Trim() -eq $_.targetOU) { return }
  Write-Host ('{0},PermId: [{1}],SN: [{2}],Current OU:[{3}],New OU: [{4}]' -f $msg) -F Magenta
  $list.Add("$($_.sis.ID),$($_.cros.serialNumber),$($_.targetOU)")
  if (!$WhatIf) {
   & $gam update cros $_.cros.deviceId ou $_.targetOU *>$null
   Write-Host ('{0},{1},{2},CrOS OU Updated {3}>' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.targetOU, ('=' * 20)) -F Green
  }
  $_
 }
 end {
  if ($list.Count -gt 1) {
   $list | Out-File -FilePath $awardLog -Encoding utf8 -Force -Confirm:$false
   Write-Host ('{0},Award log exported to: {1}' -f $MyInvocation.MyCommand.Name, $awardLog) -F Green
  }
 }
}

# ==================== Main =====================
# Imported Functions
Import-Module -Name dbatools -Cmdlet Invoke-DbaQuery, Set-DbatoolsConfig, Connect-DbaInstance, Disconnect-DbaInstance
Import-Module -Name CommonScriptFunctions
Show-BlockInfo main
Clear-SessionData
if ($WhatIf) { Write-Host (Show-TestRun) -F Blue }

$gam = 'C:\GAM7\gam.exe'
$sisInstance = Connect-DbaInstance -SqlInstance $Server -Database $Database -SqlCredential $Credential

$awardTable = Import-Csv -Path '.\csv\awardTable.csv'

$tierData = $awardTable | Sort-Object -Property days -Descending | Format-TierObject |
 Set-WeekendDays |
  Set-StudentFreeDays -instance $sisInstance |
   Set-DaysBack |
    Set-TierCutOffDate
# Show-Object
# Write-Host ($tierData | Out-String) -F Green

$schoolStartDate = Get-SchoolStartDate -instance $sisInstance

$siSCrosDevices = Get-SiSCrosDevices -instance $sisInstance
$gSuiteCrosDevices = Get-GSuiteCrosDevices

Get-SiSStudents -instance $sisInstance -siteCodes $ValidSiteCodes | Format-StudentObject |
 Set-CrosDevice -gSuiteData $gSuiteCrosDevices -sisData $siSCrosDevices |
  Set-LatestTardyLookupSql |
   Set-LatestTardyDate -instance $sisInstance |
    Set-DefaultOU $DefaultCrosOrgUnit |
     Set-AwardZone -tierArray $tierData -startDate $schoolStartDate -defaultOU |
      Set-CrosDevice -sisData $siSCrosDevices -gSuiteData $gSuiteCrosDevices |
       Update-CrosOU |
        Show-Object

if ($WhatIf) { Show-TestRun }