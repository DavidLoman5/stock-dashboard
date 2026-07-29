# lib/stance-log.ps1 - the only module that reads or writes stance-log.json.
#
# ASCII source only (no BOM needed): file lifecycle and date arithmetic, no CJK literals.
#
# stance-log.json records one row per code per trade day: the confirmed level the page shows,
# the raw (unconfirmed) reading tomorrow's two-day confirmation needs, the score and the close.
# evaluate.ps1 reads it to score whether the grading engine's calls were any good.
#
# Two rules, both learned the hard way:
#
#   * rows are [ordered]. update-holdings.ps1 appended plain @{} rows to an array whose existing
#     members were order-preserving PSCustomObjects, so every run reshuffled only the new rows.
#     The file on disk had SIX different key orders in it before this module existed. That never
#     showed up in a commit only because stance-log.json is gitignored - which also means git is
#     not holding a backup of it
#   * an unreadable log SKIPS today's append and leaves the file alone. Unlike picks-log this is
#     deliberately not fatal: the daily run's real output is the page, and a missing stance row
#     costs one day of evaluation data. What it must never do is rewrite the file from an empty
#     or partial read

# Canonical key order. Anything not listed is dropped on normalisation, so an experiment that
# adds a field has to add it here too - which is the point.
$StanceLogFields = @('date','code','close','score','stance','raw')


function ConvertTo-StanceLogRow {
  <#  One row (PSCustomObject from ConvertFrom-Json, or a dictionary) in canonical key order.
      Normalising on READ as well as write is what lets an existing mixed-order file converge
      to one order the next time it is written. #>
  param($Row)
  $o=[ordered]@{}
  foreach($f in $StanceLogFields){
    $v = $null
    if($Row -is [System.Collections.IDictionary]){
      if($Row.Contains($f)){ $v=$Row[$f] }
    } else {
      $prop=$Row.PSObject.Properties[$f]
      if($prop){ $v=$prop.Value }
    }
    if($null -eq $v){ continue }
    switch($f){
      'close' { $o[$f]=[double]$v }
      'score' { $o[$f]=[int]$v }
      default { $o[$f]="$v" }
    }
  }
  return $o
}


function Get-StanceLog {
  <#  Returns @{ Rows=<normalised rows>; Ok=<bool> }.

      Ok=$false means "the file exists but could not be read" - the caller must then skip its
      append and must NOT write, or a transient read failure silently truncates history. A file
      that simply does not exist yet is Ok=$true with no rows. #>
  param([string]$Path, [int]$Retries=3, [int]$RetryPauseMs=1500)
  if(-not (Test-Path $Path)){ return @{ Rows=@(); Ok=$true } }
  $sj=$null
  for($i=0; $i -lt $Retries -and $null -eq $sj; $i++){
    try{ $sj = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch{ Start-Sleep -Milliseconds $RetryPauseMs }
  }
  if($null -eq $sj -or -not $sj.PSObject.Properties['rows']){
    return @{ Rows=@(); Ok=$false }
  }
  $rows=@()
  foreach($r in @($sj.rows)){ $rows += ,(ConvertTo-StanceLogRow $r) }
  return @{ Rows=$rows; Ok=$true }
}


function Get-PrevStanceMap {
  <#  code -> @{ d=<date>; s=<confirmed level>; raw=<unconfirmed reading> } from the most recent
      row STRICTLY BEFORE $Before.

      The page compares this against today's grade to flag transitions - the transition day is
      the actionable signal, not the standing level - and Get-StanceGrade needs `raw` for the
      two-day confirmation rule. Rows written before six levels shipped have no `raw`; fall back
      to `stance` so the first run after the switchover confirms against itself rather than
      throwing. Pure function of rows + date, which is what makes it testable at all. #>
  param($Rows, [string]$Before)
  $map=@{}
  foreach($r in @($Rows)){
    $rc="$($r.code)"; $rd="$($r.date)"
    if($rd -ge $Before){ continue }
    if($null -eq $r.stance -or "$($r.stance)" -eq ''){ continue }
    if($map.ContainsKey($rc) -and $rd -le $map[$rc].d){ continue }
    $rw = if($null -ne $r.raw -and "$($r.raw)" -ne ''){ "$($r.raw)" } else { "$($r.stance)" }
    $map[$rc]=@{ d=$rd; s="$($r.stance)"; raw=$rw }
  }
  return $map
}


function Set-StanceLog {
  <#  Write the log, normalising every row so a file that accumulated several key orders
      converges to one. -ErrorAction Stop: the callers run with $ErrorActionPreference
      ='Continue', where a failed write is merely printed and the run reports success. #>
  param([string]$Path, $Rows)
  $out=@()
  foreach($r in @($Rows)){ $out += ,(ConvertTo-StanceLogRow $r) }
  [ordered]@{ rows=$out } | ConvertTo-Json -Depth 4 |
    Out-File $Path -Encoding UTF8 -ErrorAction Stop
}
