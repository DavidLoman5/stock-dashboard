# screen.ps1 - TWSE quant screening engine v2 (ASCII source only)
# v2: regime-aware scoring, 20-day auto-close tracking, dedupe, spark output
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Num($s){ if($null -eq $s){return $null}; $t=("$s" -replace '[^0-9\.\-]',''); if($t -eq '' -or $t -eq '-'){return $null}; [double]$t }
function GetJson($url){ for($i=0;$i -lt 3;$i++){ try{ return Invoke-RestMethod -Uri $url -TimeoutSec 45 }catch{ Start-Sleep -Milliseconds 1500 } } return $null }

Write-Host "[1/8] STOCK_DAY_ALL..."
$all = GetJson "https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL"
if(-not $all){ Write-Host "FATAL: STOCK_DAY_ALL failed"; exit 1 }
$rawDate = "$($all[0].Date)"
if($rawDate.Length -eq 7){ $lastDate = "{0}{1}" -f ([int]$rawDate.Substring(0,3)+1911), $rawDate.Substring(3) } else { $lastDate = $rawDate }
Write-Host "  latest trade date = $lastDate rows=$($all.Count)"
$px=@{}
foreach($r in $all){
  $c="$($r.Code)".Trim()
  $px[$c]=@{ name=$r.Name; c=(Num $r.ClosingPrice); o=(Num $r.OpeningPrice); h=(Num $r.HighestPrice); l=(Num $r.LowestPrice); v=(Num $r.TradeVolume); val=(Num $r.TradeValue); chg=(Num $r.Change) }
}
$upN=0;$dnN=0
foreach($k in $px.Keys){ $g=$px[$k].chg; if($g -gt 0){$upN++} elseif($g -lt 0){$dnN++} }

Write-Host "[2/8] FMTQIK (index history)..."
$months=@(); $d0=[datetime]::ParseExact($lastDate,'yyyyMMdd',$null)
for($m=3;$m -ge 0;$m--){ $months += $d0.AddMonths(-$m).ToString('yyyyMM01') }
$idxC=@(); $tradeDates=@()
foreach($mm in $months){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/FMTQIK?date=$mm&response=json"
  if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){ $idxC += (Num $d[4]); $p="$($d[0])".Split('/'); $tradeDates += ("{0}{1}{2}" -f ([int]$p[0]+1911), $p[1], $p[2]) } }
  Start-Sleep -Milliseconds 700
}
function SMAlast($a,$n){ if($a.Count -lt $n){return $null}; ($a[($a.Count-$n)..($a.Count-1)] | Measure-Object -Average).Average }
$idxLast=$idxC[$idxC.Count-1]; $idxMA20=SMAlast $idxC 20; $idxMA60=SMAlast $idxC 60
$last5=$tradeDates | Select-Object -Last 5

Write-Host "[3/8] T86 x5 days: $($last5 -join ',')"
$chip=@{}
$t86ok=0
foreach($d in $last5){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/fund/T86?date=$d&selectType=ALL&response=json"
  if($r -and $r.stat -eq 'OK'){
    $t86ok++
    foreach($row in $r.data){
      $c="$($row[0])".Trim()
      if(-not $chip.ContainsKey($c)){ $chip[$c]=@{f=@();t=@();tot=@()} }
      $chip[$c].f += [double](Num $row[4]); $chip[$c].t += [double](Num $row[10]); $chip[$c].tot += [double](Num $row[18])
    }
  }
  Start-Sleep -Milliseconds 800
}
if($t86ok -lt 5){ Write-Host "  WARNING: only $t86ok/5 T86 days fetched - chip screening degraded. Consider re-run later." }

Write-Host "[4/8] BFI82U (market inst amount)..."
$instNet=$null
$r=GetJson "https://www.twse.com.tw/rwd/zh/fund/BFI82U?dayDate=$lastDate&type=day&response=json"
if($r -and $r.stat -eq 'OK' -and $r.data.Count -gt 0){ $lastRow=$r.data[$r.data.Count-1]; $instNet=[math]::Round([double](Num $lastRow[3])/1e8,0) }  # last row = total
Write-Host "  instNet = $instNet (yi NTD)"

