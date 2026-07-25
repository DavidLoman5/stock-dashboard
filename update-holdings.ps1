# update-holdings.ps1 - fully scripted fetch of holdings' official TWSE data.
# AI never sees raw API responses: this script fetches, computes, and splices
# window.DASH / window.META / window.HOLDINGS_META directly into index.html,
# then writes a small holdings-context.json for the AI to read for writing analysis text.
#
# Server mode (multi-user): -HoldingsFile points at the owner's portfolio exported from the
# app DB, and -CodesFrom adds the union of every active user's codes so one fetch serves
# everyone (quotes are identical per code; only lots/trades are personal). Both default to
# the single-user behaviour, so a fresh clone still runs with just holdings.json.
param(
  [string]$HoldingsFile,
  [string]$CodesFrom,
  [string]$DataDir
)
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/feed.ps1')       # Get-FeedJson / Get-FeedDailySeries / FeedCols
. (Join-Path $root 'lib/pagedata.ps1')   # Set-PageBlocks / Get-PageBlockText / Get-PageContract
. (Join-Path $root 'lib/stance.ps1')     # Get-StanceGrade (the 判級 rule engine)
# bodies live in lib/feed.ps1; names kept so the call sites below read the same
function Num($s){ ConvertTo-FeedNum $s }
function GetJson($url){ Get-FeedJson $url }
function SMAlast($a,$n){ if($a.Count -lt $n){return $null}; ($a[($a.Count-$n)..($a.Count-1)] | Measure-Object -Average).Average }
# Quantities are shares. A `lots` key means the file predates that change (or came from an older
# clone) - convert instead of rejecting, 1 lot = 1000 shares.
function SharesOf($h){
  if($h.PSObject.Properties['shares'] -and $null -ne $h.shares){ return [int]$h.shares }
  if($h.PSObject.Properties['lots'] -and $null -ne $h.lots){ return [int]([double]$h.lots * 1000) }
  return 0
}
# local reads can transiently fail (lock/partial write) - retry before giving up (caller decides how to fail)
function ReadJsonRetry($path){
  for($i=0;$i -lt 3;$i++){
    try{ return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}

if(-not $DataDir){ $DataDir = Join-Path $root 'data' }
if(-not (Test-Path $DataDir)){ New-Item -ItemType Directory -Path $DataDir | Out-Null }
# Server mode is detected, not configured: if the app DB has exported an owner portfolio we
# analyse that, otherwise we fall back to the in-repo holdings.json. A fresh clone has no
# data/ dir and so behaves exactly like the original single-user script.
if(-not $HoldingsFile){
  $ownerExport = Join-Path $DataDir 'owner-holdings.json'
  $HoldingsFile = if(Test-Path $ownerExport){ $ownerExport } else { Join-Path $root 'holdings.json' }
}
if(-not $CodesFrom){
  $codesExport = Join-Path $DataDir 'active-codes.json'
  if(Test-Path $codesExport){ $CodesFrom = $codesExport }
}

Write-Host "[1/6] $(Split-Path -Leaf $HoldingsFile)..."
$hj = Get-Content $HoldingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$ownCodes = @($hj.holdings | ForEach-Object { "$($_.code)" })
# extra codes = other users' holdings; fetched into DASH so the server can serve them, but
# they never reach HOLDINGS_META / holdings-context.json (those stay this portfolio's only)
$extraCodes = @()
if($CodesFrom -and (Test-Path $CodesFrom)){
  $cf = ReadJsonRetry $CodesFrom
  # a broken/empty codes file must not silently shrink the fetch set - warn and carry on
  if($null -eq $cf){ Write-Host "  WARN: $CodesFrom unreadable - fetching own codes only" }
  else { $extraCodes = @(@($cf.codes) | ForEach-Object { "$_" } | Where-Object { $_ -and $ownCodes -notcontains $_ } | Select-Object -Unique) }
}
$codes = @($ownCodes) + @($extraCodes)
Write-Host "  codes: $($ownCodes -join ', ')$(if($extraCodes.Count){" (+$($extraCodes.Count) shared: $($extraCodes -join ', '))"})"

Write-Host "[2/6] STOCK_DAY per holding (4 months) + FMTQIK (TAIEX)..."
$today = Get-Date
$months=@(); for($m=3;$m -ge 0;$m--){ $months += $today.AddMonths(-$m).ToString('yyyyMM01') }
$DASH=[ordered]@{}
$tx=@(); $tradeDates=@()
foreach($mm in $months){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/FMTQIK?date=$mm&response=json"
  if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){
    $p="$($d[0])".Split('/'); $tradeDates += ("{0}{1}{2}" -f ([int]$p[0]+1911),$p[1],$p[2])
    $tx += [ordered]@{ d=("{0}/{1}" -f [int]$p[1],[int]$p[2]); c=[double](Num $d[4]); chg=(Num $d[5]); amt=[math]::Round((Num $d[2])/1e8,0) }
  } }
  Start-Sleep -Milliseconds 700
}
$DASH['TAIEX']=$tx
# FATAL guard: without index history we would splice a broken DASH and blank the whole page
if($tx.Count -lt 10){ Write-Host "FATAL: FMTQIK returned $($tx.Count) rows - aborting, index.html untouched"; exit 1 }
$lastDate = $tradeDates[$tradeDates.Count-1]
Write-Host "  latest trade date = $lastDate ($($tx.Count) TAIEX rows)"

