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
# Keep the four levels in sync with page-contract.json's `stanceLevels` and index.html's
# STANCE_NM / STANCE_RANK maps; tests.ps1 [9] asserts they agree.

# simple moving average of the last $n values; $null when there is not enough history
function Get-StanceSma($values,$n){
  $a=@($values)
  if($a.Count -lt $n){ return $null }
  $t=0.0
  for($i=$a.Count-$n;$i -lt $a.Count;$i++){ $t += [double]$a[$i] }
  return $t/$n
}

# Grade one holding from its daily series, institutional flow and margin history.
#   $Series  array of bars: o,h,l,c,chg,v (oldest first)
#   $Inst    array of institutional rows with .f (foreign net, lots)
#   $Margin  array of margin rows with .fin/.finPrev
# Returns $null when there is not enough history to grade (fewer than 25 bars), otherwise an
# ordered map of the four component scores, their total, and the level.
function Get-StanceGrade {
  param($Series,$Inst,$Margin)
  $s=@($Series)
  if($s.Count -lt 25){ return $null }
  $cl=@($s | ForEach-Object { $_.c }); $L=$cl.Count; $lastB=$s[$L-1]

  # tech: above a rising 20-day line is constructive; below the 60-day line is defensive
  $m20=Get-StanceSma $cl 20; $m60=Get-StanceSma $cl 60
  $m20p= if($L -ge 25){ Get-StanceSma ($cl[0..($L-6)]) 20 } else { $null }
  $tech=0
  if($m20 -and $lastB.c -gt $m20 -and $m20p -and $m20 -gt $m20p){ $tech=1 }
  elseif($m60 -and $lastB.c -lt $m60){ $tech=-1 }

  # chip: foreign flow only counts when the 5-day sum and the latest day agree
  $f=@($Inst | ForEach-Object { $_.f })
  $chip=0
  if($f.Count){
    $f5=($f | Measure-Object -Sum).Sum; $lf=$f[$f.Count-1]
    if($f5 -gt 0 -and $lf -gt 0){ $chip=1 } elseif($f5 -lt 0 -and $lf -lt 0){ $chip=-1 }
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
  $vp=0
  if(($lastB.c/$hi40-1) -ge -0.03 -and $vr -and $vr -ge 2 -and ($cp -lt 0.35 -or $upW -gt 0.6)){ $vp=-1 }
  elseif($lastB.chg -gt 0 -and $vr -and $vr -ge 1.5){ $vp=1 }

  $score=$tech+$chip+$extra+$vp
  $level= if($score -ge 2){'up'} elseif($score -ge 0){'hold'} elseif($score -eq -1){'trim'} else {'defend'}
  return [ordered]@{ score=$score; level=$level; tech=$tech; chip=$chip; extra=$extra; vp=$vp }
}
