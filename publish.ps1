# publish.ps1 - deterministic finishing step for the daily routine.
# Takes small AI-authored note files (holdings-notes.json, picks-notes.json), splices them
# into index.html markers, then commits and pushes. AI never edits the 200KB+ HTML directly
# and never has to chain individual git commands.
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$idxPath = Join-Path $root 'index.html'
$enc = New-Object System.Text.UTF8Encoding($false)
$html = [IO.File]::ReadAllText($idxPath, $enc)

function Splice([string]$html,[string]$marker,[string]$payload){
  $st='<script id="'+$marker+'">'
  $i1=$html.IndexOf($st)
  if($i1 -lt 0){ Write-Host "  marker $marker not found - skip"; return $html }
  $i2=$html.IndexOf('</script>',$i1)
  return $html.Substring(0,$i1+$st.Length)+$payload+$html.Substring($i2)
}

$hnPath = Join-Path $root 'holdings-notes.json'
if(Test-Path $hnPath){
  $hn = Get-Content $hnPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $html = Splice $html 'holdingsnotes' ('window.HOLDINGS_NOTES='+($hn | ConvertTo-Json -Depth 5 -Compress)+';')
  Write-Host "spliced holdings-notes.json -> window.HOLDINGS_NOTES"
} else { Write-Host "no holdings-notes.json found - skipping (holdings text stays as-is)" }

$pnPath = Join-Path $root 'picks-notes.json'
if(Test-Path $pnPath){
  $pn = Get-Content $pnPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $html = Splice $html 'pknotes' ('window.PICKS_NOTES='+($pn | ConvertTo-Json -Depth 4 -Compress)+';')
  Write-Host "spliced picks-notes.json -> window.PICKS_NOTES"
} else { Write-Host "no picks-notes.json found - skipping (pick notes stay as-is)" }

[IO.File]::WriteAllText($idxPath, $html, $enc)

Set-Location $root
git add -A
$today = Get-Date -Format 'yyyy-MM-dd'
$status = git status --porcelain
if([string]::IsNullOrWhiteSpace($status)){
  Write-Host "nothing to commit"
} else {
  git commit -m "daily update $today" | Out-Null
  git push origin main
  Write-Host "committed and pushed: daily update $today"
}