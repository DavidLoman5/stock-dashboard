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
# weights        how the three faces combine into the 0-100 composite; must sum to 1
$ScreenProfiles = @{
  stock = @{ minDayValue=1e8; tSumMin=300000;  fSumMin=3000000; overheatRet5=0.25
             distBonus=-0.08; useCandles=$true;  momentumBonus=$true
             weights=@{ chip=0.40; tech=0.30; fund=0.30 } }
  etf   = @{ minDayValue=5e7; tSumMin=200000;  fSumMin=1000000; overheatRet5=0.20
             distBonus=-0.05; useCandles=$false; momentumBonus=$false
             weights=@{ chip=(40/70); tech=(30/70); fund=0.0 } }
}

# Each face is scored out of its own legacy maximum and then normalised to 0-100, so the three
# are directly comparable and the composite is a weighted average rather than a sum of unequal
# scales. An ETF has no company fundamentals, so its fund weight is 0 and the other two absorb
# it - which is what finally makes a stock's score and an ETF's score the same number (they were
# 0-100 and 0-70 before, silently incomparable).
#
# The weights above are deliberately the OLD maxima as fractions (40/30/30 and 40/70, 30/70).
# That makes this restructure arithmetically identical to the sum it replaced, so the rewrite
# could be verified to produce the same picks before any new factor was introduced. Changing
# them is a strategy change and needs backtest.ps1's out-of-sample gate, per plan.md's rules.
$ScoreFaceMax = @{ chip=40.0; tech=30.0; fund=30.0 }

function New-FaceScore {
  <#  The uniform shape every face returns.
        Raw     points on that face's own legacy scale (what picks-log.json has always stored)
        Score   the same thing normalised to 0-100, for display and for the composite
        Signals the itemised reasons, which is also exactly what the page's number row renders
        Drop    a rejection, not a low score - see Get-TechScore #>
  param([double]$Raw, [string]$Face, $Signals=@(), [bool]$Drop=$false, [string]$Reason=$null)
  $max=$ScoreFaceMax[$Face]
  $r=[math]::Max(0.0,[math]::Min($max,$Raw))
  return @{ Raw=$r; Score=[math]::Round($r/$max*100,1); Max=$max
            Signals=@($Signals); Drop=$Drop; Reason=$Reason }
}

function New-ScoreSignal {
  <#  One itemised line: what was measured, its value, and what it earned. #>
  param([string]$Key,[string]$Label,$Value,[string]$Unit='',[double]$Pts=0)
  return @{ key=$Key; label=$Label; value=$Value; unit=$Unit; pts=$Pts }
}

