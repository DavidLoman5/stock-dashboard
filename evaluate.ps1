# evaluate.ps1 - weekly attribution report (run Fridays by the schedule, or manually anytime)
# Reads picks-log.json (closed picks w/ factor snapshots) + stance-log.json (holding stances),
# answers "which entry conditions actually beat the index", writes eval-report.json for the AI
# to distill into lessons.md, and splices <script id="evaldata"> so the page shows the report.
# UTF-8 with BOM (the comments below name the CJK exit reasons; tests.ps1 [2] enforces it).
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/pagedata.ps1')     # Set-PageBlocks / Get-PageBlockText / Get-PageContract
. (Join-Path $root 'lib/stance-log.ps1')  # Get-StanceLog / Get-StanceAttribution

function Grp($rows){
  $a=@($rows | Where-Object { $_.PSObject.Properties['alphaFinal'] -and $null -ne $_.alphaFinal })
  if($a.Count -eq 0){ return $null }
  $w=@($a | Where-Object { $_.alphaFinal -gt 0 }).Count
  # [ordered] so the emitted JSON is byte-stable across runs: a plain hashtable enumerates in
  # per-process string-hash order, which made every daily commit rewrite the whole report.
  return [ordered]@{ n=$a.Count
            winRate=[math]::Round($w/$a.Count*100,0)
            avgAlpha=[math]::Round(($a|Measure-Object -Property alphaFinal -Average).Average,2)
            avgRet=[math]::Round(($a|Measure-Object -Property retFinal -Average).Average,2) }
}
function Bucket($rows,$prop,$cuts,$labels){
  $b=[ordered]@{}
  for($i=0;$i -lt $labels.Count;$i++){
    $lo=$cuts[$i]; $hi=$cuts[$i+1]
    $sel=@($rows | Where-Object { $_.PSObject.Properties[$prop] -and $null -ne $_.$prop -and $_.$prop -ge $lo -and $_.$prop -lt $hi })
    $g=Grp $sel; if($g){ $b[$labels[$i]]=$g }
  }
  return $b
}

