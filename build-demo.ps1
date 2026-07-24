# build-demo.ps1 - rebuild the PUBLIC, committed index.html from the de-identified demo
# portfolio in holdings.json.
#
# Why this exists: in server mode update-holdings.ps1 analyses the OWNER's real portfolio
# (data/owner-holdings.json) and splices it into index.html. Committing that would publish a
# real person's holdings to GitHub Pages - exactly what moving to a server was meant to stop.
# So this runs last, before publish.ps1, and overwrites the personal blocks with demo data.
#
# Costs nothing: it re-uses data/quotes.json that the daily fetch already produced (the demo
# codes are part of the fetch union via admin.py export-codes), and makes no network calls.
#
# Run:  pwsh -File build-demo.ps1
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $root 'data'
$idxPath = Join-Path $root 'index.html'

function ReadJson($path){
  if(-not (Test-Path $path)){ return $null }
  try{ return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }catch{ return $null }
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
$HOLDINGS_META['_trades']=@($demo.trades)
foreach($h in $demo.holdings){
  $c="$($h.code)"
  $divNote = $null
  if($sharedMeta -and $sharedMeta.PSObject.Properties[$c]){ $divNote = $sharedMeta.$c.divNote }
  # prevStance per DEMO code only (rule-engine output on public quotes - not personal).
  # The union `_prevStance` map must NEVER be copied here: its key set is the union of every
  # user's holdings, and publishing it would leak which codes users hold.
  $prevStance = $null
  if($sharedMeta -and $sharedMeta.PSObject.Properties['_prevStance'] -and $sharedMeta._prevStance.PSObject.Properties[$c]){ $prevStance = $sharedMeta._prevStance.$c }
  $HOLDINGS_META[$c]=[ordered]@{
    name=$h.name; type=$h.type; theme=$h.theme; lots=$h.lots; color=$h.color
    techLike=$(if($h.PSObject.Properties['techLike']){[bool]$h.techLike}else{$false}); divNote=$divNote; prevStance=$prevStance
  }
}

# NOTES: same rule the server applies to guests - code-level factual fields only. `rec` and
# `news` are advice written for the owner's portfolio and must not be published.
$allNotes = ReadJson (Join-Path $root 'holdings-notes.json')
$NOTES=[ordered]@{}
if($allNotes){
  # _market: allowlist only. `wind` is written as commentary on the OWNER's portfolio
  # ("投組今日明顯分化：00990A...") and names real holdings - publishing it would leak the very
  # thing this script exists to hide. buildWind() renders correctly from windLead alone.
  if($allNotes.PSObject.Properties['_market']){
    $mk=[ordered]@{}
    foreach($f in @('windLead','sox','mood','moodK')){
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
    foreach($f in @('sigFund','tech','chip','fund')){
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

$enc=New-Object System.Text.UTF8Encoding($false)
$html=[IO.File]::ReadAllText($idxPath,$enc)
function Splice([string]$html,[string]$marker,[string]$payload){
  $st='<script id="'+$marker+'">'
  $i1=$html.IndexOf($st)
  if($i1 -lt 0){ Write-Host "  marker $marker not found - skip"; return $html }
  $i2=$html.IndexOf('</script>',$i1)
  return $html.Substring(0,$i1+$st.Length)+$payload+$html.Substring($i2)
}
$html = Splice $html 'dashdata'      ('window.DASH='+($DASH|ConvertTo-Json -Depth 6 -Compress)+';')
$html = Splice $html 'holdingsmeta'  ('window.HOLDINGS_META='+($HOLDINGS_META|ConvertTo-Json -Depth 4 -Compress)+';')
$html = Splice $html 'holdingsnotes' ('window.HOLDINGS_NOTES='+($NOTES|ConvertTo-Json -Depth 5 -Compress)+';')
# appuser is server-injected per request; it must stay empty in the committed file
$html = Splice $html 'appuser' ''
[IO.File]::WriteAllText($idxPath,$html,$enc)
Write-Host "index.html rebuilt for public demo ($($demoCodes.Count) holdings, $($NOTES.Count) note entries)"
