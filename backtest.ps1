# backtest.ps1 v2 - walk-forward grid backtest (research tool; run manually, ~monthly)
# Grid: 6 ranking weights (chip vs tech mix) x 3 exit rules (hold20 / ma20 stop / production exits).
# Walk-forward: first 60% of eval days = in-sample (optimize), last 40% = out-of-sample (validate).
# Only adopt parameter changes that hold up out-of-sample; log every change in plan.md.
# Notes: TWSE-only replay (no OTC daily panels); fund factor not replayable; overlapping windows.
# Daily panels are cached under backtest-cache/ (gitignored) so re-runs only fetch new dates.
# ASCII source only.
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Num($s){ if($null -eq $s){return $null}; $t=("$s" -replace '[^0-9\.\-]',''); if($t -notmatch '[0-9]'){return $null}; try{ return [double]$t }catch{ return $null } }
function GetJson($url){
  for($i=0;$i -lt 3;$i++){
    try{
      $resp=Invoke-WebRequest -Uri $url -TimeoutSec 60 -UseBasicParsing
      $txt=[System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
      return ($txt | ConvertFrom-Json)
    }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}

$PANEL=200   # panel days kept (=> ~156 eval days after 24-day lookback + 20-day forward)

Write-Host "[1/4] trade dates + index closes (FMTQIK 11 months)..."
$months=@(); $now=Get-Date
for($m=10;$m -ge 0;$m--){ $months += $now.AddMonths(-$m).ToString('yyyyMM01') }
$datesAll=@(); $idxMapBT=@{}
foreach($mm in $months){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/FMTQIK?date=$mm&response=json"
  if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){
    $p="$($d[0])".Split('/'); $dt=("{0}{1}{2}" -f ([int]$p[0]+1911),$p[1],$p[2])
    $datesAll += $dt; $idxMapBT[$dt]=[double](Num $d[4])
  } }
  Start-Sleep -Milliseconds 700
}
# regime per date from the full window: index vs MA60
$idxAll=@(); foreach($d in $datesAll){ $idxAll += $idxMapBT[$d] }
$regMap=@{}
for($ri=0;$ri -lt $datesAll.Count;$ri++){
  if($ri -ge 59){
    $m=($idxAll[($ri-59)..$ri] | Measure-Object -Average).Average
    $regMap[$datesAll[$ri]]=$(if($idxAll[$ri] -ge $m){'bull'}else{'bear'})
  }
}
$dates=$datesAll
if($dates.Count -gt $PANEL){ $dates=@($dates | Select-Object -Last $PANEL) }
$N=$dates.Count
Write-Host "  panel days = $N ($($dates[0])..$($dates[-1]))"

Write-Host "[2/4] daily panels (MI_INDEX + T86), disk-cached..."
$cacheDir=Join-Path $root 'backtest-cache'
if(-not (Test-Path $cacheDir)){ New-Item -ItemType Directory -Path $cacheDir | Out-Null }
$pxDay=@{}; $t86Day=@{}
$di=0; $fetched=0
foreach($d in $dates){
  $di++
  $cf=Join-Path $cacheDir "$d.json"
  $pm=@{}; $tm=@{}
  if(Test-Path $cf){
    try{
      $j=Get-Content $cf -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach($pr in $j.px.PSObject.Properties){ $pm[$pr.Name]=@{ c=[double]$pr.Value[0]; val=[double]$pr.Value[1] } }
      foreach($pr in $j.t86.PSObject.Properties){ $tm[$pr.Name]=@{ f=[double]$pr.Value[0]; t=[double]$pr.Value[1] } }
    }catch{ $pm=@{}; $tm=@{} }
  }
  if($pm.Count -eq 0){
    $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/MI_INDEX?date=$d&type=ALLBUT0999&response=json"
    if($r -and $r.tables){
      $tbl=$r.tables | Where-Object { $_.data -and $_.data.Count -gt 500 } | Select-Object -First 1
      if($tbl){ foreach($row in $tbl.data){
        $c="$($row[0])".Trim()
        if($c -match '^[1-9][0-9]{3}$'){
          $cl=Num $row[8]; $val=Num $row[4]
          if($cl -ne $null){ $pm[$c]=@{ c=$cl; val=$val } }
        }
      } }
    }
    Start-Sleep -Milliseconds 700
    $r=GetJson "https://www.twse.com.tw/rwd/zh/fund/T86?date=$d&selectType=ALL&response=json"
    if($r -and $r.stat -eq 'OK'){ foreach($row in $r.data){
      $c="$($row[0])".Trim()
      if($c -match '^[1-9][0-9]{3}$'){ $tm[$c]=@{ f=[double](Num $row[4]); t=[double](Num $row[10]) } }
    } }
    Start-Sleep -Milliseconds 700
    # save cache (compact arrays)
    $pxO=@{}; foreach($k in $pm.Keys){ $pxO[$k]=@($pm[$k].c,$pm[$k].val) }
    $t8O=@{}; foreach($k in $tm.Keys){ $t8O[$k]=@($tm[$k].f,$tm[$k].t) }
    @{ px=$pxO; t86=$t8O } | ConvertTo-Json -Depth 3 -Compress | Out-File $cf -Encoding UTF8
    $fetched++
  }
  $pxDay[$d]=$pm; $t86Day[$d]=$tm
  if($di % 20 -eq 0){ Write-Host "  ...$di/$N days (fetched $fetched, rest cached)" }
}
Write-Host "  panels ready (fetched $fetched new days)"