function Get-CompositeScore {
  <#  The single 0-100 number the screen ranks on. Faces are the objects from the three
      Get-*Score functions; a $null face contributes nothing and its weight is redistributed
      across the faces that are present, so a stock missing revenue data is not silently
      penalised against one that has it. #>
  param($Tech, $Chip, $Fund, $Profile)
  $w=$Profile.weights
  $parts=@(@{ f=$Chip; w=$w.chip }, @{ f=$Tech; w=$w.tech }, @{ f=$Fund; w=$w.fund })
  $sum=0.0; $wsum=0.0
  foreach($p in $parts){
    if($null -eq $p.f -or $p.w -le 0){ continue }
    $sum += $p.f.Score * $p.w
    $wsum += $p.w
  }
  if($wsum -le 0){ return @{ Total=0.0; Weights=$w } }
  return @{ Total=[math]::Round($sum/$wsum,1); Weights=$w }
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

function Test-RegimeEntryGate {
  <#  May today's top picks be BOOKED as entries (written to picks-log and judged later)?

      No on red. This is the only attribution finding that has cleared the n>=10 bar and kept its
      direction for four consecutive weeks (lessons.md 2026-08-14): entries opened while the index
      sits below its 60-day line closed n=16, 19% win rate, avgAlpha -2.21%, against +0.91% for
      the sample as a whole. Before this gate existed the light only nudged the scoring weights
      and was stamped on the row, so the engine went on taking a bet it had already measured
      itself losing - and those losses then dragged down every other bucket in the report.

      Ranking and display are unaffected: the page still lists the picks under its red banner.
      This decides bookkeeping only, which is why it is a separate function from Get-RegimeLight. #>
  param([string]$Light)
  return ($Light -ne 'red')
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
  <#  Up to 25 for trust days, 10 for foreign days, +5 when margin balance fell (retail leaving
      while institutions buy). Returns the uniform face shape; .Raw is the 0-40 number that
      picks-log.json has always stored, .Score the 0-100 normalisation. #>
  param($Stats, [bool]$MarginDown=$false)
  $tp=[math]::Min(25, $Stats.tPos*5)
  $fp=[math]::Min(10, $Stats.fPos*2)
  $md= if($MarginDown){ 5 } else { 0 }
  $sig=@(
    (New-ScoreSignal -Key 'trustDays'   -Label '投信買超天數' -Value $Stats.tPos -Unit '日' -Pts $tp)
    (New-ScoreSignal -Key 'foreignDays' -Label '外資買超天數' -Value $Stats.fPos -Unit '日' -Pts $fp)
    # sums are context, not points - the counts above are what the score is made of. Unit is
    # SHARES here because that is what the exchange publishes; callers divide by 1000 to show 張.
    (New-ScoreSignal -Key 'trustSum'    -Label '投信5日合計' -Value $Stats.tSum -Unit '股')
    (New-ScoreSignal -Key 'foreignSum'  -Label '外資5日合計' -Value $Stats.fSum -Unit '股')
    (New-ScoreSignal -Key 'marginDown'  -Label '融資餘額下降' -Value $MarginDown -Pts $md)
  )
  return New-FaceScore -Raw ($tp+$fp+$md) -Face 'chip' -Signals $sig
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
    return New-FaceScore -Raw 0 -Face 'tech' -Drop $true -Reason ("overheated ret5={0}%" -f [math]::Round($Ma.ret5*100,1))
  }
  if($null -ne $Ma.ma60 -and $Bar.c -lt $Ma.ma60){
    return New-FaceScore -Raw 0 -Face 'tech' -Drop $true -Reason 'below MA60'
  }

  $tech=0
  $sig=@()
  $aboveMa20 = ($null -ne $Ma.ma20 -and $Bar.c -gt $Ma.ma20)
  $aboveMa60 = ($null -ne $Ma.ma60 -and $Bar.c -gt $Ma.ma60)
  $slopeUp   = ($null -ne $Ma.ma20p -and $Ma.ma20 -gt $Ma.ma20p)
  if($aboveMa20){ $tech+=10 }
  if($aboveMa60){ $tech+=8 }
  if($slopeUp){ $tech+=5 }
  $sig+=(New-ScoreSignal -Key 'ma20' -Label '站上月線' -Value $(if($null -ne $Ma.ma20){[math]::Round($Ma.ma20,2)}else{$null}) -Pts $(if($aboveMa20){10}else{0}))
  $sig+=(New-ScoreSignal -Key 'ma60' -Label '站上季線' -Value $(if($null -ne $Ma.ma60){[math]::Round($Ma.ma60,2)}else{$null}) -Pts $(if($aboveMa60){8}else{0}))
  $sig+=(New-ScoreSignal -Key 'ma20slope' -Label '月線上揚' -Value $slopeUp -Pts $(if($slopeUp){5}else{0}))
  $nearHigh = ($Ma.dist -ge $Profile.distBonus)
  if($nearHigh){ $tech+=4 }
  $sig+=(New-ScoreSignal -Key 'distHigh40' -Label '距40日高' -Value $(if($null -ne $Ma.dist){[math]::Round($Ma.dist*100,1)}else{$null}) -Unit '%' -Pts $(if($nearHigh){4}else{0}))

  if($Profile.useCandles){
    $rng = if($null -ne $Bar.h -and $null -ne $Bar.l){ $Bar.h-$Bar.l } else { 0 }
    $upWick   = if($rng -gt 0 -and $null -ne $Bar.o){ ($Bar.h-[math]::Max($Bar.o,$Bar.c))/$rng } else { 0 }
    $loWick   = if($rng -gt 0 -and $null -ne $Bar.o){ ([math]::Min($Bar.o,$Bar.c)-$Bar.l)/$rng } else { 0 }
    $closePos = if($rng -gt 0){ ($Bar.c-$Bar.l)/$rng } else { 0.5 }
    # distribution day at the highs: huge volume with a weak close reads as institutions
    # unloading into strength - reject rather than merely score down
    if($Ma.dist -ge -0.03 -and $null -ne $Bar.vr -and $Bar.vr -ge 2 -and
       ($closePos -lt 0.35 -or $upWick -gt 0.6)){
      return New-FaceScore -Raw 0 -Face 'tech' -Drop $true -Reason ("distribution candle (vr={0})" -f [math]::Round($Bar.vr,1))
    }
    $vp=0
    if($Bar.chg -gt 0 -and $null -ne $Bar.vr -and $Bar.vr -ge 1.5){ $vp=4 }        # volume-backed advance
    elseif($Bar.chg -gt 0 -and $null -ne $Bar.val -and $Bar.val -gt 3e8){ $vp=2 }
    $wick=0
    if($Ma.dist -ge -0.03 -and $upWick -gt 0.6 -and $null -ne $Bar.vr -and $Bar.vr -ge 1.2){ $wick=-5 }  # long upper wick at highs
    $hammer=0
    if($Ma.dist -le -0.10 -and $loWick -gt 0.6){ $hammer=2 }                        # hammer near lows
    $tech += $vp + $wick + $hammer
    $sig+=(New-ScoreSignal -Key 'volume' -Label '量價配合' -Value $(if($null -ne $Bar.vr){[math]::Round($Bar.vr,2)}else{$null}) -Unit '倍' -Pts $vp)
    if($wick -ne 0){ $sig+=(New-ScoreSignal -Key 'upperWick' -Label '高檔長上影' -Value ([math]::Round($upWick,2)) -Pts $wick) }
    if($hammer -ne 0){ $sig+=(New-ScoreSignal -Key 'hammer' -Label '低檔錘子' -Value ([math]::Round($loWick,2)) -Pts $hammer) }
  } else {
    # ETFs are judged on participation, not candle structure
    $vp=0
    if($Bar.chg -gt 0 -and $null -ne $Bar.vr -and $Bar.vr -ge 1.3){ $vp=3 }
    elseif($Bar.chg -gt 0){ $vp=1 }
    $tech += $vp
    $sig+=(New-ScoreSignal -Key 'participation' -Label '量能參與' -Value $(if($null -ne $Bar.vr){[math]::Round($Bar.vr,2)}else{$null}) -Unit '倍' -Pts $vp)
  }

  # floor BEFORE the momentum reward, exactly as the original did: the reward is not allowed to
  # be cancelled by penalties that have already been clamped away
  if($tech -lt 0){ $tech=0 }
  $mom=0
  if($Profile.momentumBonus -and $Light -eq 'green' -and $Ma.ret5 -ge 0.03 -and $Ma.ret5 -le 0.15){ $mom=3 }
  $tech += $mom
  if($mom -ne 0){ $sig+=(New-ScoreSignal -Key 'momentum' -Label '綠燈動能' -Value ([math]::Round($Ma.ret5*100,1)) -Unit '%' -Pts $mom) }
  return New-FaceScore -Raw $tech -Face 'tech' -Signals $sig
}