Write-Host "[5/8] MI_MARGN (margin)..."
$fin=@{}
$r=GetJson "https://www.twse.com.tw/rwd/zh/marginTrading/MI_MARGN?date=$lastDate&selectType=ALL&response=json"
if($r){ $tbl=$r.tables | Where-Object { $_.data -and $_.data.Count -gt 100 } | Select-Object -First 1
  if($tbl){ foreach($row in $tbl.data){ $c="$($row[0])".Trim(); $fin[$c]=@{ today=(Num $row[6]); prev=(Num $row[5]) } } } }

Write-Host "[6/8] BWIBBU_ALL + revenue..."
$pe=@{}
$r=GetJson "https://openapi.twse.com.tw/v1/exchangeReport/BWIBBU_ALL"
if($r){ foreach($row in $r){ $c="$($row.Code)".Trim(); $pe[$c]=@{ pe=(Num $row.PEratio); pb=(Num $row.PBratio); dy=(Num $row.DividendYield) } } }
$rev=@{}
$r=GetJson "https://openapi.twse.com.tw/v1/opendata/t187ap05_L"
if($r){ foreach($row in $r){ $p=@($row.PSObject.Properties); $c="$($p[2].Value)".Trim(); $rev[$c]=@{ ind="$($p[4].Value)".Trim(); yoy=(Num $p[9].Value); name="$($p[3].Value)".Trim() } } }
Write-Host "  pe=$($pe.Count) rev=$($rev.Count)"

# ----- regime light (computed BEFORE scoring so weights can adapt) -----
$pts=0
if($idxLast -gt $idxMA20){ $pts++ }
if($instNet -ne $null -and $instNet -gt 0){ $pts++ }
if($upN -gt $dnN){ $pts++ }
$light='red'
if($idxMA60 -ne $null -and $idxLast -lt $idxMA60){ $light='red' }
elseif($pts -eq 3){ $light='green' }
elseif($pts -ge 2 -or ($idxMA60 -ne $null -and $idxLast -gt $idxMA60)){ $light='yellow' }
Write-Host "  regime = $light (pts=$pts)"

Write-Host "[7/8] screening..."
$cands=@()
foreach($c in $chip.Keys){
  if($c -notmatch '^[1-9][0-9]{3}$'){ continue }
  if(-not $px.ContainsKey($c)){ continue }
  if($px[$c].val -lt 1e8){ continue }             # liquidity >= NT$100M/day
  $t=$chip[$c].t; $f=$chip[$c].f
  if($t.Count -lt 4){ continue }
  $tPos=($t | Where-Object {$_ -gt 0}).Count
  $fPos=($f | Where-Object {$_ -gt 0}).Count
  $tSum=($t | Measure-Object -Sum).Sum; $fSum=($f | Measure-Object -Sum).Sum
  $ok=$false
  if($tPos -ge 3 -and $tSum -gt 300000){ $ok=$true }
  if($fPos -ge 4 -and $fSum -gt 3000000){ $ok=$true }
  if(-not $ok){ continue }
  $chipScore = [math]::Min(25, $tPos*5) + [math]::Min(10, $fPos*2)
  $fd=$fin[$c]; if($fd -and $fd.today -ne $null -and $fd.prev -ne $null -and $fd.today -lt $fd.prev){ $chipScore += 5 }
  $cands += [pscustomobject]@{ code=$c; chip=$chipScore; tPos=$tPos; fPos=$fPos; tSum=$tSum; fSum=$fSum }
}
Write-Host "  candidates = $($cands.Count)"
$short = $cands | Sort-Object -Property @{e='chip';Descending=$true}, @{e='tSum';Descending=$true} | Select-Object -First 12