$otcCodes=@{}
# completed months never change -> disk-cached like screen.ps1, but with an "h-" prefix:
# row schema differs (no dt field here), sharing files with screen's cache would silently
# break its DivSumSince/stale checks
$klineCache=Join-Path $root 'kline-cache'
if(-not (Test-Path $klineCache)){ New-Item -ItemType Directory -Path $klineCache | Out-Null }
foreach($c in $codes){
  # 'auto': try TWSE for every month first and fall back to TPEx only if that produced nothing.
  # Unlike screen.ps1 there is no whole-market table here to look the market up in, so the
  # routing has to be discovered. The OTC branch is cached now too - the hand-written copy of
  # this loop cached the TWSE months but not the TPEx fallback, so OTC holdings refetched four
  # months of history on every single run.
  $fs = Get-FeedDailySeries -Code $c -Months $months -Market 'auto' `
                            -CacheDir $klineCache -CachePrefix 'h-'
  $serF = $fs.Rows
  if($fs.Market -eq 'o'){ $otcCodes[$c]=$true; Write-Host "  $c routed to TPEx (OTC)" }
  $DASH[$c]=[ordered]@{ series=$serF; inst=@(); margin=@() }
  Write-Host "  $c series=$($serF.Count)"
}
# FATAL guard: page hydrate() crashes on an empty series (whole dashboard goes blank)
$empty=@($codes | Where-Object { @($DASH[$_].series).Count -lt 25 })
if($empty.Count -gt 0){ Write-Host "FATAL: series too short for $($empty -join ',') - aborting, index.html untouched"; exit 1 }

Write-Host "[3/6] T86 (5 days) + MI_MARGN (3 days)..."
$last5 = $tradeDates | Select-Object -Last 5
foreach($d in $last5){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/fund/T86?date=$d&selectType=ALL&response=json"
  if($r -and $r.stat -eq 'OK'){
    foreach($row in $r.data){
      $c="$($row[0])".Trim()
      if($codes -contains $c){
        $dd=("{0}/{1}" -f [int]$d.Substring(4,2),[int]$d.Substring(6,2))
        $DASH[$c].inst += [ordered]@{ d=$dd; f=[math]::Round((Num $row[4])/1000,0); t=[math]::Round((Num $row[10])/1000,0); de=[math]::Round((Num $row[11])/1000,0); tot=[math]::Round((Num $row[18])/1000,0) }
      }
    }
  }
  Start-Sleep -Milliseconds 800
}
if($otcCodes.Count -gt 0){
  # OTC institutional trades (TPEx dailyTrade EW): f=col4, t=col13, tot=col23 (indexes proven in screen.ps1);
  # dealer net derived as tot-f-t instead of guessing an unverified column
  foreach($d in $last5){
    $dSlash="{0}/{1}/{2}" -f $d.Substring(0,4),$d.Substring(4,2),$d.Substring(6,2)
    $r=GetJson "https://www.tpex.org.tw/www/zh-tw/insti/dailyTrade?type=Daily&sect=EW&date=$dSlash&response=json"
    if($r -and $r.tables -and $r.tables[0].data){
      foreach($row in $r.tables[0].data){
        $c="$($row[0])".Trim()
        if($otcCodes.ContainsKey($c)){
          $dd=("{0}/{1}" -f [int]$d.Substring(4,2),[int]$d.Substring(6,2))
          $f=[math]::Round((Num $row[4])/1000,0); $t=[math]::Round((Num $row[13])/1000,0); $tot=[math]::Round((Num $row[23])/1000,0)
          $DASH[$c].inst += [ordered]@{ d=$dd; f=$f; t=$t; de=($tot-$f-$t); tot=$tot }
        }
      }
    }
    Start-Sleep -Milliseconds 800
  }
}
$last3 = $tradeDates | Select-Object -Last 3
foreach($d in $last3){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/marginTrading/MI_MARGN?date=$d&selectType=ALL&response=json"
  if($r){
    $tbl=$r.tables | Where-Object { $_.fields -and $_.fields[0] -eq '代號' } | Select-Object -First 1
    if($tbl){
      foreach($row in $tbl.data){
        $c="$($row[0])".Trim()
        if($codes -contains $c){
          $dd=("{0}/{1}" -f [int]$d.Substring(4,2),[int]$d.Substring(6,2))
          $DASH[$c].margin += [ordered]@{ d=$dd; fin=[int](Num $row[6]); finPrev=[int](Num $row[5]); shrt=[int](Num $row[12]); shrtPrev=[int](Num $row[11]) }
        }
      }
    }
  }
  if($otcCodes.Count -gt 0){
    # OTC margin balance (TPEx): finPrev=col2, fin=col6 (indexes proven in screen.ps1);
    # short-sale columns unverified there -> 0 (adviseHolding/stance only use fin/finPrev)
    $dSlash="{0}/{1}/{2}" -f $d.Substring(0,4),$d.Substring(4,2),$d.Substring(6,2)
    $r=GetJson "https://www.tpex.org.tw/www/zh-tw/margin/balance?date=$dSlash&response=json"
    if($r -and $r.tables){
      $tbl=$r.tables | Where-Object { $_.data -and $_.data.Count -gt 100 } | Select-Object -First 1
      if($tbl){
        foreach($row in $tbl.data){
          $c="$($row[0])".Trim()
          if($otcCodes.ContainsKey($c)){
            $dd=("{0}/{1}" -f [int]$d.Substring(4,2),[int]$d.Substring(6,2))
            $DASH[$c].margin += [ordered]@{ d=$dd; fin=[int](Num $row[6]); finPrev=[int](Num $row[2]); shrt=0; shrtPrev=0 }
          }
        }
      }
    }
    Start-Sleep -Milliseconds 800
  }
  Start-Sleep -Milliseconds 800
}

Write-Host "[4/6] TWT48U_ALL (ex-dividend)..."
$divMap=@{}
$r=GetJson "https://openapi.twse.com.tw/v1/exchangeReport/TWT48U_ALL"
if($r){
  foreach($row in $r){
    $c="$($row.Code)".Trim()
    if($codes -contains $c){
      $ds="$($row.Date)"
      if($ds.Length -eq 7){
        $y=[int]$ds.Substring(0,3)+1911; $mo=[int]$ds.Substring(3,2); $da=[int]$ds.Substring(5,2)
        $exDate=Get-Date -Year $y -Month $mo -Day $da
        if($exDate -ge $today.Date){ $divMap[$c]="$mo/$da 除息" }
      }
    }
  }
}
Write-Host "  div notes: $($divMap.Count) upcoming"

Write-Host "[5/6] compute holdings-context.json (small, for AI to read) + HOLDINGS_META..."
$HOLDINGS_META=[ordered]@{}
# trades ride along as a special _-prefixed key (like _market in notes); page filters _ keys out of H
$HOLDINGS_META['_trades']=@($hj.trades | ForEach-Object { [ordered]@{ d=$_.d; side=$_.side; code="$($_.code)"; shares=(SharesOf $_); price=$_.price } })
# One definition of "the numbers an analysis step needs", used for both files below, so the
# owner's context and the all-codes context can never drift apart.
function CodeContext($c,$nm){
  $ser=@($DASH[$c].series | ForEach-Object { $_.c })
  if($ser.Count -lt 1){ return $null }
  $last=$DASH[$c].series[$DASH[$c].series.Count-1]
  $ma20=SMAlast $ser 20; $ma60=SMAlast $ser 60
  $ma20p = if($ser.Count -ge 25){ SMAlast ($ser[0..($ser.Count-6)]) 20 } else { $null }
  $n40=[math]::Min(40,$ser.Count); $hi40=($ser[($ser.Count-$n40)..($ser.Count-1)] | Measure-Object -Maximum).Maximum
  $inst=$DASH[$c].inst; $fSum=($inst | ForEach-Object {$_.f} | Measure-Object -Sum).Sum; $fLast2 = if($inst.Count -ge 2){ @($inst[-2].f,$inst[-1].f) } else { @() }
  $mg = if($DASH[$c].margin.Count){ $DASH[$c].margin[$DASH[$c].margin.Count-1] } else { $null }
  $marginDelta = if($mg){ $mg.fin-$mg.finPrev } else { $null }
  return [pscustomobject]@{
    code=$c; name=$nm
    price=$last.c; chg=$last.chg; pct=[math]::Round($last.chg/($last.c-$last.chg)*100,2)
    ma20=$(if($ma20){[math]::Round($ma20,2)}else{$null}); ma60=$(if($ma60){[math]::Round($ma60,2)}else{$null})
    ma20SlopeUp=$(if($ma20 -and $ma20p){$ma20 -gt $ma20p}else{$null})
    distFromHigh40=[math]::Round(($last.c/$hi40-1)*100,1)
    foreignSum5d=$fSum; foreignLast2=$fLast2
    marginToday=$(if($mg){$mg.fin}else{$null}); marginDelta=$marginDelta
    divNote=$(if($divMap.ContainsKey($c)){$divMap[$c]}else{$null})
  }
}

$context=@()
foreach($h in $hj.holdings){
  $c="$($h.code)"
  $HOLDINGS_META[$c]=[ordered]@{ name=$h.name; type=$h.type; theme=$h.theme; shares=(SharesOf $h); color=$h.color; techLike=$(if($h.PSObject.Properties['techLike']){[bool]$h.techLike}else{$false}); divNote=$(if($divMap.ContainsKey($c)){$divMap[$c]}else{$null}) }
  $cx=CodeContext $c $h.name
  if($cx){ $context += $cx }
}
$context | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root 'holdings-context.json') -Encoding UTF8
Write-Host "  wrote holdings-context.json ($($context.Count) holdings)"

# Same numbers for EVERY code in the fetch union - the input to the Gemini step that writes the
# analysis guests see for codes the owner does not hold. Names come from the exchange table
# (data/names.json), never from what a user typed: user text must not reach any AI prompt.
$nameMap=@{}
$namesPath=Join-Path $DataDir 'names.json'
if(Test-Path $namesPath){
  $nj=ReadJsonRetry $namesPath
  if($nj){ foreach($pr in $nj.PSObject.Properties){ $nameMap[$pr.Name]="$($pr.Value)" } }
}
$allContext=@()
foreach($c in $codes){
  $cx=CodeContext $c $(if($nameMap.ContainsKey($c)){ $nameMap[$c] } else { $c })
  if($cx){ $allContext += $cx }
}
$allContext | ConvertTo-Json -Depth 5 | Out-File (Join-Path $DataDir 'codes-context.json') -Encoding UTF8
Write-Host "  wrote data/codes-context.json ($($allContext.Count) codes, union of all users)"

Write-Host "[5b/6] stance-log.json (rule-engine stance per holding; mirrors page adviseHolding, for evaluate.ps1 validation)..."
$stancePath=Join-Path $root 'stance-log.json'
$slog=@(); $slogOk=$true
if(Test-Path $stancePath){
  $sj=ReadJsonRetry $stancePath
  if($null -eq $sj){ $slogOk=$false; Write-Host "  WARN: stance-log.json unreadable after retries - skipping today's append (history never overwritten)" }
  else{ $slog=@($sj.rows) }
}
# previous-trade-day stance per code (from history BEFORE today's append): the page compares
# it against today's rule-engine stance and flags transitions - the transition day is the
# actionable signal, not the standing level. Union codes so server mode can serve guests too.
$prevStanceMap=@{}
if($slogOk){
  foreach($r in $slog){
    $rc="$($r.code)"; $rd="$($r.date)"
    if($rd -lt $lastDate -and ($null -ne $r.stance)){
      if(-not $prevStanceMap.ContainsKey($rc) -or $rd -gt $prevStanceMap[$rc].d){ $prevStanceMap[$rc]=@{ d=$rd; s="$($r.stance)" } }
    }
  }
}
foreach($c in @($HOLDINGS_META.Keys)){
  if($c -like '_*'){ continue }
  $HOLDINGS_META[$c]['prevStance']=$(if($prevStanceMap.ContainsKey($c)){ $prevStanceMap[$c].s } else { $null })
}
$psAll=[ordered]@{}
foreach($c in $codes){ if($prevStanceMap.ContainsKey($c)){ $psAll[$c]=$prevStanceMap[$c].s } }
$HOLDINGS_META['_prevStance']=$psAll   # union-code map for server mode (page ignores _ keys)
# Grade every code, every run. The log append is still once-per-day, but the page needs the
# grade whether or not today was already logged - it renders this instead of recomputing the
# formula in JavaScript, which is how the log and the page came to disagree about 'trim'.
$grades=[ordered]@{}
foreach($c in $codes){
  $g = Get-StanceGrade $DASH[$c].series $DASH[$c].inst $DASH[$c].margin
  if($null -ne $g){ $grades[$c]=$g }
}
foreach($c in @($HOLDINGS_META.Keys)){
  if($c -like '_*'){ continue }
  $HOLDINGS_META[$c]['stance']=$(if($grades.Contains($c)){ $grades[$c] } else { $null })
}
Write-Host "  graded $($grades.Count)/$($codes.Count) codes"

$already=@($slog | Where-Object { $_.date -eq $lastDate }).Count -gt 0
if($slogOk -and -not $already){
  foreach($c in $codes){
    if(-not $grades.Contains($c)){ continue }
    $g=$grades[$c]; $s=@($DASH[$c].series)
    $slog += ,@{ date=$lastDate; code=$c; close=$s[$s.Count-1].c; score=$g.score; stance=$g.level }
  }
  @{ rows=$slog } | ConvertTo-Json -Depth 4 | Out-File $stancePath -Encoding UTF8
  Write-Host "  stance-log: appended rows for $lastDate (total $($slog.Count))"
} elseif($already){ Write-Host "  stance-log: $lastDate already logged" }

Write-Host "[6/6] splice window.DASH / window.META / window.HOLDINGS_META into index.html..."
$idxPath=Join-Path $root 'index.html'
# the page only ever renders HOLDINGS_META's codes - splicing other users' quotes would just
# bloat index.html, so the static page gets this portfolio's slice and data/quotes.json gets all
$DASHPage=[ordered]@{}
foreach($k in $DASH.Keys){ if($k -eq 'TAIEX' -or $ownCodes -contains $k){ $DASHPage[$k]=$DASH[$k] } }
$genDate = $today.ToString('yyyy/MM/dd')
$lastTradeIso = "$($lastDate.Substring(0,4))-$($lastDate.Substring(4,2))-$($lastDate.Substring(6,2))"
# META used to be written by regex over the page's JS source (and a second regex over the
# 報告日期 markup). It is a data block like every other one now; the page renders both strings
# from it, so re-indenting that line can no longer silently freeze the report date.
Set-PageBlocks -IndexPath $idxPath -Blocks @{
  dashdata     = $DASHPage
  holdingsmeta = $HOLDINGS_META
  meta         = ([ordered]@{ generated=$genDate; lastTrade=$lastTradeIso })
}

# server-mode exports: same payloads the page gets, as plain JSON for server.py to serve
# per user. Written last so a failure here can never leave index.html half-spliced.
Write-Host "[6b] data exports for server mode..."
$DASH | ConvertTo-Json -Depth 6 -Compress | Out-File (Join-Path $DataDir 'quotes.json') -Encoding UTF8
$HOLDINGS_META | ConvertTo-Json -Depth 4 -Compress | Out-File (Join-Path $DataDir 'holdings-meta.json') -Encoding UTF8
([ordered]@{ generated=$genDate; lastTrade=$lastTradeIso }) | ConvertTo-Json -Compress | Out-File (Join-Path $DataDir 'meta.json') -Encoding UTF8
Write-Host "  wrote quotes.json ($($DASH.Keys.Count) keys), holdings-meta.json, meta.json -> $DataDir"

Write-Host "DONE. lastTrade=$lastDate holdings=$($codes.Count) divNotes=$($divMap.Count)"