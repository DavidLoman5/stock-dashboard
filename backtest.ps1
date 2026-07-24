# backtest.ps1 v2.2 - walk-forward grid backtest (research tool; run manually, ~monthly)
# Grid: 6 ranking weights (chip vs tech mix) x 4 exit rules (hold20 / ma20 stop / production
# exits / stopTrail = production without the foreign-2-day-sell rule).
# Walk-forward: first 60% of eval days = in-sample (optimize), last 40% = out-of-sample (validate).
# Only adopt parameter changes that hold up out-of-sample; log every change in plan.md.
# v2.2 (2026-07-24) upgrades - results NOT comparable to v2.1 or earlier runs:
#   * panel cache v2 stores O/H/L/C/volume/value/signed-change per code-day (same MI_INDEX
#     response, no extra API calls). v1 cache files are treated as a cache miss and refetched
#     once (~200 days, 30-60 min); after that only new dates are fetched as before.
#   * dividend-adjusted (total-return) exit replay, same formula and 10% cap as production
#     DivSumSince: an ex-div gap-down no longer fakes a MA20/MA10 breach, returns include payouts.
#   * volume/candle factors replayed in techS (distribution-candle reject, volume-backed
#     advance +4/+2, high upper wick -5, hammer +2) - aligned to production scoring.
#   * stopTrail exit isolates the foreign-2-day-sell rule's contribution. (The plan.md
#     candidate "foreign sell only counts below MA20" is equivalent to removing the foreign
#     rule at daily granularity, because below-MA20 already exits via the stop.)
#   * Agg adds avgAlphaNet (round-trip cost 0.585% = 2x0.1425% fee + 0.3% tax, no discount),
#     medAlpha, and nDistinct (same code re-entered within 20 trade days counted once -
#     overlapping windows inflate n, nDistinct is the honest sample size).
# Still NOT replayable: fund factor (no revenue/PE history), regime-green momentum +3 (needs
# daily instNet/breadth), ETF board; TWSE-only (no OTC daily panels).
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

