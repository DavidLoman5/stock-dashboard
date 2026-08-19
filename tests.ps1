# tests.ps1 - offline regression suite (no network, runs in seconds)
# Run before committing engine/script changes:  pwsh -File tests.ps1
# Consolidates the smoke tests from the 2026-07-18 v9/v10/v11 health audits:
#  1. syntax-parse all scripts   2. UTF-8 BOM convention   3. DivSumSince dividend cap
#  4. GetDailySeries cache read path (also guards the legacy ConvertFrom-Json array-collapse shape)
#  5. CheckRevCols column-layout warning   6. history-wipe guards present
# UTF-8 with BOM (asserts CJK exit-reason strings byte for byte). Paths must stay
# cross-platform (no $env:TEMP - unset on Linux).
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/feed.ps1')
. (Join-Path $root 'lib/pagedata.ps1')
. (Join-Path $root 'lib/publish-gate.ps1')
. (Join-Path $root 'lib/stance.ps1')
$fails=@()
function Assert($ok,$name){ if($ok){ Write-Host "  PASS $name" } else { Write-Host "  FAIL $name"; $script:fails+=$name } }

Write-Host "[1] syntax parse..."
foreach($f in @('screen.ps1','update-holdings.ps1','evaluate.ps1','publish.ps1','backtest.ps1','build-demo.ps1','finish-daily-push.ps1','lib/pagedata.ps1','lib/publish-gate.ps1','lib/stance.ps1','lib/feed.ps1','lib/picks-log.ps1','lib/stance-log.ps1')){
  $tok=$null;$err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f),[ref]$tok,[ref]$err)
  Assert ($err.Count -eq 0) "syntax $f"
  if($err.Count){ $err | ForEach-Object { Write-Host "    $($_.Message) @ line $($_.Extent.StartLineNumber)" } }
}

Write-Host "[2] UTF-8 BOM convention (pwsh 7 does not need it; kept so CJK literals survive a PS5.1/Windows run)..."
# This used to be a hand-written list of nine filenames, which is the wrong shape twice over: a
# new script is unchecked until somebody remembers to add it, and the list had already gone
# stale - evaluate.ps1 carried 18 non-ASCII bytes with no BOM while its own header claimed
# "ASCII source only". The invariant is a property of the file, so compute it:
#   any .ps1 containing non-ASCII bytes MUST start with a UTF-8 BOM.
# It is shorter than the list, self-maintaining, and it catches the file the list missed.
$psFiles = @(Get-ChildItem -Path $root -Filter '*.ps1' -File) +
           @(Get-ChildItem -Path (Join-Path $root 'lib') -Filter '*.ps1' -File)
