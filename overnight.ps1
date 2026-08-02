# overnight.ps1 - the overnight drivers of TOMORROW's Taiwan open, as numbers.
#
# The daily schedule fires at 20:00 Taipei, ~90 minutes before the US opens. Everything else the
# pipeline produces describes the session that just closed; by definition the last US close is
# already inside those prices. What is not yet priced in is what actually sets tomorrow's open:
# index futures trading right now, the TSMC ADR, and earnings released after last night's US
# close. Until this script existed the analysis step had no numbers for any of it and had to
# infer them from news searches - which is how the 2026-07-30 run wrote "費半因FOMC升息疑慮持續
# 破底 / moodK: bear" while Microsoft's results had been public since 04:05 that morning. The
# next session was +7.97%, the largest single-day point gain in the index's history.
#
# Best-effort by design, like server/gnotes.py: the source is third-party (see the header of the
# overnight block in lib/feed.ps1) and no part of the daily run may block on it. Run it LAST in
# the fetch phase - nq/tsm/twd are live quotes, so the closer to the analysis step, the better.
#
# Run:  pwsh -File overnight.ps1
#
# -DefineOnly defines the date/percentage helpers and stops, so tests.ps1 can dot-source and
# exercise them without fetching. The week-to-date baseline in particular is the kind of rule
# that fails by producing a plausible wrong number rather than an error.
param([switch]$DefineOnly)
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/feed.ps1')
$outPath = Join-Path $root 'overnight-context.json'
$dataDir = Join-Path $root 'data'

# 1 ADR = 5 TWSE common shares. Fixed by the depositary agreement, not a market quantity.
$AdrRatio = 5

function Pct($now,$then){
  if($null -eq $now -or $null -eq $then -or $then -eq 0){ return $null }
  return [math]::Round(($now/$then-1)*100,2)
}
function LastBarBefore($bars,[string]$IsoDate){
  $prior=@($bars | Where-Object { $_.d -lt $IsoDate })
  if($prior.Count -eq 0){ return $null }
  return $prior[$prior.Count-1]
}
# Monday of the ISO week a given date falls in. The `sox` field on the page is a WEEK-to-date
# figure, so the baseline is the last close BEFORE this Monday, not five sessions back.
function WeekStart([string]$IsoDate){
  $d=[datetime]::ParseExact($IsoDate,'yyyy-MM-dd',$null)
  $off=(([int]$d.DayOfWeek)+6)%7          # Sunday=0 in .NET; ISO weeks start Monday
  return $d.AddDays(-$off).ToString('yyyy-MM-dd')
}

if($DefineOnly){ return }

