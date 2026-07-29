# lib/picks-log.ps1 - the only module that reads or writes picks-log.json.
#
# ASCII source only (no BOM needed): this file is pure file lifecycle, no CJK literals.
#
# picks-log.json is the recommendation-accountability history: which picks the engine made, at
# what price, and how each one settled. It is the one published artifact that cannot be rebuilt
# from anything else, so every rule about it is a safety rule:
#
#   * a transient read failure must NEVER end with history rewritten from an unreadable file;
#     retry, then fail loudly BEFORE any write
#   * rows are serialized from [ordered] dictionaries. A plain @{} enumerates in .NET string-hash
#     order, which is randomised per process, so ConvertTo-Json reshuffled every record's keys on
#     every run and the daily commit rewrote the whole file (measured: 4 new picks -> 408 changed
#     lines). Insertion order here is a pure function of which fields a record has, so the file is
#     byte-stable and a day's diff is that day's rows
#   * `aiSust`/`aiRisk` are written LAST, because that is where Add-PicksLogTags puts them when
#     publish.ps1 attaches them the same evening. Matching positions means the next morning's
#     rewrite does not shuffle those rows back
#   * writes use -ErrorAction Stop. The callers run with $ErrorActionPreference='Continue', where
#     a failed Out-File is merely printed and execution falls through to the next step
#
# Before this module existed, screen.ps1 owned all of the above and publish.ps1 - the file's
# second writer - re-read it with a bare Get-Content, mutated it with Add-Member and wrote it
# back with none of these guards: no retry, no ordering, no -ErrorAction Stop. A truncated write
# there bricks the next morning's screening run, which hard-aborts on an unreadable log.

$PicksLogRetainSettled = 120   # keep every open row plus this many settled ones; older ones archive

# Fields copied through verbatim when they are present, in the order they must serialize.
$PicksLogFactorFields = @('light','chipS','techS','fundS','ret5','dist','yoy','pe','dy','ind')
$PicksLogTagFields    = @('aiSust','aiRisk')


function ConvertTo-PicksLogRow {
  <#  One raw record (PSCustomObject from ConvertFrom-Json, or an ordered dict) normalised into
      the canonical key order. $NameMap heals legacy mojibake names from the daily price table. #>
  param($Row, $NameMap)
  $o=[ordered]@{
    date="$($Row.date)"; code="$($Row.code)"; name="$($Row.name)"
    price=[double]$Row.price; score=[int]$Row.score
  }
  if($NameMap -and $NameMap.ContainsKey($o.code) -and $NameMap[$o.code].name){
    $o.name="$($NameMap[$o.code].name)"
  }
  $status = Get-PicksLogField $Row 'status'
  $o.status = if($status){ "$status" } else { 'open' }
  foreach($fld in $PicksLogFactorFields){
    $v = Get-PicksLogField $Row $fld
    if($null -ne $v){ $o[$fld]=$v }
  }
  foreach($pair in @(@('exit','double'),@('retFinal','double'),@('alphaFinal','double'),
                     @('closedOn','string'),@('days','int'),@('reason','string'))){
    $v = Get-PicksLogField $Row $pair[0]
    if($null -eq $v){ continue }
    switch($pair[1]){
      'double' { $o[$pair[0]]=[double]$v }
      'int'    { $o[$pair[0]]=[int]$v }
      default  { if($v){ $o[$pair[0]]="$v" } }
    }
  }
  # AI tags last - see the header note about Add-PicksLogTags' append position
  foreach($fld in $PicksLogTagFields){
    $v = Get-PicksLogField $Row $fld
    if($null -ne $v){ $o[$fld]=$v }
  }
  return $o
}


function Get-PicksLogField {
  <#  Read a field from either shape this module handles: a PSCustomObject straight out of
      ConvertFrom-Json, or an ordered dictionary we produced ourselves. #>
  param($Row, [string]$Name)
  if($Row -is [System.Collections.IDictionary]){
    if($Row.Contains($Name)){ return $Row[$Name] }   # [ordered] has .Contains, not .ContainsKey
    return $null
  }
  $prop = $Row.PSObject.Properties[$Name]
  if($null -eq $prop){ return $null }
  return $prop.Value
}


