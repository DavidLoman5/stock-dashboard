# lib/pagedata.ps1 - the one implementation of "write a data block into index.html".
#
# Dot-source it:   . (Join-Path $PSScriptRoot 'lib/pagedata.ps1')
#
# Every block id, its window.* global and its JSON depth come from page-contract.json, so the
# marker convention is declared once instead of being hand-copied into each script. Two rules
# that the old per-script copies got wrong:
#   * an unknown block id is an error, not a typo that silently does nothing;
#   * a missing marker is an error, not a warning followed by writing the file anyway.
# Both used to fail open, which is how a stale block could survive a whole daily run unnoticed.
$script:PageContractCache = $null

function Get-PageContract {
  if($null -ne $script:PageContractCache){ return $script:PageContractCache }
  $p = Join-Path (Split-Path -Parent $PSScriptRoot) 'page-contract.json'
  if(-not (Test-Path $p)){ throw "page-contract.json not found at $p" }
  $script:PageContractCache = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
  return $script:PageContractCache
}

# Raw inner text of a block, or $null if the marker is absent. Read-only: used by the
# publication gate and by tests to inspect what a page actually carries.
function Get-PageBlockText([string]$Html,[string]$Id){
  $st = '<script id="' + $Id + '">'
  $i1 = $Html.IndexOf($st)
  if($i1 -lt 0){ return $null }
  $i2 = $Html.IndexOf('</script>', $i1)
  if($i2 -lt 0){ return $null }
  return $Html.Substring($i1 + $st.Length, $i2 - ($i1 + $st.Length))
}

# Serialise one block's value to the exact text that goes between the script tags.
# $null means "leave the block empty" (appuser in the committed file).
function ConvertTo-PageBlockPayload($Value, $Spec){
  if($null -eq $Value){ return '' }
  $json = $Value | ConvertTo-Json -Depth ([int]$Spec.depth) -Compress
  # '</' inside a JSON string would close the script element early; \/ is a legal JSON escape.
  $json = $json.Replace('</', '<\/')
  return 'window.' + $Spec.global + '=' + $json + ';'
}

# Write one or more blocks and save the file once. Reading, splicing and writing in a single
# call is deliberate: the old code left every caller to do its own read/modify/write pair,
# which is what let two scripts in the same run clobber each other's blocks.
function Set-PageBlocks {
  param(
    [Parameter(Mandatory=$true)][string]$IndexPath,
    [Parameter(Mandatory=$true)][hashtable]$Blocks
  )
  if(-not (Test-Path $IndexPath)){ throw "Set-PageBlocks: $IndexPath not found" }
  $contract = Get-PageContract
  $known = @($contract.blocks.PSObject.Properties.Name)
  $enc = New-Object System.Text.UTF8Encoding($false)
  $html = [IO.File]::ReadAllText($IndexPath, $enc)

  foreach($id in @($Blocks.Keys)){
    $prop = $contract.blocks.PSObject.Properties[$id]
    if($null -eq $prop){
      throw "Set-PageBlocks: '$id' is not a block in page-contract.json (known: $($known -join ', '))"
    }
    $st = '<script id="' + $id + '">'
    $i1 = $html.IndexOf($st)
    if($i1 -lt 0){
      throw "Set-PageBlocks: marker '$id' missing from $IndexPath - refusing to write a page whose data block cannot be filled"
    }
    $i2 = $html.IndexOf('</script>', $i1)
    if($i2 -lt 0){
      throw "Set-PageBlocks: block '$id' is never closed in $IndexPath"
    }
    $payload = ConvertTo-PageBlockPayload $Blocks[$id] $prop.Value
    $html = $html.Substring(0, $i1 + $st.Length) + $payload + $html.Substring($i2)
  }

  [IO.File]::WriteAllText($IndexPath, $html, $enc)
}
