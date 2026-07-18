# screen.ps1 - TWSE quant screening engine v2 (ASCII source only)
# v2: regime-aware scoring, 20-day auto-close tracking, dedupe, spark output
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Num($s){ if($null -eq $s){return $null}; $t=("$s" -replace '[^0-9\.\-]',''); if($t -notmatch '[0-9]'){return $null}; try{ return [double]$t }catch{ return $null } }
function GetJson($url){
  for($i=0;$i -lt 3;$i++){
    try{
      $resp=Invoke-WebRequest -Uri $url -TimeoutSec 45 -UseBasicParsing
      $txt=[System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
      return ($txt | ConvertFrom-Json)
    }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}
function IsElec($ind){ foreach($k in @('半導體','電子','電腦','光電','通信','資訊')){ if("$ind" -like "*$k*"){ return $true } } return $false }
function StripK($obj){ $o=[ordered]@{}; foreach($pr in $obj.PSObject.Properties){ if($pr.Name -ne 'kline'){ $o[$pr.Name]=$pr.Value } }; [pscustomobject]$o }
# daily OHLCV series routed by market (TWSE STOCK_DAY / TPEx tradingStock); dt=yyyymmdd for date math
function GetDailySeries($code,$mms){
  $serX=@()
  $isO = ($mkt.ContainsKey($code) -and $mkt[$code] -eq 'o')
  foreach($mm in $mms){
    if($isO){
      $ds="{0}/{1}/01" -f $mm.Substring(0,4),$mm.Substring(4,2)
      $r=GetJson "https://www.tpex.org.tw/www/zh-tw/afterTrading/tradingStock?code=$code&date=$ds&response=json"
      if($r -and $r.tables -and $r.tables[0].data){ foreach($d in $r.tables[0].data){
        $dp="$($d[0])".Split('/')
        $serX += [ordered]@{ d=("{0}/{1}" -f [int]$dp[1],[int]$dp[2]); dt=("{0}{1:00}{2:00}" -f ([int]$dp[0]+1911),[int]$dp[1],[int]$dp[2]); o=(Num $d[3]); h=(Num $d[4]); l=(Num $d[5]); c=[double](Num $d[6]); chg=(Num $d[7]); v=[math]::Round([double](Num $d[1]),0) }
      } }
    } else {
      $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?date=$mm&stockNo=$code&response=json"
      if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){
        $dp="$($d[0])".Split('/')
        $serX += [ordered]@{ d=("{0}/{1}" -f [int]$dp[1],[int]$dp[2]); dt=("{0}{1:00}{2:00}" -f ([int]$dp[0]+1911),[int]$dp[1],[int]$dp[2]); o=(Num $d[3]); h=(Num $d[4]); l=(Num $d[5]); c=[double](Num $d[6]); chg=(Num $d[7]); v=[math]::Round([double](Num $d[1])/1000,0) }
      } }
    }
    Start-Sleep -Milliseconds 700
  }
  return ,$serX
}
# strip the internal dt field before splicing kline into the page (saves bytes; JS only needs d/o/h/l/c/chg/v)
function StripDt($rows){ $out=@(); foreach($r in $rows){ $o=[ordered]@{}; foreach($k in @('d','o','h','l','c','chg','v')){ $o[$k]=$r[$k] }; $out += ,$o }; return ,$out }
# dividend add-back: on ex-div days TWSE/TPEx chg is vs the adjusted reference price,
# so per-share payout = chg - (close - prevClose); sum events strictly after entry date
function DivSumSince($rows,$sinceDt){
  $s=0.0
  for($k=1;$k -lt $rows.Count;$k++){
    if("$($rows[$k].dt)" -le "$sinceDt"){ continue }
    if($rows[$k].chg -ne $null -and $rows[$k].c -ne $null -and $rows[$k-1].c -ne $null){
      $dv=$rows[$k].chg-($rows[$k].c-$rows[$k-1].c)
      if($dv -gt 0.005){ $s+=$dv }
    }
  }
  return $s
}