# a transient read failure here would splice a false closedN=0 report - retry, then abort in the caller
function ReadJsonRetry($path){
  for($i=0;$i -lt 3;$i++){
    try{ return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}
$lg = ReadJsonRetry (Join-Path $root 'picks-log.json')
if($null -eq $lg -or -not $lg.PSObject.Properties['picks']){
  Write-Host 'FATAL: picks-log.json unreadable - aborting (would otherwise emit an empty/false report)'
  exit 1
}
# screen.ps1 keeps only the most recent settled picks in picks-log.json (it is published and
# rewritten daily); everything older was appended to this archive. Reading both back means the
# retention window never changes what the attribution report says. A missing archive is normal
# on a fresh clone and is NOT fatal - only an unreadable picks-log.json is.
$arcPath = Join-Path $root 'data/picks-archive.jsonl'
$arcRows=@()
if(Test-Path $arcPath){
  foreach($ln in (Get-Content $arcPath -Encoding UTF8)){
    if(-not "$ln".Trim()){ continue }
    try{ $arcRows += ,($ln | ConvertFrom-Json) }catch{ Write-Host "  skipped an unparsable archive line" }
  }
  Write-Host "archive rows: $($arcRows.Count)"
}
# de-dupe on date|code: a crash between the archive append and the log rewrite can leave a row
# in both files, and double-counting it would quietly bias every bucket in the report.
$seenKey=@{}
$closed=@()
foreach($p in (@($lg.picks)+$arcRows)){
  if($p.status -ne 'closed'){ continue }
  $k="$($p.date)|$($p.code)"
  if($seenKey.ContainsKey($k)){ continue }
  $seenKey[$k]=$true
  $closed += ,$p
}
Write-Host "closed picks: $($closed.Count)"

$out=[ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd'); closedN=$closed.Count; overall=(Grp $closed) }

$byReason=[ordered]@{}
foreach($g in ($closed | Group-Object reason)){ $r=Grp @($g.Group); if($r){ $byReason[$g.Name]=$r } }
$out.byReason=$byReason

$byLight=[ordered]@{}
foreach($g in ($closed | Where-Object { $_.PSObject.Properties['light'] -and $_.light } | Group-Object light)){ $r=Grp @($g.Group); if($r){ $byLight[$g.Name]=$r } }
$out.byLight=$byLight

$byInd=[ordered]@{}
foreach($g in ($closed | Where-Object { $_.PSObject.Properties['ind'] -and $_.ind } | Group-Object ind)){
  if(@($g.Group).Count -ge 3){ $r=Grp @($g.Group); if($r){ $byInd[$g.Name]=$r } }
}
$out.byInd=$byInd

$byTag=[ordered]@{}
foreach($g in ($closed | Where-Object { $_.PSObject.Properties['aiSust'] } | Group-Object aiSust)){
  $lbl= if("$($g.Name)" -match 'True'){ 'sustainable' } else { 'one-off' }
  $r=Grp @($g.Group); if($r){ $byTag[$lbl]=$r }
}
$out.byAiTag=$byTag

$out.byChip=Bucket $closed 'chipS' @(0,30,38,101)        @('chip<30','chip30-37','chip38+')
$out.byTech=Bucket $closed 'techS' @(0,15,25,101)        @('tech<15','tech15-24','tech25+')
$out.byFund=Bucket $closed 'fundS' @(0,10,20,101)        @('fund<10','fund10-19','fund20+')
$out.byYoy =Bucket $closed 'yoy'   @(-100000,0,30,100000) @('yoy<0','yoy0-30','yoy30+')

# Holding-stance forward validation - "is the 判級 grade worth anything?".
#
# The previous version of this block asked for 20 forward rows PER CODE and offered nothing else.
# Since the six-level switchover each code has had roughly 14 rows, so that loop never executed a
# single time and `stanceForward` silently never appeared in eval-report.json - the grading engine
# was the one part of the system with no accuracy measurement at all. Three windows now (5/10/20),
# so the short ones report while 20 is still filling, plus an alpha baseline, a win rate, and the
# monotonicity score that is the actual answer to "does the ordering of the six levels hold up".
# Bucketed by engine version so a rewrite of lib/stance.ps1 can be judged against its predecessor
# instead of being averaged into it. Full contract in lib/stance-log.ps1.
$stancePath=Join-Path $root 'stance-log.json'
if(Test-Path $stancePath){
  try{
    $sl=Get-StanceLog -Path $stancePath
    if(-not $sl.Ok){ Write-Host '  WARN: stance-log.json unreadable - byStance omitted from this report' }
    else{
      $st=Get-StanceAttribution -Rows $sl.Rows
      if($st){
        $out.byStance=$st
        foreach($vk in $st.Keys){
          $w=$st[$vk].windows
          $bits=@()
          foreach($wk in $w.Keys){ if($w[$wk].Contains('monotonicity')){ $bits += "$wk=$($w[$wk].monotonicity)" } }
          Write-Host "  byStance $vk (n=$($st[$vk].n)) monotonicity: $($bits -join ' ')"
        }
      }
    }
  }catch{ Write-Host "stance-log skipped: $($_.Exception.Message)" }
}

# Depth 8, not 5: byStance nests version -> windows -> fwd5 -> levels -> add -> n. At depth 5 the
# level maps serialise as the literal string "System.Collections.Specialized.OrderedDictionary",
# which is valid JSON and therefore fails silently. page-contract.json's evaldata depth matches.
$out | ConvertTo-Json -Depth 8 | Out-File (Join-Path $root 'eval-report.json') -Encoding UTF8
Write-Host "wrote eval-report.json"

# splice into the page (card auto-hides below 5 closed samples)
$idxPath=Join-Path $root 'index.html'
if(Test-Path $idxPath){
  Set-PageBlocks -IndexPath $idxPath -Blocks @{ evaldata=$out }
  Write-Host "spliced EVAL into index.html"
}
Write-Host "DONE."