Write-Host "[3/4] walk-forward grid replay..."
function CloseAt($code,$i){ $m=$pxDay[$dates[$i]]; if($m.ContainsKey($code)){ return $m[$code].c } return $null }
$rankCfgs=@(
  @{ key='chip';      wC=1.0; wT=0.0 },
  @{ key='chip+0.5t'; wC=1.0; wT=0.5 },
  @{ key='chip+t';    wC=1.0; wT=1.0 },
  @{ key='chip+2t';   wC=1.0; wT=2.0 },
  @{ key='chip+4t';   wC=1.0; wT=4.0 },
  @{ key='tech';      wC=0.0; wT=1.0 }
)
$exitKeys=@('hold20','stop','prod')
$results=@{}
foreach($rc in $rankCfgs){ foreach($ek in $exitKeys){ $results["$($rc.key)|$ek"]=New-Object System.Collections.ArrayList } }
$evalLo=24; $evalHi=$N-21
$splitI=$evalLo+[math]::Floor(($evalHi-$evalLo)*0.6)
$splitDate=$dates[$splitI]
Write-Host "  eval days $($evalHi-$evalLo+1), in-sample until $splitDate"
for($i=$evalLo; $i -le $evalHi; $i++){
  $d=$dates[$i]
  $tm=$t86Day[$d]; if(-not $tm -or $tm.Count -lt 100){ continue }
  $pxm=$pxDay[$d]
  $scored=@()
  foreach($code in $tm.Keys){
    if(-not $pxm.ContainsKey($code)){ continue }
    if($pxm[$code].val -lt 1e8){ continue }
    $tArr=@(); $fArr=@(); $okWin=$true
    for($k=$i-4;$k -le $i;$k++){ $w=$t86Day[$dates[$k]]; if($w.ContainsKey($code)){ $tArr+=$w[$code].t; $fArr+=$w[$code].f } else { $okWin=$false; break } }
    if(-not $okWin -or $tArr.Count -lt 5){ continue }
    $tPos=($tArr|Where-Object{$_ -gt 0}).Count; $fPos=($fArr|Where-Object{$_ -gt 0}).Count
    $tSum=($tArr|Measure-Object -Sum).Sum; $fSum=($fArr|Measure-Object -Sum).Sum
    $gate=$false
    if($tPos -ge 3 -and $tSum -gt 300000){ $gate=$true }
    if($fPos -ge 4 -and $fSum -gt 3000000){ $gate=$true }
    if(-not $gate){ continue }
    $chipS=[math]::Min(25,$tPos*5)+[math]::Min(10,$fPos*2)
    $cl=CloseAt $code $i; if($cl -eq $null){ continue }
    $hist=@(); $miss=$false
    for($k=$i-23;$k -le $i;$k++){ $v=CloseAt $code $k; if($v -eq $null){ $miss=$true; break }; $hist+=$v }
    if($miss){ continue }
    $ma20=($hist[($hist.Count-20)..($hist.Count-1)]|Measure-Object -Average).Average
    $ma20p=($hist[($hist.Count-24)..($hist.Count-5)]|Measure-Object -Average).Average
    $ret5=$cl/$hist[$hist.Count-6]-1
    if($ret5 -gt 0.25){ continue }
    $hi=($hist|Measure-Object -Maximum).Maximum
    $techS=0
    if($cl -gt $ma20){ $techS+=10 }
    if($ma20 -gt $ma20p){ $techS+=5 }
    if($cl/$hi-1 -ge -0.08){ $techS+=4 }
    $scored += [pscustomobject]@{ code=$code; chip=$chipS; tech=$techS; tSum=$tSum }
  }
  if($scored.Count -eq 0){ continue }
  # top5 per ranking config; union of codes gets exit simulation once
  $topByCfg=@{}
  $union=@{}
  foreach($rc in $rankCfgs){
    $wC=$rc.wC; $wT=$rc.wT
    $ranked=$scored | Sort-Object -Property @{e={ $wC*$_.chip + $wT*$_.tech };Descending=$true}, @{e='tSum';Descending=$true}
    $top=@($ranked | Select-Object -First 5)
    $topByCfg[$rc.key]=$top
    foreach($p in $top){ $union[$p.code]=$true }
  }
  # exit simulation per unique code (path i-19..i+20 for rolling MA20/MA10)
  $reg=$(if($regMap.ContainsKey($d)){$regMap[$d]}else{'na'})
  $phase=$(if($i -le $splitI){'is'}else{'oos'})
  $idx0=$idxMapBT[$d]
  $exitRes=@{}   # code -> @{hold20=@(j,ret,alpha); ...}
  foreach($code in @($union.Keys)){
    $path=@(); $bad=$false
    for($k=$i-19;$k -le $i+20;$k++){ $v=CloseAt $code $k; $path+=$v; if($k -ge $i -and $v -eq $null){ $bad=$true } }
    if($bad){ continue }
    $c0=$path[19]   # close at day i
    if($c0 -le 0){ continue }
    # rolling MA over path: index p corresponds to day i-19+p
    $er=@{}
    foreach($ek in $exitKeys){
      $exitJ=$i+20
      for($j=$i+1;$j -le $i+20;$j++){
        $p2=$j-($i-19)
        $cj=$path[$p2]
        if($cj -eq $null){ continue }
        if($ek -eq 'hold20'){ break }
        # MA20 needs path p2-19..p2 (all >= 0 since p2 >= 21 when j >= i+2... j=i+1 -> p2=20, p2-19=1 ok)
        $s20=0.0; $n20=0
        for($q=$p2-19;$q -le $p2;$q++){ if($path[$q] -ne $null){ $s20+=$path[$q]; $n20++ } }
        $m20=$(if($n20 -ge 15){ $s20/$n20 } else { $null })
        $hitStop = ($m20 -ne $null -and $cj -lt $m20)
        $hit=$false
        if($ek -eq 'stop'){ $hit=$hitStop }
        elseif($ek -eq 'prod'){
          $hit=$hitStop
          if(-not $hit){
            # foreign net sell 2 consecutive days
            $tmJ=$t86Day[$dates[$j]]; $tmJ1=$t86Day[$dates[$j-1]]
            if($tmJ -and $tmJ1 -and $tmJ.ContainsKey($code) -and $tmJ1.ContainsKey($code)){
              if($tmJ[$code].f -lt 0 -and $tmJ1[$code].f -lt 0){ $hit=$true }
            }
          }
          if(-not $hit){
            # trailing take-profit: ret >= 15% and close below MA10
            $retJ=($cj/$c0-1)*100
            if($retJ -ge 15){
              $s10=0.0; $n10=0
              for($q=$p2-9;$q -le $p2;$q++){ if($path[$q] -ne $null){ $s10+=$path[$q]; $n10++ } }
              if($n10 -ge 8 -and $cj -lt ($s10/$n10)){ $hit=$true }
            }
          }
        }
        if($hit){ $exitJ=$j; break }
      }
      $ce=CloseAt $code $exitJ
      if($ce -eq $null){ $ce=$c0; $exitJ=$i }
      $ret=($ce/$c0-1)*100
      $idx1=$idxMapBT[$dates[$exitJ]]
      $alpha=$ret-(($idx1/$idx0-1)*100)
      $er[$ek]=@([int]($exitJ-$i),[math]::Round($ret,2),[math]::Round($alpha,2))
    }
    $exitRes[$code]=$er
  }
  foreach($rc in $rankCfgs){
    foreach($p in $topByCfg[$rc.key]){
      if(-not $exitRes.ContainsKey($p.code)){ continue }
      foreach($ek in $exitKeys){
        $e=$exitRes[$p.code][$ek]
        [void]$results["$($rc.key)|$ek"].Add([pscustomobject]@{ days=$e[0]; ret=$e[1]; alpha=$e[2]; regime=$reg; phase=$phase })
      }
    }
  }
  if(($i-$evalLo) % 20 -eq 0){ Write-Host "  eval $($i-$evalLo+1)/$($evalHi-$evalLo+1) date=$d gated=$($scored.Count)" }
}

