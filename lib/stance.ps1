# lib/stance.ps1 - the holding-stance rule engine (判級). One implementation of the formula.
#
# Dot-source it:  . (Join-Path $root 'lib/stance.ps1')
#
# This used to exist twice: once here in PowerShell (feeding stance-log.json and evaluate.ps1)
# and once as adviseHolding() in index.html, hand-transcribed into JavaScript. Same thresholds,
# two taxonomies - and they had already drifted: a score of -1 was logged as 'trim' but the page
# rendered it as 'hold', so the largest bucket in the weekly attribution report named a level the
# page never showed. The page now renders the grade this module produces instead of recomputing.
#
# Keep the six levels in sync with index.html's LEVEL_VIEW / STANCE_NM / STANCE_RANK maps and
# evaluate.ps1's bucket list; tests.ps1 [9] asserts LEVEL_VIEW covers every level emitted here.
# (An older comment pointed at a `stanceLevels` key in page-contract.json - that key never
# existed; the page's LEVEL_VIEW is the thing that has to agree with this file.)

# Which formula produced a grade. Stamped onto every stance-log row so evaluate.ps1 can bucket
# by it and never average two engines together - without that, any rewrite of this file makes the
# weekly attribution numbers move for reasons that have nothing to do with the market.
#
#   1  four levels (add/hold/trim/defend), score -4..+4, no confirmation delay. Never stamped:
#      rows from this era predate the field and are identified by the absence of `raw`.
#   2  six levels, score -8..+8, two-day confirmation requiring two identical raw readings.
#      Withdrawn: that rule could freeze a level indefinitely (see the confirmation block below).
#   3  six levels, score -8..+8, hysteresis that always makes progress.
$StanceEngineVersion = 3

# The six levels, best to worst. Rank is the index, so "how far apart are two levels" is just
# arithmetic. Defined here because this is the module that emits them; lib/stance-log.ps1
# dot-sources this file rather than keeping a second copy.
#
# WARNING: index.html's STANCE_RANK runs the OTHER WAY (exit:0 .. add:5) because it answers
# "did this get worse?" with a < comparison. Both are self-consistent and this module only ever
# takes abs() of a difference, so the two never have to agree - but do not assume a rank from one
# side means the same thing on the other.
$StanceLevelOrder = @('add','addwatch','hold','cutwatch','cut','exit')

function Get-StanceLevelRank {
  <#  0..5 for a current level name, $null for anything else - including the retired four-level
      names (trim/defend/up). $null callers must treat as "no opinion", which on the switchover
      day means "just take today's reading". #>
  param([string]$Level)
  $i=[array]::IndexOf($StanceLevelOrder,"$Level")
  if($i -lt 0){ return $null }
  return $i
}

# simple moving average of the last $n values; $null when there is not enough history
function Get-StanceSma($values,$n){
  $a=@($values)
  if($a.Count -lt $n){ return $null }
  $t=0.0
  for($i=$a.Count-$n;$i -lt $a.Count;$i++){ $t += [double]$a[$i] }
  return $t/$n
}