$PANEL=200   # panel days kept (=> ~120 eval days after 60-day lookback + 20-day forward)

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
      foreach($pr in $j.px.PSObject.Properties){
        $a=@($pr.Value)
        # cache v2 = 7-element arrays (o,h,l,c,v,val,chg); shorter arrays are the old v1
        # close+value format -> leave $pm empty so the whole day refetches once
        if($a.Count -ge 7){ $pm[$pr.Name]=@{ o=$a[0]; h=$a[1]; l=$a[2]; c=[double]$a[3]; v=$a[4]; val=$a[5]; chg=[double]$a[6] } }
      }
      if($pm.Count -gt 0){
        foreach($pr in $j.t86.PSObject.Properties){ $tm[$pr.Name]=@{ f=[double]$pr.Value[0]; t=[double]$pr.Value[1] } }
      }
    }catch{ $pm=@{}; $tm=@{} }
  }
  if($pm.Count -eq 0){
    $tm=@{}
    $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/MI_INDEX?date=$d&type=ALLBUT0999&response=json"
    if($r -and $r.tables){
      $tbl=$r.tables | Where-Object { $_.data -and $_.data.Count -gt 500 } | Select-Object -First 1
      if($tbl){ foreach($row in $tbl.data){
        $c="$($row[0])".Trim()
        if($c -match '^[1-9][0-9]{3}$'){
          $cl=Num $row[8]
          if($cl -ne $null){
            # col9 is the +/- direction (may arrive as an HTML fragment), col10 the unsigned
            # change vs the (dividend-adjusted) reference price - same convention STOCK_DAY
            # uses, which is exactly what makes the DivSumSince-style add-back possible
            $chgV=Num $row[10]; if($chgV -eq $null){ $chgV=0.0 }
            if("$($row[9])" -like '*-*'){ $chgV=-$chgV }
            $pm[$c]=@{ o=(Num $row[5]); h=(Num $row[6]); l=(Num $row[7]); c=$cl; v=(Num $row[2]); val=(Num $row[4]); chg=$chgV }
          }
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
    # save cache v2 (compact arrays)
    $pxO=@{}; foreach($k in $pm.Keys){ $b=$pm[$k]; $pxO[$k]=@($b.o,$b.h,$b.l,$b.c,$b.v,$b.val,$b.chg) }
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
$exitKeys=@('hold20','stop','prod','stopTrail')
$results=@{}
foreach($rc in $rankCfgs){ foreach($ek in $exitKeys){ $results["$($rc.key)|$ek"]=New-Object System.Collections.ArrayList } }
$evalLo=60; $evalHi=$N-21   # 60-day lookback so every eval day has full MA60 history (consistency with prod)
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
    $tArr=@(); $fArr=@()
    for($k=$i-4;$k -le $i;$k++){ $w=$t86Day[$dates[$k]]; if($w.ContainsKey($code)){ $tArr+=$w[$code].t; $fArr+=$w[$code].f } }
    if($tArr.Count -lt 4){ continue }   # production gate: >=4 of the 5-day window (was 5/5, stricter than prod)
    $tPos=($tArr|Where-Object{$_ -gt 0}).Count; $fPos=($fArr|Where-Object{$_ -gt 0}).Count
    $tSum=($tArr|Measure-Object -Sum).Sum; $fSum=($fArr|Measure-Object -Sum).Sum
    $gate=$false
    if($tPos -ge 3 -and $tSum -gt 300000){ $gate=$true }
    if($fPos -ge 4 -and $fSum -gt 3000000){ $gate=$true }
    if(-not $gate){ continue }
    $chipS=[math]::Min(25,$tPos*5)+[math]::Min(10,$fPos*2)
    $cl=CloseAt $code $i; if($cl -eq $null){ continue }
    # 60-day history: last 25 days must be complete (MA20/slope/ret5 exact); older gaps tolerated (MA60 null like prod)
    $hist=@(); $miss=$false
    for($k=$i-59;$k -le $i;$k++){
      $v=CloseAt $code $k
      if($v -eq $null){ if($k -gt $i-25){ $miss=$true; break }; continue }
      $hist+=$v
    }
    if($miss -or $hist.Count -lt 25){ continue }
    $ma20=($hist[($hist.Count-20)..($hist.Count-1)]|Measure-Object -Average).Average
    $ma20p=($hist[($hist.Count-25)..($hist.Count-6)]|Measure-Object -Average).Average   # prod: 20d MA ending 5 bars back
    $ret5=$cl/$hist[$hist.Count-6]-1
    if($ret5 -gt 0.25){ continue }
    $ma60=$(if($hist.Count -ge 60){ ($hist[($hist.Count-60)..($hist.Count-1)]|Measure-Object -Average).Average } else { $null })
    if($ma60 -ne $null -and $cl -lt $ma60){ continue }   # prod filter: below MA60 -> drop
    $n40=[math]::Min(40,$hist.Count); $hi=($hist[($hist.Count-$n40)..($hist.Count-1)]|Measure-Object -Maximum).Maximum   # prod: 40-day high
    $dist=$cl/$hi-1
    $techS=0
    if($cl -gt $ma20){ $techS+=10 }
    if($ma60 -ne $null -and $cl -gt $ma60){ $techS+=8 }   # prod: above MA60 +8 (was missing)
    if($ma20 -gt $ma20p){ $techS+=5 }
    if($dist -ge -0.08){ $techS+=4 }
    # --- v2.2: volume/candle factors, same order and thresholds as production screen.ps1 ---
    $bar=$pxm[$code]
    $vs=@()
    for($k=$i-20;$k -le $i-1;$k++){ $m2=$pxDay[$dates[$k]]; if($m2.ContainsKey($code) -and $m2[$code].v -ne $null){ $vs+=[double]$m2[$code].v } }
    $vAvg= if($vs.Count -ge 15){ ($vs|Measure-Object -Average).Average } else { $null }
    $vr= if($vAvg -and $vAvg -gt 0 -and $bar.v -ne $null){ [double]$bar.v/$vAvg } else { $null }
    $rng= if($bar.h -ne $null -and $bar.l -ne $null){ [double]$bar.h-[double]$bar.l } else { 0 }
    $upW= if($rng -gt 0 -and $bar.o -ne $null){ ([double]$bar.h-[math]::Max([double]$bar.o,$cl))/$rng } else { 0 }
    $loW= if($rng -gt 0 -and $bar.o -ne $null){ ([math]::Min([double]$bar.o,$cl)-[double]$bar.l)/$rng } else { 0 }
    $cp= if($rng -gt 0){ ($cl-[double]$bar.l)/$rng } else { 0.5 }
    # distribution day at highs -> reject outright (prod does the same)
    if($dist -ge -0.03 -and $vr -ne $null -and $vr -ge 2 -and ($cp -lt 0.35 -or $upW -gt 0.6)){ continue }
    if($bar.chg -gt 0 -and $vr -ne $null -and $vr -ge 1.5){ $techS+=4 }
    elseif($bar.chg -gt 0 -and $bar.val -ne $null -and [double]$bar.val -gt 3e8){ $techS+=2 }
    if($dist -ge -0.03 -and $upW -gt 0.6 -and $vr -ne $null -and $vr -ge 1.2){ $techS-=5 }
    if($dist -le -0.10 -and $loW -gt 0.6){ $techS+=2 }
    if($techS -lt 0){ $techS=0 }
    if($techS -gt 30){ $techS=30 }
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
    $path=@(); $chgP=@(); $bad=$false
    for($k=$i-19;$k -le $i+20;$k++){
      $m2=$pxDay[$dates[$k]]
      $b= if($m2 -and $m2.ContainsKey($code)){ $m2[$code] } else { $null }
      $v= if($b){ $b.c } else { $null }
      $path+=$v; $chgP+=$(if($b){ $b.chg } else { $null })
      if($k -ge $i -and $v -eq $null){ $bad=$true }
    }
    if($bad){ continue }
    $c0=$path[19]   # close at day i
    if($c0 -le 0){ continue }
    # v2.2: cumulative dividend add-back over the path (same formula + 10% cap as prod
    # DivSumSince). All MA and return math below runs on total-return closes, so an ex-div
    # gap-down is not mistaken for a technical break.
    $cum=@(); $cumV=0.0
    for($p=0;$p -lt $path.Count;$p++){
      if($p -gt 0 -and $chgP[$p] -ne $null -and $path[$p] -ne $null -and $path[$p-1] -ne $null){
        $dvv=[double]$chgP[$p]-([double]$path[$p]-[double]$path[$p-1])
        if($dvv -gt 0.005 -and $path[$p-1] -gt 0 -and ($dvv/$path[$p-1]) -le 0.10){ $cumV+=$dvv }
      }
      $cum+=$cumV
    }
    # rolling MA over path: index p corresponds to day i-19+p
    $er=@{}
    foreach($ek in $exitKeys){
      $exitJ=$i+20
      for($j=$i+1;$j -le $i+20;$j++){
        $p2=$j-($i-19)
        $cj=$path[$p2]
        if($cj -eq $null){ continue }
        if($ek -eq 'hold20'){ break }
        $cjTr=[double]$cj+$cum[$p2]
        # MA20 needs path p2-19..p2 (all >= 0 since p2 >= 21 when j >= i+2... j=i+1 -> p2=20, p2-19=1 ok)
        $s20=0.0; $n20=0
        for($q=$p2-19;$q -le $p2;$q++){ if($path[$q] -ne $null){ $s20+=([double]$path[$q]+$cum[$q]); $n20++ } }
        $m20=$(if($n20 -ge 15){ $s20/$n20 } else { $null })
        $hitStop = ($m20 -ne $null -and $cjTr -lt $m20)
        $hit=$false
        if($ek -eq 'stop'){ $hit=$hitStop }
        elseif($ek -eq 'prod' -or $ek -eq 'stopTrail'){
          $hit=$hitStop
          if(-not $hit -and $ek -eq 'prod'){
            # foreign net sell 2 consecutive days (stopTrail = prod without this rule)
            $tmJ=$t86Day[$dates[$j]]; $tmJ1=$t86Day[$dates[$j-1]]
            if($tmJ -and $tmJ1 -and $tmJ.ContainsKey($code) -and $tmJ1.ContainsKey($code)){
              if($tmJ[$code].f -lt 0 -and $tmJ1[$code].f -lt 0){ $hit=$true }
            }
          }
          if(-not $hit){
            # trailing take-profit: total-return >= 15% and TR close below TR MA10
            $retJ=(($cjTr-$cum[19])/$c0-1)*100
            if($retJ -ge 15){
              $s10=0.0; $n10=0
              for($q=$p2-9;$q -le $p2;$q++){ if($path[$q] -ne $null){ $s10+=([double]$path[$q]+$cum[$q]); $n10++ } }
              if($n10 -ge 8 -and $cjTr -lt ($s10/$n10)){ $hit=$true }
            }
          }
        }
        if($hit){ $exitJ=$j; break }
      }
      $pE=$exitJ-($i-19)
      $ce=$path[$pE]
      if($ce -eq $null){ $ce=$c0; $pE=19; $exitJ=$i }
      # total return incl. dividends between entry and exit, entry price unadjusted (prod formula)
      $ret=((([double]$ce+($cum[$pE]-$cum[19]))/$c0)-1)*100
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
        [void]$results["$($rc.key)|$ek"].Add([pscustomobject]@{ code=$p.code; ei=$i; days=$e[0]; ret=$e[1]; alpha=$e[2]; regime=$reg; phase=$phase })
      }
    }
  }
  if(($i-$evalLo) % 20 -eq 0){ Write-Host "  eval $($i-$evalLo+1)/$($evalHi-$evalLo+1) date=$d gated=$($scored.Count)" }
}

Write-Host "[4/4] summaries + walk-forward ranking..."
$COST=0.585   # % per round trip: 2 x 0.1425% fee (no discount) + 0.3% tax - conservative
function Agg($rows){
  $a=@($rows)
  if($a.Count -eq 0){ return $null }
  $w=@($a | Where-Object {$_.alpha -gt 0}).Count
  $avgA=[math]::Round(($a|Measure-Object -Property alpha -Average).Average,2)
  $sorted=@($a | ForEach-Object { $_.alpha } | Sort-Object)
  $med=$sorted[[int][math]::Floor(($sorted.Count-1)/2)]
  # distinct entries: the same code re-picked within 20 trade days is one overlapping
  # position, not a fresh sample - nDistinct is the honest n for significance eyeballing
  $nd=0; $lastEi=@{}
  foreach($r in ($a | Sort-Object -Property code,ei)){
    if(-not $lastEi.ContainsKey($r.code) -or ($r.ei-$lastEi[$r.code]) -ge 20){ $nd++; $lastEi[$r.code]=$r.ei }
  }
  return @{ n=$a.Count
            nDistinct=$nd
            winRate=[math]::Round($w/$a.Count*100,1)
            avgAlpha=$avgA
            avgAlphaNet=[math]::Round($avgA-$COST,2)
            medAlpha=[math]::Round($med,2)
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
  note='v2.2 walk-forward: IS=first 60% (optimize), OOS=last 40% (validate); dividend-adjusted exits+returns; volume/candle factors replayed; stopTrail=prod minus foreign-2-day rule; avgAlphaNet=alpha-0.585% round-trip cost; nDistinct=non-overlapping entries; TWSE-only; fund factor + regime-green bonus not replayable; NOT comparable to v2.1'
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
    oosAlphaNet=$(if($g.oos){$g.oos.avgAlphaNet}else{$null}); oosNd=$(if($g.oos){$g.oos.nDistinct}else{$null})
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