$bomChecked = 0
foreach($f in $psFiles){
  $b = [IO.File]::ReadAllBytes($f.FullName)
  $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
  $nonAscii = 0
  foreach($byte in $b){ if($byte -gt 127){ $nonAscii++ } }
  $rel = $f.FullName.Substring($root.Length).TrimStart([char]'/',[char]'\')
  if($nonAscii -gt 0){
    $bomChecked++
    Assert $hasBom "BOM required (non-ASCII bytes=$nonAscii): $rel"
  }
}
Assert ($psFiles.Count -ge 12) "BOM check actually enumerated the scripts (found $($psFiles.Count))"
Assert ($bomChecked -ge 4) "BOM check found files that need one (checked $bomChecked)"

Write-Host "[3] extract functions from screen.ps1..."
# Num/GetJson/GetDailySeries are one-line delegates to lib/feed.ps1 now and are tested
# there directly (section [5]); only the logic screen.ps1 still owns is extracted here.
$tok=$null;$err=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'screen.ps1'),[ref]$tok,[ref]$err)
$fns=$ast.FindAll({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($n in @('DivSumSince')){
  $fd=$fns | Where-Object { $_.Name -eq $n } | Select-Object -First 1
  Assert ($null -ne $fd) "function $n exists"
  if($fd){ Invoke-Expression $fd.Extent.Text }
}
# picks-log lifecycle moved to lib/picks-log.ps1, so it is dot-sourced like the other modules
# rather than lifted out of screen.ps1's source by name.
. (Join-Path $root 'lib/picks-log.ps1')
# network stub: cache-hit tests must never fetch; loud failure if the fallback path is taken
function GetJson($url){ throw "network disabled in tests (unexpected fetch: $url)" }

Write-Host "[4] DivSumSince dividend cap..."
$rows=@(
  @{ dt='20260701'; c=100.0; chg=0.5 },
  @{ dt='20260702'; c=98.0;  chg=1.0 },   # dv=3 normal dividend -> counted
  @{ dt='20260703'; c=50.0;  chg=2.0 }    # dv=50 = 51% of prev close (capital reduction) -> skipped
)
$s=DivSumSince $rows '20260630'
Assert ([math]::Abs($s-3.0) -lt 1e-9) "cap skips capital-reduction gap (got $s, want 3)"
$rows2=@(
  @{ dt='20260701'; c=100.0; chg=0.0 },
  @{ dt='20260702'; c=95.0;  chg=5.0 }    # dv=10 = exactly 10% boundary -> counted
)
$s2=DivSumSince $rows2 '20260630'
Assert ([math]::Abs($s2-10.0) -lt 1e-9) "10 percent boundary counted (got $s2, want 10)"
$s3=DivSumSince $rows '20260702'          # since-date filter: only day3 event, which is capped away
Assert ([math]::Abs($s3) -lt 1e-9) "sinceDt filter (got $s3, want 0)"

Write-Host "[5] feed module: cache, live-fetch parse, market routing..."
# The live-fetch branch had never been executed by a test: fetch, cache and parse were fused in
# one function body, so the only way to stay offline was to stub the fetcher into throwing and
# assert the cache path. Set-FeedTransport makes the fetch a seam, so the parsing that actually
# reads the exchange response is now covered too.
$tmp=Join-Path ([IO.Path]::GetTempPath()) ("feed-test-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

# a. cache hit must not fetch at all
Set-FeedTransport { param($u) throw "cache hit must never fetch (got $u)" }
$fixture=@()
for($i=1;$i -le 21;$i++){ $fixture += [ordered]@{ d="1/$i"; dt=("202501{0:00}" -f $i); o=10.0; h=11.0; l=9.0; c=(10.0+$i*0.1); chg=0.1; v=100 } }
ConvertTo-Json -InputObject $fixture -Depth 3 -Compress | Out-File (Join-Path $tmp '9999-202501.json') -Encoding UTF8
$r=Get-FeedDailySeries -Code '9999' -Months @('20250101') -Market 't' -CacheDir $tmp -WithDt
Assert ($r.Rows.Count -eq 21) "cache hit returns 21 rows (got $($r.Rows.Count))"
Assert ("$($r.Rows[0].dt)" -eq '20250101' -and $r.Rows[20].c -eq 12.1) "row fields intact (dt=$($r.Rows[0].dt) c=$($r.Rows[20].c))"

# b. a suspiciously short cache file is treated as corrupt and refetched
$one=@([ordered]@{ d='1/2'; dt='20250102'; o=1;h=1;l=1;c=1.0;chg=0;v=1 })
ConvertTo-Json -InputObject $one -Depth 3 -Compress | Out-File (Join-Path $tmp '9998-202501.json') -Encoding UTF8
$threw=$false
try{ $null=Get-FeedDailySeries -Code '9998' -Months @('20250101') -Market 't' -CacheDir $tmp }catch{ $threw=$true }
Assert $threw "suspicious cache (<5 rows) falls through to refetch"

# c. live TWSE parse: ROC dates -> yyyymmdd, share volume -> lots
Set-FeedTransport {
  param($u)
  if($u -match 'STOCK_DAY\?date=(\d{6})'){
    $ym=$Matches[1]; $data=@()
    for($i=1;$i -le 6;$i++){
      $data += ,@(("115/{0}/{1:00}" -f $ym.Substring(4,2),$i),"12345000","1","10.0","11.0","9.0",("{0}" -f (10.0+$i*0.1)),"0.10")
    }
    return [pscustomobject]@{ stat='OK'; data=$data }
  }
  return $null
}
$r=Get-FeedDailySeries -Code '2330' -Months @('20250601') -Market 't' -WithDt
Assert ($r.Rows.Count -eq 6) "live TWSE parse returns 6 bars (got $($r.Rows.Count))"
Assert ("$($r.Rows[0].dt)" -eq '20260601') "ROC 115/06/01 -> 20260601 (got $($r.Rows[0].dt))"
Assert ($r.Rows[0].v -eq 12345) "TWSE share volume normalised to lots (got $($r.Rows[0].v))"

# d. a no-trade day ('--' close) is skipped, never turned into a 0 close
Set-FeedTransport {
  param($u)
  return [pscustomobject]@{ stat='OK'; data=@(
    ,@('115/06/01','1000','1','10.0','11.0','9.0','--','0.0')
    ,@('115/06/02','2000','1','10.0','11.0','9.0','10.5','0.5')
  ) }
}
$r=Get-FeedDailySeries -Code '2330' -Months @('20250601') -Market 't'
Assert ($r.Rows.Count -eq 1 -and $r.Rows[0].c -eq 10.5) "no-trade day skipped, close never 0 (rows=$($r.Rows.Count))"

# e. 'auto' routing: TWSE empty -> TPEx, and TPEx volume is already lots
Set-FeedTransport {
  param($u)
  if($u -match 'tradingStock'){
    return [pscustomobject]@{ tables=@([pscustomobject]@{ data=@( ,@('115/06/01','900','1','5.0','5.5','4.5','5.2','0.1') ) }) }
  }
  return [pscustomobject]@{ stat='no data' }
}
$r=Get-FeedDailySeries -Code '6488' -Months @('20250601') -Market 'auto'
Assert ($r.Market -eq 'o' -and $r.Rows.Count -eq 1) "auto routing falls back to TPEx (market=$($r.Market))"
Assert ($r.Rows[0].v -eq 900) "TPEx volume already in lots, not divided (got $($r.Rows[0].v))"

# f. the two institutional endpoints do NOT share a column layout - conflating them is the
#    exact mistake hand-copied indices invite
Assert ($FeedCols.T86.trust -eq 10 -and $FeedCols.T86.total -eq 18) "T86 (TWSE) trust/total = 10/18"
Assert ($FeedCols.TpexInsti.trust -eq 13 -and $FeedCols.TpexInsti.total -eq 23) "TPEx insti trust/total = 13/23"

# g. ROC date conversion - one implementation, both shapes, month/day zero-padded. Two of the
#    five hand-written copies used "{0}{1}{2}" and so silently depended on the API padding.
Assert ((ConvertFrom-FeedRocDate '115/06/01') -eq '20260601') "ROC slash form -> 20260601"
Assert ((ConvertFrom-FeedRocDate '115/6/1') -eq '20260601') "ROC unpadded form still pads (got $(ConvertFrom-FeedRocDate '115/6/1'))"
Assert ((ConvertFrom-FeedRocDate '1150601') -eq '20260601') "ROC compact form -> 20260601"
Assert ($null -eq (ConvertFrom-FeedRocDate 'rubbish')) "ROC garbage -> null, not a bogus date"
Assert ((ConvertTo-FeedSlashDate '20260601') -eq '2026/06/01') "yyyymmdd -> TPEx slash form"
Assert ((ConvertTo-FeedShortDate '20260601') -eq '6/1') "yyyymmdd -> short label"

# h. the whole-market parsers. These had NEVER been executed by a test: every one of them was
#    inline in a caller with its column numbers written out by hand, so $FeedCols had no
#    production reader and nothing could reach the parsing offline.
Set-FeedTransport {
  param($u)
  if($u -match 'FMTQIK'){
    # real layout: 日期, 成交股數, 成交金額, 成交筆數, 加權指數, 漲跌點數
    return [pscustomobject]@{ stat='OK'; data=@(
      ,@('115/06/01','1000','520000000000','777','18000.5','120.25')
      ,@('115/06/02','1100','480000000000','888','18100.75','100.25')
    ) }
  }
  if($u -match 'fund/T86'){
    $row=@(0..18 | ForEach-Object { '0' }); $row[0]='2330'
    $row[4]='5000000'; $row[10]='2000000'; $row[11]='1000000'; $row[18]='8000000'
    return [pscustomobject]@{ stat='OK'; data=@(,$row) }
  }
  if($u -match 'insti/dailyTrade'){
    $row=@(0..23 | ForEach-Object { '0' }); $row[0]='6488'
    $row[4]='300000'; $row[13]='100000'; $row[23]='500000'
    return [pscustomobject]@{ tables=@([pscustomobject]@{ data=@(,$row) }) }
  }
  if($u -match 'MI_MARGN'){
    $row=@(0..12 | ForEach-Object { '0' }); $row[0]='2330'
    $row[5]='900'; $row[6]='1000'; $row[11]='40'; $row[12]='50'
    return [pscustomobject]@{ tables=@([pscustomobject]@{ fields=@('代號','x'); data=@(,$row) }) }
  }
  if($u -match 'margin/balance'){
    $row=@(0..6 | ForEach-Object { '0' }); $row[0]='6488'; $row[2]='700'; $row[6]='800'
    return [pscustomobject]@{ tables=@([pscustomobject]@{ fields=@('代號','x'); data=@(,$row) }) }
  }
  if($u -match 'BFI82U'){
    return [pscustomobject]@{ stat='OK'; data=@(
      ,@('自營商','1','2','1000000000')
      ,@('合計','1','2','12300000000')
    ) }
  }
  if($u -match 'MI_INDEX'){
    $row=@(0..10 | ForEach-Object { '0' }); $row[0]='2330'
    $row[2]='30000'; $row[4]='990000'; $row[5]='100.0'; $row[6]='105.0'; $row[7]='99.0'
    $row[8]='104.0'; $row[9]='<p style=color:green>-</p>'; $row[10]='2.5'
    # the all-securities table is picked by size (>500 rows) - pad with non-stock codes, which
    # also exercises the 4-digit filter
    $rows=@(,$row)
    for($i=0;$i -lt 520;$i++){
      $pad=@(0..10 | ForEach-Object { '0' }); $pad[0]="00$i"; $pad[8]='1.0'
      $rows += ,$pad
    }
    return [pscustomobject]@{ tables=@([pscustomobject]@{ data=$rows }) }
  }
  return $null
}
$ih=Get-FeedIndexHistory -Months @('20260601')
Assert ($ih.MonthsOk -eq 1 -and $ih.Rows.Count -eq 2) "index history: 2 bars from 1 month (got $($ih.Rows.Count))"
Assert ("$($ih.Rows[0].dt)" -eq '20260601' -and $ih.Rows[0].c -eq 18000.5) "index history: dt + close parsed"
Assert ($ih.Rows[0].amt -eq 5200) "index history: turnover normalised to 億 (got $($ih.Rows[0].amt))"
Assert ("$($ih.Rows[0].d)" -eq '6/1') "index history: short label"

$ti=Get-FeedInstitutional -Date '20260601' -Market 't'
Assert ($ti.Ok -and $ti.Rows['2330'].f -eq 5000000) "T86: foreign net in SHARES, not lots (got $($ti.Rows['2330'].f))"
Assert ($ti.Rows['2330'].t -eq 2000000 -and $ti.Rows['2330'].de -eq 1000000) "T86: trust from col 10, dealer from col 11"
Assert ($ti.Rows['2330'].tot -eq 8000000) "T86: total from col 18"

$oi=Get-FeedInstitutional -Date '20260601' -Market 'o'
Assert ($oi.Ok -and $oi.Rows['6488'].t -eq 100000) "TPEx insti: trust from col 13, NOT col 10 (got $($oi.Rows['6488'].t))"
Assert ($oi.Rows['6488'].tot -eq 500000) "TPEx insti: total from col 23"
Assert ($oi.Rows['6488'].de -eq 100000) "TPEx insti: dealer derived as tot-f-t (got $($oi.Rows['6488'].de))"

$mg=Get-FeedMargin -Date '20260601' -Market 't'
Assert ($mg.Ok -and $mg.Rows['2330'].fin -eq 1000 -and $mg.Rows['2330'].finPrev -eq 900) "MI_MARGN: fin/finPrev = col6/col5"
Assert ($mg.Rows['2330'].shrt -eq 50 -and $mg.Rows['2330'].shrtPrev -eq 40) "MI_MARGN: short cols 12/11"
$mo=Get-FeedMargin -Date '20260601' -Market 'o'
Assert ($mo.Rows['6488'].finPrev -eq 700) "TPEx margin: prev balance is col 2, not col 5 (got $($mo.Rows['6488'].finPrev))"
Assert ($mo.Rows['6488'].shrt -eq 0) "TPEx margin: unverified short columns report 0, never a guess"

Assert ((Get-FeedMarketInstAmount -Date '20260601') -eq 123) "BFI82U: last row is the total, normalised to 億"

$q=Get-FeedMarketQuotes -Date '20260601'
Assert ($q.Ok -and $q.Rows['2330'].c -eq 104.0) "MI_INDEX: close from col 8"
Assert ($q.Rows.Count -eq 1) "MI_INDEX: only 4-digit common stocks kept (got $($q.Rows.Count))"
Assert ($q.Rows['2330'].chg -eq -2.5) "MI_INDEX: col 9 direction makes col 10 signed (got $($q.Rows['2330'].chg))"

# a response that is missing / has no usable table must report Ok=false, not throw
Set-FeedTransport { param($u) return $null }
Assert (-not (Get-FeedInstitutional -Date '20260601' -Market 't').Ok) "a dead T86 response reports Ok=false"
Assert (-not (Get-FeedMargin -Date '20260601' -Market 'o').Ok) "a dead TPEx margin response reports Ok=false"
Assert ($null -eq (Get-FeedMarketInstAmount -Date '20260601')) "a dead BFI82U response yields null, not 0"

# i. the month cache has one owner. Two tenants share the directory (screen.ps1's rows carry a
#    `dt` field, update-holdings.ps1's do not, hence its 'h-' prefix) and the prune used to live
#    in screen.ps1 with a regex that matched both - so it evicted the other script's files, and
#    evicted nothing at all on a day screen.ps1 aborted before reaching it.
$cacheTmp=Join-Path ([IO.Path]::GetTempPath()) ("cache-"+[guid]::NewGuid().ToString('N'))
try{
  $cd=Get-FeedCacheDir $cacheTmp
  Assert (Test-Path $cd) "cache: Get-FeedCacheDir creates the directory"
  Assert ((Get-FeedCacheDir $cacheTmp) -eq $cd) "cache: asking twice is idempotent"
  $old=(Get-Date).AddMonths(-9).ToString('yyyyMM')
  $new=(Get-Date).AddMonths(-1).ToString('yyyyMM')
  foreach($n in @("2330-$old.json","h-2330-$old.json","2330-$new.json","h-2330-$new.json")){
    '[]' | Out-File (Join-Path $cd $n) -Encoding UTF8
  }
  'keep me' | Out-File (Join-Path $cd 'notes.txt') -Encoding UTF8
  $removed=Invoke-FeedCachePrune $cd
  Assert ($removed -eq 2) "cache: prunes only the out-of-window months (removed $removed)"
  Assert ((Test-Path (Join-Path $cd "2330-$new.json")) -and (Test-Path (Join-Path $cd "h-2330-$new.json"))) "cache: in-window files of BOTH tenants survive"
  Assert (-not (Test-Path (Join-Path $cd "h-2330-$old.json"))) "cache: the prefixed tenant is pruned on the same schedule"
  Assert (Test-Path (Join-Path $cd 'notes.txt')) "cache: non-month files are left alone"
  Assert ((Invoke-FeedCachePrune $cd) -eq 0) "cache: pruning twice removes nothing more"
}finally{ Remove-Item -Recurse -Force $cacheTmp -ErrorAction SilentlyContinue }

Set-FeedTransport $null
Remove-Item -Recurse -Force $tmp

Write-Host "[6] Test-FeedRowFields warns when an endpoint renames a field..."
# Was CheckRevCols in screen.ps1, which could only detect that column 9 had stopped being called
# 增減; the revenue endpoints are read by NAME now, so this checks the names we actually read.
$revF=$FeedFields.Revenue
$fakeBad=@([pscustomobject]@{ A=1; B=2; C=3; D=4; E=5; F=6; G=7; H=8; I=9; J=10 })
$msgs=@(Test-FeedRowFields -Rows $fakeBad -Fields $revF -Label 'fixture' 6>&1)
Assert (@($msgs | Where-Object { "$_" -like '*WARN*' }).Count -ge 1) "a renamed field triggers WARN"
Assert (@($msgs | Where-Object { "$_" -like '*去年同月增減*' }).Count -ge 1) "the warning names the field that vanished"
# a response that still carries every mapped name must stay quiet
$fakeOk=@([pscustomobject]@{ '公司代號'='1101'; '公司名稱'='台泥'; '產業別'='水泥工業'
                             '營業收入-去年同月增減(%)'='1.53'; '營業收入-上月比較增減(%)'='2.70'
                             '累計營業收入-前期比較增減(%)'='1.54' })
$msgsOk=@(Test-FeedRowFields -Rows $fakeOk -Fields $revF -Label 'fixture' 6>&1)
Assert ((Test-FeedRowFields -Rows $fakeOk -Fields $revF -Label 'fixture') -and @($msgsOk | Where-Object { "$_" -like '*WARN*' }).Count -eq 0) "the real field names pass without warning"
Assert ((Test-FeedRowFields -Rows @() -Fields $revF -Label 'fixture')) "an empty response is not a layout change"

Write-Host "[7] history-wipe guards (behavioural, not a grep for a comment)..."
# This used to be `Select-String screen.ps1 'FATAL: picks-log'` - green on a reworded comment,
# red on a rename, and silent about what the code actually does. The read is a module function
# now, so assert the behaviour: a log that cannot be parsed must THROW, because the only safe
# response is to abort before anything is written. Returning an empty history is how a
# transient read failure turns into a wiped file.
$plTmp = Join-Path ([IO.Path]::GetTempPath()) ("pl-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $plTmp | Out-Null
try{
  Assert ((Get-PicksLog -Path (Join-Path $plTmp 'nope.json')).Count -eq 0) "picks-log: a missing file is an empty history, not an error"
  $corrupt = Join-Path $plTmp 'corrupt.json'
  '{ this is not json' | Out-File $corrupt -Encoding UTF8
  $threw=$false
  try{ $null = Get-PicksLog -Path $corrupt -Retries 1 -RetryPauseMs 0 }catch{ $threw=$true }
  Assert $threw "picks-log: an unreadable file throws instead of returning empty history"
  $noPicks = Join-Path $plTmp 'nopicks.json'
  '{"other":1}' | Out-File $noPicks -Encoding UTF8
  $threw2=$false
  try{ $null = Get-PicksLog -Path $noPicks -Retries 1 -RetryPauseMs 0 }catch{ $threw2=$true }
  Assert $threw2 "picks-log: a file with no picks array throws"
  # normalisation is what makes the file byte-stable: canonical key order regardless of input
  $mixed = Join-Path $plTmp 'mixed.json'
  '{"picks":[{"score":7,"code":"2330","date":"20260101","name":"x","price":1.5,"status":"open"}]}' | Out-File $mixed -Encoding UTF8
  $rows = Get-PicksLog -Path $mixed
  Assert ((@($rows[0].Keys) -join ',') -eq 'date,code,name,price,score,status') "picks-log: normalisation fixes key order (got $(@($rows[0].Keys) -join ','))"
  # AI tags must land at the tail, matching where the next morning's rewrite puts them
  $tags = [pscustomobject]@{ '2330' = [pscustomobject]@{ sust=$true; risk='r' } }
  Assert ((Add-PicksLogTags -Rows $rows -Tags $tags) -eq 1) "picks-log: tags attach to open picks"
  Assert (((@($rows[0].Keys))[-2..-1] -join ',') -eq 'aiSust,aiRisk') "picks-log: AI tags serialize last (got $(@($rows[0].Keys) -join ','))"
  Assert ((Add-PicksLogTags -Rows $rows -Tags $tags) -eq 0) "picks-log: an already-tagged pick is not retagged"
  # a closed pick never gets tagged
  $closed = Get-PicksLog -Path $mixed
  $closed[0]['status']='closed'
  Assert ((Add-PicksLogTags -Rows $closed -Tags $tags) -eq 0) "picks-log: settled picks are not tagged"
  # closing an ALREADY-TAGGED pick appends exit/closedOn after the tags (that is what assigning
  # a new key to an ordered dictionary does). The write must put them back in canonical order,
  # or every closure costs one row of churn the next morning. Seen for real in the 7/29 e2e run.
  $ct = Get-PicksLog -Path $mixed
  $null = Add-PicksLogTags -Rows $ct -Tags $tags
  $ct[0]['status']='closed'; $ct[0]['exit']=12.0; $ct[0]['retFinal']=5.0; $ct[0]['closedOn']='20260201'
  Assert ((@($ct[0].Keys)[-1]) -eq 'closedOn') "picks-log fixture: closing really does append past the tags"
  $outPath = Join-Path $plTmp 'closed.json'
  Set-PicksLog -Path $outPath -Rows $ct
  $round = Get-PicksLog -Path $outPath
  Assert (((@($round[0].Keys))[-2..-1] -join ',') -eq 'aiSust,aiRisk') "picks-log: the write restores AI tags to the tail (got $(@($round[0].Keys) -join ','))"
  Assert ("$($round[0].closedOn)" -eq '20260201' -and $round[0].exit -eq 12.0) "picks-log: normalising on write loses no values"
  # an unrecognised field must stop the write, not vanish from the file
  $ct[0]['somethingNew']='x'
  $threw3=$false
  try{ Set-PicksLog -Path $outPath -Rows $ct }catch{ $threw3=$true }
  Assert $threw3 "picks-log: an unknown field fails the write instead of being silently dropped"
}finally{ Remove-Item -Recurse -Force $plTmp -ErrorAction SilentlyContinue }
Assert ($null -ne (Select-String -Path (Join-Path $root 'screen.ps1') -Pattern 'FATAL:' -SimpleMatch)) "screen.ps1 still aborts rather than continuing on an unreadable log"

# stance-log: unreadable must SKIP (not abort, unlike picks-log) and must never rewrite the file
. (Join-Path $root 'lib/stance-log.ps1')
$slTmp = Join-Path ([IO.Path]::GetTempPath()) ("sl-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $slTmp | Out-Null
try{
  $bad = Join-Path $slTmp 'bad.json'
  'not json at all' | Out-File $bad -Encoding UTF8
  $r = Get-StanceLog -Path $bad -Retries 1 -RetryPauseMs 0
  Assert (-not $r.Ok -and $r.Rows.Count -eq 0) "stance-log: an unreadable file reports Ok=false so the caller skips its append"
  Assert ((Get-StanceLog -Path (Join-Path $slTmp 'none.json')).Ok) "stance-log: a file that does not exist yet is not an error"
  # normalisation converges a file that accumulated several key orders (the live file had six)
  $mixed = Join-Path $slTmp 'mixed.json'
  '{"rows":[{"stance":"hold","score":1,"close":10.5,"code":"2330","date":"20260101"},{"date":"20260102","code":"2330","close":11.0,"score":2,"stance":"add","raw":"add"}]}' | Out-File $mixed -Encoding UTF8
  $sl = Get-StanceLog -Path $mixed
  Assert ((@($sl.Rows[0].Keys) -join ',') -eq 'date,code,close,score,stance') "stance-log: rows normalise to one key order (got $(@($sl.Rows[0].Keys) -join ','))"
  Set-StanceLog -Path $mixed -Rows $sl.Rows
  $again = Get-StanceLog -Path $mixed
  Assert ($again.Rows.Count -eq 2 -and "$($again.Rows[1].raw)" -eq 'add') "stance-log: round-trip preserves rows and the raw reading"
  # Get-PrevStanceMap is pure: most recent row strictly before the given date
  $rows = @(
    [ordered]@{ date='20260101'; code='2330'; stance='hold'; raw='hold' },
    [ordered]@{ date='20260102'; code='2330'; stance='add';  raw='add'  },
    [ordered]@{ date='20260103'; code='2330'; stance='cut';  raw='cut'  },
    [ordered]@{ date='20260102'; code='0050'; stance='exit' }
  )
  $m = Get-PrevStanceMap -Rows $rows -Before '20260103'
  Assert ($m['2330'].s -eq 'add' -and $m['2330'].d -eq '20260102') "prevStance: takes the latest row strictly before the date (got $($m['2330'].s))"
  Assert ($m['0050'].raw -eq 'exit') "prevStance: a row with no raw falls back to stance (pre-six-level history)"
  $m2 = Get-PrevStanceMap -Rows $rows -Before '20260101'
  Assert ($m2.Count -eq 0) "prevStance: nothing before the earliest date"
}finally{ Remove-Item -Recurse -Force $slTmp -ErrorAction SilentlyContinue }
Assert ($null -ne (Select-String -Path (Join-Path $root 'update-holdings.ps1') -Pattern 'history never overwritten' -SimpleMatch)) "update-holdings stance-log guard"
Assert ($null -ne (Select-String -Path (Join-Path $root 'evaluate.ps1') -Pattern 'FATAL: picks-log.json unreadable' -SimpleMatch)) "evaluate.ps1 read guard"
Assert ($null -ne (Select-String -Path (Join-Path $root 'publish.ps1') -Pattern 'publish continues' -SimpleMatch)) "publish.ps1 notes fallback"

Write-Host "[8] multi-user privacy guards (nothing personal may reach the repo)..."
# .gitignore must cover every per-deployment artifact. Losing one of these lines is how a real
# user's portfolio ends up on GitHub Pages, so it is a test, not a convention.
$gi = Get-Content (Join-Path $root '.gitignore') -Raw
foreach($pat in @('data/','*.db','config.json')){
  Assert ($gi -split "`n" | Where-Object { $_.Trim() -eq $pat }) "gitignore covers $pat"
}
# the committed holdings.json is the public demo: it must never carry real transaction prices
$hj = Get-Content (Join-Path $root 'holdings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert (@($hj.trades).Count -eq 0) "holdings.json demo carries no trades (found $(@($hj.trades).Count))"
# build-demo.ps1 publishes guest-level notes only; `rec`/`news` are owner-specific advice.
# The field lists live in page-contract.json now, so assert the contract rather than the source.
$contract = Get-PageContract
Assert (@($contract.noteFields.guest).Count -gt 0) "contract declares guest note fields"
foreach($f in @('rec','news')){
  Assert (@($contract.noteFields.ownerOnly) -contains $f) "contract marks '$f' owner-only"
  Assert (@($contract.noteFields.guest) -notcontains $f) "contract never lets '$f' through to guests"
}
# The three guest fields ARE the analysis, one per face, each confined to its own evidence.
Assert ((@($contract.noteFields.guest) -join ',') -eq 'tech,chip,fund') "contract's guest notes are exactly the three faces (got $(@($contract.noteFields.guest) -join ','))"
# The market read is its own block with its own policy now, not a `_market` pseudo-code inside
# the per-code notes; `wind` names owner holdings in prose and `night` is 若X則Y written against
# this portfolio's own levels - advice, not a market fact.
Assert (@($contract.marketFields.guest).Count -gt 0) "contract declares shareable market fields"
foreach($f in @('wind','night')){
  Assert (@($contract.marketFields.ownerOnly) -contains $f) "contract marks market.$f owner-only"
  Assert (@($contract.marketFields.guest) -notcontains $f) "contract keeps market.$f private"
}
Assert ($null -eq $contract.noteFields.marketPublic) "the retired marketPublic list is gone, not left behind to be read by mistake"
Assert (@($contract.blocks.PSObject.Properties.Name) -contains 'marketnotes') "contract declares the marketnotes block"
$bd = Get-Content (Join-Path $root 'build-demo.ps1') -Raw
Assert ($bd -match 'noteFields\.guest') "build-demo filters by the contract's guest field list"
Assert ($bd -match 'marketFields\.guest') "build-demo filters the market block by the contract too"
Assert ($bd -notmatch "@\('windLead','sox','mood','moodK'\)") "build-demo no longer hardcodes the _market list"
Assert ($bd -notmatch "'rec'") "build-demo never publishes rec"
# _prevStance's KEY SET is the union of every user's codes; per-demo-code values are fine,
# publishing the map itself would leak which codes users hold
Assert ($bd -notmatch "HOLDINGS_META\['_prevStance'\]") "build-demo never publishes the _prevStance union map"
# `_fund` is the same shape of hazard: its VALUES are exchange figures and safe, but its key set
# is every user's codes. Per-demo-code copies only, never the map.
Assert ($bd -notmatch "HOLDINGS_META\['_fund'\]") "build-demo never publishes the _fund union map"
Assert ($bd -match '_fund.*PSObject\.Properties\[\$c\]') "build-demo copies _fund per demo code, not wholesale"
# The checks above only prove build-demo.ps1 *can* filter - they say nothing about whether its
# output survives to the commit. On 2026-07-23/24 it did not: run-daily.sh called build-demo
# first and publish.ps1's note splice then overwrote the filtered block with the owner's real
# notes. These three assertions test the pipeline, not the intent.
$pb = Get-Content (Join-Path $root 'publish.ps1') -Raw
Assert ($pb -match "build-demo\.ps1") "publish.ps1 runs the demo rebuild itself (after its splice)"
Assert ($pb -match "Invoke-PublishGate") "publish.ps1 exits through the publication gate, not raw git"
Assert ($pb -notmatch "git add -A") "publish.ps1 no longer stages the whole working tree"
$rd = Get-Content (Join-Path $root 'run-daily.sh') -Raw
$bdCall = ([regex]::Matches($rd, '(?m)^\s*pwsh -File build-demo\.ps1')).Count
Assert ($bdCall -eq 0) "run-daily.sh does not call build-demo.ps1 (publish.ps1 owns the ordering)"
# end state: at rest, the committed index.html is the PUBLIC page. Per-user notes are injected
# by server.py at request time, so owner-only fields have no business being in the file on disk.
$idxTxt = [IO.File]::ReadAllText((Join-Path $root 'index.html'), (New-Object System.Text.UTF8Encoding($false)))
$mkr='<script id="holdingsnotes">'
$p1=$idxTxt.IndexOf($mkr)
Assert ($p1 -ge 0) "index.html has a holdingsnotes marker"
if($p1 -ge 0){
  $noteBlock=$idxTxt.Substring($p1+$mkr.Length, $idxTxt.IndexOf('</script>',$p1)-($p1+$mkr.Length))
  # Derived from the contract, not listed here: a hand-copied trio silently stopped covering
  # `night` the day it was added to noteFields.ownerOnly (2026-08-02), which is the same drift
  # page-contract.json exists to end.
  foreach($f in @($contract.noteFields.ownerOnly)){
    Assert (-not $noteBlock.Contains("`"$f`"")) "index.html at rest carries no owner-only note field `"$f`""
  }
}
# The real check is no longer "are these particular names untracked" but "is everything git
# tracks on the publish allowlist". That is the assertion that would have caught
# holdings-notes.json / holdings-context.json / stance-log.json in 2026-07-23..25; a
# name-by-name denylist by definition only catches leaks somebody already thought of.
if(Get-Command git -ErrorAction SilentlyContinue){
  Push-Location $root
  $tracked = @(git ls-files 'data' 'config.json' '*.db' 2>$null)
  $allTracked = @(git ls-files)
  $allowed = @(git ls-files -- $PublishAllowlist)
  Pop-Location
  Assert ($tracked.Count -eq 0) "no per-deployment files tracked by git (found: $($tracked -join ', '))"
  $stray = @($allTracked | Where-Object { $allowed -notcontains $_ })
  Assert ($stray.Count -eq 0) "every tracked file is on the publish allowlist (stray: $($stray -join ', '))"
  foreach($f in @('holdings-notes.json','holdings-context.json','stance-log.json')){
    Assert ($allTracked -notcontains $f) "$f is not tracked (owner-derived, must never be published)"
  }
}
# 2026-07-31: plan.md had carried the owner's real Funnel hostname since 07-24, and the content
# scan only ever opened .json and .html - so no run would ever have caught it. Guard both
# directions. The false-positive half matters as much: SETUP.md documents the placeholder form,
# and a scan that fired on it would block every future publish.
if(Get-Command git -ErrorAction SilentlyContinue){
  Push-Location $root
  $hostLeaks = @(git grep -nE $TailnetHostPattern -- . 2>$null)
  Pop-Location
  Assert ($hostLeaks.Count -eq 0) "no tracked file names a concrete tailnet host (found: $($hostLeaks -join '; '))"
}
# Built by concatenation on purpose: spelled out in full, this fixture would be a concrete
# hostname sitting in a tracked file, and the assertion above would fail on tests.ps1 itself.
$fakeHost = 'box-7.' + 'tailabc123.' + 'ts' + '.net'
$tmpLeak = Join-Path ([IO.Path]::GetTempPath()) ("leak-"+[guid]::NewGuid().ToString('N')+".md")
$encL = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($tmpLeak,"the dashboard lives at https://$fakeHost/ these days",$encL)
Assert (@(Test-FileForOwnerContent $tmpLeak 'leak.md').Count -eq 1) "the gate catches a tailnet hostname in a .md file"
[IO.File]::WriteAllText($tmpLeak,"URL is <machine>.<tailnet>.ts.net - any .ts.net address is fine",$encL)
Assert (@(Test-FileForOwnerContent $tmpLeak 'clean.md').Count -eq 0) "the gate ignores the placeholder and a bare .ts.net mention"
Remove-Item $tmpLeak -ErrorAction SilentlyContinue

Write-Host "[9] page-data contract + publication gate + stance engine..."
# a block id that is not in the contract must be an error, not a silent no-op
$tmpIdx = Join-Path ([IO.Path]::GetTempPath()) ("idx-"+[guid]::NewGuid().ToString('N')+".html")
Copy-Item (Join-Path $root 'index.html') $tmpIdx
$threw=$false
try{ Set-PageBlocks -IndexPath $tmpIdx -Blocks @{ notarealblock=1 } }catch{ $threw=$true }
Assert $threw "Set-PageBlocks rejects an unknown block id"
# a missing marker must refuse to write, not warn and carry on (the old Splice wrote anyway)
$encT = New-Object System.Text.UTF8Encoding($false)
$htmlT = [IO.File]::ReadAllText($tmpIdx,$encT).Replace('<script id="evaldata">','<script id="renamed">')
[IO.File]::WriteAllText($tmpIdx,$htmlT,$encT)
$threw=$false
try{ Set-PageBlocks -IndexPath $tmpIdx -Blocks @{ evaldata=@{a=1} } }catch{ $threw=$true }
Assert $threw "Set-PageBlocks refuses to write when a marker is missing"
# payload must not be able to close the script element early
Copy-Item (Join-Path $root 'index.html') $tmpIdx -Force
Set-PageBlocks -IndexPath $tmpIdx -Blocks @{ evaldata=@{ x='a</script>b' } }
$blk = Get-PageBlockText ([IO.File]::ReadAllText($tmpIdx,$encT)) 'evaldata'
Assert ($blk -notmatch '</script>') "spliced payload cannot close the script tag"
Remove-Item $tmpIdx -Force

# every block the contract declares must actually exist in index.html
$idxAll = [IO.File]::ReadAllText((Join-Path $root 'index.html'), $encT)
foreach($id in @($contract.blocks.PSObject.Properties.Name)){
  Assert ($null -ne (Get-PageBlockText $idxAll $id)) "index.html has a '$id' block"
}

# the gate's content check must see an owner-only field wherever it is nested
$tmpJson = Join-Path ([IO.Path]::GetTempPath()) ("gate-"+[guid]::NewGuid().ToString('N')+".json")
'{"_market":{"windLead":"ok","wind":"leak"},"2330":{"tech":"fine"}}' | Out-File $tmpJson -Encoding UTF8
$hits = @(Test-FileForOwnerContent $tmpJson 'fixture.json')
Assert ($hits.Count -ge 1) "gate finds a nested owner-only field (_market.wind)"
'{"2330":{"tech":"fine","chip":"fine"}}' | Out-File $tmpJson -Encoding UTF8
$hits = @(Test-FileForOwnerContent $tmpJson 'fixture.json')
Assert ($hits.Count -eq 0) "gate passes a guest-safe notes file"
Remove-Item $tmpJson -Force

# Invoke-PublishGate -NoPush: must commit but NOT push. finish-daily-push.ps1 (the cron
# wrapper's token-usage handoff, plan.md 2026-07-25) relies on this to fold the day's real
# token count into that still-local commit instead of shipping a stale number or a second push.
$gateRepo = Join-Path ([IO.Path]::GetTempPath()) ("gaterepo-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $gateRepo -Force | Out-Null
try {
  $barePath = Join-Path $gateRepo 'bare.git'
  $workPath = Join-Path $gateRepo 'work'
  git init -q --bare -b main $barePath 2>$null | Out-Null
  git clone -q $barePath $workPath 2>$null | Out-Null
  Push-Location $workPath
  try {
    git config user.email test@test.local
    git config user.name test
    # .gitignore must exist: `git add -A -- $PublishAllowlist` includes it as a literal
    # pathspec, and git aborts the whole add (staging nothing at all) if any pathspec in the
    # list matches zero files - a missing .gitignore silently made this test stage nothing.
    '' | Out-File (Join-Path $workPath '.gitignore') -Encoding UTF8
    'v1' | Out-File (Join-Path $workPath 'picks-notes.json') -Encoding UTF8
    git add -A | Out-Null; git commit -q -m init | Out-Null
    git push -q origin main 2>$null | Out-Null

    'v2' | Out-File (Join-Path $workPath 'picks-notes.json') -Encoding UTF8
    $ok1 = Invoke-PublishGate -Root $workPath -Message 'test nopush' -NoPush
    $head1 = (git rev-parse HEAD).Trim(); $remote1 = (git rev-parse origin/main).Trim()
    Assert $ok1 "gate -NoPush reports success"
    Assert ($head1 -ne $remote1) "gate -NoPush commits locally but does not push"

    'v3' | Out-File (Join-Path $workPath 'picks-notes.json') -Encoding UTF8
    $ok2 = Invoke-PublishGate -Root $workPath -Message 'test push'
    $head2 = (git rev-parse HEAD).Trim(); $remote2 = (git rev-parse origin/main).Trim()
    Assert $ok2 "gate without -NoPush reports success"
    Assert ($head2 -eq $remote2) "gate without -NoPush actually pushes (also carries the earlier -NoPush commit)"

    # regression: this fixture never creates run-daily.sh / index.html / token-usage.json /
    # etc - almost every other $PublishAllowlist entry is absent. `git add -A -- <the whole
    # list>` used to abort STAGING EVERYTHING (not just the missing ones) the instant any one
    # pathspec matched zero files, so the two assertions above only pass post-fix; this one
    # names the failure mode directly so it stays obvious if the per-entry loop ever regresses
    # back to a single `git add -A -- $PublishAllowlist` call.
    Assert ((git log --format=%s -1).Trim() -eq 'test push') "gate stages a real change even though most of the allowlist does not exist on disk"
  } finally { Pop-Location }
} finally {
  Remove-Item $gateRepo -Recurse -Force -ErrorAction SilentlyContinue
}

# stance engine: the six levels and their boundaries, in one place
$mkSer = {
  param($n,$closes)
  $out=@()
  for($i=0;$i -lt $n;$i++){ $c=[double]$closes[$i]; $out += [ordered]@{ o=$c; h=$c; l=$c; c=$c; chg=0.0; v=100 } }
  return ,$out
}
$flat = & $mkSer 70 (1..70 | ForEach-Object { 10.0 })
Assert ($null -eq (Get-StanceGrade (& $mkSer 10 (1..10 | ForEach-Object { 10.0 })) @() @())) "stance: <25 bars is ungraded"
$g0 = Get-StanceGrade $flat @() @()
Assert ($g0.score -eq 0 -and $g0.level -eq 'hold') "stance: flat series scores 0 -> hold (got $($g0.score)/$($g0.level))"
# 70 bars, not 30: every +-2/+-3 tech rung compares against the 60-day line, so a shorter
# fixture can never reach them and would silently grade everything on the +-1 rungs.
# The two anchors of the six-level scheme: price below ALL of 5/10/20/60 is 'exit' on its own,
# above all four is 'add' on its own. If either stops holding, the vocabulary is a lie.
$down = & $mkSer 70 (1..70 | ForEach-Object { 40.0 - $_ * 0.3 })
$gd = Get-StanceGrade $down @() @()
Assert ($gd.tech -eq -3) "stance: below all of 5/10/20/60 scores tech=-3 (got $($gd.tech))"
Assert ($gd.score -eq -3 -and $gd.level -eq 'exit') "stance: score -3 alone is 'exit' (got $($gd.score)/$($gd.level))"
$rise = & $mkSer 70 (1..70 | ForEach-Object { 10.0 + $_ * 0.3 })
$gu = Get-StanceGrade $rise @() @()
Assert ($gu.tech -eq 3) "stance: above all of 5/10/20/60 scores tech=+3 (got $($gu.tech))"
Assert ($gu.score -eq 3 -and $gu.level -eq 'add') "stance: score +3 alone is 'add' (got $($gu.score)/$($gu.level))"
# chip +-2 needs a run (every day agreeing), not just a net - and needs a full window.
# These double as the middle-bucket boundary checks: the flat series scores tech=vp=extra=0,
# so the chip term alone is the score, and -1/-2/+1/+2 must land on four different levels.
$gc1 = Get-StanceGrade $flat @(@{f=-5},@{f=-5},@{f=-5},@{f=-5},@{f=-5}) @()
Assert ($gc1.chip -eq -2 -and $gc1.score -eq -2 -and $gc1.level -eq 'cut') "stance: 5 straight sell days -> chip=-2, score -2 is 'cut' (got $($gc1.chip)/$($gc1.score)/$($gc1.level))"
$gc2 = Get-StanceGrade $flat @(@{f=-9},@{f=1},@{f=1},@{f=1},@{f=-5}) @()
Assert ($gc2.chip -eq -1 -and $gc2.level -eq 'cutwatch') "stance: net-sell but mixed days stays chip=-1, score -1 is 'cutwatch' (got $($gc2.chip)/$($gc2.level))"
$gc3 = Get-StanceGrade $flat @(@{f=-5},@{f=-5}) @()
Assert ($gc3.chip -eq -1) "stance: a 2-row partial feed must not earn chip=-2 (got $($gc3.chip))"
$gc4 = Get-StanceGrade $flat @(@{f=5},@{f=5},@{f=5},@{f=5},@{f=5}) @()
Assert ($gc4.chip -eq 2 -and $gc4.score -eq 2 -and $gc4.level -eq 'addwatch') "stance: 5 straight buy days -> chip=+2, score +2 is still 'addwatch' (got $($gc4.chip)/$($gc4.score)/$($gc4.level))"
$gc5 = Get-StanceGrade $flat @(@{f=9},@{f=-1},@{f=-1},@{f=-1},@{f=5}) @()
Assert ($gc5.chip -eq 1 -and $gc5.level -eq 'addwatch') "stance: score +1 is 'addwatch' (got $($gc5.chip)/$($gc5.level))"
# Confirmation (v3). Hysteresis must swallow a one-day blip but ALWAYS make progress: v2 required
# two identical raw readings, so a reading oscillating between adjacent levels froze the badge
# forever (47% of live rows sat on a suppressed reading; worst case 9 trade days).
# $down grades to raw='exit'; 'hold' is 3 rungs away, so it is a real move, not a blip.
$gp1 = Get-StanceGrade $down @() @() 'hold' 'hold'
Assert ($gp1.raw -eq 'exit' -and $gp1.level -eq 'exit') "stance: a jump of 2+ levels takes effect at once, it does not wait for confirmation (got $($gp1.level))"
$gp2 = Get-StanceGrade $down @() @() 'hold' 'exit'
Assert ($gp2.level -eq 'exit' -and -not $gp2.pending) "stance: the same reading two days running switches the level (got $($gp2.level))"
# an isolated ONE-rung blip is still suppressed - that is the part of v2 worth keeping
$gp3 = Get-StanceGrade $flat @() @() 'addwatch' 'addwatch'
Assert ($gp3.raw -eq 'hold' -and $gp3.level -eq 'addwatch' -and $gp3.pending) "stance: an isolated one-rung blip keeps the previous level (got $($gp3.level)/raw $($gp3.raw))"
# ...but two consecutive days of disagreement resolve, even when they disagree with each other.
# This is the exact shape that froze code 8150 for five trade days.
$gp4 = Get-StanceGrade $flat @() @() 'addwatch' 'cut'
Assert ($gp4.level -eq 'hold') "stance: two days of disagreement resolve even if the two readings differ - no indefinite freeze (got $($gp4.level))"
# Regression fixture: code 8150's real raw readings, 2026-08-11..08-18, replayed through both
# confirmation rules. v2 ("two IDENTICAL readings") never resolves once the readings start
# oscillating, so the badge stayed on 加碼觀察 for all six days while the stock fell from 99.0 to
# 89.1. v3 must track the bearish turn from 8/14, the day the reading first jumped two rungs.
$freeze=@('addwatch','hold','addwatch','cut','cutwatch','cut')
function Replay-Confirmation($readings,$startLevel,$rule){
  $lvl=$startLevel; $prevRaw=$startLevel; $seen=@()
  foreach($rw in $readings){
    $next = & $rule $rw $lvl $prevRaw
    $seen+=$next; $prevRaw=$rw; $lvl=$next
  }
  return $seen
}
$v2rule={ param($rw,$lvl,$prevRaw) if($lvl -and $rw -ne $lvl -and $prevRaw -ne $rw){ $lvl } else { $rw } }
$v3rule={ param($rw,$lvl,$prevRaw)
  $rk=Get-StanceLevelRank $rw; $rl=Get-StanceLevelRank $lvl; $pr=Get-StanceLevelRank $prevRaw
  if($null -ne $rl -and $null -ne $rk -and $rk -ne $rl -and [math]::Abs($rk-$rl) -lt 2 -and ($null -eq $pr -or $pr -eq $rl)){ $lvl } else { $rw } }
$oldSeq=Replay-Confirmation $freeze 'addwatch' $v2rule
$newSeq=Replay-Confirmation $freeze 'addwatch' $v3rule
Assert ((@($oldSeq | Where-Object { $_ -eq 'addwatch' }).Count) -eq 6) "stance: the v2 rule really did freeze this sequence for all six days (got $($oldSeq -join '->'))"
Assert ($newSeq[3] -eq 'cut' -and $newSeq[4] -eq 'cut' -and $newSeq[5] -eq 'cut') "stance: v3 tracks 8150's bearish turn from the two-rung jump onward (got $($newSeq -join '->'))"
Assert ($newSeq[1] -eq 'addwatch') "stance: v3 still suppresses the isolated one-rung blip on day 2 (got $($newSeq -join '->'))"
Assert ($StanceEngineVersion -ge 3) "stance: the engine version is stamped so evaluate.ps1 never averages v2 and v3 together"
# the page's display map must cover exactly the levels the engine can emit
$idxJs = $idxAll
foreach($lvl in @('add','addwatch','hold','cutwatch','cut','exit')){
  Assert ($idxJs -match ("LEVEL_VIEW=\{[^}]*" + $lvl + ":")) "index.html LEVEL_VIEW maps '$lvl'"
}
Assert ($idxJs -notmatch "score>=2\?\['up'") "index.html no longer re-derives the stance thresholds"
# retired four-level keys must not come back as engine output (STANCE_NM keeps them read-only
# so the switchover day's prevStance still renders, but nothing may emit them)
# (comments still discuss the old levels by name, so look at code lines only)
$stanceCode = (Get-Content (Join-Path $root 'lib/stance.ps1') -Encoding UTF8 |
  Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
foreach($old in @("'up'","'trim'","'defend'")){
  Assert ($stanceCode -notmatch [regex]::Escape($old)) "lib/stance.ps1 no longer emits the retired level $old"
}

# Holding names are user-typed in server mode (api._holding_name), and server/validate.py
# deliberately delegates HTML escaping to the page - it only strips control characters and caps
# length, so "<img src=x onerror=...>" fits well inside MAX_NAME. Every ${...name} that reaches
# innerHTML must therefore be escaped: either esc() at the site, or inside an html`` tagged
# template, which escapes every interpolation by default. buildCostPanel was the one site of
# twelve that was neither.
$idxLines = Get-Content (Join-Path $root 'index.html') -Encoding UTF8
$unescapedName = @()
for($i=0; $i -lt $idxLines.Count; $i++){
  $ln = $idxLines[$i]
  if($ln -match '\$\{[^}]*\.name[^}]*\}' -and $ln -notmatch 'esc\(' -and $ln -notmatch 'html`'){
    $unescapedName += ($i + 1)
  }
}
Assert ($unescapedName.Count -eq 0) "index.html escapes every interpolated holding name (unescaped at line(s): $($unescapedName -join ', '))"
Assert ($idxAll -match 'const html=\(strings') "index.html has the escape-by-default html`` template"

# --- Get-StanceAttribution: is the 判級 grade worth anything? ---------------------------------
# The engine had no accuracy measurement at all: evaluate.ps1's old block asked for 20 forward
# rows per code when each code had ~14, so the loop never ran once and the report silently
# omitted the section for months. These tests pin the replacement's behaviour.
function New-StanceFixture($code,$closes,$level,$ver,$startDay=10){
  $rows=@()
  for($i=0;$i -lt $closes.Count;$i++){
    $rows += ,([ordered]@{ date=("202601{0:d2}" -f ($startDay+$i)); code=$code
                           close=$closes[$i]; score=0; stance=$level; raw=$level; v=$ver })
  }
  return $rows
}
# a rising stock graded 'add' and a falling one graded 'exit' is the ordering holding perfectly
$fxUp   = New-StanceFixture '1111' @(100,102,104,106,108,110,112,114) 'add'  2
$fxDown = New-StanceFixture '2222' @(100,98,96,94,92,90,88,86)        'exit' 2
$saGood = Get-StanceAttribution -Rows ($fxUp+$fxDown) -Windows @(5)
Assert ($null -ne $saGood) "byStance: a non-empty log must produce a report (guards the case-insensitive local-vs-parameter collision that made this return null for every input)"
Assert ($saGood.v2.windows.fwd5.monotonicity -eq 100) "byStance: correctly ordered grades score monotonicity 100 (got $($saGood.v2.windows.fwd5.monotonicity))"
Assert ($saGood.v2.windows.fwd5.inversions -eq 0 -and $saGood.v2.windows.fwd5.pairs -eq 1) "byStance: one level pair, no inversions"
Assert ($saGood.v2.windows.fwd5.levels.add.avgAlpha -gt 0 -and $saGood.v2.windows.fwd5.levels.exit.avgAlpha -lt 0) "byStance: alpha is cross-sectional, so add and exit land on opposite sides of the same-day mean"
Assert ($saGood.v2.windows.fwd5.levels.add.provisional) "byStance: a bucket below MinN is flagged provisional, not silently quoted as evidence"
# swap the labels and the same price action must score exactly inverted
$fxUpBad   = New-StanceFixture '1111' @(100,102,104,106,108,110,112,114) 'exit' 2
$fxDownBad = New-StanceFixture '2222' @(100,98,96,94,92,90,88,86)        'add'  2
$saBad = Get-StanceAttribution -Rows ($fxUpBad+$fxDownBad) -Windows @(5)
Assert ($saBad.v2.windows.fwd5.monotonicity -eq 0) "byStance: inverted grades score monotonicity 0 (got $($saBad.v2.windows.fwd5.monotonicity))"
# engine versions are reported side by side and never averaged together - the whole point of `v`
$saVer = Get-StanceAttribution -Rows ($fxUp + $fxDown +
  (New-StanceFixture '3333' @(100,98,96,94,92,90,88,86) 'add' 3) +
  (New-StanceFixture '4444' @(100,102,104,106,108,110,112,114) 'exit' 3)) -Windows @(5)
Assert ($saVer.Contains('v2') -and $saVer.Contains('v3')) "byStance: each engine version gets its own block"
Assert ($saVer.v2.windows.fwd5.monotonicity -eq 100 -and $saVer.v3.windows.fwd5.monotonicity -eq 0) "byStance: a good engine and a bad one are not blended into one average (got v2=$($saVer.v2.windows.fwd5.monotonicity) v3=$($saVer.v3.windows.fwd5.monotonicity))"
# Forward windows count TRADE DAYS IN THE LOG, not rows of this code: a code missing for a day
# must not be measured over a longer real horizon than the codes it is compared against.
# Closes rise by 5 a day, and 20260113 is dropped from this code only. Counting trade days gives
# 25%/23.8%/22.7% (avg 24); counting this code's own rows would skip to the next date and give
# 30%/28.6% (avg 29). The two answers are far enough apart to tell which one ran.
$fxGap = @(New-StanceFixture '1111' @(100,105,110,115,120,125,130,135) 'add' 2 | Where-Object { $_.date -ne '20260113' })
$saGap = Get-StanceAttribution -Rows ($fxGap + $fxDown) -Windows @(5)
Assert ([math]::Round($saGap.v2.windows.fwd5.levels.add.avgRet,0) -eq 24) "byStance: a one-day gap in a code does not stretch its forward window (trade-day counting gives ~24%, row counting ~29%; got $($saGap.v2.windows.fwd5.levels.add.avgRet)%)"
# version inference for rows written before the stamp existed
Assert ((Get-StanceRowVersion ([ordered]@{ date='20260101'; code='2330'; close=1; stance='hold' })) -eq 1) "byStance: a row with no raw is the four-level engine (v1)"
Assert ((Get-StanceRowVersion ([ordered]@{ date='20260101'; code='2330'; close=1; stance='hold'; raw='hold' })) -eq 2) "byStance: raw but no stamp is the six-level engine (v2)"
Assert ((Get-StanceRowVersion ([ordered]@{ date='20260101'; code='2330'; close=1; stance='hold'; raw='hold'; v=7 })) -eq 7) "byStance: an explicit v stamp wins over inference"
# a window with only one level says nothing about order and must not pad the report
$saOne = Get-StanceAttribution -Rows (New-StanceFixture '1111' @(100,101,102,103,104,105,106,107) 'hold' 2) -Windows @(5)
Assert ($null -eq $saOne) "byStance: a single level carries no ordering information and is dropped"
# idx is optional: rows written before it existed must still produce a report
$noIdx = Get-StanceAttribution -Rows ($fxUp+$fxDown) -Windows @(5)
Assert ($noIdx.v2.windows.fwd5.nIdx -eq 0 -and $noIdx.v2.windows.fwd5.baseline -eq 'cross-section') "byStance: rows without idx still report, on the cross-sectional baseline"
# evaluate.ps1 must serialise deep enough for the nested level maps to survive
$evalSrc = Get-Content (Join-Path $root 'evaluate.ps1') -Raw -Encoding UTF8
Assert ($evalSrc -match 'ConvertTo-Json -Depth 8') "evaluate.ps1 serialises byStance at a depth that does not truncate levels to a type name"
Assert ((Get-PageContract).blocks.evaldata.depth -ge 8) "page-contract evaldata depth covers the nested byStance block"

Write-Host "[10] picks-log retention + JSON key stability..."
# --- Move-SettledPicksToArchive (lib/picks-log.ps1) -------------------------------------------------
# The invariant that matters: log + archive must always be exactly the input set. Trimming a
# published, daily-rewritten file is only safe if every failure mode keeps the rows.
function MkPickRows([int]$closed,[int]$open){
  $r=@()
  for($i=0;$i -lt $closed;$i++){
    $r += ,[ordered]@{ date=("2026{0:0000}" -f (1000+$i)); code=("A{0:0000}" -f $i); name="n$i"; price=10.0
                       score=50; status='closed'; closedOn=("2026{0:0000}" -f (2000+$i)); retFinal=1.0; alphaFinal=0.5 }
  }
  for($i=0;$i -lt $open;$i++){
    $r += ,[ordered]@{ date='20260728'; code=("B{0:0000}" -f $i); name="o$i"; price=20.0; score=60; status='open' }
  }
  return ,$r
}
function PickKeys($rows){ @($rows | ForEach-Object { "$($_.date)|$($_.code)" }) }
function ArcPickKeys($p){
  if(-not (Test-Path $p)){ return @() }
  @(Get-Content $p -Encoding UTF8 | Where-Object { "$_".Trim() } | ForEach-Object { $o=$_|ConvertFrom-Json; "$($o.date)|$($o.code)" })
}
$tmpF=Join-Path ([IO.Path]::GetTempPath()) ("foldtest-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpF | Out-Null
try{
  $arc=Join-Path $tmpF 'a1.jsonl'
  $out=Move-SettledPicksToArchive (MkPickRows 5 3) 120 $arc
  Assert ($out.Count -eq 8) "fold: under the retention limit nothing moves"
  Assert (-not (Test-Path $arc)) "fold: under the limit no archive file is created"

  $arc=Join-Path $tmpF 'a2.jsonl'
  $rows=MkPickRows 10 3
  $origKeys=(PickKeys $rows | Sort-Object -Unique) -join ','
  $out=Move-SettledPicksToArchive $rows 4 $arc
  Assert ($out.Count -eq 7) "fold: retain=4 leaves 4 settled + 3 open"
  Assert (@($out|Where-Object{$_.status -eq 'open'}).Count -eq 3) "fold: open rows are never archived"
  Assert ((@(PickKeys $out)+@(ArcPickKeys $arc) | Sort-Object -Unique) -join ',' -eq $origKeys) "fold: log + archive equals the input set"
  Assert ((@($out|Where-Object{$_.status -eq 'closed'}|ForEach-Object{$_.code}) -join ',') -eq 'A0006,A0007,A0008,A0009') "fold: the rows kept are the newest settled ones"

  $out2=Move-SettledPicksToArchive $out 4 $arc
  Assert ($out2.Count -eq 7 -and (ArcPickKeys $arc).Count -eq 6) "fold: running twice changes nothing (idempotent)"

  # crash between the append and the log rewrite: rows are in both files on the next run
  $arc=Join-Path $tmpF 'a4.jsonl'
  $rows=MkPickRows 10 0
  Set-Content -Path $arc -Encoding UTF8 -Value @($rows[0..5] | ForEach-Object { $_ | ConvertTo-Json -Depth 4 -Compress })
  $out=Move-SettledPicksToArchive $rows 4 $arc
  Assert ((ArcPickKeys $arc).Count -eq 6 -and (@(ArcPickKeys $arc)|Sort-Object -Unique).Count -eq 6) "fold: crash-then-retry appends no duplicates"
  Assert ($out.Count -eq 4) "fold: crash-then-retry still converges to the retention limit"

  # an unwritable archive must cost history nothing
  $blocked=Join-Path $tmpF 'blocked'
  Set-Content -Path $blocked -Value 'this is a file, not a directory' -Encoding UTF8
  $out=Move-SettledPicksToArchive (MkPickRows 10 2) 4 (Join-Path $blocked 'deeper/a5.jsonl')
  Assert ($out.Count -eq 12) "fold: an unwritable archive drops nothing from the log"
}finally{ Remove-Item $tmpF -Recurse -Force -ErrorAction SilentlyContinue }

# --- key ordering ---------------------------------------------------------------------------
# A plain @{} enumerates in per-process string-hash order, so ConvertTo-Json reshuffled every
# record and the daily commit rewrote the whole file. These files are published and rewritten
# daily; unstable key order is what makes them grow the repo without bound.
$screenSrc = Get-Content (Join-Path $root 'screen.ps1') -Raw -Encoding UTF8
foreach($pat in @('$perfSummary=[ordered]@{','$regimeObj=[ordered]@{','$metaObj=[ordered]@{','$summaryOut=[ordered]@{')){
  Assert ($screenSrc.Contains($pat)) "screen.ps1 serializes with a stable key order: $pat"
}
# the picks-log row shape moved to lib/picks-log.ps1; assert the module, not screen.ps1's source
$plSrc = Get-Content (Join-Path $root 'lib/picks-log.ps1') -Raw -Encoding UTF8
Assert ($plSrc.Contains('$o=[ordered]@{')) "lib/picks-log.ps1 builds rows with a stable key order"
Assert ($plSrc.Contains('-ErrorAction Stop')) "lib/picks-log.ps1 writes with -ErrorAction Stop"
# publish.ps1 is the file's second writer and must go through the module, not raw Get-Content
$pubSrc = Get-Content (Join-Path $root 'publish.ps1') -Raw -Encoding UTF8
Assert ($pubSrc -match 'Get-PicksLog') "publish.ps1 reads picks-log through the module"
Assert ($pubSrc -match 'Set-PicksLog') "publish.ps1 writes picks-log through the module"
Assert ($pubSrc -notmatch 'Out-File \$logPath') "publish.ps1 no longer writes picks-log by hand"
Assert ((Get-Content (Join-Path $root 'evaluate.ps1') -Raw -Encoding UTF8).Contains('return [ordered]@{ n=$a.Count')) "evaluate.ps1 Grp() emits a stable key order"
# proof rather than pattern-matching: same input, two fresh processes, identical bytes
$stab=Join-Path ([IO.Path]::GetTempPath()) ("stab-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stab | Out-Null
try{
  $mkPath=Join-Path $stab 'mk.ps1'
  Set-Content -Path $mkPath -Encoding UTF8 -Value @(
    'param($Out)'
    '$o=[ordered]@{date="20260709";code="2890";name="x";price=40.45;score=89}'
    '$o.status="closed"'
    'foreach($f in @("light","chipS","ind")){$o[$f]="v"}'
    '$o.exit=39.85; $o.retFinal=-1.48'
    '@{picks=@($o)}|ConvertTo-Json -Depth 5|Out-File $Out -Encoding UTF8'
  )
  foreach($i in 1..2){ pwsh -NoProfile -File $mkPath (Join-Path $stab "s$i.json") }
  $s1=Join-Path $stab 's1.json'; $s2=Join-Path $stab 's2.json'
  # guard against a vacuous pass: two missing files also compare equal
  Assert ((Test-Path $s1) -and (Test-Path $s2)) "key-order probe actually produced both files"
  $a=Get-Content $s1 -Raw -Encoding UTF8
  $b=Get-Content $s2 -Raw -Encoding UTF8
  Assert ($a -and $b -and $a -eq $b) "picks-log JSON is byte-identical across separate pwsh processes"
  Assert ($a -match '(?s)"date".*"code".*"name".*"price".*"score".*"status"') "picks-log keys come out in declaration order"
}finally{ Remove-Item $stab -Recurse -Force -ErrorAction SilentlyContinue }

# --- the archive must never become a published artifact --------------------------------------
$giF = Get-Content (Join-Path $root '.gitignore') -Raw -Encoding UTF8
Assert ($giF -match '(?m)^data/\s*$') ".gitignore still covers data/ (where picks-archive.jsonl lives)"
Assert (-not (git -C $root ls-files --error-unmatch 'data/picks-archive.jsonl' 2>$null)) "picks-archive.jsonl is not git-tracked"

Write-Host "[11] selection rules (lib/score.ps1)..."
# The funnel had NO behavioural test before this module existed: it was straight-line code inside
# screen.ps1, duplicated for ETFs and transcribed a third time into backtest.ps1 under a comment
# promising "same order and thresholds as production". These assertions are what that comment
# used to be.
. (Join-Path $root 'lib/score.ps1')
$PS = Get-ScoreProfile 'stock'
$PE_ = Get-ScoreProfile 'etf'

# regime light
Assert ((Get-RegimeLight -IdxLast 100 -IdxMA20 90 -IdxMA60 80 -InstNet 5 -UpCount 600 -DownCount 300) -eq 'green') "regime: all three points = green"
Assert ((Get-RegimeLight -IdxLast 70 -IdxMA20 90 -IdxMA60 80 -InstNet 5 -UpCount 600 -DownCount 300) -eq 'red') "regime: below MA60 is red whatever the points say"
Assert ((Get-RegimeLight -IdxLast 100 -IdxMA20 90 -IdxMA60 80 -InstNet $null -UpCount 200 -DownCount 600) -eq 'yellow') "regime: above MA60 but weak internals = yellow"

# entry gate: red days rank and display as usual but must not be BOOKED as entries. The one
# attribution finding past n>=10 and stable for four weeks (red: n=16, 19% win, -2.21% alpha).
Assert (-not (Test-RegimeEntryGate -Light 'red')) "regime gate: red does not book entries"
Assert ((Test-RegimeEntryGate -Light 'yellow') -and (Test-RegimeEntryGate -Light 'green')) "regime gate: yellow and green still book entries"
# and screen.ps1 must actually consult it rather than re-deciding inline
$scrSrc = Get-Content (Join-Path $root 'screen.ps1') -Raw -Encoding UTF8
Assert ($scrSrc -match 'Test-RegimeEntryGate') "screen.ps1 books entries through the shared gate, not an inline light check"
Assert ($scrSrc -match '-not \$dateLogged -and -not \$gateRed') "screen.ps1's picks-log append is guarded by the gate"

# chip gate + score
$stTrust = Get-ChipStats -Trust @(1e5,1e5,1e5,-1,-1) -Foreign @(-1,-1,-1,-1,-1)
Assert ($stTrust.tPos -eq 3 -and $stTrust.tSum -eq 299998) "chip stats: counts positives, sums EVERY day (got tSum=$($stTrust.tSum))"
Assert (-not (Test-ChipGate -Stats $stTrust -Profile $PS)) "chip gate: 3 trust days but sum not ABOVE the floor -> no"
$stTrust2 = Get-ChipStats -Trust @(2e5,2e5,2e5,-1,-1) -Foreign @(-1,-1,-1,-1,-1)
Assert (Test-ChipGate -Stats $stTrust2 -Profile $PS) "chip gate: 3 trust days over the floor -> yes"
Assert (Test-ChipGate -Stats $stTrust -Profile $PE_) "chip gate: the ETF profile has a lower floor, same shape"
Assert ((Get-ChipScore -Stats $stTrust2).Raw -eq 15) "chip score: 3 trust days = 15 raw points"
Assert ((Get-ChipScore -Stats $stTrust2 -MarginDown $true).Raw -eq 20) "chip score: margin falling adds 5"
$stCap = Get-ChipStats -Trust @(1,1,1,1,1,1,1) -Foreign @(1,1,1,1,1,1,1)
Assert ((Get-ChipScore -Stats $stCap).Raw -eq 35) "chip score: caps at 25+10"

# tech: rejections are rejections, not low scores
$maOk = @{ ma20=90.0; ma20p=88.0; ma60=80.0; ret5=0.05; dist=-0.02 }
$barOk = @{ c=100.0; o=99.0; h=101.0; l=98.0; chg=1.0; vr=1.0; val=1e8 }
$r=Get-TechScore -Bar $barOk -Ma @{ ma20=90.0; ma20p=88.0; ma60=80.0; ret5=0.30; dist=-0.02 } -Light 'red' -Profile $PS
Assert ($r.Drop -and $r.Reason -match 'overheated') "tech: ret5 over the profile cap is a drop"
$r=Get-TechScore -Bar $barOk -Ma @{ ma20=90.0; ma20p=88.0; ma60=120.0; ret5=0.05; dist=-0.02 } -Light 'red' -Profile $PS
Assert ($r.Drop -and $r.Reason -eq 'below MA60') "tech: below MA60 is a drop"
$r=Get-TechScore -Bar @{ c=98.2; o=99.0; h=101.0; l=98.0; chg=1.0; vr=2.5; val=1e8 } -Ma $maOk -Light 'red' -Profile $PS
Assert ($r.Drop -and $r.Reason -match 'distribution') "tech: heavy volume + weak close at the highs is a drop"
# the same bar is NOT a drop under the ETF profile, which does not read candles
$r=Get-TechScore -Bar @{ c=98.2; o=99.0; h=101.0; l=98.0; chg=1.0; vr=2.5; val=1e8 } -Ma $maOk -Light 'red' -Profile $PE_
Assert (-not $r.Drop) "tech: the ETF profile does not apply candle rejections"
# 0.20 vs 0.25 overheat floor is the profile's, not the caller's
$r=Get-TechScore -Bar $barOk -Ma @{ ma20=90.0; ma20p=88.0; ma60=80.0; ret5=0.22; dist=-0.02 } -Light 'red' -Profile $PE_
Assert ($r.Drop) "tech: ETF overheats earlier (0.20) than a stock (0.25)"
# scoring and clamps
$r=Get-TechScore -Bar $barOk -Ma $maOk -Light 'red' -Profile $PS
Assert ($r.Raw -eq 27) "tech: 10+8+5+4 above all lines, near the high (got $($r.Raw))"
$g=Get-TechScore -Bar $barOk -Ma @{ ma20=90.0; ma20p=88.0; ma60=80.0; ret5=0.05; dist=-0.02 } -Light 'green' -Profile $PS
Assert ($g.Raw -eq 30) "tech: green-light momentum reward, then clamped at 30 (got $($g.Raw))"
$n=Get-TechScore -Bar $barOk -Ma @{ ma20=90.0; ma20p=88.0; ma60=80.0; ret5=0.05; dist=-0.02 } -Light 'na' -Profile $PS
Assert ($n.Raw -eq 27) "tech: Light='na' (the backtest panel) skips the momentum reward"

# fundamentals
Assert ((Get-FundScore -YoY 120 -PE 12 -DividendYield 5 -Light 'green').Raw -eq 30) "fund: strong on all three, capped at 30"
Assert ((Get-FundScore -YoY $null -PE $null -DividendYield $null -Light 'red').Raw -eq 0) "fund: nothing known = 0, never a guess"
Assert ((Get-FundScore -YoY 5 -PE 12 -DividendYield 4 -Light 'red').Raw -gt (Get-FundScore -YoY 5 -PE 12 -DividendYield 4 -Light 'green').Raw) "fund: non-green regimes reward defensive traits"
Assert ((Get-FundScore -YoY 0 -PE -3 -DividendYield 0 -Light 'red').Raw -eq 0) "fund: a negative PE scores nothing (loss-making)"
# mom / yoyCum are surfaced as signals but must not (yet) move the score - they have no
# out-of-sample validation, and fund factors cannot be backtested at all (no revenue history)
$fA=Get-FundScore -YoY 40 -PE 20 -DividendYield 1 -Light 'red'
$fB=Get-FundScore -YoY 40 -PE 20 -DividendYield 1 -Light 'red' -MoM -30 -YoYCum -15
Assert ($fA.Raw -eq $fB.Raw) "fund: revenue acceleration is reported, not yet scored (needs backtest.ps1's gate)"
Assert (@($fB.Signals | Where-Object { $_.key -eq 'mom' }).Count -eq 1 -and @($fB.Signals | Where-Object { $_.key -eq 'yoyCum' }).Count -eq 1) "fund: mom and cumulative YoY reach the signal list"
Assert (@($fA.Signals | Where-Object { $_.key -eq 'mom' }).Count -eq 0) "fund: absent fundamentals emit no signal rather than a zero"

# --- three-face normalisation + composite -----------------------------------------------------
# The faces used to be scored out of 40/30/30 and summed, so a stock maxed at 100 and an ETF at
# 70 - two different scales printed side by side in the same list. Each face is now 0-100 and the
# composite is a weighted average.
$fullChip=Get-ChipScore -Stats (Get-ChipStats -Trust @(1,1,1,1,1,1,1) -Foreign @(1,1,1,1,1,1,1)) -MarginDown $true
Assert ($fullChip.Raw -eq 40 -and $fullChip.Score -eq 100) "faces: a maxed chip face is 40 raw = 100 normalised"
Assert ((Get-FundScore -YoY 120 -PE 12 -DividendYield 5 -Light 'green').Score -eq 100) "faces: a maxed fund face normalises to 100"
Assert ($r.Score -eq [math]::Round(27/30*100,1)) "faces: tech normalises against its own 30-point maximum (got $($r.Score))"
# THE property that made this rewrite safe to ship: with weights set to the old maxima as
# fractions, the composite is arithmetically identical to the sum it replaced. Any future weight
# change breaks this equality on purpose - and must go through backtest.ps1's out-of-sample gate.
$cS=Get-ChipScore -Stats $stTrust2                                   # raw 15
$tS=$r                                                                # raw 27
$fS=Get-FundScore -YoY 40 -PE 20 -DividendYield 1 -Light 'red'        # raw 16
$comp=Get-CompositeScore -Tech $tS -Chip $cS -Fund $fS -Profile $PS
Assert ([math]::Abs($comp.Total-($cS.Raw+$tS.Raw+$fS.Raw)) -lt 0.05) "composite: stock weights reproduce the old chip+tech+fund sum exactly (got $($comp.Total) vs $($cS.Raw+$tS.Raw+$fS.Raw))"
# ETF: no fund face at all, and its weight is redistributed rather than scored as zero
$compE=Get-CompositeScore -Tech $tS -Chip $cS -Fund $null -Profile $PE_
Assert ($compE.Total -gt 0 -and $compE.Total -le 100) "composite: an ETF still lands on the 0-100 scale (got $($compE.Total))"
$compEzero=Get-CompositeScore -Tech $tS -Chip $cS -Fund (New-FaceScore -Raw 0 -Face 'fund') -Profile $PS
Assert ($compE.Total -gt $compEzero.Total) "composite: a missing fund face is redistributed, not scored as a zero"
Assert ([math]::Abs($compE.Total-((($cS.Raw+$tS.Raw)/70)*100)) -lt 0.05) "composite: ETF weights are a pure rescale of chip+tech, so ETF ranking is unchanged (got $($compE.Total))"
# signals are the page's number row: every scoring factor must be itemised
foreach($k in @('trustDays','foreignDays','marginDown')){
  Assert (@($fullChip.Signals | Where-Object { $_.key -eq $k }).Count -eq 1) "signals: chip itemises '$k'"
}
foreach($k in @('ma20','ma60','ma20slope','distHigh40')){
  Assert (@($r.Signals | Where-Object { $_.key -eq $k }).Count -eq 1) "signals: tech itemises '$k'"
}
Assert ((@($r.Signals | Measure-Object -Property pts -Sum).Sum) -eq $r.Raw) "signals: the itemised points add up to the face's raw score (got $((@($r.Signals | Measure-Object -Property pts -Sum).Sum)) vs $($r.Raw))"
# a rejection stays a rejection, and carries no misleading signal list
$dropF=Get-TechScore -Bar $barOk -Ma @{ ma20=90.0; ma20p=88.0; ma60=80.0; ret5=0.30; dist=-0.02 } -Light 'red' -Profile $PS
Assert ($dropF.Drop -and $dropF.Score -eq 0 -and @($dropF.Signals).Count -eq 0) "faces: a dropped name scores 0 with no signals to read"

# total-return series: the dividend add-back that keeps an ex-div gap from faking a break
$bars=@(
  @{ c=100.0; chg=0.0 },
  @{ c=98.0;  chg=1.0 },    # dv = 1-(98-100) = 3 -> counted
  @{ c=99.0;  chg=1.0 }     # dv = 1-(99-98)  = 0 -> nothing
)
$tr=Get-TotalReturnSeries $bars
Assert ([math]::Abs($tr.Cum-3.0) -lt 1e-9) "total-return: one 3.0 dividend added back (got $($tr.Cum))"
Assert ([math]::Abs($tr.Series[2]-102.0) -lt 1e-9) "total-return: later closes carry the payout (got $($tr.Series[2]))"
$capBars=@( @{ c=100.0; chg=0.0 }, @{ c=50.0; chg=2.0 } )   # dv=52 = 52% -> capital reduction, ignored
Assert ([math]::Abs((Get-TotalReturnSeries $capBars).Cum) -lt 1e-9) "total-return: a >10% gap is a capital reduction, not a dividend"

# exit rules, in priority order
$flat=@(); for($i=0;$i -lt 25;$i++){ $flat += 100.0 }
Assert ((Test-ExitRules -ForeignNet @(-1,-1) -TotalReturnSeries $flat -Current 100.0 -ReturnPct 0) -eq '外資連2日轉賣') "exit: foreign selling two days running wins first"
Assert ($null -eq (Test-ExitRules -ForeignNet @(-1,1) -TotalReturnSeries $flat -Current 100.0 -ReturnPct 0)) "exit: one down day is not the rule"
Assert ((Test-ExitRules -ForeignNet @(1,1) -TotalReturnSeries $flat -Current 90.0 -ReturnPct 0) -eq '跌破月線') "exit: close below the 20-day line"
# a rising series: MA10 (recent, high) sits ABOVE MA20 (older, lower), so a pullback can break
# the 10-day line while still holding the 20-day one - which is the only way to reach the
# trailing rule at all. A flat series cannot: below MA10 there always means below MA20 too.
$rise=@(); for($i=0;$i -lt 15;$i++){ $rise += 90.0 }; for($i=0;$i -lt 10;$i++){ $rise += 110.0 }
$ma20r=Get-ScoreSma $rise 20; $ma10r=Get-ScoreSma $rise 10
Assert ($ma20r -eq 100.0 -and $ma10r -eq 110.0) "exit fixture: MA20=100 < MA10=110 as intended (got $ma20r/$ma10r)"
Assert ((Test-ExitRules -ForeignNet @(1,1) -TotalReturnSeries $rise -Current 107.0 -ReturnPct 20) -eq '移動停利（獲利15%+回檔破10日線）') "exit: trailing take-profit once up 15%"
Assert ($null -eq (Test-ExitRules -ForeignNet @(1,1) -TotalReturnSeries $rise -Current 107.0 -ReturnPct 5)) "exit: below MA10 but under 15% profit is not an exit"
Assert ((Test-ExitRules -ForeignNet @(1,1) -TotalReturnSeries $rise -Current 95.0 -ReturnPct 20) -eq '跌破月線') "exit: the 20-day break outranks the trailing rule"
$short=@(100.0,100.0,100.0)
Assert ($null -eq (Test-ExitRules -ForeignNet @(1,1) -TotalReturnSeries $short -Current 50.0 -ReturnPct 0)) "exit: under 20 bars of history, no MA rule fires"

# the profiles differ only where they are meant to
Assert ($PS.tSumMin -ne $PE_.tSumMin -and $PS.overheatRet5 -ne $PE_.overheatRet5) "profiles: stock and ETF differ on thresholds"
Assert ($PS.useCandles -and -not $PE_.useCandles) "profiles: candle structure is stock-only"
# and screen.ps1 no longer carries its own copy of any of it
$scrSrc = Get-Content (Join-Path $root 'screen.ps1') -Raw -Encoding UTF8
Assert ($scrSrc -notmatch '\[math\]::Min\(25,\s*\$tPos\*5\)') "screen.ps1 no longer inlines the chip score"
Assert ($scrSrc -match 'Get-TechScore') "screen.ps1 scores through the module"
$btSrc = Get-Content (Join-Path $root 'backtest.ps1') -Raw -Encoding UTF8
Assert ($btSrc -match 'Get-TechScore') "backtest.ps1 replays production scoring, not a transcription"
Assert ($btSrc -notmatch '\$techS\+=10') "backtest.ps1 no longer carries its own tech ladder"

Write-Host "[12] shared design tokens across the four HTML pages..."
# CSP (style-src 'unsafe-inline', no 'self') blocks an external stylesheet on all four pages, so
# the token block has to be duplicated. Duplication is only safe if drift is detectable: the three
# server pages must carry a byte-identical block, and every colour value in it must still match
# index.html. Without this the pages silently diverge one edit at a time (they already had).
$staticDir = Join-Path $root 'server/static'
$sharedBlocks = @{}
foreach($pg in @('login.html','admin.html','pending.html')){
  $txt = Get-Content (Join-Path $staticDir $pg) -Raw -Encoding UTF8
  $m = [regex]::Match($txt, '/\* SHARED-TOKENS-START.*?/\* SHARED-TOKENS-END \*/', 'Singleline')
  Assert $m.Success "$pg carries the shared token block"
  if($m.Success){ $sharedBlocks[$pg] = $m.Value }
}
if($sharedBlocks.Count -eq 3){
  $distinct = ($sharedBlocks.Values | Select-Object -Unique)
  Assert (@($distinct).Count -eq 1) "the three server pages' token blocks are byte-identical"
  # and the values in it must still agree with index.html's single source
  $idxTok = Get-Content (Join-Path $root 'index.html') -Raw -Encoding UTF8
  $drift = @()
  foreach($pair in @(
      @('bg','#f5f6f9','#0e121b'), @('surface','#fff','#161c28'), @('line','#dfe2ea','#2a3346'),
      @('ink','#1a1e27','#e7eaf1'), @('accent','#b6842f','#d9ad57'),
      @('on-accent','#fff','#0e121b'), @('up','#d0342c','#ff5d51'), @('down','#12885e','#34c48d'),
      @('hold','#9a7a1e','#e0b955'))){
    $name,$light,$dark = $pair
    if($idxTok -notmatch [regex]::Escape("--l-$name`:$light")){ $drift += "index --l-$name != $light" }
    if($idxTok -notmatch [regex]::Escape("--d-$name`:$dark")){  $drift += "index --d-$name != $dark" }
    if($sharedBlocks['login.html'] -notmatch [regex]::Escape("--$name`:$light")){ $drift += "static --$name light != $light" }
    if($sharedBlocks['login.html'] -notmatch [regex]::Escape("--$name`:$dark")){  $drift += "static --$name dark != $dark" }
  }
  Assert ($drift.Count -eq 0) "index.html and the static pages agree on every shared colour ($($drift -join '; '))"
}
# the four #fff-on-accent rules are gone for good (--on-accent exists precisely for them)
$idxAllTok = Get-Content (Join-Path $root 'index.html') -Raw -Encoding UTF8
Assert ($idxAllTok -notmatch 'aria-pressed="true"\][^{}]*\{[^{}]*(color|background):#fff') "index.html: pressed chips use --on-accent, not #fff"

Write-Host "[13] index heavyweights (owner-controlled constituent context)..."
# Why this exists at all: the portfolio is entirely ETFs, so "what are the constituents doing"
# had no data source the owner controlled - the daily AI step was reading it out of the
# all-users context file, making analysis quality depend on which stocks OTHER people held.

# a. both boards parse, and their schemas are genuinely different (the T86/TpexInsti trap again)
Assert ($FeedFields.CompanyTwse.code -ne $FeedFields.CompanyTpex.code) "company basics: the two boards do not share a code field name"
Assert ($FeedFields.CompanyTwse.shares -ne $FeedFields.CompanyTpex.shares) "company basics: the two boards do not share a shares field name"

$twseRows = @(
  [pscustomobject]@{ '公司代號'='2330'; '公司簡稱'='台積電';   '已發行普通股數或TDR原股發行股數'='25932370067' }
  [pscustomobject]@{ '公司代號'='2327'; '公司簡稱'='國巨*';    '已發行普通股數或TDR原股發行股數'='2071000000' }
  [pscustomobject]@{ '公司代號'='9105'; '公司簡稱'='泰金寶-DR'; '已發行普通股數或TDR原股發行股數'='9000000000' }
  [pscustomobject]@{ '公司代號'='6949'; '公司簡稱'='沛爾生醫-創'; '已發行普通股數或TDR原股發行股數'='500000000' }
  [pscustomobject]@{ '公司代號'='1234'; '公司簡稱'='沒股數';    '已發行普通股數或TDR原股發行股數'='--' }
)
$tpexRows = @(
  [pscustomobject]@{ SecuritiesCompanyCode='5274'; CompanyAbbreviation='信驊'; IssueShares='37802685' }
  [pscustomobject]@{ SecuritiesCompanyCode='2330'; CompanyAbbreviation='不該蓋掉上市的'; IssueShares='1' }
)
Set-FeedTransport {
  param($u)
  if($u -match 't187ap03_L'){ return $twseRows }
  if($u -match 'mopsfin_t187ap03_O'){ return $tpexRows }
  return $null
}
$sh=Get-FeedIssuedShares
Assert ($sh.Ok) "issued shares: both boards parsed"
Assert ($sh.Rows['2330'].shares -eq 25932370067) "issued shares read from the named field (got $($sh.Rows['2330'].shares))"
Assert ($sh.Rows['2330'].market -eq 't' -and $sh.Rows['5274'].market -eq 'o') "issued shares tag the board they came from"
Assert ($sh.Rows['5274'].shares -eq 37802685) "TPEx IssueShares parsed via its own field names (got $($sh.Rows['5274'].shares))"
Assert (-not $sh.Rows.ContainsKey('1234')) "a '--' share count drops the row rather than becoming 0"
# 5274 信驊 measured rank 30 on 2026-07-31: TWSE-only would have got the last slot wrong
Assert ($sh.Rows['2330'].shares -ne 1) "a code on both boards keeps the TWSE row (TPEx must not overwrite)"

# b. one board down is survivable; both down is not
Set-FeedTransport { param($u) if($u -match 't187ap03_L'){ return $twseRows }; return $null }
$sh1=Get-FeedIssuedShares
Assert ($sh1.Ok -and $sh1.Rows.Count -gt 0 -and -not $sh1.Rows.ContainsKey('5274')) "one board down still returns the other board"
Set-FeedTransport { param($u) return $null }
Assert (-not (Get-FeedIssuedShares).Ok) "both boards down reports Ok=false"
Set-FeedTransport $null

# c. the ranking rule itself (pure - no transport needed)
$profF=@{
  '2330'=@{ name='台積電';    shares=25932370067 }
  '2327'=@{ name='國巨*';     shares=2071000000 }   # par 2.5: capital/10 would say 518,000,000
  '9105'=@{ name='泰金寶-DR'; shares=9000000000 }
  '6949'=@{ name='沛爾生醫-創'; shares=500000000 }
  '8888'=@{ name='高價少股';  shares=1000000000 }
  '7777'=@{ name='沒報價';    shares=9999999999 }
  '6666'=@{ name='停牌';      shares=9999999999 }
}
$quoF=@{
  '2330'=@{ c=2425.0 }; '2327'=@{ c=502.0 }; '9105'=@{ c=20.0 }
  '6949'=@{ c=300.0 };  '8888'=@{ c=700.0 }; '6666'=@{ c=0.0 }
}
$rank=Select-FeedTopByMarketCap -Profile $profF -Quotes $quoF -Top 10
Assert ($rank[0] -eq '2330') "ranking is by shares x close, biggest first"
# 2327 x its real share count beats 8888; via capital/10 (518m x 502) it would lose. This is the
# regression test for "never derive the share count from paid-in capital / par value".
Assert ($rank.IndexOf('2327') -lt $rank.IndexOf('8888')) "share count comes from the issued-shares field, not capital/par"
Assert ($rank -notcontains '9105') "TDR excluded (parent's share count against a depositary price)"
Assert ($rank -notcontains '6949') "創新板 excluded (measured 10,362億 on 2026-07-31 = rank 16)"
Assert ($rank -notcontains '7777') "a code with no quote drops out instead of ranking as zero"
Assert ($rank -notcontains '6666') "a zero close drops out instead of ranking as zero"
Assert ((Select-FeedTopByMarketCap -Profile $profF -Quotes $quoF -Top 2).Count -eq 2) "-Top caps the list"
Assert ((Select-FeedTopByMarketCap -Profile $null -Quotes $quoF).Count -eq 0) "a missing profile map yields an empty list, not a throw"

# d. the fetch/context split that protects the Gemini batch. codes-context.json is gnotes.py's
# entire input and its length sets the request count (BATCH=40); heavyweights must never widen
# it. This asserts the wiring in update-holdings.ps1 rather than trusting the comment.
$uh=Get-Content (Join-Path $root 'update-holdings.ps1') -Raw -Encoding UTF8
Assert ($uh -match '\$allContext=@\(\)\s*\r?\n\s*foreach\(\$c in \$codes\)') "codes-context.json still iterates `$codes, not `$fetchCodes"
Assert ($uh -match 'heavyweights-context\.json') "heavyweights get their own context file"
Assert ($uh -match '\$fetchCodes = @\(@\(\$codes\) \+ @\(\$hwCodes\) \| Select-Object -Unique\)') "heavyweights join the fetch set but not `$codes, deduped"
# The constituent view must not depend on who else registered. Subtracting the whole user union
# (the pre-2026-08-02 wording, `$codes) deleted any heavyweight a guest happened to hold: 8 of 30
# vanished on 2026-08-02, 2330 among them. Only the OWNER's holdings may be subtracted - that is
# the codes the daily prompt is forbidden to name.
Assert ($uh -match 'Where-Object \{ \$_ -and \$ownCodes -notcontains \$_ \} \| Select-Object -Unique\)\s*\r?\n\s*Write-Host "  heavyweights:') "heavyweights subtract the owner's holdings, not the whole user union"
# the FATAL guard is now graded: owner short series aborts, anyone else's is skipped
Assert ($uh -match '\$emptyOwn=@\(\$ownCodes \|') "FATAL guard tests the owner's holdings only"
Assert ($uh -match 'WARN: series too short, skipping today') "a non-owner short series is skipped, not fatal"
# quotes.json goes out on every server page load. Heavyweights are held by nobody, so shipping
# their series added ~150KB per request to render nothing - measured, then fixed.
Assert ($uh -match ([regex]::Escape('foreach($k in $DASH.Keys){ if($k -eq ''TAIEX'' -or $codes -contains $k){ $DASHOut'))) "quotes.json ships holdings only, never the heavyweights"
# grading and stance-log stay on $codes: heavyweights must not dilute evaluate.ps1's sample
Assert ($uh -notmatch '\$psAll\[\$c\]=\$prevStanceMap\[\$c\]\.s \}[\s\S]{0,200}\$fetchCodes') "stance history stays on holdings, not the fetch set"

Write-Host ""
Write-Host "[14] overnight drivers (third-party, must fail open)..."
# The 20:00 schedule fires before the US opens, so the last US close is already inside the Taiwan
# session that just ended. These numbers are the part that is NOT priced in yet. Everything here
# runs through Set-FeedTransport, so the parsing is exercised without a network.

# a. the shape Yahoo actually returns. Bars, not meta: `previousClose` is absent on indices and
#    `chartPreviousClose` is the close before the whole range window - reading either as
#    "yesterday" yields a plausible, wrong percentage.
$soxFixture = @{
  chart = @{ result = @(@{
    meta = @{ symbol='^SOX'; regularMarketPrice=11311.075; regularMarketTime=1785532559
              chartPreviousClose=14246.96 }
    # the real 2026-07-24..07-31 sessions, at 13:30 UTC = the 09:30 ET open
    timestamp  = @(1784899800,1785159000,1785245400,1785331800,1785418200,1785504600)
    indicators = @{ quote = @(@{ close=@(11818.88,11554.88,11035.68,10447.49,11302.99,11311.08) }) }
  }) }
}
Set-FeedTransport { param($u) if($u -match 'query1\.finance\.yahoo\.com'){ return $soxFixture }; return $null }
$us=Get-FeedUsChart -Symbol '^SOX'
Assert ($us.Ok) "US chart: fixture parsed"
Assert ($us.Bars.Count -eq 6) "US chart: one bar per timestamp (got $($us.Bars.Count))"
Assert ($us.Bars[0].d -eq '2026-07-24' -and $us.Bars[5].d -eq '2026-07-31') "US chart: bar timestamps become US trading dates"
Assert ($us.Last -eq 11311.075) "US chart: Last is the live quote, not the last bar"
Assert ($us.Bars[3].c -eq 10447.49) "US chart: closes land in bar order"

# b. nulls and malformed responses must degrade, never throw. A holiday arrives as a null close;
#    a shape change arrives as a missing branch; 429 arrives as $null from the transport.
$holed = @{ chart = @{ result = @(@{
  meta=@{ symbol='^SOX'; regularMarketPrice=100.0 }
  timestamp=@(1784727000,1784986200,1785072600)
  indicators=@{ quote=@(@{ close=@(10.0,$null,12.0) }) } }) } }
Set-FeedTransport { param($u) return $holed }
$h=Get-FeedUsChart -Symbol '^SOX'
Assert ($h.Ok -and $h.Bars.Count -eq 2) "US chart: a null close drops that bar rather than becoming 0"
Set-FeedTransport { param($u) return @{ chart=@{ result=@() } } }
Assert (-not (Get-FeedUsChart -Symbol '^SOX').Ok) "US chart: an empty result reports Ok=false"
Set-FeedTransport { param($u) return @{ nothing='useful' } }
Assert (-not (Get-FeedUsChart -Symbol '^SOX').Ok) "US chart: an unrecognised shape reports Ok=false, no throw"
Set-FeedTransport { param($u) return $null }
Assert (-not (Get-FeedUsChart -Symbol '^SOX').Ok) "US chart: a failed fetch (429/offline) reports Ok=false"
Set-FeedTransport $null

# c. every symbol the daily run needs is declared, and the ADR ratio is not a magic number
Assert ($FeedUsSymbols.Contains('sox') -and $FeedUsSymbols.Contains('nq') -and $FeedUsSymbols.Contains('tsm') -and $FeedUsSymbols.Contains('twd')) "overnight symbol table covers index, future, ADR and FX"
$ov=Get-Content (Join-Path $root 'overnight.ps1') -Raw -Encoding UTF8
Assert ($ov -match '\$AdrRatio\s*=\s*5') "1 ADR = 5 TWSE shares, named rather than inlined"

# c2. the date arithmetic, on the real week the miss happened in. `sox` is a WEEK-to-date figure,
#     so the baseline is the last close BEFORE Monday - five sessions back is a different, and
#     wrong, number. Hand-typed on 2026-07-30 as -10.1%; the bars say -11.60%.
. (Join-Path $root 'overnight.ps1') -DefineOnly
Assert ((WeekStart '2026-07-31') -eq '2026-07-27') "week starts Monday (Friday input)"
Assert ((WeekStart '2026-07-27') -eq '2026-07-27') "week starts Monday (Monday input is its own start)"
Assert ((WeekStart '2026-07-26') -eq '2026-07-20') "week starts Monday (Sunday belongs to the week just ended)"
$wkBars=@(
  @{d='2026-07-24'; c=11818.88}, @{d='2026-07-27'; c=11554.88}, @{d='2026-07-28'; c=11035.68}
  @{d='2026-07-29'; c=10447.49}, @{d='2026-07-30'; c=11302.99}
)
Assert ((LastBarBefore $wkBars (WeekStart '2026-07-29')).d -eq '2026-07-24') "week-to-date baseline is the last close before Monday"
Assert ((Pct 10447.49 (LastBarBefore $wkBars (WeekStart '2026-07-29')).c) -eq -11.60) "SOX week-to-date on the day of the miss (2026-07-29 close)"
Assert ((Pct 11302.99 10447.49) -eq 8.19) "the +8.19% session the 20:00 run could not see yet"
Assert ($null -eq (Pct 100 $null) -and $null -eq (Pct 100 0)) "a missing or zero baseline yields null, not a divide-by-zero"
Assert ($null -eq (LastBarBefore $wkBars '2026-07-24')) "no earlier bar yields null rather than the first bar"

# d. fail-open, asserted on the wiring. A stale snapshot is worse than a missing one here:
#    yesterday's futures quote read as tonight's is a wrong number the analysis step cannot
#    detect, whereas a missing file is a documented "skip this section".
Assert ($ov -match 'Remove-Item \$outPath -Force') "a total failure deletes the stale snapshot"
Assert ($ov -match "exit 0\s*\r?\n?\s*\}") "a total failure still exits 0 - the daily run continues"
Assert ($ov -notmatch "\`$ErrorActionPreference='Stop'") "overnight.ps1 must not abort the fetch phase"
Assert ($ov -match "asOf=\(Get-Date\)") "the snapshot stamps asOf so staleness is detectable"
# the premium needs the FX rate AND 2330; a partial one would be a wrong number, not a gap
Assert ($ov -match "if\(\`$q\.ContainsKey\('tsm'\) -and \`$q\.ContainsKey\('twd'\)\)") "ADR premium requires both the ADR and the FX rate"
# run-daily.sh must call it best-effort, and last: nq/tsm/twd are live quotes
$rd=Get-Content (Join-Path $root 'run-daily.sh') -Raw -Encoding UTF8
Assert ($rd -match 'overnight\.ps1 \|\| true') "run-daily.sh calls overnight.ps1 best-effort"

Write-Host ""
if($fails.Count -eq 0){ Write-Host "ALL TESTS PASSED"; exit 0 }
else { Write-Host "FAILED: $($fails.Count) test(s): $($fails -join '; ')"; exit 1 }
