# lib/publish-gate.ps1 - the one place anything leaves this machine.
#
# Dot-source it:  . (Join-Path $root 'lib/publish-gate.ps1')
#
# The old arrangement had the safety check beside the exit rather than on it: publish.ps1
# inspected one <script> block of one file, then ran `git add -A` and pushed the whole working
# tree. Everything the check did not think to look at went out anyway - which is how
# holdings-notes.json, holdings-context.json and stance-log.json ended up in a public repo.
#
# So this module inverts the default. Nothing is published unless it is named in
# $PublishAllowlist, and three things have to hold before the push:
#   1. every file git already tracks is allowlisted   (catches what past runs leaked)
#   2. only allowlisted paths get staged              (a new artifact file is ignored, not shipped)
#   3. no staged JSON/HTML carries an owner-only note field  (catches content, not just names)
# Any of them failing refuses the publish; none of them can be satisfied by remembering to.
#
# Requires lib/pagedata.ps1 (Get-PageContract / Get-PageBlockText) to be dot-sourced first.

# git pathspecs for everything the public repo is allowed to contain. Add a new artifact here
# ONLY after deciding it carries nothing personal - the daily run writes several files that do.
$PublishAllowlist = @(
  '.gitignore'
  '.claude/settings.json'
  '*.md'
  '*.ps1'
  'lib/*.ps1'
  'run-daily.sh'
  'tools/'
  'server/'
  'docs/'
  'index.html'
  'apple-touch-icon.png'
  'page-contract.json'
  'config.example.json'
  # public data: the demo portfolio, market-wide screening output and its scorecards.
  # NOT holdings.json's real counterpart, NOT anything derived from the owner's positions.
  'holdings.json'
  'picks-log.json'
  'picks-notes.json'
  'screen-summary.json'
  'eval-report.json'
  'backtest-result.json'
  'backtest-card.json'
  'ai-tags.json'
  # daily Claude token/cost totals for THIS project's automation only (finish-daily-push.ps1) -
  # a plain number, never AI-authored free text, safe to publish
  'token-usage.json'
)

# Owner-only note fields, from page-contract.json. Same list build-demo.ps1 strips to and
# server/payload.py filters guests with.
function Get-OwnerOnlyFields { return @((Get-PageContract).noteFields.ownerOnly) }

# Recursively collect JSON property names, so a nested `_market.wind` is found as readily as a
# top-level one. Depth-capped: these files are shallow and a cycle would otherwise hang the run.
function Get-JsonKeyNames($Node,[int]$Depth=0){
  $names=@()
  if($null -eq $Node -or $Depth -gt 12){ return $names }
  if($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]){
    foreach($item in $Node){ $names += Get-JsonKeyNames $item ($Depth+1) }
    return $names
  }
  if($Node.PSObject -and $Node.PSObject.Properties){
    foreach($p in $Node.PSObject.Properties){
      $names += $p.Name
      $names += Get-JsonKeyNames $p.Value ($Depth+1)
    }
  }
  return $names
}

# A concrete tailnet hostname (`<machine>.<tailnet>.ts.net`) is the owner's private entry point
# to the server. The dashboard is login-gated, so this is not a credential leak - but publishing
# the URL hands it to the scanners that already probe the access log (/.env, /.git/config), and
# nothing in the repo needs the real name. Two real labels must precede `.ts.net`, so the
# angle-bracket placeholder SETUP.md documents with, and bare prose mentions of `.ts.net`,
# are deliberately NOT matched - only a host that actually resolves.
$TailnetHostPattern = '[A-Za-z0-9-]+\.[A-Za-z0-9-]+\.ts\.net'

# Extensions whose bytes are not text. Reading a PNG as UTF-8 would not throw, just waste time
# on the one binary the allowlist carries (apple-touch-icon.png).
$BinaryExtensions = @('.png','.jpg','.jpeg','.gif','.ico','.woff','.woff2','.db')

# Owner-only content found in one file, as a list of human-readable strings ('' = clean).
# JSON is checked by key name; index.html is checked block by block, because its own source
# legitimately mentions these words in JS while its data blocks must not. The tailnet-host scan
# runs on every text extension instead, because the leak that prompted it (plan.md, found
# 2026-07-31 while debugging a Funnel outage) sat in a .md file - a format neither of the
# structured checks below ever opens.
function Test-FileForOwnerContent([string]$Path,[string]$RelPath){
  $bad = Get-OwnerOnlyFields
  $hits=@()
  $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
  if($BinaryExtensions -notcontains $ext){
    $encRaw = New-Object System.Text.UTF8Encoding($false)
    $raw = [IO.File]::ReadAllText($Path,$encRaw)
    # NOT $host: that is a read-only PowerShell automatic variable and assigning it throws.
    foreach($tsHost in @([regex]::Matches($raw,$TailnetHostPattern) | ForEach-Object { $_.Value } | Sort-Object -Unique)){
      $hits += "$RelPath names the private tailnet host '$tsHost' (use a <machine>.<tailnet>.ts.net placeholder)"
    }
  }
  if($ext -eq '.json'){
    try{ $obj = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json }catch{ return @() }
    $keys = @(Get-JsonKeyNames $obj | Sort-Object -Unique)
    foreach($f in $bad){ if($keys -contains $f){ $hits += "$RelPath carries an owner-only field '$f'" } }
  } elseif($ext -eq '.html'){
    $enc = New-Object System.Text.UTF8Encoding($false)
    $html = [IO.File]::ReadAllText($Path,$enc)
    foreach($id in @((Get-PageContract).blocks.PSObject.Properties.Name)){
      $block = Get-PageBlockText $html $id
      if([string]::IsNullOrEmpty($block)){ continue }
      foreach($f in $bad){
        if($block.Contains('"' + $f + '"')){ $hits += "$RelPath block '$id' carries an owner-only field '$f'" }
      }
    }
  }
  return $hits
}

