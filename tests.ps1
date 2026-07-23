# tests.ps1 - offline regression suite (no network, runs in seconds)
# Run before committing engine/script changes:  pwsh -File tests.ps1
# Consolidates the smoke tests from the 2026-07-18 v9/v10/v11 health audits:
#  1. syntax-parse all scripts   2. UTF-8 BOM convention   3. DivSumSince dividend cap
#  4. GetDailySeries cache read path (also guards the legacy ConvertFrom-Json array-collapse shape)
#  5. CheckRevCols column-layout warning   6. history-wipe guards present
# ASCII source only. Paths must stay cross-platform (no $env:TEMP - unset on Linux).
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$fails=@()
function Assert($ok,$name){ if($ok){ Write-Host "  PASS $name" } else { Write-Host "  FAIL $name"; $script:fails+=$name } }

Write-Host "[1] syntax parse..."
foreach($f in @('screen.ps1','update-holdings.ps1','evaluate.ps1','publish.ps1','backtest.ps1')){
  $tok=$null;$err=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f),[ref]$tok,[ref]$err)
  Assert ($err.Count -eq 0) "syntax $f"
  if($err.Count){ $err | ForEach-Object { Write-Host "    $($_.Message) @ line $($_.Extent.StartLineNumber)" } }
}

Write-Host "[2] UTF-8 BOM convention (pwsh 7 does not need it; kept so CJK literals survive a PS5.1/Windows run)..."
foreach($f in @('screen.ps1','update-holdings.ps1','publish.ps1')){
  $b=[IO.File]::ReadAllBytes((Join-Path $root $f))
  Assert ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) "BOM $f"
}

Write-Host "[3] extract functions from screen.ps1..."
$tok=$null;$err=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'screen.ps1'),[ref]$tok,[ref]$err)
$fns=$ast.FindAll({param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($n in @('Num','DivSumSince','CheckRevCols','GetDailySeries')){
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

Write-Host "[5] GetDailySeries cache read path (cache-hit must never fetch; array-shape guard)..."
$tmp=Join-Path ([IO.Path]::GetTempPath()) ("kline-cache-test-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$mkt=@{}
$klineCache=$tmp
$fixture=@()
for($i=1;$i -le 21;$i++){ $fixture += [ordered]@{ d="1/$i"; dt=("202501{0:00}" -f $i); o=10.0; h=11.0; l=9.0; c=(10.0+$i*0.1); chg=0.1; v=100 } }
ConvertTo-Json -InputObject $fixture -Depth 3 -Compress | Out-File (Join-Path $tmp '9999-202501.json') -Encoding UTF8
$ser=GetDailySeries '9999' @('20250101')
Assert ($ser.Count -eq 21) "cache hit returns 21 rows (got $($ser.Count))"
Assert ("$($ser[0].dt)" -eq '20250101' -and $ser[20].c -eq 12.1) "row fields intact (dt=$($ser[0].dt) c=$($ser[20].c))"
$one=@([ordered]@{ d='1/2'; dt='20250102'; o=1;h=1;l=1;c=1.0;chg=0;v=1 })
ConvertTo-Json -InputObject $one -Depth 3 -Compress | Out-File (Join-Path $tmp '9998-202501.json') -Encoding UTF8
$threw=$false
try{ $null=GetDailySeries '9998' @('20250101') }catch{ $threw=$true }   # <5 rows = corrupt -> refetch -> stub throws
Assert $threw "suspicious cache (<5 rows) falls through to refetch"
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

Write-Host ""
if($fails.Count -eq 0){ Write-Host "ALL TESTS PASSED"; exit 0 }
else { Write-Host "FAILED: $($fails.Count) test(s): $($fails -join '; ')"; exit 1 }
