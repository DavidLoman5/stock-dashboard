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
  'server/'
  'docs/'
  'index.html'
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

# Owner-only content found in one file, as a list of human-readable strings ('' = clean).
# JSON is checked by key name; index.html is checked block by block, because its own source
# legitimately mentions these words in JS while its data blocks must not.
function Test-FileForOwnerContent([string]$Path,[string]$RelPath){
  $bad = Get-OwnerOnlyFields
  $hits=@()
  $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
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
function Invoke-PublishGate {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string]$Message,
    [switch]$DryRun
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
    git add -A -- $PublishAllowlist
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
    git push origin main
    Write-Host "committed and pushed: $Message"
    return $true
  } finally { Pop-Location }
}
