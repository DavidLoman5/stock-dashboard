# finish-daily-push.ps1 - deterministic (no AI) completion of the daily publish.
#
# Run by the cron wrapper (~/run-stock-briefing.sh), AFTER `claude -p` exits, once the wrapper
# knows today's real token/cost usage. Exists because of a timing gap (plan.md, 2026-07-25):
# SKILL.md's own publish step runs *inside* the `claude -p` process, but that process's own
# token/cost total is only reported once it exits - by which point a normal publish would
# already have pushed. So SKILL.md is told to commit with `run-daily.sh --phase publish
# --no-push` (see lib/publish-gate.ps1's -NoPush), leaving today's commit local and unpushed,
# and THIS script folds the token number into that same commit and does the actual push -
# one push per day, carrying the real number, not a stale one and not a second commit.
#
#   pwsh -File finish-daily-push.ps1 -UsageFile <path to json: {inputTokens,outputTokens,cacheReadTokens,cacheCreationTokens}>
#
# Safety, in order of priority (this is unattended automation touching the real main branch):
#   1. NEVER force-push. If origin/main moved since today's local commit (something else pushed
#      in the gap), fall back to a normal extra commit on top instead of amending.
#   2. NEVER leave today's real dashboard update stuck local-only because of a token-handling
#      bug. Any failure while merging/splicing the token number falls back to just pushing
#      whatever is already committed.
param(
  [Parameter(Mandatory=$true)][string]$UsageFile
)
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib/pagedata.ps1')   # Set-PageBlocks
Push-Location $root
$exitCode = 0
try {
  $pushedWithUsage = $false
  try {
    $ErrorActionPreference = 'Stop'
    $today = Get-Date -Format 'yyyy-MM-dd'
    $usagePath = Join-Path $root 'token-usage.json'

    $incoming = Get-Content $UsageFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $existing = $null
    if (Test-Path $usagePath) {
      try { $existing = Get-Content $usagePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $existing = $null }
    }
    $sameDay = ($null -ne $existing) -and ($existing.date -eq $today)
    function AsInt($v) { if ($null -eq $v) { 0 } else { [int]$v } }

    $merged = [ordered]@{
      date                = $today
      inputTokens         = (AsInt $incoming.inputTokens)         + $(if ($sameDay) { AsInt $existing.inputTokens } else { 0 })
      outputTokens        = (AsInt $incoming.outputTokens)        + $(if ($sameDay) { AsInt $existing.outputTokens } else { 0 })
      cacheReadTokens     = (AsInt $incoming.cacheReadTokens)     + $(if ($sameDay) { AsInt $existing.cacheReadTokens } else { 0 })
      cacheCreationTokens = (AsInt $incoming.cacheCreationTokens) + $(if ($sameDay) { AsInt $existing.cacheCreationTokens } else { 0 })
      runs                = 1 + $(if ($sameDay) { AsInt $existing.runs } else { 0 })
    }
    $merged | ConvertTo-Json | Out-File $usagePath -Encoding UTF8
    Write-Host "token-usage.json: date=$today run#$($merged.runs) in=$($merged.inputTokens) out=$($merged.outputTokens) cacheRead=$($merged.cacheReadTokens) cacheCreate=$($merged.cacheCreationTokens)"

    Set-PageBlocks -IndexPath (Join-Path $root 'index.html') -Blocks @{ tokenusage = $merged }
    git add -- token-usage.json index.html

    git fetch origin main *>$null
    $localHead = (git rev-parse HEAD).Trim()
    $remoteHead = (git rev-parse origin/main).Trim()

    if ($localHead -ne $remoteHead) {
      # expected path: SKILL.md committed today's update with -NoPush and it is still unpushed -
      # fold the token number into that same commit rather than shipping two.
      git commit --amend --no-edit | Out-Null
      Write-Host "amended today's unpushed commit with token usage"
    } else {
      # HEAD is already what origin has - something published without -NoPush (a manual run, or
      # the flag not taking effect). Do not touch already-public history: add on top instead.
      git commit -m "token usage $today" | Out-Null
      Write-Host "HEAD was already pushed - added a separate token-usage commit instead of amending"
    }

    git push origin main
    if ($LASTEXITCODE -ne 0) { throw "git push origin main failed (exit $LASTEXITCODE)" }
    Write-Host "pushed (with token usage)"
    $pushedWithUsage = $true
  } catch {
    Write-Host "WARN: token-usage handoff failed ($($_.Exception.Message)) - falling back to a plain push of today's update"
  }

  if (-not $pushedWithUsage) {
    # Whatever went wrong above, today's real dashboard update must still ship if it is sitting
    # local-only. This never force-pushes either - a normal rejected push here means something
    # deeper is wrong (e.g. real divergence) and needs a human, not an automatic --force.
    $ErrorActionPreference = 'Continue'
    $localHead = (git rev-parse HEAD 2>$null)
    $remoteHead = (git rev-parse origin/main 2>$null)
    if ($localHead -and $remoteHead -and $localHead.Trim() -ne $remoteHead.Trim()) {
      git push origin main
      if ($LASTEXITCODE -eq 0) { Write-Host "pushed today's update WITHOUT token usage" }
      else {
        Write-Host "FATAL: fallback push also failed (exit $LASTEXITCODE) - today's commit is stuck local-only, needs manual attention"
        $exitCode = 1
      }
    } else {
      Write-Host "nothing local to push - today's update was already published"
    }
  }
}
finally {
  Pop-Location
}
exit $exitCode
