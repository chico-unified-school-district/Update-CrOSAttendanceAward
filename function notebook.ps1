function Set-AwardZone ($tierArray, $startDate, $noTardiesOu) {
 begin {
  $daysSinceSchoolStart = ((Get-Date) - (Get-Date $startDate)).days

 }
 process {

  # TODO Rewrite using just whole integers instead of stupid dates!

  # If no tardy date detected the set to GOAT and move on to next step
  # if ($_.latestTardyDate -isnot [datetime]) {
  if ($_.lastTardy -notmatch '\d') {
   $_.targetOU = $_.rootOU + $noTardiesOu
   return $_
  }

  # $dateSinceEnr = (Get-Date 5:00PM).AddDays($_.daysSinceEnrollment * -1)

  foreach ($tier in $tierArray) {
   # $tiersArray MUST be ordered highest to lowest.
   # if ($tier.cutOffDate -lt $firstDaySchoolDate) {
   if ($tier.awardData.days -lt $daysSinceSchoolStart) {
    $_.targetOU = $_.rootOU + $noTardiesOu
    return $_
   }
   if ($dateSinceEnr -gt $tier.cutOffDate) {
    $_.targetOU = $_.rootOU + $noTardiesOu
   }
   if ($_.latestTardyDate -lt $tier.cutOffDate) {
    $_.targetOU = $_.rootOU + $tier.AwardData.ou
    return $_ # If we get a match, we can exit the loop and function early since tiers are ordered highest to lowest.
   }
  }
  $_.targetOU = $_.rootOU + $tierArray[-1].AwardData.ou # No award, set target OU to 0 day OU
  $_
 }
}


# function Set-AwardZone ($tierArray, $startDate, $noTardiesOu) {
#  begin {
#   $firstDaySchoolDate = Get-Date $startDate
#  }
#  process {

#   # TODO Rewrite using just whole integers instead of stupid dates!

#   # If no tardy date detected the set to GOAT and move on to next step
#   if ($_.latestTardyDate -isnot [datetime]) {
#    $_.targetOU = $_.rootOU + $noTardiesOu
#    return $_
#   }

#   $dateSinceEnr = (Get-Date 5:00PM).AddDays($_.daysSinceEnrollment * -1)

#   foreach ($tier in $tierArray) {
#    # $tiersArray MUST be ordered highest to lowest.
#    if ($tier.cutOffDate -lt $firstDaySchoolDate) {
#     $_.targetOU = $_.rootOU + $noTardiesOu
#     return $_
#    }
#    if ($dateSinceEnr -gt $tier.cutOffDate) {
#     $_.targetOU = $_.rootOU + $noTardiesOu
#    }
#    if ($_.latestTardyDate -lt $tier.cutOffDate) {
#     $_.targetOU = $_.rootOU + $tier.AwardData.ou
#     return $_ # If we get a match, we can exit the loop and function early since tiers are ordered highest to lowest.
#    }
#   }
#   $_.targetOU = $_.rootOU + $tierArray[-1].AwardData.ou # No award, set target OU to 0 day OU
#   $_
#  }
# }

# function Set-AwardZoneOU ($tierArray, $noTardiesOu, $schoolYearStartDays) {
#  process {
#   if ($_.targetOU) { return $_ } # Skip if already set.

#   $_.targetOU = foreach ($tier in $tierArray) {
#    # $tiersArray MUST be ordered highest to lowest.
#    # if ($tier.awardData.days -lt $schoolYearStartDays) {
#    #  $_.targetOU = $_.rootOU + $noTardiesOu
#    #  return $_
#    # }
#    # if ($_.daysSinceEnrollment -gt $tier.cutOffDays) {
#    #  $_.targetOU = $_.rootOU + $noTardiesOu
#    # }
#    Write-Host ('{0},{1} < {2}' -f $MyInvocation.MyCommand.Name, $tier.cutOffDays, $_.lastTardyDays) -F Blue
#    if ($tier.cutOffDays -lt $_.lastTardyDays) {
#     $_.rootOU + $tier.AwardData.ou
#     continue
#     # $_.targetOU = $_.rootOU + $tier.AwardData.ou
#     # return $_ # If we get a match, we can exit the loop and function early since tiers are ordered highest to lowest.
#    }
#   }
#   # $_.targetOU = $_.rootOU + $tierArray[-1].AwardData.ou # No award, set target OU to 0 day OU
#   return $_
#  }
# }

# function Set-AwardZoneOU ($tiers) {
#  process {
#   if ($_.targetOU) { return $_ } # Skip if already set.

