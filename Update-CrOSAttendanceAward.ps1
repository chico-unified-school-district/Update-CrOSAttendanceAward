[cmdletbinding()]
param (
 [Parameter(Mandatory = $True)][string]$Server,
 [Parameter(Mandatory = $True)][string]$Database,
 [Parameter(Mandatory = $True)][System.Management.Automation.PSCredential]$Credential,
 [Parameter(Mandatory = $True)][int[]]$ValidSiteCodes,
 [Parameter(Mandatory = $True)][string]$DefaultCrosOrgUnit,
 [Parameter(Mandatory = $True)][string]$NoTardiesOrgUnit,
 # [string]$RootCrosOrgUnit,
 [switch]$CheckEachLoop,
 [Alias('wi')]
 [switch]$WhatIf
)

function Format-StudentObject {
 process {
  [PSCustomObject]@{
   cros                = $null
   lastTardyDays       = $null
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
   cutOffDays = $null
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

function Set-AwardZoneOU ($tiers) {
 process {
  if ($_.targetOU) { return $_ } # Skip if already set.
  # Best if tiers are sorted highest days to lowest
  $myTier = foreach ($tier in $tiers) {
   if ($_.lastTardyDays -gt $tier.cutOffDays) {
    $tier
    break
   }
  }
  $msg = $MyInvocation.MyCommand.Name, $_.sis.ID, $myTier.cutOffDays, $myTier.awardData.ou
  Write-Verbose ('{0},[{1}],CutOff Days: [{2}],Zone: [{3}]' -f $msg)
  $_.targetOU = $_.rootOU + $myTier.awardData.ou
  return $_
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

function Set-GoatOU ($ou) {
 process {
  # If no tardy date detected the set targetOU to GOAT. LET'S GOOOO!!!!
  if ($_.lastTardyDays -isnot [int]) {
   $_.targetOU = $_.rootOU + $ou
   Write-Information -MessageData "$($MyInvocation.MyCommand.Name),$($_.sis.ID),GOATED!" -InformationAction Continue
  }
  return $_
 }
}

function Set-LastTardyDays ($instance) {
 begin {
  $endOfDay = Get-Date 5PM
 }
 process {
  $sql = Get-Content -Path $_.tardyLookupSql -Raw
  $data = New-SqlOperation -Server $instance -Query $sql -Parameters "sn=$($_.sis.SN)"
  # Set tardy date to 11:59pm of that day to ensure that any tardies on the cut-off date will be included in the award zone evaluation.
  # This is because the award zone evaluation is looking for any tardies that are greater than the cut-off date,
  # so if a student had a tardy on the cut-off date and we set the time to 12:00am, it would not be included in the evaluation.
  $_.lastTardyDays = if ($data.DT -match '\d{4}') { ($endOfDay - (Get-Date $data.DT).AddDays(1).AddSeconds(-1)).days }
  if (($_.lastTardyDays -is [int]) -and ($_.lastTardyDays -lt 1)) { $_.lastTardyDays = 1 } # Round up to 1 when less than 1
  Write-Verbose ('{0},{1},[{2}],[{3}]' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.lastTardyDays, $data.DT)
  return $_
 }
}

function Set-LatestTardyLookupSql {
 process {
  $_.tardyLookupSql = switch ($_.sis.SC) {
   { $_ -in 5 } { '.\sql\sis-tardy-lookup-middle-school-full-day.sql' }
   default { throw ('{0},{1},Unknown SC: [{2}]' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.sis.SC) }
  }
  if (!$_.tardyLookupSql) { return }
  $_
 }
}

function Set-RootOU ($ou) {
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
   $ou + $specialOU
  }
  else {
   $ou
  }
  Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.rootOU)
  $_
 }
}

function Set-TierCutOffDays ($instance, $today) {
 process {
  $sql = (Get-Content -Path '.\sql\sis-select-cutoff-date.sql' -Raw) -replace '@count', $_.awardData.days
  $date = New-SqlOperation -Server $instance -Query $sql -Parameters "Count=$($_.awardData.days)" | Select-Object -ExpandProperty date
  # TODO maybe offset time to ensure proper count
  $_.cutOffDays = ($today - (Get-Date "$date 5:00PM")).days
  # Write-Verbose ('{0},{1},{2},{3:yyyy-MM-dd}' -f $MyInvocation.MyCommand.Name, $_.awardData.ou, $_.lookBackDayCount, $_.cutOffDays)
  $_
 }
}

function Show-Object {
 process {
  Write-Verbose ($MyInvocation.MyCommand.Name, $_, '=============================' | Out-String)
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
  $list.Add('id,sn,srcOU,targOU,daysSinceTardy')
 }
 process {
  $msg = $MyInvocation.MyCommand.Name, $_.sis.ID, $_.cros.serialNumber, $_.cros.orgUnitPath, $_.targetOU
  Write-Host ('{0},PermId:[{1}],SN:[{2}],Current OU:[{3}],New OU:[{4}]' -f $msg) -F Magenta
  $list.Add("$($_.sis.ID),$($_.cros.serialNumber),$($_.cros.orgUnitPath),$($_.targetOU),$($_.lastTardyDays)")
  if ($_.cros.orgUnitPath.Trim() -eq $_.targetOU) { return $_ } # No need to update if OU is correct
  if (!$WhatIf) {
   & $gam redirect stderr null update cros $_.cros.deviceId ou $_.targetOU
   # & $gam update cros $_.cros.deviceId ou $_.targetOU *>$null
   Write-Host ('{0},[{1}],[{2}],CrOS OU Updated {3}>' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.targetOU, ('=' * 20)) -F Green
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
Import-Module -Name dbatools -Cmdlet Invoke-DbaQuery, Set-DbatoolsConfig, Connect-DbaInstance, Disconnect-DbaInstance
Import-Module -Name CommonScriptFunctions

Show-BlockInfo main
Clear-SessionData
if ($WhatIf) { Write-Host (Show-TestRun) -F Blue }

$gam = 'C:\GAM7\gam.exe'
$sisInstance = Connect-DbaInstance -SqlInstance $Server -Database $Database -SqlCredential $Credential
$endOfSchoolDay = Get-Date 5PM

$tierData = Import-Csv -Path '.\csv\awardTable.csv' |
 Sort-Object -Property days -Descending |
  Format-TierObject |
   Set-TierCutOffDays -instance $sisInstance -today $endOfSchoolDay

Write-Host ($tierData | Out-String) -F Green
if ($WhatIf) { Start-Sleep -Seconds 5 }
# exit

$siSCrosDevices = Get-SiSCrosDevices -instance $sisInstance
$gSuiteCrosDevices = Get-GSuiteCrosDevices

Get-SiSStudents -instance $sisInstance -siteCodes $ValidSiteCodes |
 Format-StudentObject |
   Set-CrosDevice -gSuiteData $gSuiteCrosDevices -sisData $siSCrosDevices |
    Set-LatestTardyLookupSql |
     Set-LastTardyDays -instance $sisInstance |
      Set-RootOU -ou $DefaultCrosOrgUnit |
       Set-GoatOU -ou $NoTardiesOrgUnit |
        Set-AwardZoneOU -tiers $tierData |
         Update-CrosOU |
          Show-Object

if ($WhatIf) { Show-TestRun }