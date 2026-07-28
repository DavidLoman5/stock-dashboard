# tests.ps1 - offline regression suite (no network, runs in seconds)
# Run before committing engine/script changes:  pwsh -File tests.ps1
# Consolidates the smoke tests from the 2026-07-18 v9/v10/v11 health audits:
#  1. syntax-parse all scripts   2. UTF-8 BOM convention   3. DivSumSince dividend cap
#  4. GetDailySeries cache read path (also guards the legacy ConvertFrom-Json array-collapse shape)
#  5. CheckRevCols column-layout warning   6. history-wipe guards present
# ASCII source only. Paths must stay cross-platform (no $env:TEMP - unset on Linux).
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/feed.ps1')
. (Join-Path $root 'lib/pagedata.ps1')
. (Join-Path $root 'lib/publish-gate.ps1')
. (Join-Path $root 'lib/stance.ps1')
$fails=@()
function Assert($ok,$name){ if($ok){ Write-Host "  PASS $name" } else { Write-Host "  FAIL $name"; $script:fails+=$name } }

Write-Host "[1] syntax parse..."
foreach($f in @('screen.ps1','update-holdings.ps1','evaluate.ps1','publish.ps1','backtest.ps1','build-demo.ps1','finish-daily-push.ps1','lib/pagedata.ps1','lib/publish-gate.ps1','lib/stance.ps1','lib/feed.ps1')){
  $tok=$null;$err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f),[ref]$tok,[ref]$err)
  Assert ($err.Count -eq 0) "syntax $f"
  if($err.Count){ $err | ForEach-Object { Write-Host "    $($_.Message) @ line $($_.Extent.StartLineNumber)" } }
}

Write-Host "[2] UTF-8 BOM convention (pwsh 7 does not need it; kept so CJK literals survive a PS5.1/Windows run)..."
foreach($f in @('screen.ps1','update-holdings.ps1','publish.ps1','build-demo.ps1','finish-daily-push.ps1','lib/pagedata.ps1','lib/publish-gate.ps1','lib/stance.ps1','lib/feed.ps1')){
  $b=[IO.File]::ReadAllBytes((Join-Path $root $f))
  Assert ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) "BOM $f"
}

Write-Host "[3] extract functions from screen.ps1..."
# Num/GetJson/GetDailySeries are one-line delegates to lib/feed.ps1 now and are tested
# there directly (section [5]); only the logic screen.ps1 still owns is extracted here.
$tok=$null;$err=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'screen.ps1'),[ref]$tok,[ref]$err)
$fns=$ast.FindAll({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($n in @('DivSumSince','CheckRevCols')){
  $fd=$fns | Where-Object { $_.Name -eq $n } | Select-Object -First 1
  Assert ($null -ne $fd) "function $n exists"
  if($fd){ Invoke-Expression $fd.Extent.Text }
}
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

Set-FeedTransport $null
Remove-Item -Recurse -Force $tmp

Write-Host "[6] CheckRevCols warns on layout change..."
$fake=@([pscustomobject]@{ A=1; B=2; C=3; D=4; E=5; F=6; G=7; H=8; I=9; J=10 })
$msgs=@(CheckRevCols $fake 'fixture' 6>&1)
Assert ($msgs.Count -ge 1 -and "$($msgs[0])" -like '*WARN*') "wrong column names trigger WARN"

Write-Host "[7] history-wipe guards present..."
Assert ($null -ne (Select-String -Path (Join-Path $root 'screen.ps1') -Pattern 'FATAL: picks-log' -SimpleMatch)) "screen.ps1 picks-log guard"
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
foreach($f in @('rec','news','wind')){
  Assert (@($contract.noteFields.ownerOnly) -contains $f) "contract marks '$f' owner-only"
  Assert (@($contract.noteFields.guest) -notcontains $f) "contract never lets '$f' through to guests"
}
$bd = Get-Content (Join-Path $root 'build-demo.ps1') -Raw
Assert ($bd -match 'noteFields\.guest') "build-demo filters by the contract's guest field list"
Assert ($bd -notmatch "'rec'") "build-demo never publishes rec"
# _prevStance's KEY SET is the union of every user's codes; per-demo-code values are fine,
# publishing the map itself would leak which codes users hold
Assert ($bd -notmatch "HOLDINGS_META\['_prevStance'\]") "build-demo never publishes the _prevStance union map"
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
  foreach($f in @('"rec"','"wind"','"news"')){
    Assert (-not $noteBlock.Contains($f)) "index.html at rest carries no owner-only note field $f"
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
# two-day confirmation: a new reading has to repeat before it becomes the level we show/log
$gp1 = Get-StanceGrade $down @() @() 'hold' 'hold'
Assert ($gp1.raw -eq 'exit' -and $gp1.level -eq 'hold' -and $gp1.pending) "stance: first day at a new reading keeps the previous level (got $($gp1.level)/raw $($gp1.raw))"
$gp2 = Get-StanceGrade $down @() @() 'hold' 'exit'
Assert ($gp2.level -eq 'exit' -and -not $gp2.pending) "stance: the same reading two days running switches the level (got $($gp2.level))"
$gp3 = Get-StanceGrade $down @() @() 'hold' 'cut'
Assert ($gp3.level -eq 'hold') "stance: a different pending reading does not confirm (got $($gp3.level))"
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

Write-Host ""
if($fails.Count -eq 0){ Write-Host "ALL TESTS PASSED"; exit 0 }
else { Write-Host "FAILED: $($fails.Count) test(s): $($fails -join '; ')"; exit 1 }
