# screen.ps1 - TWSE quant screening engine v2 (UTF-8 with BOM; contains CJK literals, e.g. IsElec/exit-reason strings)
# Runs on pwsh 7 (Linux); BOM is not required there but is kept so the file also parses under Windows PS5.1.
# v2: regime-aware scoring, 20-day auto-close tracking, dedupe, spark output
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/feed.ps1')       # Get-FeedJson / Get-FeedDailySeries / FeedCols
. (Join-Path $root 'lib/pagedata.ps1')   # Set-PageBlocks / Get-PageBlockText / Get-PageContract
. (Join-Path $root 'lib/picks-log.ps1')  # Get-PicksLog / Set-PicksLog / Add-PicksLogTags
. (Join-Path $root 'lib/score.ps1')      # the selection rules (shared with backtest.ps1)
# Num/GetJson keep their names so the ~30 call sites below read the same; the bodies live in
# lib/feed.ps1 now, because there used to be three copies of each and the timeouts had drifted.
function Num($s){ ConvertTo-FeedNum $s }
function GetJson($url){ Get-FeedJson $url }
function IsElec($ind){ foreach($k in @('半導體','電子','電腦','光電','通信','資訊')){ if("$ind" -like "*$k*"){ return $true } } return $false }
function StripK($obj){ $o=[ordered]@{}; foreach($pr in $obj.PSObject.Properties){ if($pr.Name -ne 'kline'){ $o[$pr.Name]=$pr.Value } }; [pscustomobject]$o }
# daily OHLCV series routed by market (TWSE STOCK_DAY / TPEx tradingStock); dt=yyyymmdd for date math
# completed months never change -> disk-cached under kline-cache/ (gitignored); current month always fetched live
# creation + eviction belong to lib/feed.ps1: this directory has two tenants (see the note
# there), and the prune used to sit here where a FATAL above it meant no eviction at all
$klineCache = Get-FeedCacheDir $root
$pruned = Invoke-FeedCachePrune $klineCache
if($pruned -gt 0){ Write-Host "  cache: pruned $pruned stale month file(s)" }
function GetDailySeries($code,$mms){
  # market is known upfront here (the whole-market tables in [1/8] said so), so no 'auto' probe
  $isO = ($mkt.ContainsKey($code) -and $mkt[$code] -eq 'o')
  $r = Get-FeedDailySeries -Code $code -Months $mms -Market $(if($isO){'o'}else{'t'}) `
                           -CacheDir $klineCache -WithDt
  return ,$r.Rows
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
      # cap at 10% of prev close: bigger gaps are capital reductions / rights issues, not cash dividends
      if($dv -gt 0.005 -and $rows[$k-1].c -gt 0 -and ($dv/$rows[$k-1].c) -le 0.10){ $s+=$dv }
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

# code -> official Chinese name for the WHOLE market (listed + OTC). The server uses this to fill
# in the name when someone adds a holding without typing one, so their page stops showing bare
# codes. It is exchange data, not user input, so nothing here weakens the "user text never
# reaches an AI prompt" rule. Only rewritten when the fetch actually produced names, so a failed
# TPEx call cannot blank the file.
if($px.Count -gt 0){
  $nameDir=Join-Path $root 'data'
  if(-not (Test-Path $nameDir)){ New-Item -ItemType Directory -Path $nameDir | Out-Null }
  $nameMap=[ordered]@{}
  foreach($k in ($px.Keys | Sort-Object)){ $n="$($px[$k].name)".Trim(); if($n){ $nameMap[$k]=$n } }
  $nameMap | ConvertTo-Json -Depth 2 -Compress | Out-File (Join-Path $nameDir 'names.json') -Encoding UTF8
  Write-Host "  wrote data/names.json ($($nameMap.Count) codes)"
}
$upN=0;$dnN=0
foreach($k in $px.Keys){ $g=$px[$k].chg; if($g -gt 0){$upN++} elseif($g -lt 0){$dnN++} }

Write-Host "[2/8] FMTQIK (index history)..."
$months=@(); $d0=[datetime]::ParseExact($lastDate,'yyyyMMdd',$null)
for($m=3;$m -ge 0;$m--){ $months += $d0.AddMonths(-$m).ToString('yyyyMM01') }
$idxHist=Get-FeedIndexHistory -Months $months
$idxC=@(); $tradeDates=@(); $idxOk=$idxHist.MonthsOk
foreach($row in $idxHist.Rows){ $idxC += $row.c; $tradeDates += $row.dt }
# total failure here would silently produce an empty-picks run indistinguishable from a real
# no-qualifying-stocks day (regime defaults to red, screening loops never execute) -> abort instead
if($idxC.Count -eq 0){ Write-Host "FATAL: FMTQIK failed for all $($months.Count) months - no index data, aborting to avoid overwriting good data with a silently-empty run"; exit 1 }
if($idxOk -lt $months.Count){ Write-Host "  WARNING: only $idxOk/$($months.Count) FMTQIK months fetched - regime/index calc may be degraded" }
function SMAlast($a,$n){ Get-ScoreSma $a $n }   # one implementation, in lib/score.ps1
$idxLast=$idxC[$idxC.Count-1]; $idxMA20=SMAlast $idxC 20; $idxMA60=SMAlast $idxC 60
$last5=$tradeDates | Select-Object -Last 5

Write-Host "[3/8] T86 x5 days: $($last5 -join ',')"
# Institutional net-buy series, collected per DATE and materialised aligned to the days that
# actually came back. These tables only list codes that traded with institutions that day, so
# appending as rows arrive silently shortens a quiet code's series - and then f[-1]/f[-2] (the
# "外資連2日轉賣" exit rule further down) would be comparing two days that are not the last two,
# and tPos>=3 could be 3-of-3 instead of 3-of-5. Absent from the table means zero net, so gaps
# are zero-filled; the count of days a code really appeared is kept as .n for the sufficiency
# gate that `$t.Count -lt 4` used to serve.
$chipDay=@{}
$t86ok=0
$tpexOk=0
$twDays=@(); $otcDays=@()
foreach($d in $last5){
  # values stay in SHARES here (the exchange's own unit) - the chip gate below is written in
  # shares, unlike update-holdings.ps1 which shows lots
  $tw=Get-FeedInstitutional -Date $d -Market 't'
  if($tw.Ok){
    $t86ok++; $twDays += $d
    foreach($c in $tw.Rows.Keys){
      if(-not $chipDay.ContainsKey($c)){ $chipDay[$c]=@{} }
      $e=$tw.Rows[$c]
      $chipDay[$c][$d]=@{ f=$e.f; t=$e.t; tot=$e.tot }
    }
  }
  $otc=Get-FeedInstitutional -Date $d -Market 'o'
  if($otc.Ok){
    $tpexOk++; $otcDays += $d
    foreach($c in $otc.Rows.Keys){
      if(-not $chipDay.ContainsKey($c)){ $chipDay[$c]=@{} }
      # a code listed on both boards keeps its TWSE row: same precedence as the $px build above
      if(-not $chipDay[$c].ContainsKey($d)){
        $e=$otc.Rows[$c]
        $chipDay[$c][$d]=@{ f=$e.f; t=$e.t; tot=$e.tot }
      }
    }
  }
}
if($t86ok -lt 5){ Write-Host "  WARNING: only $t86ok/5 T86 days fetched - chip screening degraded. Consider re-run later." }
if($tpexOk -lt 5){ Write-Host "  WARNING: only $tpexOk/5 TPEx insti days fetched - OTC chip screening degraded. Consider re-run later." }
# a code is aligned to the day list of ITS OWN market, so one failed TPEx day cannot zero-fill
# every OTC stock (which would quietly push them under the tPos/fPos gates)
$chip=@{}
foreach($c in $chipDay.Keys){
  $days = if($mkt.ContainsKey($c) -and $mkt[$c] -eq 'o'){ $otcDays } else { $twDays }
  $fA=@(); $tA=@(); $totA=@(); $seen=0
  foreach($d in $days){
    if($chipDay[$c].ContainsKey($d)){ $e=$chipDay[$c][$d]; $fA+=$e.f; $tA+=$e.t; $totA+=$e.tot; $seen++ }
    else { $fA+=0.0; $tA+=0.0; $totA+=0.0 }
  }
  $chip[$c]=@{ f=$fA; t=$tA; tot=$totA; n=$seen }
}

Write-Host "[4/8] BFI82U (market inst amount)..."
$instNet=Get-FeedMarketInstAmount -Date $lastDate
Write-Host "  instNet = $instNet (yi NTD)"

Write-Host "[5/8] MI_MARGN (margin)..."
$fin=@{}
foreach($mkKind in @('t','o')){
  $mg=Get-FeedMargin -Date $lastDate -Market $mkKind
  foreach($c in $mg.Rows.Keys){
    if($fin.ContainsKey($c)){ continue }   # TWSE row wins for a dual-listed code
    $fin[$c]=@{ today=$mg.Rows[$c].fin; prev=$mg.Rows[$c].finPrev }
  }
}

Write-Host "[6/8] BWIBBU_ALL + revenue..."
$pe=@{}
$r=GetJson "https://openapi.twse.com.tw/v1/exchangeReport/BWIBBU_ALL"
if($r){ foreach($row in $r){ $c="$($row.Code)".Trim(); $pe[$c]=@{ pe=(Num $row.PEratio); pb=(Num $row.PBratio); dy=(Num $row.DividendYield) } } }
$r=GetJson "https://www.tpex.org.tw/openapi/v1/tpex_mainboard_peratio_analysis"
if($r){ foreach($row in $r){ $c="$($row.SecuritiesCompanyCode)".Trim(); if(-not $pe.ContainsKey($c)){ $pe[$c]=@{ pe=(Num $row.PriceEarningRatio); pb=(Num $row.PriceBookRatio); dy=(Num $row.YieldRatio) } } } }
$rev=@{}
# positional-index guard: these two endpoints are parsed by column position; warn loudly if the layout ever shifts
function CheckRevCols($rows,$label){
  if(-not $rows -or @($rows).Count -eq 0){ return }
  $p0=@(@($rows)[0].PSObject.Properties)
  if($p0.Count -le 9 -or "$($p0[2].Name)" -notlike '*代號*' -or "$($p0[9].Name)" -notlike '*增減*'){
    Write-Host "  WARN: $label column layout changed (col2=$($p0[2].Name) col9=$($p0[9].Name)) - yoy/ind may be wrong, review parser"
  }
}
$r=GetJson "https://openapi.twse.com.tw/v1/opendata/t187ap05_L"
CheckRevCols $r 't187ap05_L'
if($r){ foreach($row in $r){ $p=@($row.PSObject.Properties); $c="$($p[2].Value)".Trim(); $rev[$c]=@{ ind="$($p[4].Value)".Trim(); yoy=(Num $p[9].Value); name="$($p[3].Value)".Trim() } } }
$r=GetJson "https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap05_O"
CheckRevCols $r 'mopsfin_t187ap05_O'
if($r){ foreach($row in $r){ $p=@($row.PSObject.Properties); $c="$($p[2].Value)".Trim(); if(-not $rev.ContainsKey($c)){ $rev[$c]=@{ ind="$($p[4].Value)".Trim(); yoy=(Num $p[9].Value); name="$($p[3].Value)".Trim() } } } }
Write-Host "  pe=$($pe.Count) rev=$($rev.Count) (TWSE+TPEx)"

# ----- regime light (computed BEFORE scoring so weights can adapt) -----
$light = Get-RegimeLight -IdxLast $idxLast -IdxMA20 $idxMA20 -IdxMA60 $idxMA60 `
                        -InstNet $instNet -UpCount $upN -DownCount $dnN
Write-Host "  regime = $light"

Write-Host "[7/8] screening..."
$ProfStock = Get-ScoreProfile 'stock'
$ProfEtf   = Get-ScoreProfile 'etf'
$cands=@()
foreach($c in $chip.Keys){
  if($c -notmatch '^[1-9][0-9]{3}$'){ continue }
  if(-not $px.ContainsKey($c)){ continue }
  if($px[$c].val -lt 1e8){ continue }             # liquidity >= NT$100M/day
  if($chip[$c].n -lt 4){ continue }               # .n = days the code actually appeared (gaps are zero-filled)
  $st=Get-ChipStats -Trust $chip[$c].t -Foreign $chip[$c].f
  if(-not (Test-ChipGate -Stats $st -Profile $ProfStock)){ continue }
  $fd=$fin[$c]
  $mDown = [bool]($fd -and $null -ne $fd.today -and $null -ne $fd.prev -and $fd.today -lt $fd.prev)
  $cands += [pscustomobject]@{ code=$c; chip=(Get-ChipScore -Stats $st -MarginDown $mDown)
                               tPos=$st.tPos; fPos=$st.fPos; tSum=$st.tSum; fSum=$st.fSum }
}
Write-Host "  candidates = $($cands.Count)"
$short = $cands | Sort-Object -Property @{e='chip';Descending=$true}, @{e='tSum';Descending=$true} | Select-Object -First 16

$picks=@()
$curMM=$d0.ToString('yyyyMM01'); $prvMM=$d0.AddMonths(-1).ToString('yyyyMM01'); $prv2MM=$d0.AddMonths(-2).ToString('yyyyMM01'); $prv3MM=$d0.AddMonths(-3).ToString('yyyyMM01')
foreach($s in $short){
  $c=$s.code
  $serF=GetDailySeries $c @($prv3MM,$prv2MM,$prvMM,$curMM)
  if($serF.Count -lt 25){ Write-Host "  drop $c series too short ($($serF.Count) rows)"; continue }
  $lastDtS="$($serF[$serF.Count-1].dt)"
  if($lastDtS -ne $lastDate){ Write-Host "  warn $c series stale (last=$lastDtS vs $lastDate) - monthly endpoint lagging, scores use previous bar" }
  $ser=@($serF | ForEach-Object { $_.c })
  $cl=$ser[$ser.Count-1]
  $ma20=SMAlast $ser 20; $ma60=SMAlast $ser 60
  $ma20p = if($ser.Count -ge 25){ SMAlast ($ser[0..($ser.Count-6)]) 20 } else { $null }
  $ret5 = if($ser.Count -ge 6){ $cl/$ser[$ser.Count-6]-1 } else { 0 }
  $n40=[math]::Min(40,$ser.Count); $hi40=($ser[($ser.Count-$n40)..($ser.Count-1)] | Measure-Object -Maximum).Maximum
  $dist = $cl/$hi40-1
  # scoring lives in lib/score.ps1 so backtest.ps1 replays THIS, not a transcription of it
  $lb=$serF[$serF.Count-1]
  $vAvg20 = if($serF.Count -ge 21){ (@($serF[($serF.Count-21)..($serF.Count-2)] | ForEach-Object { $_.v }) | Measure-Object -Average).Average } else { $null }
  $vr = if($vAvg20 -and $vAvg20 -gt 0){ $lb.v/$vAvg20 } else { $null }
  $ts = Get-TechScore -Bar @{ c=$cl; o=$lb.o; h=$lb.h; l=$lb.l; chg=$lb.chg; vr=$vr; val=$px[$c].val } `
                      -Ma @{ ma20=$ma20; ma20p=$ma20p; ma60=$ma60; ret5=$ret5; dist=$dist } `
                      -Light $light -Profile $ProfStock
  if($ts.Drop){ Write-Host "  drop $c $($ts.Reason)"; continue }
  $tech=$ts.Score
  $y=$null; $ind=''
  if($rev.ContainsKey($c)){ $y=$rev[$c].yoy; $ind=$rev[$c].ind }
  $peV=$null; $dyV=$null
  if($pe.ContainsKey($c)){ $peV=$pe[$c].pe; $dyV=$pe[$c].dy }
  $fund = Get-FundScore -YoY $y -PE $peV -DividendYield $dyV -Light $light
  $fd=$fin[$c]; $finDelta = if($fd -and $fd.today -ne $null -and $fd.prev -ne $null){ [int]($fd.today-$fd.prev) } else { $null }
  $spark=@(); $nS=[math]::Min(40,$ser.Count)
  foreach($v in $ser[($ser.Count-$nS)..($ser.Count-1)]){ $spark += [math]::Round($v,2) }
  $nK=[math]::Min(60,$serF.Count); $kline=StripDt @($serF[($serF.Count-$nK)..($serF.Count-1)])
  # daily % from the snapshot alone (close & chg from the same endpoint; monthly series may lag a day)
  $pxC=Num $px[$c].c; $pxChg=Num $px[$c].chg
  $chgPct=$(if($pxC -ne $null -and $pxChg -ne $null -and ($pxC-$pxChg) -ne 0){ [math]::Round($pxChg/($pxC-$pxChg)*100,2) } else { 0 })
  $picks += [pscustomobject]@{
    code=$c; name=$px[$c].name; ind=$ind; close=$cl; chgPct=$chgPct
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
  # require a KNOWN non-electronics industry for the swap-in; an unresolved ind='' isn't
  # confirmed diversification, just missing data, so it must not qualify as the "alt" pick
  $alt=$allPicks | Where-Object { $_.ind -and -not (IsElec $_.ind) } | Select-Object -First 1
  if($alt -and ($top5[4].score - $alt.score) -le 15){ $top5 = @($top5[0..3]) + @($alt) }
}
foreach($p in $allPicks){ $isTop=@($top5 | Where-Object { $_.code -eq $p.code }).Count -gt 0; $p | Add-Member -NotePropertyName top -NotePropertyValue $isTop -Force }

# ----- ETF momentum screening (chips + tech only; ETF has no EPS/PE) -----
Write-Host "[7b] ETF screening..."
$hold=@{}
try{ $hj=Get-Content (Join-Path $root 'holdings.json') -Raw -Encoding UTF8 | ConvertFrom-Json; foreach($h in $hj.holdings){ $hold["$($h.code)"]=$true } }
catch{ Write-Host "  WARN: holdings.json unreadable ($($_.Exception.Message)) - ETF owned flags will all be false today" }
$ecand=@()
foreach($c in $chip.Keys){
  if($c -notmatch '^00[0-9A-Z]+$'){ continue }
  if($c -match '[LRBU]$'){ continue }           # exclude leveraged/inverse/bond/futures ETFs
  if($chip[$c].n -lt 4){ continue }
  if($px.ContainsKey($c) -and $px[$c].val -lt $ProfEtf.minDayValue){ continue }
  $st=Get-ChipStats -Trust $chip[$c].t -Foreign $chip[$c].f
  if(-not (Test-ChipGate -Stats $st -Profile $ProfEtf)){ continue }
  $fd=$fin[$c]
  $mDown = [bool]($fd -and $null -ne $fd.today -and $null -ne $fd.prev -and $fd.today -lt $fd.prev)
  $ecand += [pscustomobject]@{ code=$c; chip=(Get-ChipScore -Stats $st -MarginDown $mDown)
                               tPos=$st.tPos; fPos=$st.fPos; tSum=$st.tSum; fSum=$st.fSum }
}
Write-Host "  etf candidates = $($ecand.Count)"
$eshort=$ecand | Sort-Object -Property @{e='chip';Descending=$true}, @{e='fSum';Descending=$true} | Select-Object -First 6
$etfPicks=@()
foreach($s in $eshort){
  $c=$s.code
  $serF=GetDailySeries $c @($prv3MM,$prv2MM,$prvMM,$curMM)
  if($serF.Count -lt 25){ Write-Host "  drop ETF $c series too short ($($serF.Count) rows)"; continue }
  $lastDtE="$($serF[$serF.Count-1].dt)"
  if($lastDtE -ne $lastDate){ Write-Host "  warn ETF $c series stale (last=$lastDtE vs $lastDate)" }
  $ser=@($serF | ForEach-Object { $_.c })
  $cl=$ser[$ser.Count-1]
  $ma20=SMAlast $ser 20; $ma60=SMAlast $ser 60
  $ma20p = if($ser.Count -ge 25){ SMAlast ($ser[0..($ser.Count-6)]) 20 } else { $null }
  $ret5 = if($ser.Count -ge 6){ $cl/$ser[$ser.Count-6]-1 } else { 0 }
  $n40=[math]::Min(40,$ser.Count); $hi40=($ser[($ser.Count-$n40)..($ser.Count-1)] | Measure-Object -Maximum).Maximum
  $dist=$cl/$hi40-1
  $lbE=$serF[$serF.Count-1]; $lastChg=$lbE.chg
  $vAvgE = if($serF.Count -ge 21){ (@($serF[($serF.Count-21)..($serF.Count-2)] | ForEach-Object { $_.v }) | Measure-Object -Average).Average } else { $null }
  $vrE = if($vAvgE -and $vAvgE -gt 0){ $lbE.v/$vAvgE } else { $null }
  # same function as the stock loop, different profile - the ETF board used to be a 68-line
  # copy of it with suffixed variable names
  $tsE = Get-TechScore -Bar @{ c=$cl; o=$lbE.o; h=$lbE.h; l=$lbE.l; chg=$lastChg; vr=$vrE; val=$null } `
                       -Ma @{ ma20=$ma20; ma20p=$ma20p; ma60=$ma60; ret5=$ret5; dist=$dist } `
                       -Light $light -Profile $ProfEtf
  if($tsE.Drop){ Write-Host "  drop ETF $c $($tsE.Reason)"; continue }
  $tech=$tsE.Score
  $fd=$fin[$c]; $finDelta = if($fd -and $fd.today -ne $null -and $fd.prev -ne $null){ [int]($fd.today-$fd.prev) } else { $null }
  $nm = if($px.ContainsKey($c)){ $px[$c].name } else { $c }
  $spark=@(); $nS=[math]::Min(40,$ser.Count)
  foreach($v in $ser[($ser.Count-$nS)..($ser.Count-1)]){ $spark += [math]::Round($v,2) }
  $nK=[math]::Min(60,$serF.Count); $kline=StripDt @($serF[($serF.Count-$nK)..($serF.Count-1)])
  # daily % from the snapshot alone (fallback to series if the ETF is missing from quotes)
  $pxCE=$(if($px.ContainsKey($c)){ Num $px[$c].c }else{ $null }); $pxChgE=$(if($px.ContainsKey($c)){ Num $px[$c].chg }else{ $null })
  $chgPctE=$(if($pxCE -ne $null -and $pxChgE -ne $null -and ($pxCE-$pxChgE) -ne 0){ [math]::Round($pxChgE/($pxCE-$pxChgE)*100,2) }
             elseif($lastChg -ne $null -and ($cl-$lastChg) -ne 0){ [math]::Round($lastChg/($cl-$lastChg)*100,2) } else { 0 })
  $etfPicks += [pscustomobject]@{
    code=$c; name=$nm; ind='ETF'; close=$cl; chgPct=$chgPctE
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
# Read + normalise through lib/picks-log.ps1: the retry, the FATAL-before-any-write guard and
# the [ordered] key order all live there now, so publish.ps1 (this file's second writer) gets
# exactly the same treatment instead of a bare Get-Content.
$norm=@()
try{ $norm = Get-PicksLog -Path $logPath -NameMap $px }
catch{
  Write-Host "FATAL: $($_.Exception.Message)"
  exit 1
}
$idxMap=@{}; for($i=0;$i -lt $tradeDates.Count;$i++){ $idxMap[$tradeDates[$i]]=$idxC[$i] }
$perfRows=@()
$histCache=@{}
foreach($o in $norm){
  if($o.date -eq $lastDate -and $o.status -eq 'open'){ continue }   # logged today, no perf yet
  if($o.status -eq 'void'){ continue }                              # settled without a price, see below
  if($o.status -eq 'closed'){
    $al = if($o.Contains('alphaFinal')){ $o.alphaFinal } else { $null }
    $dy2 = if($o.Contains('days')){ $o.days } else { 20 }
    $rs = if($o.Contains('reason')){ $o.reason } else { '20日到期' }
    $lg2=$(if($o.Contains('light')){$o.light}else{$null})
    $perfRows += [pscustomobject]@{ date=$o.date; code=$o.code; name=$o.name; entry=$o.price; cur=$o.exit; ret=$o.retFinal; alpha=$al; days=$dy2; status='closed'; reason=$rs; light=$lg2 }
    continue
  }
  $c=$o.code
  if(-not $px.ContainsKey($c)){
    # No quote today: delisted, suspended, or the market's fetch failed. Skipping forever left the
    # row 'open' for good - invisible on the page, never closed, and permanently holding the dedupe
    # key so the code could never be picked again. Give it the normal window, then settle it as
    # 'void': out of the tracking stats (no price = no honest return) but no longer open.
    $dGone=($tradeDates | Where-Object { $_ -gt $o.date -and $_ -le $lastDate }).Count
    if($dGone -ge 25){
      $o.status='void'; $o.days=$dGone; $o.closedOn=$lastDate; $o.reason='資料中斷'
      Write-Host "  作廢(連續無報價): $c $($o.name) days=$dGone"
    }
    continue
  }
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
  # MA rules run on dividend-adjusted (total-return) closes: an ex-div gap-down is mechanical,
  # not a technical break, and without the add-back a fat dividend fakes a MA20/MA10 breach.
  $tr = Get-TotalReturnSeries $hs
  $exitReason = Test-ExitRules -ForeignNet $(if($chip.ContainsKey($c)){ $chip[$c].f }else{ @() }) `
                               -TotalReturnSeries $tr.Series -Current ($cur+$tr.Cum) -ReturnPct $ret
  $lg3=$(if($o.Contains('light')){$o.light}else{$null})
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
  $perfSummary=[ordered]@{
    closedN=$closedR.Count
    winRate=$(if($ct -gt 0){[math]::Round($cw/$ct*100,0)}else{$null})
    avgRetClosed=$(if($closedR.Count -gt 0){[math]::Round(($closedR|Measure-Object -Property ret -Average).Average,2)}else{$null})
    avgAlphaClosed=$(if($ct -gt 0){[math]::Round((($closedR|Where-Object {$_.alpha -ne $null}|Measure-Object -Property alpha -Average).Average),2)}else{$null})
    openN=$openR.Count
    avgRetOpen=$(if($openR.Count -gt 0){[math]::Round(($openR|Measure-Object -Property ret -Average).Average,2)}else{$null})
  }
  # win rate grouped by regime light at entry (validates regime-aware scoring)
  $byLight=[ordered]@{}
  foreach($g in @('green','yellow','red')){
    $gr=@($closedR | Where-Object { $_.light -eq $g -and $_.alpha -ne $null })
    if($gr.Count -gt 0){
      $gw=($gr | Where-Object {$_.alpha -gt 0}).Count
      $byLight[$g]=[ordered]@{ n=$gr.Count; winRate=[math]::Round($gw/$gr.Count*100,0); avgAlpha=[math]::Round(($gr|Measure-Object -Property alpha -Average).Average,2) }
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
    $norm += ,[ordered]@{ date=$lastDate; code=$p.code; name=$p.name; price=$p.close; score=$p.score; status='open'; light=$light
                 chipS=$p.chip; techS=$p.tech; fundS=$p.fund; ret5=$p.ret5; dist=$p.dist; yoy=$p.yoy; pe=$p.pe; dy=$p.dy; ind=$p.ind }
    $newLogged++
  }
} else { Write-Host "  date $lastDate already logged - snapshot preserved, no append" }

# ---- retention + write. Both live in lib/picks-log.ps1: the fold's append-then-read-back
# ordering, the [ordered] key stability and the -ErrorAction Stop on the write. Passing -Retain
# is what opts this caller into archiving; publish.ps1 rewrites the same file without it.
Set-PicksLog -Path $logPath -Rows $norm -Retain $PicksLogRetainSettled `
             -ArchivePath (Join-Path $root 'data/picks-archive.jsonl')

$regimeObj=[ordered]@{ light=$light; idx=[math]::Round($idxLast,2); ma20=[math]::Round($idxMA20,2); ma60=[math]::Round($idxMA60,2); instNet=$instNet; up=$upN; down=$dnN }
$metaObj=[ordered]@{ candidates=$cands.Count; shortlist=@($short).Count; etfCand=$ecand.Count; newLogged=$newLogged; t86ok=$t86ok; tpexOk=$tpexOk; idxOk=$idxOk; revRows=$rev.Count }
$out=[ordered]@{
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
# Only the codes the AI actually writes about: SKILL.md says short comments are for top:true
# stocks plus the ETF board, and the non-top rows were ~60% of this file's bytes for nothing.
# The page draws its picks from PICKS_DATA, not from here, so nothing visible is lost.
$summaryOut=[ordered]@{
  date=$lastDate
  regime=$regimeObj
  picks=@($allPicks | Where-Object { $_.top } | ForEach-Object { SlimPick $_ })
  etf=@($etfTop | Select-Object -First 3 | ForEach-Object { SlimEtf $_ })
  perf=$perfSummary
  meta=$metaObj
}
$summaryOut | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root 'screen-summary.json') -Encoding UTF8
Write-Host "  wrote screen-summary.json (slim, for AI to read instead of screen-result.json)"

# build PICKS_KLINE + PICKS_DATA once, then (a) splice into index.html for the static page
# and (b) export as JSON for server mode. Picks are market-wide, so every user shares them.
$kd=[ordered]@{}
foreach($p in @($allPicks)+@($etfTop)){ $kd[$p.code]=[ordered]@{ chgPct=$p.chgPct; dist=$p.dist; kline=$p.kline } }
# cap page detail rows: all open + last 40 closed (full history stays in picks-log.json),
# otherwise index.html grows without bound as closed picks accumulate
$perfRowsPage=@($perfRows | Where-Object {$_.status -eq 'open'})+@(@($perfRows | Where-Object {$_.status -eq 'closed'}) | Select-Object -Last 40)
$pd=[ordered]@{
  date=$lastDate; regime=$regimeObj; meta=$metaObj; perf=$perfSummary; perfRows=$perfRowsPage
  picks=@($allPicks | ForEach-Object { StripK $_ })
  etf=@($etfTop | ForEach-Object { StripK $_ })
}

$idxPath=Join-Path $root 'index.html'
if(Test-Path $idxPath){
  Set-PageBlocks -IndexPath $idxPath -Blocks @{ pkline=$kd; pkdata=$pd }
  Write-Host "  spliced PICKS_KLINE + PICKS_DATA into index.html"
}

$dataDir=Join-Path $root 'data'
if(-not (Test-Path $dataDir)){ New-Item -ItemType Directory -Path $dataDir | Out-Null }
$pd | ConvertTo-Json -Depth 6 -Compress | Out-File (Join-Path $dataDir 'picks.json') -Encoding UTF8
$kd | ConvertTo-Json -Depth 6 -Compress | Out-File (Join-Path $dataDir 'picks-kline.json') -Encoding UTF8
Write-Host "  wrote data/picks.json + data/picks-kline.json"
Write-Host "DONE. light=$light idx=$idxLast stocks=$($allPicks.Count) etf=$($etfTop.Count) newLogged=$newLogged openPos=$($openR.Count) closed=$($closedR.Count)"
foreach($p in $top5){ Write-Host ("  TOP {0} {1} score={2} (chip{3}/tech{4}/fund{5})" -f $p.code,$p.name,$p.score,$p.chip,$p.tech,$p.fund) }
foreach($p in $etfTop){ Write-Host ("  ETF {0} {1} score={2}/70 owned={3}" -f $p.code,$p.name,$p.score,$p.owned) }