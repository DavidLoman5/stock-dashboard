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

function ConvertTo-FeedNum($s){
  if($null -eq $s){ return $null }
  $t=("$s" -replace '[^0-9\.\-]','')
  if($t -notmatch '[0-9]'){ return $null }
  try{ return [double]$t }catch{ return $null }
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