Write-Host "[1/8] STOCK_DAY_ALL..."
$all = GetJson "https://openapi.twse.com.tw/v1/exchangeReport/STOCK_DAY_ALL"
if(-not $all){ Write-Host "FATAL: STOCK_DAY_ALL failed"; exit 1 }
$rawDate = "$($all[0].Date)"
if($rawDate.Length -eq 7){ $lastDate = "{0}{1}" -f ([int]$rawDate.Substring(0,3)+1911), $rawDate.Substring(3) } else { $lastDate = $rawDate }
Write-Host "  latest trade date = $lastDate rows=$($all.Count)"
$px=@{}; $mkt=@{}
foreach($r in $all){
  $c="$($r.Code)".Trim()
  $px[$c]=@{ name=$r.Name; c=(Num $r.ClosingPrice); o=(Num $r.OpeningPrice); h=(Num $r.HighestPrice); l=(Num $r.LowestPrice); v=(Num $r.TradeVolume); val=(Num $r.TradeValue); chg=(Num $r.Change) }
  $mkt[$c]='t'
}

Write-Host "[1b/8] TPEx mainboard quotes (OTC market)..."
$otc=GetJson "https://www.tpex.org.tw/openapi/v1/tpex_mainboard_quotes"
$otcN=0
if($otc){
  foreach($r in $otc){
    $c="$($r.SecuritiesCompanyCode)".Trim()
    if($px.ContainsKey($c)){ continue }
    $px[$c]=@{ name=$r.CompanyName; c=(Num $r.Close); o=(Num $r.Open); h=(Num $r.High); l=(Num $r.Low); v=(Num $r.TradingShares); val=(Num $r.TransactionAmount); chg=(Num $r.Change) }
    $mkt[$c]='o'; $otcN++
  }
} else { Write-Host "  WARNING: TPEx quotes failed - screening TWSE only today" }
Write-Host "  otc rows=$otcN (total px=$($px.Count))"
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
  # TPEx daily institutional trading (OTC): col[4]=foreign net, col[13]=trust net, col[23]=3-insti total
  $dSlash="{0}/{1}/{2}" -f $d.Substring(0,4),$d.Substring(4,2),$d.Substring(6,2)
  $r2=GetJson "https://www.tpex.org.tw/www/zh-tw/insti/dailyTrade?type=Daily&sect=EW&date=$dSlash&response=json"
  if($r2 -and $r2.tables -and $r2.tables[0].data){
    foreach($row in $r2.tables[0].data){
      $c="$($row[0])".Trim()
      if(-not $chip.ContainsKey($c)){ $chip[$c]=@{f=@();t=@();tot=@()} }
      $chip[$c].f += [double](Num $row[4]); $chip[$c].t += [double](Num $row[13]); $chip[$c].tot += [double](Num $row[23])
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
# TPEx margin balance (OTC): col[2]=prev balance, col[6]=today balance
$lastSlash="{0}/{1}/{2}" -f $lastDate.Substring(0,4),$lastDate.Substring(4,2),$lastDate.Substring(6,2)
$r=GetJson "https://www.tpex.org.tw/www/zh-tw/margin/balance?date=$lastSlash&response=json"
if($r -and $r.tables){ $tbl=$r.tables | Where-Object { $_.data -and $_.data.Count -gt 100 } | Select-Object -First 1
  if($tbl){ foreach($row in $tbl.data){ $c="$($row[0])".Trim(); if(-not $fin.ContainsKey($c)){ $fin[$c]=@{ today=(Num $row[6]); prev=(Num $row[2]) } } } } }

Write-Host "[6/8] BWIBBU_ALL + revenue..."
$pe=@{}
$r=GetJson "https://openapi.twse.com.tw/v1/exchangeReport/BWIBBU_ALL"
if($r){ foreach($row in $r){ $c="$($row.Code)".Trim(); $pe[$c]=@{ pe=(Num $row.PEratio); pb=(Num $row.PBratio); dy=(Num $row.DividendYield) } } }
$r=GetJson "https://www.tpex.org.tw/openapi/v1/tpex_mainboard_peratio_analysis"
if($r){ foreach($row in $r){ $c="$($row.SecuritiesCompanyCode)".Trim(); if(-not $pe.ContainsKey($c)){ $pe[$c]=@{ pe=(Num $row.PriceEarningRatio); pb=(Num $row.PriceBookRatio); dy=(Num $row.YieldRatio) } } } }
$rev=@{}
$r=GetJson "https://openapi.twse.com.tw/v1/opendata/t187ap05_L"
if($r){ foreach($row in $r){ $p=@($row.PSObject.Properties); $c="$($p[2].Value)".Trim(); $rev[$c]=@{ ind="$($p[4].Value)".Trim(); yoy=(Num $p[9].Value); name="$($p[3].Value)".Trim() } } }
$r=GetJson "https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap05_O"
if($r){ foreach($row in $r){ $p=@($row.PSObject.Properties); $c="$($p[2].Value)".Trim(); if(-not $rev.ContainsKey($c)){ $rev[$c]=@{ ind="$($p[4].Value)".Trim(); yoy=(Num $p[9].Value); name="$($p[3].Value)".Trim() } } } }
Write-Host "  pe=$($pe.Count) rev=$($rev.Count) (TWSE+TPEx)"

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
$short = $cands | Sort-Object -Property @{e='chip';Descending=$true}, @{e='tSum';Descending=$true} | Select-Object -First 16

$picks=@()
$curMM=$d0.ToString('yyyyMM01'); $prvMM=$d0.AddMonths(-1).ToString('yyyyMM01'); $prv2MM=$d0.AddMonths(-2).ToString('yyyyMM01'); $prv3MM=$d0.AddMonths(-3).ToString('yyyyMM01')
foreach($s in $short){
  $c=$s.code
  $serF=GetDailySeries $c @($prv3MM,$prv2MM,$prvMM,$curMM)
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
  # --- volume/price structure & candle patterns (user framework: price-volume is king) ---
  $lb=$serF[$serF.Count-1]
  $vAvg20 = if($serF.Count -ge 21){ (@($serF[($serF.Count-21)..($serF.Count-2)] | ForEach-Object { $_.v }) | Measure-Object -Average).Average } else { $null }
  $vr = if($vAvg20 -and $vAvg20 -gt 0){ $lb.v/$vAvg20 } else { $null }
  $rng=$lb.h-$lb.l
  $upWick = if($rng -gt 0){ ($lb.h-[math]::Max($lb.o,$lb.c))/$rng } else { 0 }
  $loWick = if($rng -gt 0){ ([math]::Min($lb.o,$lb.c)-$lb.l)/$rng } else { 0 }
  $closePos = if($rng -gt 0){ ($lb.c-$lb.l)/$rng } else { 0.5 }
  # distribution day at highs: huge volume + weak close = possible institutional dumping -> reject
  if($dist -ge -0.03 -and $vr -ne $null -and $vr -ge 2 -and ($closePos -lt 0.35 -or $upWick -gt 0.6)){ Write-Host ("  drop $c distribution candle (vr={0})" -f [math]::Round($vr,1)); continue }
  if($lb.chg -gt 0 -and $vr -ne $null -and $vr -ge 1.5){ $tech+=4 }                    # volume-backed advance
  elseif($lb.chg -gt 0 -and $px[$c].val -gt 3e8){ $tech+=2 }
  if($dist -ge -0.03 -and $upWick -gt 0.6 -and $vr -ne $null -and $vr -ge 1.2){ $tech-=5 }  # long upper wick at highs
  if($dist -le -0.10 -and $loWick -gt 0.6){ $tech+=2 }                                  # hammer near lows = support
  if($tech -lt 0){ $tech=0 }
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
  $nK=[math]::Min(60,$serF.Count); $kline=StripDt @($serF[($serF.Count-$nK)..($serF.Count-1)])
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
$allPicks=@($picks | Select-Object -First 16)
$top5=@($allPicks | Select-Object -First 5)
if($top5.Count -eq 5 -and (@($top5 | Where-Object { -not (IsElec $_.ind) })).Count -eq 0){
  $alt=$allPicks | Where-Object { -not (IsElec $_.ind) } | Select-Object -First 1
  if($alt -and ($top5[4].score - $alt.score) -le 15){ $top5 = @($top5[0..3]) + @($alt) }
}
foreach($p in $allPicks){ $isTop=@($top5 | Where-Object { $_.code -eq $p.code }).Count -gt 0; $p | Add-Member -NotePropertyName top -NotePropertyValue $isTop -Force }

# ----- ETF momentum screening (chips + tech only; ETF has no EPS/PE) -----
Write-Host "[7b] ETF screening..."
$hold=@{}
try{ $hj=Get-Content (Join-Path $root 'holdings.json') -Raw -Encoding UTF8 | ConvertFrom-Json; foreach($h in $hj.holdings){ $hold["$($h.code)"]=$true } }catch{}
$ecand=@()
foreach($c in $chip.Keys){
  if($c -notmatch '^00[0-9A-Z]+$'){ continue }
  if($c -match '[LRBU]$'){ continue }           # exclude leveraged/inverse/bond/futures ETFs
  $t=$chip[$c].t; $f=$chip[$c].f
  if($t.Count -lt 4){ continue }
  $tPos=($t | Where-Object {$_ -gt 0}).Count
  $fPos=($f | Where-Object {$_ -gt 0}).Count
  $tSum=($t | Measure-Object -Sum).Sum; $fSum=($f | Measure-Object -Sum).Sum
  if($px.ContainsKey($c) -and $px[$c].val -lt 5e7){ continue }
  $ok=$false
  if($tPos -ge 3 -and $tSum -gt 200000){ $ok=$true }
  if($fPos -ge 4 -and $fSum -gt 1000000){ $ok=$true }
  if(-not $ok){ continue }
  $chipScore=[math]::Min(25,$tPos*5)+[math]::Min(10,$fPos*2)
  $fd=$fin[$c]; if($fd -and $fd.today -ne $null -and $fd.prev -ne $null -and $fd.today -lt $fd.prev){ $chipScore+=5 }
  $ecand += [pscustomobject]@{ code=$c; chip=$chipScore; tPos=$tPos; fPos=$fPos; tSum=$tSum; fSum=$fSum }
}
Write-Host "  etf candidates = $($ecand.Count)"
$eshort=$ecand | Sort-Object -Property @{e='chip';Descending=$true}, @{e='fSum';Descending=$true} | Select-Object -First 6
$etfPicks=@()
foreach($s in $eshort){
  $c=$s.code
  $serF=GetDailySeries $c @($prv3MM,$prv2MM,$prvMM,$curMM)
  if($serF.Count -lt 25){ continue }
  $ser=@($serF | ForEach-Object { $_.c })
  $cl=$ser[$ser.Count-1]
  $ma20=SMAlast $ser 20; $ma60=SMAlast $ser 60
  $ma20p = if($ser.Count -ge 25){ SMAlast ($ser[0..($ser.Count-6)]) 20 } else { $null }
  $ret5 = if($ser.Count -ge 6){ $cl/$ser[$ser.Count-6]-1 } else { 0 }
  $n40=[math]::Min(40,$ser.Count); $hi40=($ser[($ser.Count-$n40)..($ser.Count-1)] | Measure-Object -Maximum).Maximum
  $dist=$cl/$hi40-1
  if($ret5 -gt 0.20){ Write-Host "  drop ETF $c overheated"; continue }
  if($ma60 -ne $null -and $cl -lt $ma60){ Write-Host "  drop ETF $c below MA60"; continue }
  $tech=0
  if($ma20 -ne $null -and $cl -gt $ma20){ $tech+=10 }
  if($ma60 -ne $null -and $cl -gt $ma60){ $tech+=8 }
  if($ma20p -ne $null -and $ma20 -gt $ma20p){ $tech+=5 }
  if($dist -ge -0.05){ $tech+=4 }
  $lbE=$serF[$serF.Count-1]; $lastChg=$lbE.chg
  $vAvgE = if($serF.Count -ge 21){ (@($serF[($serF.Count-21)..($serF.Count-2)] | ForEach-Object { $_.v }) | Measure-Object -Average).Average } else { $null }
  $vrE = if($vAvgE -and $vAvgE -gt 0){ $lbE.v/$vAvgE } else { $null }
  if($lastChg -gt 0 -and $vrE -ne $null -and $vrE -ge 1.3){ $tech+=3 } elseif($lastChg -gt 0){ $tech+=1 }
  if($tech -gt 30){ $tech=30 }
  $fd=$fin[$c]; $finDelta = if($fd -and $fd.today -ne $null -and $fd.prev -ne $null){ [int]($fd.today-$fd.prev) } else { $null }
  $nm = if($px.ContainsKey($c)){ $px[$c].name } else { $c }
  $spark=@(); $nS=[math]::Min(40,$ser.Count)
  foreach($v in $ser[($ser.Count-$nS)..($ser.Count-1)]){ $spark += [math]::Round($v,2) }
  $nK=[math]::Min(60,$serF.Count); $kline=StripDt @($serF[($serF.Count-$nK)..($serF.Count-1)])
  $etfPicks += [pscustomobject]@{
    code=$c; name=$nm; ind='ETF'; close=$cl; chgPct=[math]::Round($lastChg/($cl-$lastChg)*100,2)
    score=($s.chip+$tech); chip=$s.chip; tech=$tech
    tPos=$s.tPos; fPos=$s.fPos; tSum=[math]::Round($s.tSum/1000,0); fSum=[math]::Round($s.fSum/1000,0)
    finDelta=$finDelta; ret5=[math]::Round($ret5*100,1); dist=[math]::Round($dist*100,1)
    ma20=[math]::Round($ma20,2); ma60=$(if($ma60 -ne $null){[math]::Round($ma60,2)}else{$null})
    owned=$hold.ContainsKey($c)
    spark=$spark; kline=$kline
  }
}
$etfTop=@($etfPicks | Sort-Object -Property @{e='score';Descending=$true} | Select-Object -First 5)
Write-Host "  etf picks = $($etfTop.Count)"

Write-Host "[8/8] picks-log (20-day auto-close, dedupe) + output..."
$logPath=Join-Path $root 'picks-log.json'
$norm=@()
if(Test-Path $logPath){
  try{
    $lg=Get-Content $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($p in @($lg.picks)){
      $o=@{ date="$($p.date)"; code="$($p.code)"; name="$($p.name)"; price=[double]$p.price; score=[int]$p.score }
      if($px.ContainsKey($o.code) -and $px[$o.code].name){ $o.name="$($px[$o.code].name)" }   # heals legacy mojibake names
      $o.status = if($p.PSObject.Properties['status'] -and $p.status){ "$($p.status)" } else { 'open' }
      # pass through factor snapshot + AI tags (added at entry; used by evaluate.ps1 attribution)
      foreach($fld in @('light','chipS','techS','fundS','ret5','dist','yoy','pe','dy','ind','aiSust','aiRisk')){
        if($p.PSObject.Properties[$fld] -and $null -ne $p.$fld){ $o[$fld]=$p.$fld }
      }
      if($p.PSObject.Properties['exit'] -and $p.exit -ne $null){ $o.exit=[double]$p.exit }
      if($p.PSObject.Properties['retFinal'] -and $p.retFinal -ne $null){ $o.retFinal=[double]$p.retFinal }
      if($p.PSObject.Properties['alphaFinal'] -and $p.alphaFinal -ne $null){ $o.alphaFinal=[double]$p.alphaFinal }
      if($p.PSObject.Properties['closedOn'] -and $p.closedOn){ $o.closedOn="$($p.closedOn)" }
      if($p.PSObject.Properties['days'] -and $p.days -ne $null){ $o.days=[int]$p.days }
      if($p.PSObject.Properties['reason'] -and $p.reason){ $o.reason="$($p.reason)" }
      $norm += ,$o
    }
  }catch{}
}
$idxMap=@{}; for($i=0;$i -lt $tradeDates.Count;$i++){ $idxMap[$tradeDates[$i]]=$idxC[$i] }
$perfRows=@()
$histCache=@{}
foreach($o in $norm){
  if($o.date -eq $lastDate -and $o.status -eq 'open'){ continue }   # logged today, no perf yet
  if($o.status -eq 'closed'){
    $al = if($o.ContainsKey('alphaFinal')){ $o.alphaFinal } else { $null }
    $dy2 = if($o.ContainsKey('days')){ $o.days } else { 20 }
    $rs = if($o.ContainsKey('reason')){ $o.reason } else { '20日到期' }
    $lg2=$(if($o.ContainsKey('light')){$o.light}else{$null})
    $perfRows += [pscustomobject]@{ date=$o.date; code=$o.code; name=$o.name; entry=$o.price; cur=$o.exit; ret=$o.retFinal; alpha=$al; days=$dy2; status='closed'; reason=$rs; light=$lg2 }
    continue
  }
  $c=$o.code
  if(-not $px.ContainsKey($c)){ continue }
  $cur=$px[$c].c
  if($o.price -le 0){ continue }
  $days=($tradeDates | Where-Object { $_ -gt $o.date -and $_ -le $lastDate }).Count
  # 2-month history for exit rules + dividend add-back (total-return tracking)
  if(-not $histCache.ContainsKey($c)){ $histCache[$c]=GetDailySeries $c @($prvMM,$curMM) }
  $hs=$histCache[$c]
  $divSum=DivSumSince $hs $o.date
  $ret=[math]::Round((($cur+$divSum)/$o.price-1)*100,2)
  $alpha=$null
  if($idxMap.ContainsKey($o.date)){ $alpha=[math]::Round($ret - (($idxLast/$idxMap[$o.date]-1)*100),2) }
  # ---- early-exit rules: foreign 2-day sell / close below MA20 / trailing take-profit ----
  $exitReason=$null
  if($chip.ContainsKey($c)){
    $fArr=$chip[$c].f
    if($fArr.Count -ge 2 -and $fArr[$fArr.Count-1] -lt 0 -and $fArr[$fArr.Count-2] -lt 0){ $exitReason='外資連2日轉賣' }
  }
  if(-not $exitReason -and $hs.Count -ge 20){
    $hcl=@($hs | ForEach-Object { $_.c })
    $m20x=SMAlast $hcl 20
    if($m20x -ne $null -and $cur -lt $m20x){ $exitReason='跌破月線' }
    elseif($ret -ge 15){
      $m10x=SMAlast $hcl 10
      if($m10x -ne $null -and $cur -lt $m10x){ $exitReason='移動停利（獲利15%+回檔破10日線）' }
    }
  }
  $lg3=$(if($o.ContainsKey('light')){$o.light}else{$null})
  if($exitReason -or $days -ge 20){
    $rs = if($exitReason){ $exitReason } else { '20日到期' }
    $o.status='closed'; $o.exit=$cur; $o.retFinal=$ret; $o.days=$days; $o.closedOn=$lastDate; $o.reason=$rs
    if($alpha -ne $null){ $o.alphaFinal=$alpha }
    $perfRows += [pscustomobject]@{ date=$o.date; code=$c; name=$o.name; entry=$o.price; cur=$cur; ret=$ret; alpha=$alpha; days=$days; status='closed'; reason=$rs; light=$lg3 }
    Write-Host "  early/期滿出場: $c $($o.name) $rs ret=$ret%"
  } else {
    $perfRows += [pscustomobject]@{ date=$o.date; code=$c; name=$o.name; entry=$o.price; cur=$cur; ret=$ret; alpha=$alpha; days=$days; status='open'; reason=$null; light=$lg3 }
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
  # win rate grouped by regime light at entry (validates regime-aware scoring)
  $byLight=@{}
  foreach($g in @('green','yellow','red')){
    $gr=@($closedR | Where-Object { $_.light -eq $g -and $_.alpha -ne $null })
    if($gr.Count -gt 0){
      $gw=($gr | Where-Object {$_.alpha -gt 0}).Count
      $byLight[$g]=@{ n=$gr.Count; winRate=[math]::Round($gw/$gr.Count*100,0); avgAlpha=[math]::Round(($gr|Measure-Object -Property alpha -Average).Average,2) }
    }
  }
  if($byLight.Keys.Count -gt 0){ $perfSummary.byLight=$byLight }
}
# append today's picks: ONE snapshot per trade date (reruns never append), plus open-code dedupe
$openCodes=@{}; foreach($o in $norm){ if($o.status -eq 'open'){ $openCodes[$o.code]=$true } }
$dateLogged=($norm | Where-Object { $_.date -eq $lastDate }).Count -gt 0
$newLogged=0
if(-not $dateLogged){
  foreach($p in $top5){
    if($openCodes.ContainsKey($p.code)){ continue }
    $norm += ,@{ date=$lastDate; code=$p.code; name=$p.name; price=$p.close; score=$p.score; status='open'; light=$light
                 chipS=$p.chip; techS=$p.tech; fundS=$p.fund; ret5=$p.ret5; dist=$p.dist; yoy=$p.yoy; pe=$p.pe; dy=$p.dy; ind=$p.ind }
    $newLogged++
  }
} else { Write-Host "  date $lastDate already logged - snapshot preserved, no append" }
@{ picks=$norm } | ConvertTo-Json -Depth 5 | Out-File $logPath -Encoding UTF8

$regimeObj=@{ light=$light; idx=[math]::Round($idxLast,2); ma20=[math]::Round($idxMA20,2); ma60=[math]::Round($idxMA60,2); instNet=$instNet; up=$upN; down=$dnN }
$metaObj=@{ candidates=$cands.Count; shortlist=@($short).Count; etfCand=$ecand.Count; newLogged=$newLogged; t86ok=$t86ok; revRows=$rev.Count }
$out=@{
  date=$lastDate
  regime=$regimeObj
  picks=$allPicks
  etf=$etfTop
  perf=$perfSummary
  perfRows=$perfRows
  meta=$metaObj
}
$out | ConvertTo-Json -Depth 7 | Out-File (Join-Path $root 'screen-result.json') -Encoding UTF8

# slim summary for the AI to read (no kline/spark) - screen-result.json is for the page/debug only,
# it can be 500KB+; this file is what AI should Read for writing PICKS_NOTES (a few KB, not hundreds).
function SlimPick($p){ [pscustomobject]@{ code=$p.code; name=$p.name; ind=$p.ind; close=$p.close; chgPct=$p.chgPct; score=$p.score; chip=$p.chip; tech=$p.tech; fund=$p.fund; top=$p.top; tPos=$p.tPos; fPos=$p.fPos; tSum=$p.tSum; fSum=$p.fSum; finDelta=$p.finDelta; yoy=$p.yoy; pe=$p.pe; dy=$p.dy; ret5=$p.ret5; dist=$p.dist } }
function SlimEtf($p){ [pscustomobject]@{ code=$p.code; name=$p.name; close=$p.close; chgPct=$p.chgPct; score=$p.score; chip=$p.chip; tech=$p.tech; owned=$p.owned; tPos=$p.tPos; fPos=$p.fPos; tSum=$p.tSum; fSum=$p.fSum; finDelta=$p.finDelta; ret5=$p.ret5; dist=$p.dist } }
$summaryOut=@{
  date=$lastDate
  regime=$regimeObj
  picks=@($allPicks | ForEach-Object { SlimPick $_ })
  etf=@($etfTop | ForEach-Object { SlimEtf $_ })
  perf=$perfSummary
  meta=$metaObj
}
$summaryOut | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root 'screen-summary.json') -Encoding UTF8
Write-Host "  wrote screen-summary.json (slim, for AI to read instead of screen-result.json)"

# splice PICKS_KLINE + PICKS_DATA directly into index.html
$idxPath=Join-Path $root 'index.html'
if(Test-Path $idxPath){
  $enc=New-Object System.Text.UTF8Encoding($false)
  $html=[IO.File]::ReadAllText($idxPath,$enc)
  function Splice([string]$html,[string]$marker,[string]$payload){
    $st='<script id="'+$marker+'">'
    $i1=$html.IndexOf($st)
    if($i1 -lt 0){ Write-Host "  marker $marker not found - skip"; return $html }
    $i2=$html.IndexOf('</script>',$i1)
    return $html.Substring(0,$i1+$st.Length)+$payload+$html.Substring($i2)
  }
  $kd=[ordered]@{}
  foreach($p in @($allPicks)+@($etfTop)){ $kd[$p.code]=@{ chgPct=$p.chgPct; dist=$p.dist; kline=$p.kline } }
  $html=Splice $html 'pkline' ('window.PICKS_KLINE='+($kd|ConvertTo-Json -Depth 6 -Compress)+';')
  # cap page detail rows: all open + last 40 closed (full history stays in picks-log.json),
  # otherwise index.html grows without bound as closed picks accumulate
  $perfRowsPage=@($perfRows | Where-Object {$_.status -eq 'open'})+@(@($perfRows | Where-Object {$_.status -eq 'closed'}) | Select-Object -Last 40)
  $pd=[ordered]@{
    date=$lastDate; regime=$regimeObj; meta=$metaObj; perf=$perfSummary; perfRows=$perfRowsPage
    picks=@($allPicks | ForEach-Object { StripK $_ })
    etf=@($etfTop | ForEach-Object { StripK $_ })
  }
  $html=Splice $html 'pkdata' ('window.PICKS_DATA='+($pd|ConvertTo-Json -Depth 6 -Compress)+';')
  [IO.File]::WriteAllText($idxPath,$html,$enc)
  Write-Host "  spliced PICKS_KLINE + PICKS_DATA into index.html"
}
Write-Host "DONE. light=$light idx=$idxLast stocks=$($allPicks.Count) etf=$($etfTop.Count) newLogged=$newLogged openPos=$($openR.Count) closed=$($closedR.Count)"
foreach($p in $top5){ Write-Host ("  TOP {0} {1} score={2} (chip{3}/tech{4}/fund{5})" -f $p.code,$p.name,$p.score,$p.chip,$p.tech,$p.fund) }
foreach($p in $etfTop){ Write-Host ("  ETF {0} {1} score={2}/70 owned={3}" -f $p.code,$p.name,$p.score,$p.owned) }