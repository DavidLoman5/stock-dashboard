# lib/score.ps1 - the selection rules, in one place, as pure functions.
#
# UTF-8 with BOM: the exit reasons are CJK literals stored verbatim in picks-log.json.
#
# Before this module, the same funnel existed three times: screen.ps1's stock loop, screen.ps1's
# ETF loop (the same 68 lines with suffixed variable names), and backtest.ps1's replay - whose
# comment said "same order and thresholds as production screen.ps1", which is a convention, not
# a guarantee. The backtest that validates the strategy was validating a hand-copy of it.
#
# Everything here is a pure function of numbers: no fetching, no files, no globals. That is what
# makes the funnel testable at all - screen.ps1 previously exposed exactly three functions to
# tests.ps1 by lifting them out of its own source with the AST parser, and none of them were
# these.
#
# Stock vs ETF is a PROFILE, not a second copy. An ETF has no EPS/PE, trades thinner and is not
# judged on candle structure, so its thresholds differ - but the shape of the funnel does not.

# --- profiles ---------------------------------------------------------------------------------
# minDayValue    liquidity floor, NT$ of turnover
# tSumMin/fSumMin  net-buy sums (SHARES) the chip gate needs
# overheatRet5   5-day return above which the name is dropped as overheated
# distBonus      distance-from-40d-high at/above which the +4 proximity bonus applies
# useCandles     apply the volume/candle structure factors (and the distribution-day rejection)
# momentumBonus  apply the green-light momentum reward
$ScreenProfiles = @{
  stock = @{ minDayValue=1e8; tSumMin=300000;  fSumMin=3000000; overheatRet5=0.25
             distBonus=-0.08; useCandles=$true;  momentumBonus=$true }
  etf   = @{ minDayValue=5e7; tSumMin=200000;  fSumMin=1000000; overheatRet5=0.20
             distBonus=-0.05; useCandles=$false; momentumBonus=$false }
}

function Get-ScoreProfile([string]$Kind){
  if(-not $ScreenProfiles.ContainsKey($Kind)){ throw "unknown screening profile '$Kind'" }
  return $ScreenProfiles[$Kind]
}

# Simple moving average of the last $N values, or $null when there is not enough history.
# screen.ps1's SMAlast and backtest.ps1's three inline Measure-Object slices were all this.
function Get-ScoreSma($Values,[int]$N){
  $a=@($Values)
  if($a.Count -lt $N){ return $null }
  return ($a[($a.Count-$N)..($a.Count-1)] | Measure-Object -Average).Average
}

# --- regime -----------------------------------------------------------------------------------
function Get-RegimeLight {
  <#  The market red/yellow/green light. Three points - index above MA20, institutions net
      buying, more risers than fallers - except that below MA60 is red no matter what. Pure
      function of six scalars; it used to be ten lines of top-level script. #>
  param($IdxLast, $IdxMA20, $IdxMA60, $InstNet, [int]$UpCount, [int]$DownCount)
  $pts=0
  if($IdxLast -gt $IdxMA20){ $pts++ }
  if($null -ne $InstNet -and $InstNet -gt 0){ $pts++ }
  if($UpCount -gt $DownCount){ $pts++ }
  if($null -ne $IdxMA60 -and $IdxLast -lt $IdxMA60){ return 'red' }
  if($pts -eq 3){ return 'green' }
  if($pts -ge 2 -or ($null -ne $IdxMA60 -and $IdxLast -gt $IdxMA60)){ return 'yellow' }
  return 'red'
}

# --- chips ------------------------------------------------------------------------------------
function Get-ChipStats {
  <#  Positive-day counts and sums for the trust (投信) and foreign (外資) net-buy windows. #>
  param($Trust, $Foreign)
  $t=@($Trust); $f=@($Foreign)
  return @{
    tPos=($t | Where-Object { $_ -gt 0 }).Count
    fPos=($f | Where-Object { $_ -gt 0 }).Count
    tSum=($t | Measure-Object -Sum).Sum
    fSum=($f | Measure-Object -Sum).Sum
  }
}

function Test-ChipGate {
  <#  Either a trust run (>=3 positive days and enough volume) or a foreign run (>=4). #>
  param($Stats, $Profile)
  if($Stats.tPos -ge 3 -and $Stats.tSum -gt $Profile.tSumMin){ return $true }
  if($Stats.fPos -ge 4 -and $Stats.fSum -gt $Profile.fSumMin){ return $true }
  return $false
}