$picks=@()
$curMM=$d0.ToString('yyyyMM01'); $prvMM=$d0.AddMonths(-1).ToString('yyyyMM01'); $prv2MM=$d0.AddMonths(-2).ToString('yyyyMM01'); $prv3MM=$d0.AddMonths(-3).ToString('yyyyMM01')
foreach($s in $short){
  $c=$s.code; $serF=@()
  foreach($mm in @($prv3MM,$prv2MM,$prvMM,$curMM)){
    $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?date=$mm&stockNo=$c&response=json"
    if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){
      $dp="$($d[0])".Split('/')
      $serF += [ordered]@{ d=("{0}/{1}" -f [int]$dp[1],[int]$dp[2]); o=(Num $d[3]); h=(Num $d[4]); l=(Num $d[5]); c=[double](Num $d[6]); chg=(Num $d[7]); v=[math]::Round((Num $d[1])/1000,0) }
    } }
    Start-Sleep -Milliseconds 700
  }
  if($serF.Count -lt 25){ continue }
  $ser=@($serF | ForEach-Object { $_.c })
  $cl=$ser[$ser.Count-1]
  $ma20=SMAlast $ser 20; $ma60=SMAlast $ser 60
  $ma20p = if($ser.Count -ge 25){ SMAlast ($ser[0..($ser.Count-6)]) 20 } else { $null }
  $ret5 = if($ser.Count -ge 6){ $cl/$ser[$ser.Count-6]-1 } else { 0 }
  $n40=[math]::Min(40,$ser.Count); $hi40=($ser[($ser.Count-$n40)..($ser.Count-1)] | Measure-Object -Maximum).Maximum
  $dist = $cl/$hi40-1
  if($ret5 -gt 0.25){ Write-Host "  drop $c overheated ret5=$([math]::Round($ret5*100,1))%"; continue }
  if($ma60 -ne $null -and $cl -lt $ma60){ Write-Host "  drop $c below MA60"; continue }
  $tech=0
  if($ma20 -ne $null -and $cl -gt $ma20){ $tech+=10 }
  if($ma60 -ne $null -and $cl -gt $ma60){ $tech+=8 }
  if($ma20p -ne $null -and $ma20 -gt $ma20p){ $tech+=5 }
  if($dist -ge -0.08){ $tech+=4 }
  if($px[$c].chg -gt 0 -and $px[$c].val -gt 3e8){ $tech+=3 }
  # regime-aware: green light rewards momentum
  if($light -eq 'green' -and $ret5 -ge 0.03 -and $ret5 -le 0.15){ $tech+=3 }
  if($tech -gt 30){ $tech=30 }
  $fund=0; $y=$null; $ind=''
  if($rev.ContainsKey($c)){ $y=$rev[$c].yoy; $ind=$rev[$c].ind }
  if($y -ne $null){ if($y -ge 100){$fund+=15}elseif($y -ge 30){$fund+=12}elseif($y -ge 10){$fund+=8}elseif($y -gt 0){$fund+=4} }
  $peV=$null; $dyV=$null
  if($pe.ContainsKey($c)){ $peV=$pe[$c].pe; $dyV=$pe[$c].dy }
  if($peV -ne $null -and $peV -gt 0){ if($peV -le 15){$fund+=10}elseif($peV -le 25){$fund+=7}elseif($peV -le 40){$fund+=4} }
  if($dyV -ne $null -and $dyV -ge 3){ $fund+=5 }
  # regime-aware: non-green rewards defensive traits
  if($light -ne 'green'){
    if($dyV -ne $null -and $dyV -ge 4){ $fund+=3 }
    if($peV -ne $null -and $peV -gt 0 -and $peV -le 15){ $fund+=2 }
  }
  if($fund -gt 30){ $fund=30 }
  $fd=$fin[$c]; $finDelta = if($fd -and $fd.today -ne $null -and $fd.prev -ne $null){ [int]($fd.today-$fd.prev) } else { $null }
  $spark=@(); $nS=[math]::Min(40,$ser.Count)
  foreach($v in $ser[($ser.Count-$nS)..($ser.Count-1)]){ $spark += [math]::Round($v,2) }
  $nK=[math]::Min(60,$serF.Count); $kline=@($serF[($serF.Count-$nK)..($serF.Count-1)])
  $picks += [pscustomobject]@{
    code=$c; name=$px[$c].name; ind=$ind; close=$cl; chgPct=[math]::Round((Num $px[$c].chg)/($cl-(Num $px[$c].chg))*100,2)
    score=($s.chip+$tech+$fund); chip=$s.chip; tech=$tech; fund=$fund
    tPos=$s.tPos; fPos=$s.fPos; tSum=[math]::Round($s.tSum/1000,0); fSum=[math]::Round($s.fSum/1000,0)
    finDelta=$finDelta; yoy=$y; pe=$peV; dy=$dyV
    ret5=[math]::Round($ret5*100,1); dist=[math]::Round($dist*100,1)
    ma20=[math]::Round($ma20,2); ma60=[math]::Round($ma60,2)
    spark=$spark; kline=$kline
  }
}
$picks = $picks | Sort-Object -Property @{e='score';Descending=$true}
$elec=@('24','25','26','27','28','29','30','31')
$top5=@($picks | Select-Object -First 5)
if($top5.Count -eq 5 -and ($top5 | Where-Object { $elec -notcontains $_.ind }).Count -eq 0){
  $alt=$picks | Where-Object { $elec -notcontains $_.ind } | Select-Object -First 1
  if($alt -and ($top5[4].score - $alt.score) -le 15){ $top5 = @($top5[0..3]) + @($alt) }
}

