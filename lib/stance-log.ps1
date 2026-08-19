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
#
#   idx  the TAIEX close on the same trade day. Present so evaluate.ps1 can compute an
#        index-relative alpha for each grade WITHOUT a network call or a join against another
#        file - the log becomes self-sufficient for attribution. Rows written before this field
#        shipped have no idx; evaluate.ps1 falls back to a cross-sectional baseline for those.
#   v    which version of the grading engine produced the row ($StanceEngineVersion in
#        lib/stance.ps1). Averaging rows from two different formulas is how an engine change
#        gets to look like an improvement, so evaluate.ps1 buckets by this and never mixes.
$StanceLogFields = @('date','code','close','score','stance','raw','idx','v')


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
      'idx'   { $o[$f]=[double]$v }
      'score' { $o[$f]=[int]$v }
      'v'     { $o[$f]=[int]$v }
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


# $StanceLevelOrder / Get-StanceLevelRank come from the engine that emits the levels - one
# definition, not a second copy that drifts. stance.ps1 is a pure leaf (functions and constants,
# no side effects), so dot-sourcing it here is free and safe to do twice.
. (Join-Path $PSScriptRoot 'stance.ps1')


function Get-StanceRowVersion {
  <#  Which engine produced a row. Explicit `v` stamp wins; otherwise infer from shape, because
      the two pre-stamp eras are distinguishable: six-level rows carry `raw`, four-level ones
      do not. Self-describing beats a hard-coded cutover date that nobody updates. #>
  param($Row)
  $r = ConvertTo-StanceLogRow $Row
  if($r.Contains('v')){ return [int]$r['v'] }
  if($r.Contains('raw') -and "$($r['raw'])" -ne ''){ return 2 }
  return 1
}