Write-Host "[4/4] summaries + walk-forward ranking..."
function Agg($rows){
  $a=@($rows)
  if($a.Count -eq 0){ return $null }
  $w=@($a | Where-Object {$_.alpha -gt 0}).Count
  return @{ n=$a.Count
            winRate=[math]::Round($w/$a.Count*100,1)
            avgAlpha=[math]::Round(($a|Measure-Object -Property alpha -Average).Average,2)
            avgRet=[math]::Round(($a|Measure-Object -Property ret -Average).Average,2)
            avgDays=[math]::Round(($a|Measure-Object -Property days -Average).Average,1) }
}
$grid=@()
foreach($rc in $rankCfgs){
  foreach($ek in $exitKeys){
    $rows=$results["$($rc.key)|$ek"]
    if($rows.Count -eq 0){ continue }
    $g=[ordered]@{
      rank=$rc.key; exit=$ek
      is =(Agg @($rows | Where-Object {$_.phase -eq 'is'}))
      oos=(Agg @($rows | Where-Object {$_.phase -eq 'oos'}))
      bear=(Agg @($rows | Where-Object {$_.regime -eq 'bear'}))
    }
    $grid += [pscustomobject]$g
    $o=$g.oos
    Write-Host ("  {0,-10} {1,-7} OOS n={2} win={3}% alpha={4}%" -f $rc.key,$ek,$(if($o){$o.n}else{0}),$(if($o){$o.winRate}else{'-'}),$(if($o){$o.avgAlpha}else{'-'}))
  }
}
$valid=@($grid | Where-Object { $_.oos -and $_.oos.n -ge 20 })
$best=$valid | Sort-Object -Property @{e={ $_.oos.avgAlpha };Descending=$true} | Select-Object -First 1
$cur=$grid | Where-Object { $_.rank -eq 'chip+t' -and $_.exit -eq 'prod' } | Select-Object -First 1
$fmtP="{0}/{1}/{2}-{3}/{4}" -f $dates[0].Substring(0,4),$dates[0].Substring(4,2),$dates[0].Substring(6,2),$dates[-1].Substring(4,2),$dates[-1].Substring(6,2)
$out=@{
  generated=(Get-Date -Format 'yyyy-MM-dd HH:mm')
  period=$fmtP; panelDays=$N; splitDate=$splitDate
  note='walk-forward: IS=first 60% (optimize), OOS=last 40% (validate); TWSE-only; fund factor not replayable; overlapping windows'
  grid=$grid
  current=$cur
  bestOOS=$best
}
$out | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root 'backtest-result.json') -Encoding UTF8
Write-Host "saved backtest-result.json"
if($best){ Write-Host ("  BEST OOS: {0}|{1} win={2}% alpha={3}%  (current chip+t|prod: win={4}% alpha={5}%)" -f $best.rank,$best.exit,$best.oos.winRate,$best.oos.avgAlpha,$(if($cur -and $cur.oos){$cur.oos.winRate}else{'-'}),$(if($cur -and $cur.oos){$cur.oos.avgAlpha}else{'-'})) }

