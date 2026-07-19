# evaluate.ps1 - weekly attribution report (run Fridays by the schedule, or manually anytime)
# Reads picks-log.json (closed picks w/ factor snapshots) + stance-log.json (holding stances),
# answers "which entry conditions actually beat the index", writes eval-report.json for the AI
# to distill into lessons.md, and splices <script id="evaldata"> so the page shows the report.
# ASCII source only (no BOM needed).
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Grp($rows){
  $a=@($rows | Where-Object { $_.PSObject.Properties['alphaFinal'] -and $null -ne $_.alphaFinal })
  if($a.Count -eq 0){ return $null }
  $w=@($a | Where-Object { $_.alphaFinal -gt 0 }).Count
  return @{ n=$a.Count
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

# OneDrive can transiently lock/garble reads; a null read here would splice a false closedN=0 report
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
$closed=@($lg.picks | Where-Object { $_.status -eq 'closed' })
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
    foreach($k in @('up','hold','trim','defend')){
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
  $enc=New-Object System.Text.UTF8Encoding($false)
  $html=[IO.File]::ReadAllText($idxPath,$enc)
  $st='<script id="evaldata">'; $i1=$html.IndexOf($st)
  if($i1 -ge 0){
    $i2=$html.IndexOf('</script>',$i1)
    $html=$html.Substring(0,$i1+$st.Length)+('window.EVAL='+($out|ConvertTo-Json -Depth 5 -Compress)+';')+$html.Substring($i2)
    [IO.File]::WriteAllText($idxPath,$html,$enc)
    Write-Host "spliced EVAL into index.html"
  } else { Write-Host "evaldata marker not found - page not updated" }
}
Write-Host "DONE."
