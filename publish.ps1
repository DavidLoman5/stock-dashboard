# publish.ps1 - deterministic finishing step for the daily routine.
# Takes small AI-authored note files (holdings-notes.json, picks-notes.json), splices them
# into index.html markers, then publishes. AI never edits the 200KB+ HTML directly and never
# has to chain individual git commands.
#
# The commit/push itself lives in lib/publish-gate.ps1, not here: it is the only place anything
# leaves this machine, so it stages an allowlist and content-checks what it staged rather than
# trusting whatever the daily run happened to write. See that file for why.
#
#   pwsh -File publish.ps1            splice, rebuild the demo page, publish
#   pwsh -File publish.ps1 -DryRun    everything except the commit and push
param([switch]$DryRun)
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/pagedata.ps1')     # Set-PageBlocks / Get-PageBlockText / Get-PageContract
. (Join-Path $root 'lib/publish-gate.ps1') # Invoke-PublishGate
$idxPath = Join-Path $root 'index.html'

# guard: never splice yesterday's notes (e.g. today's Write step failed but old file remains)
function IsFresh($path){ ((Get-Date) - (Get-Item $path).LastWriteTime).TotalHours -le 15 }
# a broken notes file must not abort the whole publish (engine data is still fresh) - retry then skip
function ReadJsonRetry($path){
  for($i=0;$i -lt 3;$i++){
    try{ return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}

$blocks = @{}
$hnPath = Join-Path $root 'holdings-notes.json'
if((Test-Path $hnPath) -and -not (IsFresh $hnPath)){
  Write-Host "holdings-notes.json older than 15h - stale, skipping splice"
} elseif(Test-Path $hnPath){
  $hn = ReadJsonRetry $hnPath
  if($null -ne $hn){
    $blocks['holdingsnotes'] = $hn
    Write-Host "spliced holdings-notes.json -> window.HOLDINGS_NOTES"
  } else { Write-Host "WARN: holdings-notes.json unreadable after retries - skipping this splice, publish continues" }
} else { Write-Host "no holdings-notes.json found - skipping (holdings text stays as-is)" }

$pnPath = Join-Path $root 'picks-notes.json'
if((Test-Path $pnPath) -and -not (IsFresh $pnPath)){
  Write-Host "picks-notes.json older than 15h - stale, skipping splice"
} elseif(Test-Path $pnPath){
  $pn = ReadJsonRetry $pnPath
  if($null -ne $pn){
    $blocks['pknotes'] = $pn
    Write-Host "spliced picks-notes.json -> window.PICKS_NOTES"
  } else { Write-Host "WARN: picks-notes.json unreadable after retries - skipping this splice, publish continues" }
} else { Write-Host "no picks-notes.json found - skipping (pick notes stay as-is)" }

if($blocks.Count){ Set-PageBlocks -IndexPath $idxPath -Blocks $blocks }

# The splice above wrote the OWNER's full notes (incl. `rec` and `_market.wind`) into
# index.html. That is correct for the local/server copy but must never be committed, so the
# demo rebuild has to be the LAST thing that touches the file. It used to be called before
# publish.ps1 from run-daily.sh, which meant the splice above silently clobbered it and the
# owner's real holdings + advice went to GitHub on every day the notes were freshly written
# (2026-07-23 and 2026-07-24 both shipped that way). Calling it from here makes the order
# structural instead of a convention someone has to remember.
# run as a child process, not `& script.ps1`: build-demo signals failure with `exit 1`, and only
# a native command sets $LASTEXITCODE reliably (dot-called scripts leave it $null on a clean run,
# which reads as a failure).
pwsh -File (Join-Path $root 'build-demo.ps1')
if($LASTEXITCODE -ne 0){ Write-Host "FATAL: build-demo.ps1 failed - refusing to commit an unfiltered page"; exit 1 }

# attach AI verdict tags (ai-tags.json: {code:{sust:bool,risk:string}}) to open picks-log
# entries lacking them - lets evaluate.ps1 score whether AI topic judgment adds value
$tagPath = Join-Path $root 'ai-tags.json'
$logPath = Join-Path $root 'picks-log.json'
if((Test-Path $tagPath) -and (Test-Path $logPath) -and (IsFresh $tagPath)){
  try{
    $tags = Get-Content $tagPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lg = Get-Content $logPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $n=0
    foreach($pk in $lg.picks){
      if($pk.status -eq 'open' -and $tags.PSObject.Properties["$($pk.code)"] -and -not $pk.PSObject.Properties['aiSust']){
        $t=$tags.("$($pk.code)")
        $pk | Add-Member -NotePropertyName aiSust -NotePropertyValue ([bool]$t.sust) -Force
        $pk | Add-Member -NotePropertyName aiRisk -NotePropertyValue "$($t.risk)" -Force
        $n++
      }
    }
    if($n -gt 0){ $lg | ConvertTo-Json -Depth 5 | Out-File $logPath -Encoding UTF8; Write-Host "attached AI tags to $n open picks" }
  }catch{ Write-Host "ai-tags attach skipped: $($_.Exception.Message)" }
}

$today = Get-Date -Format 'yyyy-MM-dd'
if(-not (Invoke-PublishGate -Root $root -Message "daily update $today" -DryRun:$DryRun)){ exit 1 }
