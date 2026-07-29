# build-demo.ps1 - rebuild the PUBLIC, committed index.html from the de-identified demo
# portfolio in holdings.json.
#
# Why this exists: in server mode update-holdings.ps1 analyses the OWNER's real portfolio
# (data/owner-holdings.json) and splices it into index.html. Committing that would publish a
# real person's holdings to GitHub Pages - exactly what moving to a server was meant to stop.
# So this must overwrite the personal blocks with demo data as the LAST step before the commit.
# It is therefore invoked from inside publish.ps1, after that script splices the owner's notes -
# do not call it before publish.ps1, or the splice will simply undo everything here.
#
# Costs nothing: it re-uses data/quotes.json that the daily fetch already produced (the demo
# codes are part of the fetch union via admin.py export-codes), and makes no network calls.
#
# Run:  pwsh -File build-demo.ps1
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/pagedata.ps1')   # Set-PageBlocks / Get-PageBlockText / Get-PageContract
$dataDir = Join-Path $root 'data'
$idxPath = Join-Path $root 'index.html'

function ReadJson($path){
  if(-not (Test-Path $path)){ return $null }
  try{ return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }catch{ return $null }
}
# Quantities are shares. A `lots` key means the file predates that change (or came from an older
# clone) - convert instead of rejecting, 1 lot = 1000 shares.
function SharesOf($h){
  if($h.PSObject.Properties['shares'] -and $null -ne $h.shares){ return [int]$h.shares }
  if($h.PSObject.Properties['lots'] -and $null -ne $h.lots){ return [int]([double]$h.lots * 1000) }
  return 0
}

$quotes = ReadJson (Join-Path $dataDir 'quotes.json')
if($null -eq $quotes){ Write-Host "FATAL: data/quotes.json missing or unreadable - run update-holdings.ps1 first"; exit 1 }
$demo = ReadJson (Join-Path $root 'holdings.json')
if($null -eq $demo -or -not $demo.holdings){ Write-Host "FATAL: holdings.json missing or has no holdings"; exit 1 }

$demoCodes = @($demo.holdings | ForEach-Object { "$($_.code)" })
Write-Host "demo portfolio: $($demoCodes -join ', ')"

# guard: a demo code with no quotes would splice a DASH the page cannot render (DASH[c].series)
$missing = @($demoCodes | Where-Object { -not $quotes.PSObject.Properties["$_"] })
if($missing.Count){
  Write-Host "FATAL: no quotes for $($missing -join ', ') - add them to the fetch union (they are"
  Write-Host "       picked up automatically once holdings.json lists them and the daily run happens)"
  exit 1
}

# DASH: index history + demo codes only
$DASH=[ordered]@{}
$DASH['TAIEX'] = $quotes.TAIEX
foreach($c in $demoCodes){ $DASH[$c] = $quotes.$c }

# HOLDINGS_META from the demo file; no trades are published
$sharedMeta = ReadJson (Join-Path $dataDir 'holdings-meta.json')
$HOLDINGS_META=[ordered]@{}
$HOLDINGS_META['_trades']=@($demo.trades | ForEach-Object { [ordered]@{ d=$_.d; side=$_.side; code="$($_.code)"; shares=(SharesOf $_); price=$_.price } })
foreach($h in $demo.holdings){
  $c="$($h.code)"
  $divNote = $null
  if($sharedMeta -and $sharedMeta.PSObject.Properties[$c]){ $divNote = $sharedMeta.$c.divNote }
  # prevStance per DEMO code only (rule-engine output on public quotes - not personal).
  # The union `_prevStance` map must NEVER be copied here: its key set is the union of every
  # user's holdings, and publishing it would leak which codes users hold.
  $prevStance = $null
  if($sharedMeta -and $sharedMeta.PSObject.Properties['_prevStance'] -and $sharedMeta._prevStance.PSObject.Properties[$c]){ $prevStance = $sharedMeta._prevStance.$c }
  # today's rule-engine grade, per demo code. The page renders this instead of recomputing the
  # judgement formula in JS; without it a demo holding shows no stance badge at all.
  $stance = $null
  if($sharedMeta -and $sharedMeta.PSObject.Properties[$c]){ $stance = $sharedMeta.$c.stance }
  $HOLDINGS_META[$c]=[ordered]@{
    name=$h.name; type=$h.type; theme=$h.theme; shares=(SharesOf $h); color=$h.color
    techLike=$(if($h.PSObject.Properties['techLike']){[bool]$h.techLike}else{$false}); divNote=$divNote
    prevStance=$prevStance; stance=$stance
  }
}

