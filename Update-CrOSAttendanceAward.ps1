[cmdletbinding()]
param (
 [Parameter(Mandatory = $True)][string]$Server,
 [Parameter(Mandatory = $True)][string]$Database,
 [Parameter(Mandatory = $True)][System.Management.Automation.PSCredential]$Credential,
 [Parameter(Mandatory = $True)][int[]]$ValidSiteCodes,
 [Parameter(Mandatory = $True)][string]$DefaultCrosOrgUnit,
 # [string]$RootCrosOrgUnit,
 [switch]$CheckEachLoop,
 [Alias('wi')]
 [switch]$WhatIf
)

function Format-StudentObject {
 process {
  [PSCustomObject]@{
   cros                = $null
   daysSinceEnrollment = $null
   latestTardyDate     = $null
   rootOU              = $null
   sis                 = $_
   tardyLookupSql      = $null
   targetOU            = $null
  }
 }
}

function Format-TierObject {
 process {
  # Write-Verbose ($_ | Out-String)
  [PSCustomObject]@{
   awardData  = $_
   cutOffDate = $null
  }
 }
}

function Get-GSuiteCrosDevices {
 # TODO For Testing only, remove caching and backdating for production use. Maybe add a parameter to control this.
 Write-Host ('{0},Removing old .csv (gSuite data) files...' -f $MyInvocation.MyCommand.Name) -F Cyan
 $deleteOlderThanDate = (Get-Date).AddDays(-1)
 $oldCSVs = Get-ChildItem -Path .\data\*.csv | Where-Object { ($_.LastWriteTime -le $deleteOlderThanDate) }
 $oldCSVs | Remove-Item -Force -Confirm:$false

 $exportPath = ".\data\GSuite-Export-$(Get-Date -f yyyy-MM-dd).csv"
 if ((Test-Path -Path $exportPath) -and ($WhatIf)) {
  Write-Host ('{0},Importing GSuite Cros data from existing .csv file...' -f $MyInvocation.MyCommand.Name) -F Green
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
  # TODO
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
  $dateSinceEnr = (Get-Date 5:00PM).AddDays($_.daysSinceEnrollment * -1)
  # Tiers being ordered highest to lowest required.
  foreach ($tier in $tierArray) {
   if ($tier.cutOffDate -lt $firstDaySchoolDate) {
    Write-Verbose ( '{0},{1} > {2}, Too early in the school year.=============>' -f $MyInvocation.MyCommand.Name, $tier.cutOffDate, $firstDaySchoolDate, $tier.awardData.ou )
    continue
   }
   if ($dateSinceEnr -gt $tier.cutOffDate) {
    Write-Verbose ( '{0},{1},{2} > {3}, Enrollment too fresh for tier {4} ||||||||||' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $dateSinceEnr, $tier.cutOffDate, $tier.awardData.ou )
    continue
   }
   if (($_.latestTardyDate -lt $tier.cutOffDate) -or ($_.latestTardyDate -isnot [datetime])) {
    Write-Host ('{0},{1},{2},{3}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.latestTardyDate, $tier.awardData.ou) -F Green
    $_.targetOU = $_.rootOU + $tier.AwardData.ou # Update from default OU to award OU
    return $_ # If we get a match, we can exit the loop and function early since tiers are ordered highest to lowest.
   }
  }
  $_.targetOU = $_.rootOU + $tierArray[-1].AwardData.ou # No award, set target OU to 0 day OU
  Write-Host ('{0},{1},No award tier matched. Target OU set to Restart Day OU: {2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.targetOU) -F Blue
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

function Set-DaysSinceEnrollment {
 process {
  $_.daysSinceEnrollment = New-TimeSpan -Start (Get-Date $_.sis.ED) -End (Get-Date) | Select-Object -ExpandProperty Days
  # Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.daysSinceEnrollment)
  $_
 }
}

# function Set-DefaultOU ($ou) {
#  process {
#   $_.targetOU = switch ($_.sis.SC) {
#    { $_ -in 5 } { '/Chromebooks/1:1' }
#    default { $ou }
#   }
#   Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.targetOU)
#   $_
#  }
# }

function Set-LatestTardyDate($instance) {
 process {
  $sql = Get-Content -Path $_.tardyLookupSql -Raw
  $data = New-SqlOperation -Server $instance -Query $sql -Parameters "permId=$($_.sis.ID)"
  # Set tardy date to 11:59pm of that day to ensure that any tardies on the cut-off date will be included in the award zone evaluation.
  # This is because the award zone evaluation is looking for any tardies that are greater than the cut-off date,
  # so if a student had a tardy on the cut-off date and we set the time to 12:00am, it would not be included in the evaluation.
  $_.latestTardyDate = if ($data.DT -match '\d{4}') { (Get-Date $data.DT).Date.AddDays(1).AddSeconds(-1) } else { $null }
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

function Set-RootOU ($defaultRootOU) {
 begin {
  $specialOUs = Import-Csv -Path .\csv\special-ous.csv
 }
 process {
  $specialOU = foreach ($entry in $specialOUs) {
   if ($_.cros.OrgUnitPath -match $entry.ou) {
    $entry.ou
   }
  }
  $_.rootOU = if ($specialOU) {
   $defaultRootOU + $specialOU
  }
  else {
   $defaultRootOU
  }
  Write-Host ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.rootOU) -F Yellow
  $_
 }
}

function Set-TierCutOffDate ($instance) {
 process {
  $sql = (Get-Content -Path '.\sql\sis-select-cutoff-date.sql' -Raw) -replace '@count', $_.awardData.days
  $date = New-SqlOperation -Server $instance -Query $sql -Parameters "Count=$($_.awardData.days)" | Select-Object -ExpandProperty date
  $_.cutOffDate = Get-Date "$date 5:00PM"
  Write-Verbose ('{0},{1},{2},{3:yyyy-MM-dd}' -f $MyInvocation.MyCommand.Name, $_.awardData.ou, $_.lookBackDayCount, $_.cutOffDate)
  $_
 }
}

function Show-Object {
 process {
  Write-Verbose ($MyInvocation.MyCommand.Name, $_ | Out-String)
  if ($CheckEachLoop) { Read-Host 'eh?' }
 }
}

function Update-CrosOU {
 begin {
  New-Item -Path .\log -ItemType Directory -Force | Out-Null
  $oldLogs = Get-ChildItem -Path .\log
  Write-Host ('{0},Removing old log files...' -f $MyInvocation.MyCommand.Name) -F Cyan
  $oldLogs | Remove-Item -Force -Confirm:$false

  $awardLog = ".\log\award-log-$(Get-Date -f yyyy-MM-dd).csv"
  $list = New-Object System.Collections.Generic.List[string]
  $list.Add('id,sn,srcOU,targOU,lastTardyDate')
 }
 process {
  $msg = $MyInvocation.MyCommand.Name, $_.sis.ID, $_.cros.serialNumber, $_.cros.orgUnitPath, $_.targetOU
  if ($_.cros.orgUnitPath.Trim() -eq $_.targetOU) { return } # No need to update if OU is correct
  Write-Host ('{0},PermId: [{1}],SN: [{2}],Current OU:[{3}],New OU:[{4}]' -f $msg) -F Magenta
  $list.Add("$($_.sis.ID),$($_.cros.serialNumber),$($_.cros.orgUnitPath),$($_.targetOU),$($_.latestTardyDate)")
  if (!$WhatIf) {
   & $gam update cros $_.cros.deviceId ou $_.targetOU *>$null
   Write-Host ('{0}, {1}, {2}, CrOS OU Updated {3}>' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.targetOU, ('=' * 20)) -F Green
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

$tierData = Import-Csv -Path '.\csv\awardTable.csv' |
 Sort-Object -Property days -Descending |
  Format-TierObject |
   Set-TierCutOffDate -instance $sisInstance

Write-Host ($tierData | Out-String) -F Green
if ($WhatIf) { Start-Sleep -Seconds 5`  }
# exit
$schoolStartDate = Get-SchoolStartDate -instance $sisInstance

$siSCrosDevices = Get-SiSCrosDevices -instance $sisInstance
$gSuiteCrosDevices = Get-GSuiteCrosDevices

Get-SiSStudents -instance $sisInstance -siteCodes $ValidSiteCodes |
 Format-StudentObject |
  Set-DaysSinceEnrollment |
   Set-CrosDevice -gSuiteData $gSuiteCrosDevices -sisData $siSCrosDevices |
    Set-LatestTardyLookupSql |
     Set-LatestTardyDate -instance $sisInstance |
      # Set-DefaultOU -ou $DefaultCrosOrgUnit |
      Set-RootOU -defaultRootOU $DefaultCrosOrgUnit |
       Set-AwardZone -tierArray $tierData -startDate $schoolStartDate |
        Update-CrosOU |
         Show-Object

if ($WhatIf) { Show-TestRun }