Write-Host "[8/8] picks-log (20-day auto-close, dedupe) + output..."
$logPath=Join-Path $root 'picks-log.json'
$norm=@()
if(Test-Path $logPath){
  try{
    $lg=Get-Content $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($p in @($lg.picks)){
      $o=@{ date="$($p.date)"; code="$($p.code)"; name="$($p.name)"; price=[double]$p.price; score=[int]$p.score }
      $o.status = if($p.PSObject.Properties['status'] -and $p.status){ "$($p.status)" } else { 'open' }
      if($p.PSObject.Properties['exit'] -and $p.exit -ne $null){ $o.exit=[double]$p.exit }
      if($p.PSObject.Properties['retFinal'] -and $p.retFinal -ne $null){ $o.retFinal=[double]$p.retFinal }
      if($p.PSObject.Properties['alphaFinal'] -and $p.alphaFinal -ne $null){ $o.alphaFinal=[double]$p.alphaFinal }
      if($p.PSObject.Properties['closedOn'] -and $p.closedOn){ $o.closedOn="$($p.closedOn)" }
      if($p.PSObject.Properties['days'] -and $p.days -ne $null){ $o.days=[int]$p.days }
      $norm += ,$o
    }
  }catch{}
}
$idxMap=@{}; for($i=0;$i -lt $tradeDates.Count;$i++){ $idxMap[$tradeDates[$i]]=$idxC[$i] }
$perfRows=@()
foreach($o in $norm){
  if($o.date -eq $lastDate -and $o.status -eq 'open'){ continue }   # logged today, no perf yet
  if($o.status -eq 'closed'){
    $al = if($o.ContainsKey('alphaFinal')){ $o.alphaFinal } else { $null }
    $dy2 = if($o.ContainsKey('days')){ $o.days } else { 20 }
    $perfRows += [pscustomobject]@{ date=$o.date; code=$o.code; name=$o.name; entry=$o.price; cur=$o.exit; ret=$o.retFinal; alpha=$al; days=$dy2; status='closed' }
    continue
  }
  $c=$o.code
  if(-not $px.ContainsKey($c)){ continue }
  $cur=$px[$c].c
  if($o.price -le 0){ continue }
  $days=($tradeDates | Where-Object { $_ -gt $o.date -and $_ -le $lastDate }).Count
  $ret=[math]::Round(($cur/$o.price-1)*100,2)
  $alpha=$null
  if($idxMap.ContainsKey($o.date)){ $alpha=[math]::Round($ret - (($idxLast/$idxMap[$o.date]-1)*100),2) }
  if($days -ge 20){
    $o.status='closed'; $o.exit=$cur; $o.retFinal=$ret; $o.days=$days; $o.closedOn=$lastDate
    if($alpha -ne $null){ $o.alphaFinal=$alpha }
    $perfRows += [pscustomobject]@{ date=$o.date; code=$c; name=$o.name; entry=$o.price; cur=$cur; ret=$ret; alpha=$alpha; days=$days; status='closed' }
  } else {
    $perfRows += [pscustomobject]@{ date=$o.date; code=$c; name=$o.name; entry=$o.price; cur=$cur; ret=$ret; alpha=$alpha; days=$days; status='open' }
  }
}
$closedR=@($perfRows | Where-Object {$_.status -eq 'closed'})
$openR=@($perfRows | Where-Object {$_.status -eq 'open'})
$perfSummary=$null
if($closedR.Count -gt 0 -or $openR.Count -gt 0){
  $cw=($closedR | Where-Object {$_.alpha -ne $null -and $_.alpha -gt 0}).Count
  $ct=($closedR | Where-Object {$_.alpha -ne $null}).Count
  $perfSummary=@{
    closedN=$closedR.Count
    winRate=$(if($ct -gt 0){[math]::Round($cw/$ct*100,0)}else{$null})
    avgRetClosed=$(if($closedR.Count -gt 0){[math]::Round(($closedR|Measure-Object -Property ret -Average).Average,2)}else{$null})
    avgAlphaClosed=$(if($ct -gt 0){[math]::Round((($closedR|Where-Object {$_.alpha -ne $null}|Measure-Object -Property alpha -Average).Average),2)}else{$null})
    openN=$openR.Count
    avgRetOpen=$(if($openR.Count -gt 0){[math]::Round(($openR|Measure-Object -Property ret -Average).Average,2)}else{$null})
  }
}
# append today's picks: ONE snapshot per trade date (reruns never append), plus open-code dedupe
$openCodes=@{}; foreach($o in $norm){ if($o.status -eq 'open'){ $openCodes[$o.code]=$true } }
$dateLogged=($norm | Where-Object { $_.date -eq $lastDate }).Count -gt 0
$newLogged=0
if(-not $dateLogged){
  foreach($p in $top5){
    if($openCodes.ContainsKey($p.code)){ continue }
    $norm += ,@{ date=$lastDate; code=$p.code; name=$p.name; price=$p.close; score=$p.score; status='open' }
    $newLogged++
  }
} else { Write-Host "  date $lastDate already logged - snapshot preserved, no append" }
@{ picks=$norm } | ConvertTo-Json -Depth 5 | Out-File $logPath -Encoding UTF8