function Get-ChipScore {
  <#  0-40: up to 25 for trust days, 10 for foreign days, +5 when margin balance fell (retail
      leaving while institutions buy). #>
  param($Stats, [bool]$MarginDown=$false)
  $s = [math]::Min(25, $Stats.tPos*5) + [math]::Min(10, $Stats.fPos*2)
  if($MarginDown){ $s += 5 }
  return $s
}

# --- technicals -------------------------------------------------------------------------------
function Get-TechScore {
  <#  0-30, plus the reasons a name is rejected outright.

      $Bar  @{ c; o; h; l; chg; vr; val }   last bar; vr = volume vs its own 20-day average
      $Ma   @{ ma20; ma20p; ma60; ret5; dist }
              ma20p = the 20-day average ending 5 bars back (slope), dist = vs the 40-day high
      $Light  'red'|'yellow'|'green'|'na'   'na' disables the momentum reward
      $Profile  from $ScreenProfiles

      Returns @{ Score; Drop; Reason }. Drop=$true means "do not carry this name forward" and is
      how overheating, sub-MA60 and distribution days are expressed - they are rejections, not
      score penalties, and collapsing them into a low score would change what gets screened. #>
  param($Bar, $Ma, [string]$Light='red', $Profile)

  if($Ma.ret5 -gt $Profile.overheatRet5){
    return @{ Score=0; Drop=$true; Reason=("overheated ret5={0}%" -f [math]::Round($Ma.ret5*100,1)) }
  }
  if($null -ne $Ma.ma60 -and $Bar.c -lt $Ma.ma60){
    return @{ Score=0; Drop=$true; Reason='below MA60' }
  }

  $tech=0
  if($null -ne $Ma.ma20 -and $Bar.c -gt $Ma.ma20){ $tech+=10 }
  if($null -ne $Ma.ma60 -and $Bar.c -gt $Ma.ma60){ $tech+=8 }
  if($null -ne $Ma.ma20p -and $Ma.ma20 -gt $Ma.ma20p){ $tech+=5 }
  if($Ma.dist -ge $Profile.distBonus){ $tech+=4 }

  if($Profile.useCandles){
    $rng = if($null -ne $Bar.h -and $null -ne $Bar.l){ $Bar.h-$Bar.l } else { 0 }
    $upWick   = if($rng -gt 0 -and $null -ne $Bar.o){ ($Bar.h-[math]::Max($Bar.o,$Bar.c))/$rng } else { 0 }
    $loWick   = if($rng -gt 0 -and $null -ne $Bar.o){ ([math]::Min($Bar.o,$Bar.c)-$Bar.l)/$rng } else { 0 }
    $closePos = if($rng -gt 0){ ($Bar.c-$Bar.l)/$rng } else { 0.5 }
    # distribution day at the highs: huge volume with a weak close reads as institutions
    # unloading into strength - reject rather than merely score down
    if($Ma.dist -ge -0.03 -and $null -ne $Bar.vr -and $Bar.vr -ge 2 -and
       ($closePos -lt 0.35 -or $upWick -gt 0.6)){
      return @{ Score=0; Drop=$true; Reason=("distribution candle (vr={0})" -f [math]::Round($Bar.vr,1)) }
    }
    if($Bar.chg -gt 0 -and $null -ne $Bar.vr -and $Bar.vr -ge 1.5){ $tech+=4 }        # volume-backed advance
    elseif($Bar.chg -gt 0 -and $null -ne $Bar.val -and $Bar.val -gt 3e8){ $tech+=2 }
    if($Ma.dist -ge -0.03 -and $upWick -gt 0.6 -and $null -ne $Bar.vr -and $Bar.vr -ge 1.2){ $tech-=5 }  # long upper wick at highs
    if($Ma.dist -le -0.10 -and $loWick -gt 0.6){ $tech+=2 }                            # hammer near lows
  } else {
    # ETFs are judged on participation, not candle structure
    if($Bar.chg -gt 0 -and $null -ne $Bar.vr -and $Bar.vr -ge 1.3){ $tech+=3 }
    elseif($Bar.chg -gt 0){ $tech+=1 }
  }

  if($tech -lt 0){ $tech=0 }
  if($Profile.momentumBonus -and $Light -eq 'green' -and $Ma.ret5 -ge 0.03 -and $Ma.ret5 -le 0.15){ $tech+=3 }
  if($tech -gt 30){ $tech=30 }
  return @{ Score=$tech; Drop=$false; Reason=$null }
}