# Grade one holding from its daily series, institutional flow and margin history.
#   $Series     array of bars: o,h,l,c,chg,v (oldest first)
#   $Inst       array of institutional rows with .f (foreign net, lots) - normally the last 5 days
#   $Margin     array of margin rows with .fin/.finPrev
#   $PrevLevel  the previous trade day's *confirmed* level (stance-log's `stance`), or $null
#   $PrevRaw    the previous trade day's *raw* level (stance-log's `raw`), or $null
# Returns $null when there is not enough history to grade (fewer than 25 bars), otherwise an
# ordered map of the four component scores, their total, the raw level and the confirmed level.
#
# Two-day confirmation: with six levels a one-day wobble in any component would flip the badge
# daily, so a new reading has to show up twice in a row before it becomes the level we display
# and log. $PrevLevel/$PrevRaw keep this a pure function - the caller does the file reading.
function Get-StanceGrade {
  param($Series,$Inst,$Margin,$PrevLevel,$PrevRaw)
  $s=@($Series)
  if($s.Count -lt 25){ return $null }
  $cl=@($s | ForEach-Object { $_.c }); $L=$cl.Count; $lastB=$s[$L-1]

  # tech (-3..+3), the dominant term: price above ALL of 5/10/20/60 is the add signal on its own,
  # and below all four is the exit signal on its own. The +-1 rungs are the original rules and
  # still catch everything in between. Order matters - -3 implies -1, so the wide bands go first.
  # The +-2/+-3 rungs all need the 60-day line, so a short-history code (<60 bars, $m60 null)
  # simply falls through to the +-1 behaviour instead of being scored on partial information.
  $m5=Get-StanceSma $cl 5; $m10=Get-StanceSma $cl 10
  $m20=Get-StanceSma $cl 20; $m60=Get-StanceSma $cl 60
  $m20p= if($L -ge 25){ Get-StanceSma ($cl[0..($L-6)]) 20 } else { $null }
  $c=$lastB.c
  $tech=0
  if($m5 -and $m10 -and $m20 -and $m60 -and $c -gt $m5 -and $c -gt $m10 -and $c -gt $m20 -and $c -gt $m60){ $tech=3 }
  elseif($m5 -and $m10 -and $m20 -and $m60 -and $c -gt $m5 -and $c -gt $m10 -and $c -gt $m20){ $tech=2 }
  elseif($m20 -and $c -gt $m20 -and $m20p -and $m20 -gt $m20p){ $tech=1 }
  elseif($m5 -and $m10 -and $m20 -and $m60 -and $c -lt $m5 -and $c -lt $m10 -and $c -lt $m20 -and $c -lt $m60){ $tech=-3 }
  elseif($m10 -and $m20 -and $m60 -and $c -lt $m10 -and $c -lt $m20 -and $c -lt $m60){ $tech=-2 }
  elseif($m60 -and $c -lt $m60){ $tech=-1 }

  # chip (-2..+2): foreign flow only counts when the 5-day sum and the latest day agree (+-1);
  # +-2 additionally needs every day in the window to point the same way - a run, not a net.
  # Deliberately a run rather than "net buy as a share of volume": that would mix $Inst.f with
  # $Series.v, and one wrong unit assumption would silently disable the threshold entirely.
  $f=@($Inst | ForEach-Object { $_.f })
  $chip=0
  if($f.Count){
    $f5=($f | Measure-Object -Sum).Sum; $lf=$f[$f.Count-1]
    if($f5 -gt 0 -and $lf -gt 0){ $chip=1 } elseif($f5 -lt 0 -and $lf -lt 0){ $chip=-1 }
    # 4 is the floor for "a run": a partial feed (1-2 rows fetched) must not earn +-2 for free
    if($chip -ne 0 -and $f.Count -ge 4){
      $allUp=$true; $allDn=$true
      foreach($x in $f){ if($x -le 0){ $allUp=$false }; if($x -ge 0){ $allDn=$false } }
      if($chip -gt 0 -and $allUp){ $chip=2 } elseif($chip -lt 0 -and $allDn){ $chip=-2 }
    }
  }

  # extra: margin moving against the institutions is the tell, so it only fires with chip
  $mgA=@($Margin); $mg= if($mgA.Count){ $mgA[$mgA.Count-1] } else { $null }
  $extra=0
  if($mg -and $mg.finPrev -gt 0){
    $r=($mg.fin-$mg.finPrev)/$mg.finPrev
    if($r -gt 0.03 -and $chip -lt 0){ $extra=-1 } elseif($r -lt -0.02 -and $chip -gt 0){ $extra=1 }
  }

  # vp: volume against candle shape - heavy volume closing weak near the highs is distribution
  $vAvg= if($L -ge 21){ (@($s[($L-21)..($L-2)] | ForEach-Object { $_.v }) | Measure-Object -Average).Average } else { $null }
  $vr= if($vAvg -and $vAvg -gt 0){ $lastB.v/$vAvg } else { $null }
  $rng=$lastB.h-$lastB.l
  $upW= if($rng -gt 0){ ($lastB.h-[math]::Max($lastB.o,$lastB.c))/$rng } else { 0 }
  $cp= if($rng -gt 0){ ($lastB.c-$lastB.l)/$rng } else { 0.5 }
  $n40=[math]::Min(40,$L); $hi40=($cl[($L-$n40)..($L-1)] | Measure-Object -Maximum).Maximum
  # -2 / +2 are the same shapes at a heavier volume multiple: blow-off distribution vs a wide-range
  # up day that also closes near its high (a strong close is what separates it from a volume spike)
  $vp=0
  if(($lastB.c/$hi40-1) -ge -0.03 -and $vr -and $vr -ge 2 -and ($cp -lt 0.35 -or $upW -gt 0.6)){
    $vp= if($vr -ge 3){ -2 } else { -1 }
  }
  elseif($lastB.chg -gt 0 -and $vr -and $vr -ge 1.5){
    $vp= if($vr -ge 2.5 -and $cp -gt 0.65){ 2 } else { 1 }
  }

  # score spans -8..+8. tech=+3 alone reaches 'add' and tech=-3 alone reaches 'exit', but because
  # this is a sum and not an override, chips or volume pointing the other way still pull it back
  # a bucket - a moving-average line-up never outvotes a bad tape.
  $score=$tech+$chip+$extra+$vp
  $raw= if($score -ge 3){'add'} elseif($score -ge 1){'addwatch'} elseif($score -eq 0){'hold'} elseif($score -eq -1){'cutwatch'} elseif($score -eq -2){'cut'} else {'exit'}

  # Confirmation. The point is to swallow a one-day wobble without freezing.
  #
  # v2 required two IDENTICAL raw readings in a row ($PrevRaw -eq $raw). Readings that oscillate
  # between adjacent levels never satisfy that, so the displayed level could stick indefinitely:
  # across the live log 47% of rows were sitting on a suppressed reading and one code held the
  # same stale level for 9 trade days. Code 8150 spent 8/14-8/18 showing 加碼觀察 while the raw
  # reading was cut / cutwatch / cut - the badge said buy for three days of a decline.
  #
  # v3 keeps a one-day delay but guarantees progress. Today's reading is adopted unless it is
  # BOTH adjacent to the current level AND yesterday's reading agreed with the current level -
  # i.e. only an isolated one-rung blip is suppressed. Two rungs or more is a real move and takes
  # effect at once (a 續抱 -> 清倉 crash must not wait for confirmation), and two consecutive days
  # of disagreement always resolve, whatever direction they point in.
  $level=$raw
  if($PrevLevel){
    $rl=Get-StanceLevelRank $PrevLevel
    $rr=Get-StanceLevelRank $raw
    if($null -ne $rl -and $null -ne $rr -and $rr -ne $rl){
      $prevRank=Get-StanceLevelRank $PrevRaw
      $prevAgreed = ($null -eq $prevRank -or $prevRank -eq $rl)
      if([math]::Abs($rr-$rl) -lt 2 -and $prevAgreed){ $level=$PrevLevel }
    }
  }
  return [ordered]@{ score=$score; level=$level; raw=$raw; pending=($level -ne $raw); tech=$tech; chip=$chip; extra=$extra; vp=$vp }
}
