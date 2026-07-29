# evaluate.ps1 - weekly attribution report (run Fridays by the schedule, or manually anytime)
# Reads picks-log.json (closed picks w/ factor snapshots) + stance-log.json (holding stances),
# answers "which entry conditions actually beat the index", writes eval-report.json for the AI
# to distill into lessons.md, and splices <script id="evaldata"> so the page shows the report.
# UTF-8 with BOM (the comments below name the CJK exit reasons; tests.ps1 [2] enforces it).
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/pagedata.ps1')   # Set-PageBlocks / Get-PageBlockText / Get-PageContract

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

# holding-stance forward validation: avg return 20 rows (trade days) after each stance
$stancePath=Join-Path $root 'stance-log.json'
if(Test-Path $stancePath){
  try{
    $sl=@((Get-Content $stancePath -Raw -Encoding UTF8 | ConvertFrom-Json).rows)
    # Only rows written under the six-level scheme are comparable: the old four levels came from a
    # different score range (-4..+4, no two-day confirmation), so mixing them would average apples
    # with pears. Presence of `raw` is the cutover marker - self-describing, no hard-coded date.
    # Cost: ~21 new rows per code are needed before any forward return exists, so the weekly
    # "持股判級驗證" block stays empty for about a month after the switch.
    $sl=@($sl | Where-Object { $null -ne $_.raw })
    $byCode=@{}
    foreach($r in $sl){ $c="$($r.code)"; if(-not $byCode.ContainsKey($c)){ $byCode[$c]=@() }; $byCode[$c]+=,$r }
    $fw=@{}
    foreach($c in $byCode.Keys){
      $rows=$byCode[$c]
      for($i=0;$i -lt $rows.Count-20;$i++){
        $r0=$rows[$i]; $r1=$rows[$i+20]
        if($r0.close -gt 0){
          $ret=($r1.close/$r0.close-1)*100
          $k="$($r0.stance)"
          if(-not $fw.ContainsKey($k)){ $fw[$k]=@() }
          $fw[$k]+=,$ret
        }
      }
    }
    $stanceFw=[ordered]@{}
    foreach($k in @('add','addwatch','hold','cutwatch','cut','exit')){
      if($fw.ContainsKey($k)){ $v=$fw[$k]; $stanceFw[$k]=@{ n=$v.Count; avgFwd20=[math]::Round(($v|Measure-Object -Average).Average,2) } }
    }
    if($stanceFw.Keys.Count -gt 0){ $out.stanceForward=$stanceFw }
  }catch{ Write-Host "stance-log skipped: $($_.Exception.Message)" }
}

$out | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root 'eval-report.json') -Encoding UTF8
Write-Host "wrote eval-report.json"

# splice into the page (card auto-hides below 5 closed samples)
$idxPath=Join-Path $root 'index.html'
if(Test-Path $idxPath){
  Set-PageBlocks -IndexPath $idxPath -Blocks @{ evaldata=$out }
  Write-Host "spliced EVAL into index.html"
}
Write-Host "DONE."
