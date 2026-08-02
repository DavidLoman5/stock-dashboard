# lib/feed.ps1 - official market data: one fetch, one cache, one place that knows the columns.
#
# Dot-source it:  . (Join-Path $root 'lib/feed.ps1')
#
# What this replaces:
#   * three copies of GetJson (screen.ps1, update-holdings.ps1, backtest.ps1) whose timeouts had
#     already drifted apart - 45s, 45s, 60s;
#   * two copies of "fetch a code's monthly OHLCV, cache completed months, route TWSE vs TPEx",
#     one of which cached the OTC fallback and one of which did not;
#   * TWSE column indices copied between scripts by hand. update-holdings.ps1 said so out loud:
#     "f=col4, t=col13, tot=col23 (indexes proven in screen.ps1)". When the exchange moves a
#     column, one edit here is the whole fix.
#
# The transport is a seam. In production Get-FeedJson does the HTTP; Set-FeedTransport swaps in
# a fixture so tests can exercise the *live-fetch* path offline. Before this existed the suite
# could only stub GetJson to throw, which meant the parsing and routing code that actually reads
# the exchange's response had never once been executed by a test.

$script:FeedTransport = $null
$FeedTimeoutSec = 45
$FeedRetries = 3
$FeedPolitePauseMs = 700

# Column indices for the official endpoints, named once. Values are 0-based positions in the
# `data` rows each endpoint returns.
$FeedCols = @{
  # TWSE STOCK_DAY / TPEx tradingStock: date, volume, value, open, high, low, close, change
  DailyBar = @{ date=0; volume=1; open=3; high=4; low=5; close=6; change=7 }
  # TWSE FMTQIK (index history): date, volume, value, index, change
  Index    = @{ date=0; value=2; close=4; change=5 }
  # TWSE T86 institutional net. Values are SHARES here - divide by 1000 for lots.
  T86      = @{ code=0; foreign=4; trust=10; dealer=11; total=18 }
  # TPEx insti/dailyTrade is the OTC equivalent and does NOT share T86's layout: trust and
  # total sit at 13 and 23, not 10 and 18. Keeping them as one entry was exactly the mistake
  # hand-copying these indices invites.
  TpexInsti = @{ code=0; foreign=4; trust=13; total=23 }
  # TWSE MI_MARGN (margin balances, in lots)
  Margin     = @{ code=0; finPrev=5; fin=6; shortPrev=11; short=12 }
  # TPEx margin/balance: same idea, different layout - prev balance is col 2, not col 5, and the
  # short-sale columns are not verified, so callers get 0 rather than a guess.
  TpexMargin = @{ code=0; finPrev=2; fin=6 }
  # TWSE BFI82U (market-wide institutional amount). Last row is the total; col 3 is net.
  MarketInst = @{ net=3 }
  # TWSE MI_INDEX ALLBUT0999 (whole-market OHLCV for one day). col 9 is the +/- direction and
  # may arrive as an HTML fragment; col 10 is the UNSIGNED change against the (dividend-adjusted)
  # reference price - the same convention STOCK_DAY uses, which is what makes the dividend
  # add-back possible.
  MiIndex    = @{ code=0; volume=2; value=4; open=5; high=6; low=7; close=8; dir=9; change=10 }
}

# Object-shaped OpenAPI endpoints. Everything in $FeedCols above is a 0-based POSITION in an
# array row; these endpoints return JSON objects instead, so what is named here are FIELD NAMES.
# Deliberately a second table rather than more entries in $FeedCols - handing a caller a field
# name where it expects an index is precisely the class of bug $FeedCols exists to prevent.
#
# The two boards do NOT share a schema, the same trap as T86 vs TpexInsti.
#
# Read the share count from 已發行普通股數 / IssueShares, NEVER from 實收資本額 / 面額. 21 listed
# companies have a par value other than NT$10 - 2327 國巨 is 2.5, where the division understates
# the count fourfold and drops a genuine top-20 name off the list entirely.
$FeedFields = @{
  CompanyTwse = @{ code='公司代號'; name='公司簡稱'; shares='已發行普通股數或TDR原股發行股數' }
  CompanyTpex = @{ code='SecuritiesCompanyCode'; name='CompanyAbbreviation'; shares='IssueShares' }
}