# NOTES: same rule the server applies to guests - code-level factual fields only. `rec` and
# `news` are advice written for the owner's portfolio and must not be published. The field list
# is page-contract.json's `noteFields.guest`, the same one server/payload.py filters guests
# with, so the published page and a logged-in guest can never disagree about what is factual.
$guestFields = @((Get-PageContract).noteFields.guest)
if($guestFields.Count -eq 0){ Write-Host "FATAL: page-contract.json has no noteFields.guest"; exit 1 }
$marketFields = @((Get-PageContract).noteFields.marketPublic)
if($marketFields.Count -eq 0){ Write-Host "FATAL: page-contract.json has no noteFields.marketPublic"; exit 1 }
$allNotes = ReadJson (Join-Path $root 'holdings-notes.json')
$NOTES=[ordered]@{}
if($allNotes){
  # _market: allowlist only, from page-contract.json's `noteFields.marketPublic` - the same list
  # server/payload.py slims _market with. `wind` is deliberately not on it: it is written as
  # commentary on the OWNER's portfolio ("投組今日明顯分化：00990A...") and names real holdings,
  # so publishing it would leak the very thing this script exists to hide. buildWind() renders
  # correctly from windLead alone.
  if($allNotes.PSObject.Properties['_market']){
    $mk=[ordered]@{}
    foreach($f in $marketFields){
      if($allNotes._market.PSObject.Properties[$f]){ $mk[$f]=$allNotes._market.$f }
    }
    if($mk.Count){ $NOTES['_market']=$mk }
  }
  # A per-code note is written with the whole owner portfolio in view, so it can name other
  # holdings ("成分股與0050/00947/00981A高度重疊"). Drop any field that mentions one of the
  # owner's OTHER codes - matching the real code list means no false positives on prices.
  $ownerCodes=@()
  $ownerFile = Join-Path $dataDir 'owner-holdings.json'
  if(Test-Path $ownerFile){
    $oj = ReadJson $ownerFile
    if($oj -and $oj.holdings){ $ownerCodes = @($oj.holdings | ForEach-Object { "$($_.code)" }) }
  }
  $dropped=0
  foreach($c in $demoCodes){
    if(-not $allNotes.PSObject.Properties[$c]){ continue }
    $n=$allNotes.$c; $slim=[ordered]@{}
    foreach($f in $guestFields){
      if(-not $n.PSObject.Properties[$f]){ continue }
      $txt = "$($n.$f)"
      $leaks = @($ownerCodes | Where-Object { $_ -ne $c -and $txt.Contains($_) })
      if($leaks.Count){ $dropped++; continue }
      $slim[$f]=$n.$f
    }
    if($slim.Count){ $NOTES[$c]=$slim }
  }
  if($dropped){ Write-Host "  dropped $dropped note field(s) that named other owner holdings" }
}

Set-PageBlocks -IndexPath $idxPath -Blocks @{
  dashdata      = $DASH
  holdingsmeta  = $HOLDINGS_META
  holdingsnotes = $NOTES
  # appuser is server-injected per request; it must stay empty in the committed file
  appuser       = $null
}
Write-Host "index.html rebuilt for public demo ($($demoCodes.Count) holdings, $($NOTES.Count) note entries)"