#   $ou = switch ($_.lastTardyDays) {
#    { $_ -gt ($tiers.Where({ [int]$_.awardData.days -eq 80 })).cutOffDays } { '/AttStreak/80day'; break }
#    { $_ -gt ($tiers.Where({ [int]$_.awardData.days -eq 50 })).cutOffDays } { '/AttStreak/50day'; break }
#    { $_ -gt ($tiers.Where({ [int]$_.awardData.days -eq 30 })).cutOffDays } { '/AttStreak/30day'; break }
#    { $_ -gt ($tiers.Where({ [int]$_.awardData.days -eq 10 })).cutOffDays } { '/AttStreak/10day'; break }
#    { $_ -gt ($tiers.Where({ [int]$_.awardData.days -eq 05 })).cutOffDays } { '/AttStreak/5day'; break }
#    default { '/AttStreak/0day' }
#   }
#   $_.targetOU = $_.rootOU + $ou
#   return $_
#  }
# }

# function Get-SchoolStartDate ($instance) {
#  $sql = Get-Content -Path .\sql\sis-select-first-day-of-school.sql -Raw
#  $result = New-SqlOperation -Server $instance -Query $sql
#  if ($result.date -notmatch '\d{4}') {
#   Write-Error ('{0},School start date lookup error. Exiting.' -f $MyInvocation.MyCommand.Name)
#   exit
#  }
#  $startDate = Get-Date $result.date
#  if ($startDate -isnot [datetime]) {
#   Write-Error ('{0}' -f $MyInvocation.MyCommand.Name)
#   exit
#  }
#  Write-Host ('{0},{1}' -f $MyInvocation.MyCommand.Name, $startDate) -F Green
#  $startDate
# }

# $daysSinceSchoolStart = Get-DaysSinceSchoolStart -instance $sisInstance -today $endOfSchoolDay
# $schoolStartDate = Get-SchoolStartDate -instance $sisInstance

function Get-DaysSinceSchoolStart ($instance, $today ) {
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
 $days = ($today - $startDate).days
 Write-Host ('{0},{1},Days Since School Start: {2}' -f $MyInvocation.MyCommand.Name, $startDate, $days) -F Green
 $days
}


function Set-DaysSinceEnrollment {
 process {
  $_.daysSinceEnrollment = New-TimeSpan -Start (Get-Date $_.sis.ED) -End (Get-Date) | Select-Object -ExpandProperty Days
  # Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.daysSinceEnrollment)
  $_
 }
}


function Set-DefaultOU ($ou) {
 process {
  $_.targetOU = switch ($_.sis.SC) {
   { $_ -in 5 } { '/Chromebooks/1:1' }
   default { $ou }
  }
  Write-Verbose ('{0},{1},{2}' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.targetOU)
  $_
 }
}

# function Update-CrosOU {
#  begin {
#   New-Item -Path .\log -ItemType Directory -Force | Out-Null
#   $oldLogs = Get-ChildItem -Path .\log
#   Write-Host ('{0},Removing old log files...' -f $MyInvocation.MyCommand.Name) -F Cyan
#   $oldLogs | Remove-Item -Force -Confirm:$false

#   $awardLog = ".\log\award-log-$(Get-Date -f yyyy-MM-dd).csv"
#   $list = New-Object System.Collections.Generic.List[string]
#   $list.Add('id,sn,srcOU,targOU,daysSinceTardy')
#  }
#  process {
#   $msg = $MyInvocation.MyCommand.Name, $_.sis.ID, $_.cros.serialNumber, $_.cros.orgUnitPath, $_.targetOU
#   Write-Host ('{0},PermId:[{1}],SN:[{2}],Current OU:[{3}],New OU:[{4}]' -f $msg) -F Magenta
#   $list.Add("$($_.sis.ID),$($_.cros.serialNumber),$($_.cros.orgUnitPath),$($_.targetOU),$($_.lastTardyDays)")
#   if ($_.cros.orgUnitPath.Trim() -eq $_.targetOU) { return $_ } # No need to update if OU is correct
#   if (!$WhatIf) {
#    & $gam redirect stderr null update cros $_.cros.deviceId ou $_.targetOU
#    # & $gam update cros $_.cros.deviceId ou $_.targetOU *>$null
#    Write-Host ('{0},[{1}],[{2}],CrOS OU Updated {3}>' -f $MyInvocation.MyCommand.Name, $_.sis.ID, $_.targetOU, ('=' * 20)) -F Green
#   }
#   $_
#  }
#  end {
#   if ($list.Count -gt 1) {
#    $list | Out-File -FilePath $awardLog -Encoding utf8 -Force -Confirm:$false
#    Write-Host ('{0},Award log exported to: {1}' -f $MyInvocation.MyCommand.Name, $awardLog) -F Green
#   }
#  }
# }