# "Now" in New York, because every US trading date below is an ET calendar date. At 20:00 Taipei
# this is 08:00 the same morning ET, i.e. before the open - which is precisely the window that
# makes futures worth reading.
$nowUtc=(Get-Date).ToUniversalTime()
try{ $etNow=[System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($nowUtc,'America/New_York') }
catch{ $etNow=$nowUtc.AddHours(-4) }      # tzdata missing: EDT is close enough to date-bucket
$todayEt=$etNow.ToString('yyyy-MM-dd')

Write-Host "overnight: fetching $($FeedUsSymbols.Count) symbol(s), ET date $todayEt"
$q=@{}
foreach($k in $FeedUsSymbols.Keys){
  $r=Get-FeedUsChart -Symbol $FeedUsSymbols[$k]
  if($r.Ok){
    $q[$k]=$r
    Write-Host "  $k ($($FeedUsSymbols[$k])): last=$($r.Last) bars=$($r.Bars.Count)"
  } else {
    Write-Host "  WARN: $k ($($FeedUsSymbols[$k])) unavailable - that section is omitted today"
  }
}

$out=[ordered]@{ asOf=(Get-Date).ToString('yyyy-MM-ddTHH:mmzzz') }

# --- SOX: the last COMPLETED US close, plus week-to-date. This is the number the page's `sox`
#     field has been carrying by hand; -10.1% was typed on 2026-07-30 against an actual -11.6%.
if($q.ContainsKey('sox')){
  $b=@($q['sox'].Bars)
  $last=$b[$b.Count-1]
  $prev=LastBarBefore $b $last.d
  $wkBase=LastBarBefore $b (WeekStart $last.d)
  $out['sox']=[ordered]@{
    close=[math]::Round($last.c,2); asOf=$last.d
    chgPct=(Pct $last.c $(if($prev){$prev.c}else{$null}))
    wtdPct=(Pct $last.c $(if($wkBase){$wkBase.c}else{$null}))
    wtdFrom=$(if($wkBase){$wkBase.d}else{$null})
  }
}

# --- Nasdaq future: the genuinely forward-looking one. Compared against the last daily bar that
#     closed BEFORE today ET, because the current session's bar is still forming.
if($q.ContainsKey('nq')){
  $r=$q['nq']
  $ref=LastBarBefore $r.Bars $todayEt
  $ageMin=$null
  if($r.QuoteAt){ $ageMin=[math]::Round(($nowUtc-$r.QuoteAt).TotalMinutes,0) }
  $out['nq']=[ordered]@{
    last=[math]::Round($r.Last,2)
    refClose=$(if($ref){[math]::Round($ref.c,2)}else{$null})
    refAsOf=$(if($ref){$ref.d}else{$null})
    chgPct=(Pct $r.Last $(if($ref){$ref.c}else{$null}))
    quoteAgeMin=$ageMin
    live=$(if($null -ne $ageMin){ $ageMin -le 60 }else{ $false })
  }
}

# --- TSMC ADR against 2330's Taipei close: how the US repriced the index's largest weight after
#     Taiwan shut. Needs the FX rate and 2330, so it is all-or-nothing - a partial premium would
#     be a wrong number rather than a missing one.
if($q.ContainsKey('tsm') -and $q.ContainsKey('twd')){
  $twClose=$null
  try{
    $hw=Get-Content (Join-Path $dataDir 'heavyweights-context.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $row=@($hw | Where-Object { "$($_.code)" -eq '2330' })[0]
    if($row){ $twClose=[double]$row.price }
  }catch{}
  $implied=[math]::Round($q['tsm'].Last*$q['twd'].Last/$AdrRatio,2)
  $adr=[ordered]@{
    tsm=[math]::Round($q['tsm'].Last,2); usdTwd=[math]::Round($q['twd'].Last,4)
    impliedTwd=$implied; twClose=$twClose
    premiumPct=(Pct $implied $twClose)
  }
  if($null -eq $twClose){
    Write-Host "  WARN: 2330 not in data/heavyweights-context.json - ADR premium omitted"
  }
  $out['adr']=$adr
}

$sections=@($out.Keys | Where-Object { $_ -ne 'asOf' })
if($sections.Count -eq 0){
  # Nothing usable. Remove any previous file rather than leave it: unlike a log, this is a
  # snapshot with no history worth protecting, and yesterday's futures quote read as tonight's
  # is worse than no quote at all. The analysis step treats a missing file as "skip the section".
  if(Test-Path $outPath){ Remove-Item $outPath -Force -ErrorAction SilentlyContinue }
  Write-Host "overnight: every symbol failed - no file written (daily run continues)"
  exit 0
}

$out['note']='nq/tsm/twd 為抓取當下的即時報價（非收盤）；sox 為最近一個已完成的美股收盤。使用前先確認 asOf 是今天。'
try{
  $out | ConvertTo-Json -Depth 4 | Out-File $outPath -Encoding UTF8 -ErrorAction Stop
  Write-Host "overnight: wrote overnight-context.json ($($sections -join ', '))"
}catch{
  Write-Host "  WARN: could not write overnight-context.json ($($_.Exception.Message))"
}
exit 0