# Roll the index back after an abort or a dry run - but only when the gate is the only thing
# that touched it. A blanket `git reset` here would silently undo a `git rm --cached` the user
# staged before running publish, which is exactly the operation that stops a leak.
function Unstage-IfOurs($PreStaged){
  if(@($PreStaged).Count -eq 0){ git reset -q }
  else { Write-Host "  (index had staged changes before this run - leaving it alone)" }
}

# The gate. Returns $true when the working tree was published (or would be, under -DryRun).
# Writes its reasoning to the host; a refusal is always explained with the command that fixes it.
#
# -NoPush: commit locally but do not `git push`. Exists for the cron wrapper's token-usage
# handoff (plan.md, 2026-07-25): the daily token/cost number is only known once `claude -p`
# exits, which is *after* this gate would normally have already pushed. The wrapper amends this
# still-local commit once it knows the number (see finish-daily-push.ps1) instead of pushing
# twice or publishing a number that belongs to yesterday's run. Interactive/manual callers must
# not pass this - they have no second process coming along to finish the push.
function Invoke-PublishGate {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Message,
    [switch]$DryRun,
    [switch]$NoPush
  )
  Push-Location $Root
  try{
    # Anything staged before we started (a `git rm --cached`, a half-finished edit) is the
    # user's, not ours. Only roll the index back on abort if we are the only thing in it.
    $preStaged = @(git diff --cached --name-only)

    # 1. anything already tracked that the allowlist would not have published is a past leak.
    #    Refuse until it is untracked - the file itself stays on disk, only git forgets it.
    $tracked = @(git ls-files)
    $allowed = @(git ls-files -- $PublishAllowlist)
    $stray = @($tracked | Where-Object { $allowed -notcontains $_ })
    if($stray.Count){
      Write-Host "FATAL: these files are tracked by git but are not on the publish allowlist:"
      foreach($s in $stray){ Write-Host "         $s" }
      Write-Host "       They are being published on every run. If they carry nothing personal, add"
      Write-Host "       them to `$PublishAllowlist in lib/publish-gate.ps1. Otherwise:"
      Write-Host "         git rm --cached $($stray -join ' ')   # keeps the file, stops publishing it"
      Write-Host "       and add them to .gitignore. Refusing to publish."
      return $false
    }

    # 2. stage the allowlist only. Whatever else the daily run wrote stays in the working tree.
    #    Pathspecs go in ONE AT A TIME, not as a single list: `git add -A -- <list>` aborts the
    #    WHOLE call - staging nothing, not even the other entries - the moment any single
    #    pathspec matches zero files, true for a missing literal file (token-usage.json before
    #    its first run ever wrote one) and even for a glob with zero current matches. Staged
    #    together, one not-yet-created allowlisted file would silently no-op the entire publish
    #    while this function still returns success - exactly the "looked fine, published
    #    nothing" failure mode this file exists to prevent (found 2026-07-25 while adding
    #    token-usage.json - it very nearly shipped that way).
    foreach($entry in $PublishAllowlist){ git add -A -- $entry 2>$null }
    $staged = @(git diff --cached --name-only)
    if($staged.Count -eq 0){ Write-Host "nothing to commit"; return $true }

    # 3. content check on what is actually about to be committed. Deletions are excluded by
    #    --diff-filter: a file being REMOVED from the repo still exists on disk (that is the
    #    point of `git rm --cached`), and scanning it would refuse the very commit that stops
    #    it being published.
    $added = @(git diff --cached --name-only --diff-filter=ACMR)
    $violations=@()
    foreach($rel in $added){
      $full = Join-Path $Root $rel
      if(-not (Test-Path $full)){ continue }
      $violations += Test-FileForOwnerContent $full $rel
    }
    if($violations.Count){
      Write-Host "FATAL: refusing to publish - owner-only content in staged files:"
      foreach($v in $violations){ Write-Host "         $v" }
      Unstage-IfOurs $preStaged
      return $false
    }
    Write-Host "publish gate passed: $($staged.Count) file(s), no owner-only content"

    if($DryRun){
      foreach($line in @(git diff --cached --name-status)){ Write-Host "  would publish: $line" }
      Unstage-IfOurs $preStaged
      return $true
    }
    git commit -m $Message | Out-Null
    if($NoPush){
      Write-Host "committed locally, NOT pushed (-NoPush): $Message"
      return $true
    }
    git push origin main
    Write-Host "committed and pushed: $Message"
    return $true
  } finally { Pop-Location }
}