$out=@{
  date=$lastDate
  regime=@{ light=$light; idx=[math]::Round($idxLast,2); ma20=[math]::Round($idxMA20,2); ma60=[math]::Round($idxMA60,2); instNet=$instNet; up=$upN; down=$dnN }
  picks=$top5
  perf=$perfSummary
  perfRows=$perfRows
  meta=@{ candidates=$cands.Count; shortlist=@($short).Count; newLogged=$newLogged }
}
$out | ConvertTo-Json -Depth 6 | Out-File (Join-Path $root 'screen-result.json') -Encoding UTF8

# splice PICKS_KLINE (full OHLCV for pick modals) directly into index.html
$idxPath=Join-Path $root 'index.html'
if(Test-Path $idxPath){
  $enc=New-Object System.Text.UTF8Encoding($false)
  $html=[IO.File]::ReadAllText($idxPath,$enc)
  $startTag='<script id="pkline">'
  $i1=$html.IndexOf($startTag)
  if($i1 -ge 0){
    $i2=$html.IndexOf('</script>',$i1)
    $kd=[ordered]@{}
    foreach($p in $top5){ $kd[$p.code]=@{ chgPct=$p.chgPct; dist=$p.dist; kline=$p.kline } }
    $js='window.PICKS_KLINE='+($kd|ConvertTo-Json -Depth 6 -Compress)+';'
    $html=$html.Substring(0,$i1+$startTag.Length)+$js+$html.Substring($i2)
    [IO.File]::WriteAllText($idxPath,$html,$enc)
    Write-Host "  spliced PICKS_KLINE into index.html ($($js.Length) bytes)"
  } else { Write-Host "  pkline marker not found - skip splice" }
}
Write-Host "DONE. light=$light idx=$idxLast picks=$($top5.Count) newLogged=$newLogged openPos=$($openR.Count) closed=$($closedR.Count)"
foreach($p in $top5){ Write-Host ("  {0} {1} score={2} (chip{3}/tech{4}/fund{5}) spark={6}pts" -f $p.code,$p.name,$p.score,$p.chip,$p.tech,$p.fund,$p.spark.Count) }