# --- fundamentals -----------------------------------------------------------------------------
function Get-FundScore {
  <#  Revenue growth, valuation and yield. Non-green regimes additionally reward defensive
      traits. ETFs never reach here - they have no company financials, which is also why the ETF
      profile gives this face weight 0 rather than scoring it as a zero.

      $MoM / $YoYCum are context only and earn no points yet. They come from the same monthly
      response as $YoY and were simply never parsed, so single-month YoY was the only revenue
      figure anywhere in the system - and it cannot distinguish "growing" from "growing more
      slowly", nor a one-month spike from a trend. 2454 currently reads YoY +12.2% with MoM
      -16.4% and cumulative +0.8%; 3661 reads YoY +181.8% with cumulative -13.8%. Scoring them
      needs backtest.ps1's out-of-sample gate, and fund factors cannot be backtested at all yet
      (no revenue/PE history panel - backtest.ps1's own header says so), so they are surfaced as
      signals for a human to read while evaluate.ps1's weekly byFund buckets accumulate. #>
  param($YoY, $PE, $DividendYield, [string]$Light='red', $MoM=$null, $YoYCum=$null)
  $fund=0
  $sig=@()
  $yp=0
  if($null -ne $YoY){
    if($YoY -ge 100){ $yp=15 } elseif($YoY -ge 30){ $yp=12 }
    elseif($YoY -ge 10){ $yp=8 } elseif($YoY -gt 0){ $yp=4 }
  }
  $fund+=$yp
  $sig+=(New-ScoreSignal -Key 'yoy' -Label '月營收YoY' -Value $YoY -Unit '%' -Pts $yp)
  if($null -ne $YoYCum){ $sig+=(New-ScoreSignal -Key 'yoyCum' -Label '累計營收YoY' -Value $YoYCum -Unit '%') }
  if($null -ne $MoM){ $sig+=(New-ScoreSignal -Key 'mom' -Label '月營收MoM' -Value $MoM -Unit '%') }

  $pp=0
  if($null -ne $PE -and $PE -gt 0){
    if($PE -le 15){ $pp=10 } elseif($PE -le 25){ $pp=7 } elseif($PE -le 40){ $pp=4 }
  }
  $fund+=$pp
  $sig+=(New-ScoreSignal -Key 'pe' -Label '本益比' -Value $PE -Unit '倍' -Pts $pp)

  $dp=0
  if($null -ne $DividendYield -and $DividendYield -ge 3){ $dp=5 }
  $fund+=$dp
  $sig+=(New-ScoreSignal -Key 'dy' -Label '殖利率' -Value $DividendYield -Unit '%' -Pts $dp)

  $def=0
  if($Light -ne 'green'){
    if($null -ne $DividendYield -and $DividendYield -ge 4){ $def+=3 }
    if($null -ne $PE -and $PE -gt 0 -and $PE -le 15){ $def+=2 }
  }
  $fund+=$def
  if($def -ne 0){ $sig+=(New-ScoreSignal -Key 'defensive' -Label '非綠燈防禦加分' -Value $Light -Pts $def) }
  return New-FaceScore -Raw $fund -Face 'fund' -Signals $sig
}

function Get-FundSignal {
  <#  The fundamentals face as a display chip: @(kind, short label), kind in bull|neu|bear.

      The page's other two chips have always come from the engine; only the fundamentals one was
      written by the AI, which meant a label with no defined relationship to any number on the
      page. Same split as everywhere else now - the engine decides the direction, the AI writes
      the prose explaining it.

      $Face is a Get-FundScore result, or $null for an ETF (no company financials). "No data" and
      "scored zero" are different answers and must not render the same: a loss-making company
      with a negative PE really is weak, an ETF simply has nothing to score. #>
  param($Face)
  if($null -eq $Face){ return @('neu','ETF無個別基本面') }
  $known=@($Face.Signals | Where-Object { $_.key -in @('yoy','pe','dy') -and $null -ne $_.value })
  if($known.Count -eq 0){ return @('neu','基本面資料不足') }
  $s=$Face.Score
  if($s -ge 67){ return @('bull','基本面強') }
  if($s -ge 34){ return @('neu','基本面中性') }
  return @('bear','基本面偏弱')
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