# --- fundamentals -----------------------------------------------------------------------------
function Get-FundScore {
  <#  0-30 from revenue growth, valuation and yield. Non-green regimes additionally reward
      defensive traits. ETFs never reach here - they have no EPS. #>
  param($YoY, $PE, $DividendYield, [string]$Light='red')
  $fund=0
  if($null -ne $YoY){
    if($YoY -ge 100){ $fund+=15 } elseif($YoY -ge 30){ $fund+=12 }
    elseif($YoY -ge 10){ $fund+=8 } elseif($YoY -gt 0){ $fund+=4 }
  }
  if($null -ne $PE -and $PE -gt 0){
    if($PE -le 15){ $fund+=10 } elseif($PE -le 25){ $fund+=7 } elseif($PE -le 40){ $fund+=4 }
  }
  if($null -ne $DividendYield -and $DividendYield -ge 3){ $fund+=5 }
  if($Light -ne 'green'){
    if($null -ne $DividendYield -and $DividendYield -ge 4){ $fund+=3 }
    if($null -ne $PE -and $PE -gt 0 -and $PE -le 15){ $fund+=2 }
  }
  if($fund -gt 30){ $fund=30 }
  return $fund
}

# --- exits ------------------------------------------------------------------------------------
function Get-TotalReturnSeries {
  <#  Dividend-restored closes, oldest first, plus the cumulative payout.

      On an ex-dividend day the exchange reports `chg` against the ADJUSTED reference price, so
      the per-share payout is chg - (close - prevClose). Adding it back makes the moving averages
      continuous: without this a fat dividend gap-down reads as a technical break and fires an
      exit that never happened. The 0.005 floor ignores rounding noise and the 10% cap keeps a
      capital reduction (which is not a dividend) from inventing a huge payout.

      Returns @{ Series; Cum }. `Cum` is what a caller adds to a *snapshot* close taken from a
      different endpoint, which is why it is returned separately rather than folded in. #>
  param($Bars)
  $bs=@($Bars)
  $series=@(); $cum=0.0
  for($k=0;$k -lt $bs.Count;$k++){
    if($k -gt 0 -and $null -ne $bs[$k].chg -and $null -ne $bs[$k].c -and $null -ne $bs[$k-1].c){
      $dv=$bs[$k].chg-($bs[$k].c-$bs[$k-1].c)
      if($dv -gt 0.005 -and $bs[$k-1].c -gt 0 -and ($dv/$bs[$k-1].c) -le 0.10){ $cum+=$dv }
    }
    $series += ($bs[$k].c+$cum)
  }
  return @{ Series=$series; Cum=$cum }
}

function Test-ExitRules {
  <#  Should an open recommendation be closed today? Returns the CJK exit reason stored in
      picks-log.json, or $null to keep holding.

      $ForeignNet          the foreign net-buy window (most recent last)
      $TotalReturnSeries   dividend-restored closes from Get-TotalReturnSeries
      $Current             TODAY's total-return close. Deliberately separate from the series'
                           last element: the series comes from the monthly endpoint, which can
                           lag a day, while the snapshot is current. Collapsing them would
                           silently change which names exit on a lagging day.
      $ReturnPct           total return since entry, in percent

      Three rules, in priority order: foreign investors selling two days running, a break of the
      20-day line, or - once up 15% or more - a break of the 10-day line, which is the trailing
      take-profit. index.html re-implements that last one in JavaScript for the holdings cards;
      that copy is why this needs to stay one definition. #>
  param($ForeignNet, $TotalReturnSeries, $Current, [double]$ReturnPct)
  $f=@($ForeignNet)
  if($f.Count -ge 2 -and $f[$f.Count-1] -lt 0 -and $f[$f.Count-2] -lt 0){ return '外資連2日轉賣' }
  $trS=@($TotalReturnSeries)
  if($trS.Count -ge 20){
    $m20=Get-ScoreSma $trS 20
    if($null -ne $m20 -and $Current -lt $m20){ return '跌破月線' }
    if($ReturnPct -ge 15){
      $m10=Get-ScoreSma $trS 10
      if($null -ne $m10 -and $Current -lt $m10){ return '移動停利（獲利15%+回檔破10日線）' }
    }
  }
  return $null
}