# splice page card rows: current + top-4 OOS combos
$rows=@()
$sel=@()
if($cur){ $sel += $cur }
foreach($g in ($valid | Sort-Object -Property @{e={ $_.oos.avgAlpha };Descending=$true} | Select-Object -First 4)){
  if(-not ($sel | Where-Object { $_.rank -eq $g.rank -and $_.exit -eq $g.exit })){ $sel += $g }
}
foreach($g in $sel){
  $rows += [ordered]@{
    rank=$g.rank; exit=$g.exit
    cur=($cur -and $g.rank -eq $cur.rank -and $g.exit -eq $cur.exit)
    best=($best -and $g.rank -eq $best.rank -and $g.exit -eq $best.exit)
    isWin=$(if($g.is){$g.is.winRate}else{$null});   isAlpha=$(if($g.is){$g.is.avgAlpha}else{$null})
    oosWin=$(if($g.oos){$g.oos.winRate}else{$null}); oosAlpha=$(if($g.oos){$g.oos.avgAlpha}else{$null}); oosN=$(if($g.oos){$g.oos.n}else{$null})
    bearWin=$(if($g.bear){$g.bear.winRate}else{$null}); bearN=$(if($g.bear){$g.bear.n}else{$null})
  }
}
$bt=@{ period=$fmtP; generated=(Get-Date -Format 'yyyy-MM-dd'); splitDate=$splitDate; rows=$rows }
$idxPath=Join-Path $root 'index.html'
if(Test-Path $idxPath){
  $enc=New-Object System.Text.UTF8Encoding($false)
  $html=[IO.File]::ReadAllText($idxPath,$enc)
  $st='<script id="backtest">'; $i1=$html.IndexOf($st)
  if($i1 -ge 0){ $i2=$html.IndexOf('</script>',$i1)
    $html=$html.Substring(0,$i1+$st.Length)+('window.BACKTEST='+($bt|ConvertTo-Json -Depth 4 -Compress)+';')+$html.Substring($i2)
    [IO.File]::WriteAllText($idxPath,$html,$enc); Write-Host "spliced backtest card into index.html" }
}
Write-Host "DONE."