function Get-PicksLog {
  <#  Normalised rows from picks-log.json, or an empty array when the file does not exist yet.
      THROWS if the file exists but cannot be read or parsed after $Retries attempts - callers
      must let that abort the run rather than continue with an empty history. #>
  param([string]$Path, $NameMap, [int]$Retries=3, [int]$RetryPauseMs=1500)
  if(-not (Test-Path $Path)){ return ,@() }
  $lg=$null
  for($try=0; $try -lt $Retries -and $null -eq $lg; $try++){
    try{ $lg = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch{ Start-Sleep -Milliseconds $RetryPauseMs }
  }
  if($null -eq $lg -or -not $lg.PSObject.Properties['picks']){
    throw "picks-log.json exists but is unreadable after $Retries tries - refusing to continue, nothing written"
  }
  $rows=@()
  foreach($p in @($lg.picks)){ $rows += ,(ConvertTo-PicksLogRow $p $NameMap) }
  return ,$rows
}


function Move-SettledPicksToArchive {
  <#  Fold settled rows past the retention window into an append-only JSONL archive.

      The ORDER OF OPERATIONS IS THE SAFETY ARGUMENT: append, read the archive back, and drop
      rows from the log only once every folded row is provably in it. A crash in between simply
      re-folds the same rows next run - the `date|code` key makes the append idempotent - so
      nothing is lost and nothing is duplicated. Any failure returns the input untouched. #>
  param($Rows, [int]$Retain, [string]$ArchivePath)
  $settled=@($Rows | Where-Object { $_.status -ne 'open' })
  if($settled.Count -le $Retain){ return ,@($Rows) }
  $sorted=@($settled | Sort-Object @{e={"$($_.closedOn)"}}, @{e={"$($_.date)"}}, @{e={"$($_.code)"}})
  $fold=@($sorted[0..($sorted.Count-$Retain-1)])
  try{
    $arcDir=Split-Path -Parent $ArchivePath
    if($arcDir -and -not (Test-Path $arcDir)){
      New-Item -ItemType Directory -Path $arcDir -ErrorAction Stop | Out-Null
    }
    $have=@{}
    if(Test-Path $ArchivePath){
      foreach($ln in (Get-Content $ArchivePath -Encoding UTF8 -ErrorAction Stop)){
        if(-not "$ln".Trim()){ continue }
        try{ $ob=$ln | ConvertFrom-Json; $have["$($ob.date)|$($ob.code)"]=$true }catch{}
      }
    }
    $lines=@()
    foreach($o in $fold){
      if(-not $have.ContainsKey("$($o.date)|$($o.code)")){
        $lines += ($o | ConvertTo-Json -Depth 4 -Compress)
      }
    }
    if($lines.Count -gt 0){ Add-Content -Path $ArchivePath -Value $lines -Encoding UTF8 -ErrorAction Stop }
    $back=@{}
    foreach($ln in (Get-Content $ArchivePath -Encoding UTF8 -ErrorAction Stop)){
      if(-not "$ln".Trim()){ continue }
      try{ $ob=$ln | ConvertFrom-Json; $back["$($ob.date)|$($ob.code)"]=$true }catch{}
    }
    $missing=@($fold | Where-Object { -not $back.ContainsKey("$($_.date)|$($_.code)") })
    if($missing.Count -gt 0){
      Write-Host "  WARNING: archive read-back missing $($missing.Count) rows - log left intact, nothing dropped"
      return ,@($Rows)
    }
    $drop=@{}; foreach($o in $fold){ $drop["$($o.date)|$($o.code)"]=$true }
    $kept=@($Rows | Where-Object { -not $drop.ContainsKey("$($_.date)|$($_.code)") })
    Write-Host "  archived $($fold.Count) settled picks -> $ArchivePath (log keeps $Retain settled + all open)"
    return ,$kept
  }catch{
    Write-Host "  WARNING: archive step failed ($($_.Exception.Message)) - log left intact, nothing dropped"
    return ,@($Rows)
  }
}


function Add-PicksLogTags {
  <#  Attach the daily AI verdict tags to still-open picks. Returns how many rows changed.
      Appends at the tail, which is where ConvertTo-PicksLogRow also puts them. #>
  param($Rows, $Tags)
  $n=0
  foreach($row in $Rows){
    if($row.status -ne 'open'){ continue }
    $t = $null
    if($Tags -is [System.Collections.IDictionary]){
      if($Tags.Contains("$($row.code)")){ $t=$Tags["$($row.code)"] }
    } elseif($Tags) {
      $prop = $Tags.PSObject.Properties["$($row.code)"]
      if($prop){ $t=$prop.Value }
    }
    if($null -eq $t){ continue }
    if($row.Contains('aiSust')){ continue }   # already tagged; do not rewrite
    $row['aiSust']=[bool]$t.sust
    $row['aiRisk']="$($t.risk)"
    $n++
  }
  return $n
}


function Set-PicksLog {
  <#  Write the log. Pass -Retain/-ArchivePath to fold settled rows out first; omit them (as
      publish.ps1 does) to rewrite in place without touching retention.

      Every row is re-normalised on the way out. Normalising only on READ is not enough: when
      screen.ps1 closes a pick it assigns new keys (`$o.exit=`, `$o.closedOn=`, ...) to an
      ordered dictionary, and those APPEND - so a row that was already AI-tagged ends up with
      exit/closedOn *after* aiSust/aiRisk, out of canonical order, and the next morning's read
      shuffles it back. One row per closure, every closure, forever. Normalising here makes the
      key order a property of the file rather than of the order the code happened to touch it. #>
  param([string]$Path, $Rows, [int]$Retain=0, [string]$ArchivePath)
  $out=@($Rows)
  if($Retain -gt 0 -and $ArchivePath){
    $out = Move-SettledPicksToArchive $out $Retain $ArchivePath
  }
  $known = @('date','code','name','price','score','status') + $PicksLogFactorFields +
           @('exit','retFinal','alphaFinal','closedOn','days','reason') + $PicksLogTagFields
  $norm=@()
  foreach($r in $out){
    # fail loud rather than drop: a field added upstream must be added to this module too,
    # not silently disappear on the next write
    foreach($k in @(Get-PicksLogFieldNames $r)){
      if($known -notcontains $k){
        throw "picks-log row has unknown field '$k' - add it to lib/picks-log.ps1 before writing"
      }
    }
    $norm += ,(ConvertTo-PicksLogRow $r)
  }
  [ordered]@{ picks=@($norm) } | ConvertTo-Json -Depth 5 |
    Out-File $Path -Encoding UTF8 -ErrorAction Stop
}


function Get-PicksLogFieldNames {
  <#  Field names of a row, whichever of the two shapes it is. #>
  param($Row)
  if($Row -is [System.Collections.IDictionary]){ return @($Row.Keys) }
  return @($Row.PSObject.Properties.Name)
}