# Swap the transport. $Transport is a scriptblock taking a url and returning parsed JSON
# (or $null for "no data"). Passing $null restores live HTTP.
function Set-FeedTransport([scriptblock]$Transport){ $script:FeedTransport = $Transport }
function Test-FeedIsLive { return ($null -eq $script:FeedTransport) }

# Official APIs must be read with Invoke-WebRequest + manual UTF-8 decode; Invoke-RestMethod
# mangles the Chinese names. Retries then gives up with $null - callers decide how to fail.
function Get-FeedJson([string]$Url){
  if($null -ne $script:FeedTransport){ return (& $script:FeedTransport $Url) }
  for($i=0;$i -lt $FeedRetries;$i++){
    try{
      $resp=Invoke-WebRequest -Uri $Url -TimeoutSec $FeedTimeoutSec -UseBasicParsing
      $txt=[System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
      return ($txt | ConvertFrom-Json)
    }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}

# Pause between calls so a whole-market sweep does not hammer the exchange. Skipped when a
# fixture transport is installed, or a 200-code test run would sit here for two minutes.
function Wait-FeedPolite { if(Test-FeedIsLive){ Start-Sleep -Milliseconds $FeedPolitePauseMs } }

# ------------------------------------------------------------------ the month cache
# Completed months never change, so they live on disk under kline-cache/ (gitignored).
#
# The directory has TWO tenants: screen.ps1's rows carry a `dt` field and update-holdings.ps1's
# do not, so the latter prefixes its files 'h-' to keep the schemas apart. Creation and eviction
# used to belong to the callers, which made the arrangement quietly wrong: screen.ps1 pruned
# with a regex that matched BOTH prefixes, so it evicted update-holdings' files too - and if
# screen.ps1 FATAL'd early (it has two such guards before the prune) nothing was evicted at all.
# One owner, called by both, so the shared tenancy is deliberate rather than accidental.
$FeedCacheRetainMonths = 5

function Get-FeedCacheDir {
  param([string]$Root, [string]$Name='kline-cache')
  $dir = Join-Path $Root $Name
  if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null }
  return $dir
}

function Invoke-FeedCachePrune {
  <#  Drop month files older than the window any caller reads. Deliberately prunes every tenant:
      both use the same 4-month window, and whichever script runs today keeps the directory
      bounded for the other. Returns how many files were removed. #>
  param([string]$CacheDir, [int]$RetainMonths=$FeedCacheRetainMonths)
  if(-not (Test-Path $CacheDir)){ return 0 }
  $cut=(Get-Date).AddMonths(-$RetainMonths).ToString('yyyyMM')
  $n=0
  try{
    foreach($f in (Get-ChildItem $CacheDir -Filter '*.json' -File)){
      if($f.Name -match '-(\d{6})\.json$' -and $Matches[1] -lt $cut){
        Remove-Item $f.FullName -Force -ErrorAction Stop; $n++
      }
    }
  }catch{ Write-Host "  WARN: cache prune stopped early ($($_.Exception.Message))" }
  return $n
}

function ConvertTo-FeedNum($s){
  if($null -eq $s){ return $null }
  $t=("$s" -replace '[^0-9\.\-]','')
  if($t -notmatch '[0-9]'){ return $null }
  try{ return [double]$t }catch{ return $null }
}

# ------------------------------------------------------------------ dates
# Exchange dates are ROC (民國): year =西元 - 1911. Both forms appear - "115/06/01" from the
# rwd JSON endpoints and "1150601" from the OpenAPI ones. There were five hand-written copies of
# this conversion across the scripts, two of which used "{0}{1}{2}" and so depended on the API
# zero-padding the month; the other two padded defensively. One conversion, padded, here.
function ConvertFrom-FeedRocDate([string]$Roc){
  $t="$Roc".Trim()
  if(-not $t){ return $null }
  if($t -match '^(\d{2,3})/(\d{1,2})/(\d{1,2})$'){
    return ("{0}{1:00}{2:00}" -f ([int]$Matches[1]+1911),[int]$Matches[2],[int]$Matches[3])
  }
  if($t -match '^(\d{3})(\d{2})(\d{2})$'){
    return ("{0}{1}{2}" -f ([int]$Matches[1]+1911),$Matches[2],$Matches[3])
  }
  return $null
}

# yyyymmdd -> yyyy/MM/dd, the form the TPEx endpoints want in their query string.
function ConvertTo-FeedSlashDate([string]$Ymd){
  $t="$Ymd".Trim()
  if($t -notmatch '^\d{8}$'){ return $null }
  return ("{0}/{1}/{2}" -f $t.Substring(0,4),$t.Substring(4,2),$t.Substring(6,2))
}

# yyyymmdd -> M/D, the short label the page shows on chart axes.
function ConvertTo-FeedShortDate([string]$Ymd){
  $t="$Ymd".Trim()
  if($t -notmatch '^\d{8}$'){ return $null }
  return ("{0}/{1}" -f [int]$t.Substring(4,2),[int]$t.Substring(6,2))
}

# ------------------------------------------------------------------ whole-market endpoints
# Each of these used to be parsed inline in screen.ps1 / update-holdings.ps1 / backtest.ps1 with
# the column numbers written out by hand - which is why $FeedCols had no production callers at
# all and the module's "one edit here is the whole fix" promise was not true. Routing them
# through here also puts them behind Set-FeedTransport, so their parsing is testable offline.

function Get-FeedIndexHistory {
  <#  TAIEX daily history (FMTQIK) across several yyyymm01 months, oldest first.

      Returns @{ Rows=@([ordered]@{ dt; d; c; chg; amt }); MonthsOk=<int> }. `amt` is turnover in
      億 (1e8 NTD). Callers project what they need: screen.ps1 wants dt+c, update-holdings wants
      d/c/chg/amt. MonthsOk lets each keep its own "how degraded is too degraded" rule. #>
  param([string[]]$Months)
  $c=$FeedCols.Index
  $rows=@(); $ok=0
  foreach($mm in $Months){
    $r=Get-FeedJson "https://www.twse.com.tw/rwd/zh/afterTrading/FMTQIK?date=$mm&response=json"
    if($r -and $r.stat -eq 'OK'){
      $ok++
      foreach($d in $r.data){
        $dt=ConvertFrom-FeedRocDate $d[$c.date]
        if(-not $dt){ continue }
        $rows += ,[ordered]@{
          dt  = $dt
          d   = (ConvertTo-FeedShortDate $dt)
          c   = [double](ConvertTo-FeedNum $d[$c.close])
          chg = (ConvertTo-FeedNum $d[$c.change])
          amt = [math]::Round((ConvertTo-FeedNum $d[$c.value])/1e8,0)
        }
      }
    }
    Wait-FeedPolite
  }
  return @{ Rows=$rows; MonthsOk=$ok }
}

function Get-FeedInstitutional {
  <#  One day of institutional net buying, for a whole market.

      $Market 't' = TWSE T86, 'o' = TPEx dailyTrade EW. Returns
      @{ Ok=<bool>; Rows=@{ code -> @{ f; t; de; tot } } } in SHARES, the exchange's own unit -
      divide by 1000 for lots. TPEx publishes no dealer column, so `de` is derived as tot-f-t
      rather than guessed from an unverified position. #>
  param([string]$Date, [string]$Market='t')
  $out=@{}
  if($Market -eq 'o'){
    $c=$FeedCols.TpexInsti
    $ds=ConvertTo-FeedSlashDate $Date
    $r=Get-FeedJson "https://www.tpex.org.tw/www/zh-tw/insti/dailyTrade?type=Daily&sect=EW&date=$ds&response=json"
    if(-not ($r -and $r.tables -and $r.tables[0].data)){ return @{ Ok=$false; Rows=$out } }
    foreach($row in $r.tables[0].data){
      $code="$($row[$c.code])".Trim()
      if(-not $code){ continue }
      $f=[double](ConvertTo-FeedNum $row[$c.foreign])
      $t=[double](ConvertTo-FeedNum $row[$c.trust])
      $tot=[double](ConvertTo-FeedNum $row[$c.total])
      $out[$code]=@{ f=$f; t=$t; de=($tot-$f-$t); tot=$tot }
    }
    Wait-FeedPolite
    return @{ Ok=$true; Rows=$out }
  }
  $c=$FeedCols.T86
  $r=Get-FeedJson "https://www.twse.com.tw/rwd/zh/fund/T86?date=$Date&selectType=ALL&response=json"
  if(-not ($r -and $r.stat -eq 'OK')){ return @{ Ok=$false; Rows=$out } }
  foreach($row in $r.data){
    $code="$($row[$c.code])".Trim()
    if(-not $code){ continue }
    $out[$code]=@{
      f   = [double](ConvertTo-FeedNum $row[$c.foreign])
      t   = [double](ConvertTo-FeedNum $row[$c.trust])
      de  = [double](ConvertTo-FeedNum $row[$c.dealer])
      tot = [double](ConvertTo-FeedNum $row[$c.total])
    }
  }
  Wait-FeedPolite
  return @{ Ok=$true; Rows=$out }
}

function Select-FeedCodeTable {
  <#  Pick the code-level table out of a multi-table rwd response.

      screen.ps1 looked for "a table with more than 100 rows"; update-holdings.ps1 looked for
      "fields[0] is 代號". Two predicates for the same table in the same response. This tries the
      semantic one first and falls back to the size heuristic, so it is at least as robust as
      either was. #>
  param($Response, [int]$MinRows=100)
  if(-not ($Response -and $Response.tables)){ return $null }
  $byName = $Response.tables | Where-Object { $_.fields -and "$($_.fields[0])" -eq '代號' } | Select-Object -First 1
  if($byName -and $byName.data){ return $byName }
  return ($Response.tables | Where-Object { $_.data -and $_.data.Count -gt $MinRows } | Select-Object -First 1)
}

function Get-FeedMargin {
  <#  One day of margin balances, for a whole market.

      Returns @{ Ok=<bool>; Rows=@{ code -> @{ fin; finPrev; shrt; shrtPrev } } }, in lots.
      TPEx's short-sale columns are not verified, so they come back 0 - the stance engine and
      adviseHolding only read fin/finPrev. #>
  param([string]$Date, [string]$Market='t')
  $out=@{}
  if($Market -eq 'o'){
    $c=$FeedCols.TpexMargin
    $ds=ConvertTo-FeedSlashDate $Date
    $r=Get-FeedJson "https://www.tpex.org.tw/www/zh-tw/margin/balance?date=$ds&response=json"
    $tbl=Select-FeedCodeTable $r
    if(-not $tbl){ return @{ Ok=$false; Rows=$out } }
    foreach($row in $tbl.data){
      $code="$($row[$c.code])".Trim()
      if(-not $code){ continue }
      $out[$code]=@{
        fin=(ConvertTo-FeedNum $row[$c.fin]); finPrev=(ConvertTo-FeedNum $row[$c.finPrev])
        shrt=0; shrtPrev=0
      }
    }
    Wait-FeedPolite
    return @{ Ok=$true; Rows=$out }
  }
  $c=$FeedCols.Margin
  $r=Get-FeedJson "https://www.twse.com.tw/rwd/zh/marginTrading/MI_MARGN?date=$Date&selectType=ALL&response=json"
  $tbl=Select-FeedCodeTable $r
  if(-not $tbl){ return @{ Ok=$false; Rows=$out } }
  foreach($row in $tbl.data){
    $code="$($row[$c.code])".Trim()
    if(-not $code){ continue }
    $out[$code]=@{
      fin=(ConvertTo-FeedNum $row[$c.fin]); finPrev=(ConvertTo-FeedNum $row[$c.finPrev])
      shrt=(ConvertTo-FeedNum $row[$c.short]); shrtPrev=(ConvertTo-FeedNum $row[$c.shortPrev])
    }
  }
  Wait-FeedPolite
  return @{ Ok=$true; Rows=$out }
}

function Get-FeedMarketInstAmount {
  <#  Market-wide institutional net amount for one day (BFI82U), in 億 NTD, or $null. #>
  param([string]$Date)
  $r=Get-FeedJson "https://www.twse.com.tw/rwd/zh/fund/BFI82U?dayDate=$Date&type=day&response=json"
  if(-not ($r -and $r.stat -eq 'OK' -and $r.data.Count -gt 0)){ return $null }
  $lastRow=$r.data[$r.data.Count-1]     # last row is the all-institutions total
  return [math]::Round([double](ConvertTo-FeedNum $lastRow[$FeedCols.MarketInst.net])/1e8,0)
}

function Get-FeedMarketQuotes {
  <#  Whole-market OHLCV for one past day (MI_INDEX ALLBUT0999), keyed by code. Used by the
      backtest to replay a day it has no per-code series for. Four-digit common stocks only. #>
  param([string]$Date)
  $c=$FeedCols.MiIndex
  $out=@{}
  $r=Get-FeedJson "https://www.twse.com.tw/rwd/zh/afterTrading/MI_INDEX?date=$Date&type=ALLBUT0999&response=json"
  $tbl=Select-FeedCodeTable $r -MinRows 500
  if(-not $tbl){ return @{ Ok=$false; Rows=$out } }
  foreach($row in $tbl.data){
    $code="$($row[$c.code])".Trim()
    if($code -notmatch '^[1-9][0-9]{3}$'){ continue }
    $cl=ConvertTo-FeedNum $row[$c.close]
    if($null -eq $cl){ continue }
    $chg=ConvertTo-FeedNum $row[$c.change]
    if($null -eq $chg){ $chg=0.0 }
    if("$($row[$c.dir])" -like '*-*'){ $chg=-$chg }
    $out[$code]=@{
      o=(ConvertTo-FeedNum $row[$c.open]); h=(ConvertTo-FeedNum $row[$c.high])
      l=(ConvertTo-FeedNum $row[$c.low]);  c=$cl
      v=(ConvertTo-FeedNum $row[$c.volume]); val=(ConvertTo-FeedNum $row[$c.value]); chg=$chg
    }
  }
  Wait-FeedPolite
  return @{ Ok=$true; Rows=$out }
}

function Get-FeedIssuedShares {
  <#  Issued COMMON shares per code, both boards, from the exchanges' company-basics OpenAPI.
      This is the only share count anywhere in the project - every other endpoint carries price
      and turnover but nothing you can turn into a market cap.

      Returns @{ Ok; Rows=@{ code -> @{ shares; name; market } } }. Ok is $false only when BOTH
      boards fail; one board down still returns what it got, because the ranking degrades
      gracefully but a hard failure would take out the day's whole constituent view.

      TWSE wins a code present on both, matching the $px precedence in screen.ps1:66.

      Preferred and private shares are separate fields upstream and are deliberately left out:
      we pair COMMON shares with the common-share close. 台泥's paid-in capital over a 10 NTD par
      gives 7,723,181,742, but 200,000,000 of those are preferred - the common count published
      here is 7,523,181,742, which is the one that matches the quoted price. #>
  $out=@{}
  $okAny=$false
  foreach($src in @(
    @{ url='https://openapi.twse.com.tw/v1/opendata/t187ap03_L'; f=$FeedFields.CompanyTwse; mkt='t' }
    @{ url='https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O'; f=$FeedFields.CompanyTpex; mkt='o' }
  )){
    $r=Get-FeedJson $src.url
    if(-not $r){ continue }
    $f=$src.f
    $n=0
    foreach($row in @($r)){
      $code="$($row.($f.code))".Trim()
      if(-not $code){ continue }
      if($out.ContainsKey($code)){ continue }          # TWSE listed first, so it wins
      $sh=ConvertTo-FeedNum $row.($f.shares)
      if($null -eq $sh -or $sh -le 0){ continue }      # no share count = cannot be ranked
      $out[$code]=@{ name="$($row.($f.name))".Trim(); shares=$sh; market=$src.mkt }
      $n++
    }
    if($n -gt 0){ $okAny=$true }
    Wait-FeedPolite
  }
  return @{ Ok=$okAny; Rows=$out }
}

function Select-FeedTopByMarketCap {
  <#  The N largest codes by market cap (shares x close), biggest first. Pure - no fetching, so
      the ranking is testable without a network.

      $Profile  code -> @{shares}, from Get-FeedListedProfile
      $Quotes   code -> @{c}, any whole-market quote map (screen.ps1's $px will do)

      Deliberately does NOT take an exclude list. The one caller runs inside screen.ps1, where
      the only holdings file in reach is the DEMO portfolio in server mode (screen.ps1:276) -
      subtracting that would silently rank against the wrong set. Whoever knows the real
      positions does the dedupe; this stays "the biggest N companies", full stop.

      A code missing from either map, or lacking a usable price or share count, drops out of the
      ranking instead of sorting as zero.

      Two whole classes of listing are thrown out, because shares x close does not mean for them
      what it means everywhere else:
        * 創新板 (names ending -創): qualified-investors-only with a thin float. Measured
          2026-07-31, 6949 沛爾生醫-創 computes to 10,362億 - rank 16 in a list whose whole job is
          to describe what a market-cap ETF holds. This exclusion is load-bearing today.
        * TDR (91xx, names ending -DR): the published share count is the FOREIGN PARENT's entire
          issue while the price is the NTD depositary receipt, so the product is not a market cap
          at all. Defensive rather than load-bearing - 9105 泰金寶-DR measured 777億 on the same
          day, nowhere near the cut - but the quantity is meaningless whatever its size.
      Board membership is not published by either basics endpoint, so -創 can only be spotted by
      the name suffix. If the exchange ever drops that convention the filter fails silently, and
      the symptom is a company nobody recognises appearing mid-list. #>
  param([hashtable]$Profile,[hashtable]$Quotes,[int]$Top=30)
  if(-not $Profile -or -not $Quotes){ return @() }
  $ranked=@()
  foreach($code in $Profile.Keys){
    if($code -notmatch '^[1-9][0-9]{3}$'){ continue }
    if($code -match '^91'){ continue }                                   # TDR
    if(-not $Quotes.ContainsKey($code)){ continue }
    $nm="$($Profile[$code].name)"
    if($nm -match '(-DR|-創)$'){ continue }
    $px=$Quotes[$code].c
    $sh=$Profile[$code].shares
    if($null -eq $px -or $px -le 0 -or $null -eq $sh -or $sh -le 0){ continue }
    $ranked += [pscustomobject]@{ code=$code; cap=([double]$sh * [double]$px) }
  }
  return @($ranked | Sort-Object -Property @{e='cap';Descending=$true}, @{e='code'} |
             Select-Object -First $Top | ForEach-Object { $_.code })
}

# One code, one month, one market. Returns bar rows oldest-first; an empty array means the code
# does not trade on that market (which is how the OTC fallback is detected).
#   $Month   yyyymm01
#   $Market  't' = TWSE, 'o' = TPEx
#   -WithDt  also emit dt=yyyymmdd. screen.ps1 needs it for date maths; update-holdings.ps1
#            does not, and the two caches are kept apart by prefix because of it.
# Volume is normalised to lots in both branches: TWSE reports shares (hence /1000), TPEx
# already reports lots.
function Get-FeedMonthBars([string]$Code,[string]$Month,[string]$Market,[switch]$WithDt){
  $c=$FeedCols.DailyBar
  $rows=@()
  if($Market -eq 'o'){
    $ds="{0}/{1}/01" -f $Month.Substring(0,4),$Month.Substring(4,2)
    $r=Get-FeedJson "https://www.tpex.org.tw/www/zh-tw/afterTrading/tradingStock?code=$Code&date=$ds&response=json"
    if($r -and $r.tables -and $r.tables[0].data){
      foreach($d in $r.tables[0].data){
        $cv=ConvertTo-FeedNum $d[$c.close]
        if($null -eq $cv){ continue }   # no-trade day ("--"): skip, never let close become 0
        $dp="$($d[$c.date])".Split('/')
        $row=[ordered]@{ d=("{0}/{1}" -f [int]$dp[1],[int]$dp[2]) }
        if($WithDt){ $row['dt']=("{0}{1:00}{2:00}" -f ([int]$dp[0]+1911),[int]$dp[1],[int]$dp[2]) }
        $row['o']=(ConvertTo-FeedNum $d[$c.open]); $row['h']=(ConvertTo-FeedNum $d[$c.high])
        $row['l']=(ConvertTo-FeedNum $d[$c.low]);  $row['c']=[double]$cv
        $row['chg']=(ConvertTo-FeedNum $d[$c.change])
        $row['v']=[math]::Round([double](ConvertTo-FeedNum $d[$c.volume]),0)
        $rows += ,$row
      }
    }
  } else {
    $r=Get-FeedJson "https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?date=$Month&stockNo=$Code&response=json"
    if($r -and $r.stat -eq 'OK'){
      foreach($d in $r.data){
        $cv=ConvertTo-FeedNum $d[$c.close]
        if($null -eq $cv){ continue }
        $dp="$($d[$c.date])".Split('/')
        $row=[ordered]@{ d=("{0}/{1}" -f [int]$dp[1],[int]$dp[2]) }
        if($WithDt){ $row['dt']=("{0}{1:00}{2:00}" -f ([int]$dp[0]+1911),[int]$dp[1],[int]$dp[2]) }
        $row['o']=(ConvertTo-FeedNum $d[$c.open]); $row['h']=(ConvertTo-FeedNum $d[$c.high])
        $row['l']=(ConvertTo-FeedNum $d[$c.low]);  $row['c']=[double]$cv
        $row['chg']=(ConvertTo-FeedNum $d[$c.change])
        $row['v']=[math]::Round([double](ConvertTo-FeedNum $d[$c.volume])/1000,0)
        $rows += ,$row
      }
    }
  }
  return ,$rows
}

# Several months of bars for one code, with the completed-month disk cache.
#   $Market  't' | 'o' | 'auto'. 'auto' tries TWSE across every month and falls back to TPEx
#            only if that produced nothing at all - update-holdings.ps1's behaviour, which is
#            how an OTC holding is discovered without a whole-market table to look it up in.
# Returns a hashtable: Rows (the series) and Market (the market it actually came from), because
# callers need to remember the routing decision.
function Get-FeedDailySeries {
  param(
    [Parameter(Mandatory=$true)][string]$Code,
    [Parameter(Mandatory=$true)][string[]]$Months,
    [string]$Market='t',
    [string]$CacheDir,
    [string]$CachePrefix='',
    [switch]$WithDt
  )
  $curYM=(Get-Date).ToString('yyyyMM')
  $fetch = {
    param($mkt)
    $out=@()
    foreach($mm in $Months){
      $ym=$mm.Substring(0,6)
      $cf = if($CacheDir){ Join-Path $CacheDir ("{0}{1}-{2}.json" -f $CachePrefix,$Code,$ym) } else { $null }
      # completed months never change; the current month is always refetched
      if($cf -and $ym -lt $curYM -and (Test-Path $cf)){
        try{
          $hit=@()
          # assign first, then enumerate via @(): works whether ConvertFrom-Json enumerates the
          # array (pwsh 7) or emits it as ONE Object[] pipeline item (Windows PS5.1)
          $cached=Get-Content $cf -Raw -Encoding UTF8 | ConvertFrom-Json
          foreach($row in @($cached)){
            if($null -eq $row){ continue }
            $o=[ordered]@{}; foreach($pr in $row.PSObject.Properties){ $o[$pr.Name]=$pr.Value }
            $hit += ,$o
          }
          # a real month has >=5 trade days; less than that means a corrupt cache -> refetch
          if($hit.Count -ge 5){ $out += $hit; continue }
        }catch{}
      }
      $rowsM = Get-FeedMonthBars -Code $Code -Month $mm -Market $mkt -WithDt:$WithDt
      if($cf -and $ym -lt $curYM -and $rowsM.Count -gt 0){
        try{ ConvertTo-Json -InputObject $rowsM -Depth 3 -Compress | Out-File $cf -Encoding UTF8 }catch{}
      }
      $out += $rowsM
      Wait-FeedPolite
    }
    return ,$out
  }

  if($Market -eq 'auto'){
    $rows = & $fetch 't'
    if($rows.Count -gt 0){ return @{ Rows=$rows; Market='t' } }
    $rows = & $fetch 'o'
    return @{ Rows=$rows; Market=$(if($rows.Count){'o'}else{'t'}) }
  }
  $rows = & $fetch $Market
  return @{ Rows=$rows; Market=$Market }
}

# ------------------------------------------------- overnight drivers (third-party, NOT official)
# Everything above this line comes from TWSE/TPEx, the authoritative record for every number this
# project publishes. What follows does not. Yahoo's chart endpoint is undocumented, can change
# shape without notice, and answers 429 when it feels like it (a bare curl with no User-Agent
# gets one immediately; Invoke-WebRequest's default UA does not). Two rules follow:
#   * every caller must survive $null - nothing in the daily run may block on this
#   * these numbers are context for the analysis step. They never feed scoring, never feed the
#     rule engine, and are never presented as an official figure.
#
# Why the daily run wants them at all: the 20:00 schedule fires ~90 minutes before the US opens,
# so the most recent US *close* has already been priced into the Taiwan session that just ended.
# What has NOT been priced in is what moves tomorrow's open - index futures, the TSMC ADR, and
# earnings released after last night's US close. On 2026-07-30 that gap was the whole story:
# Microsoft's results were public from 04:05 Taipei that morning, the 20:00 run never saw them,
# and the next session was +7.97%. See plan.md 2026-08-02.
#
# It lives in this file rather than a script of its own so Set-FeedTransport covers it too - the
# parsing is then testable offline, which is the entire reason this file exists.

$FeedUsSymbols = [ordered]@{
  sox = '^SOX'    # Philadelphia Semiconductor: the index Taiwan's electronics weight tracks
  nq  = 'NQ=F'    # Nasdaq-100 front month. Trades ~23h/day, so this one IS live at 20:00 Taipei
  tsm = 'TSM'     # TSMC ADR. 1 ADR = 5 TWSE shares
  twd = 'TWD=X'   # USD/TWD, to put the ADR back into NT dollars
}

function Get-FeedUsChart {
  <#  One symbol's recent daily bars. Returns
        @{ Ok=$true; Symbol; Last; QuoteAt=[datetime] UTC; Bars=@(@{d='yyyy-MM-dd'; c=<close>}) }
      or @{ Ok=$false } for a failed fetch or any response that is not shaped as expected.

      Bars, not meta, are the source of truth for changes. `previousClose` is absent on indices
      and `chartPreviousClose` is the close before the whole range window, not the prior session
      - reading either as "yesterday" silently produces a wrong percentage. `Last` is the live
      quote (meta.regularMarketPrice), which for futures and FX at 20:00 Taipei is exactly the
      forward-looking number we came for.

      Bar timestamps are the session OPEN in UTC (13:30 for a US equity day), so the UTC date and
      the US trading date are the same calendar day. #>
  param([Parameter(Mandatory=$true)][string]$Symbol,[string]$Range='1mo')
  $url = 'https://query1.finance.yahoo.com/v8/finance/chart/{0}?range={1}&interval=1d' -f
           [uri]::EscapeDataString($Symbol),$Range
  $r = Get-FeedJson $url
  Wait-FeedPolite
  $res = $null
  try{ $res = @($r.chart.result)[0] }catch{}
  if(-not $res){ return @{ Ok=$false } }
  $ts = @($res.timestamp)
  $cl = @()
  try{ $cl = @(@($res.indicators.quote)[0].close) }catch{}
  if($ts.Count -eq 0 -or $ts.Count -ne $cl.Count){ return @{ Ok=$false } }
  $bars=@()
  for($i=0;$i -lt $ts.Count;$i++){
    if($null -eq $cl[$i]){ continue }          # holidays and half-formed bars arrive as null
    $bars += ,@{ d=([DateTimeOffset]::FromUnixTimeSeconds([long]$ts[$i])).UtcDateTime.ToString('yyyy-MM-dd')
                 c=[double]$cl[$i] }
  }
  if($bars.Count -eq 0){ return @{ Ok=$false } }
  $qa=$null
  try{ if($res.meta.regularMarketTime){ $qa=([DateTimeOffset]::FromUnixTimeSeconds([long]$res.meta.regularMarketTime)).UtcDateTime } }catch{}
  $last=$null
  try{ if($null -ne $res.meta.regularMarketPrice){ $last=[double]$res.meta.regularMarketPrice } }catch{}
  if($null -eq $last){ $last=$bars[$bars.Count-1].c }
  return @{ Ok=$true; Symbol="$($res.meta.symbol)"; Last=$last; QuoteAt=$qa; Bars=$bars }
}