function Get-StanceAttribution {
  <#  Does the grade predict anything? Returns one block per engine version:

        v2 = @{ n; windows = @{ fwd5 = @{ levels=@{add=@{n;avgRet;avgAlpha;winRate};...}
                                          monotonicity; inversions; pairs; baseline; nIdx } } }

      The headline number is `monotonicity`, not any single bucket's return. "Is this grade any
      good" is a question about ORDER - add should beat addwatch should beat hold ... should beat
      exit - so we score the share of level pairs that come out the right way round: 100 = the
      ordering held everywhere, 50 = coin flip, 0 = exactly inverted. One number, trackable week
      to week, and it is the only thing that says whether a rewrite of the engine helped.

      Versions are reported SEPARATELY and never pooled. That is the whole point of the `v` stamp:
      after the engine changes you want to see v2 and v3 side by side, not one blended average
      that moves for reasons unrelated to the market.

      Baseline for alpha is cross-sectional: the same-day equal-weight mean forward return of
      every code in the log. It controls for market drift using the same universe being graded,
      and unlike the index it is available for 100% of rows including the ones written before
      `idx` existed. `nIdx` counts how many rows could also support an index-relative baseline,
      so it is visible when switching becomes viable.

      Forward windows count TRADE DAYS PRESENT IN THE LOG, not rows of this particular code, so a
      code that is missing for a day (its owner removed and re-added it) is not quietly measured
      over a shorter horizon than everything it is being compared against.

      Pure function of rows -> report, so tests.ps1 can drive it with fixtures. #>
  param($Rows, [int[]]$Windows=@(5,10,20), [int]$MinN=10)

  # $norm, NOT $rows: PowerShell variable names are case-INSENSITIVE, so a local `$rows` is the
  # same storage as the `$Rows` parameter and emptying it discards the caller's input before the
  # loop below ever reads it. The function then returns $null for every possible input, which
  # looks exactly like "not enough data yet" and hides in a try/catch forever.
  $norm=@()
  foreach($r in @($Rows)){
    $n=ConvertTo-StanceLogRow $r
    if(-not $n.Contains('date') -or -not $n.Contains('code') -or -not $n.Contains('close')){ continue }
    if([double]$n['close'] -le 0){ continue }
    $n['_v']=Get-StanceRowVersion $r
    $norm += ,$n
  }
  if($norm.Count -eq 0){ return $null }

  $dates=@($norm | ForEach-Object { "$($_['date'])" } | Sort-Object -Unique)
  $di=@{}; for($i=0;$i -lt $dates.Count;$i++){ $di[$dates[$i]]=$i }

  $byCode=@{}
  foreach($r in $norm){
    $c="$($r['code'])"
    if(-not $byCode.ContainsKey($c)){ $byCode[$c]=@{} }
    $byCode[$c]["$($r['date'])"]=$r
  }

  $report=[ordered]@{}
  $vers=@($norm | ForEach-Object { $_['_v'] } | Sort-Object -Unique)

  foreach($w in $Windows){
    # pass 1: forward return per (date, code), plus the same-day mean that becomes the baseline
    $fwd=@{}; $sum=@{}; $cnt=@{}
    foreach($r in $norm){
      $d="$($r['date'])"; $c="$($r['code'])"
      $j=$di[$d]+$w
      if($j -ge $dates.Count){ continue }
      $d2=$dates[$j]
      if(-not $byCode[$c].ContainsKey($d2)){ continue }
      $r2=$byCode[$c][$d2]
      $ret=([double]$r2['close']/[double]$r['close']-1)*100
      if(-not $fwd.ContainsKey($d)){ $fwd[$d]=@{} }
      $fwd[$d][$c]=@{ ret=$ret; idx=$null }
      if($r.Contains('idx') -and $r2.Contains('idx') -and [double]$r['idx'] -gt 0){
        $fwd[$d][$c].idx = $ret - ([double]$r2['idx']/[double]$r['idx']-1)*100
      }
      if(-not $sum.ContainsKey($d)){ $sum[$d]=0.0; $cnt[$d]=0 }
      $sum[$d]+=$ret; $cnt[$d]++
    }

    # pass 2: bucket alpha by version and level
    $acc=@{}
    foreach($r in $norm){
      $d="$($r['date'])"; $c="$($r['code'])"
      if(-not $fwd.ContainsKey($d) -or -not $fwd[$d].ContainsKey($c)){ continue }
      if($cnt[$d] -lt 2){ continue }   # a one-code day has no cross-section to be relative to
      $lv="$($r['stance'])"
      if($StanceLevelOrder -notcontains $lv){ continue }
      $k="$($r['_v'])|$lv"
      if(-not $acc.ContainsKey($k)){ $acc[$k]=@{ ret=@(); alpha=@(); idx=@() } }
      $m=$fwd[$d][$c]
      $acc[$k].ret   += $m.ret
      $acc[$k].alpha += ($m.ret - $sum[$d]/$cnt[$d])
      if($null -ne $m.idx){ $acc[$k].idx += $m.idx }
    }

    foreach($v in $vers){
      $vk="v$v"
      if(-not $report.Contains($vk)){ $report[$vk]=[ordered]@{ n=@($norm | Where-Object { $_['_v'] -eq $v }).Count; windows=[ordered]@{} } }
      $levels=[ordered]@{}; $alphaBy=@{}; $nIdx=0
      foreach($lv in $StanceLevelOrder){
        $a=$acc["$v|$lv"]
        if(-not $a -or $a.ret.Count -eq 0){ continue }
        $avgA=($a.alpha | Measure-Object -Average).Average
        $wins=@($a.alpha | Where-Object { $_ -gt 0 }).Count
        $lr=[ordered]@{ n=$a.ret.Count
                        avgRet=[math]::Round(($a.ret | Measure-Object -Average).Average,2)
                        avgAlpha=[math]::Round($avgA,2)
                        winRate=[math]::Round($wins/$a.ret.Count*100,0) }
        # same n<10 bar the rest of this report lives by: shown, but flagged as not yet evidence
        if($a.ret.Count -lt $MinN){ $lr['provisional']=$true }
        if($a.idx.Count -gt 0){
          $lr['nIdx']=$a.idx.Count
          $lr['avgAlphaIdx']=[math]::Round(($a.idx | Measure-Object -Average).Average,2)
          $nIdx += $a.idx.Count
        }
        $levels[$lv]=$lr
        $alphaBy[$lv]=$avgA
      }
      # One level in a window says nothing about ORDER, which is the only question this block
      # exists to answer - emitting it just pads the report with a bucket nobody can act on.
      # (The v1 four-level era hits this: only its `hold` name survives into the six-level list.)
      $present=@($StanceLevelOrder | Where-Object { $alphaBy.ContainsKey($_) })
      if($present.Count -lt 2){ continue }
      # inversions: every ordered pair of levels that came out backwards
      $pairs=0; $inv=0
      for($i=0;$i -lt $present.Count;$i++){
        for($j=$i+1;$j -lt $present.Count;$j++){
          $pairs++
          if($alphaBy[$present[$i]] -lt $alphaBy[$present[$j]]){ $inv++ }
        }
      }
      $blk=[ordered]@{ levels=$levels; pairs=$pairs; inversions=$inv
                       monotonicity=[math]::Round((1-$inv/$pairs)*100,0)
                       baseline='cross-section'; nIdx=$nIdx }
      $report[$vk].windows["fwd$w"]=$blk
    }
  }
  # drop versions that produced no measurable window at all
  $keep=[ordered]@{}
  foreach($vk in $report.Keys){ if($report[$vk].windows.Keys.Count -gt 0){ $keep[$vk]=$report[$vk] } }
  if($keep.Keys.Count -eq 0){ return $null }
  return $keep
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
