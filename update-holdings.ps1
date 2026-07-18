# update-holdings.ps1 - fully scripted fetch of holdings' official TWSE data.
# AI never sees raw API responses: this script fetches, computes, and splices
# window.DASH / window.META / window.HOLDINGS_META directly into index.html,
# then writes a small holdings-context.json for the AI to read for writing analysis text.
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Num($s){ if($null -eq $s){return $null}; $t=("$s" -replace '[^0-9\.\-]',''); if($t -notmatch '[0-9]'){return $null}; try{ return [double]$t }catch{ return $null } }
function GetJson($url){
  for($i=0;$i -lt 3;$i++){
    try{
      $resp=Invoke-WebRequest -Uri $url -TimeoutSec 45 -UseBasicParsing
      $txt=[System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
      return ($txt | ConvertFrom-Json)
    }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}
function SMAlast($a,$n){ if($a.Count -lt $n){return $null}; ($a[($a.Count-$n)..($a.Count-1)] | Measure-Object -Average).Average }

Write-Host "[1/6] holdings.json..."
$hj = Get-Content (Join-Path $root 'holdings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$codes = @($hj.holdings | ForEach-Object { "$($_.code)" })
Write-Host "  codes: $($codes -join ', ')"

Write-Host "[2/6] STOCK_DAY per holding (4 months) + FMTQIK (TAIEX)..."
$today = Get-Date
$months=@(); for($m=3;$m -ge 0;$m--){ $months += $today.AddMonths(-$m).ToString('yyyyMM01') }
$DASH=[ordered]@{}
$tx=@(); $tradeDates=@()
foreach($mm in $months){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/FMTQIK?date=$mm&response=json"
  if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){
    $p="$($d[0])".Split('/'); $tradeDates += ("{0}{1}{2}" -f ([int]$p[0]+1911),$p[1],$p[2])
    $tx += [ordered]@{ d=("{0}/{1}" -f [int]$p[1],[int]$p[2]); c=[double](Num $d[4]); chg=(Num $d[5]); amt=[math]::Round((Num $d[2])/1e8,0) }
  } }
  Start-Sleep -Milliseconds 700
}
$DASH['TAIEX']=$tx
# FATAL guard: without index history we would splice a broken DASH and blank the whole page
if($tx.Count -lt 10){ Write-Host "FATAL: FMTQIK returned $($tx.Count) rows - aborting, index.html untouched"; exit 1 }
$lastDate = $tradeDates[$tradeDates.Count-1]
Write-Host "  latest trade date = $lastDate ($($tx.Count) TAIEX rows)"

foreach($c in $codes){
  $serF=@()
  foreach($mm in $months){
    $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?date=$mm&stockNo=$c&response=json"
    if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){
      $p="$($d[0])".Split('/')
      $serF += [ordered]@{ d=("{0}/{1}" -f [int]$p[1],[int]$p[2]); o=(Num $d[3]); h=(Num $d[4]); l=(Num $d[5]); c=[double](Num $d[6]); chg=(Num $d[7]); v=[math]::Round((Num $d[1])/1000,0) }
    } }
    Start-Sleep -Milliseconds 700
  }
  $DASH[$c]=[ordered]@{ series=$serF; inst=@(); margin=@() }
  Write-Host "  $c series=$($serF.Count)"
}
# FATAL guard: page hydrate() crashes on an empty series (whole dashboard goes blank)
$empty=@($codes | Where-Object { @($DASH[$_].series).Count -lt 25 })
if($empty.Count -gt 0){ Write-Host "FATAL: series too short for $($empty -join ',') - aborting, index.html untouched"; exit 1 }

Write-Host "[3/6] T86 (5 days) + MI_MARGN (3 days)..."
$last5 = $tradeDates | Select-Object -Last 5
foreach($d in $last5){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/fund/T86?date=$d&selectType=ALL&response=json"
  if($r -and $r.stat -eq 'OK'){
    foreach($row in $r.data){
      $c="$($row[0])".Trim()
      if($codes -contains $c){
        $dd=("{0}/{1}" -f [int]$d.Substring(4,2),[int]$d.Substring(6,2))
        $DASH[$c].inst += [ordered]@{ d=$dd; f=[math]::Round((Num $row[4])/1000,0); t=[math]::Round((Num $row[10])/1000,0); de=[math]::Round((Num $row[11])/1000,0); tot=[math]::Round((Num $row[18])/1000,0) }
      }
    }
  }
  Start-Sleep -Milliseconds 800
}
$last3 = $tradeDates | Select-Object -Last 3
foreach($d in $last3){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/marginTrading/MI_MARGN?date=$d&selectType=ALL&response=json"
  if($r){
    $tbl=$r.tables | Where-Object { $_.fields -and $_.fields[0] -eq '代號' } | Select-Object -First 1
    if($tbl){
      foreach($row in $tbl.data){
        $c="$($row[0])".Trim()
        if($codes -contains $c){
          $dd=("{0}/{1}" -f [int]$d.Substring(4,2),[int]$d.Substring(6,2))
          $DASH[$c].margin += [ordered]@{ d=$dd; fin=[int](Num $row[6]); finPrev=[int](Num $row[5]); shrt=[int](Num $row[12]); shrtPrev=[int](Num $row[11]) }
        }
      }
    }
  }
  Start-Sleep -Milliseconds 800
}

Write-Host "[4/6] TWT48U_ALL (ex-dividend)..."
$divMap=@{}
$r=GetJson "https://openapi.twse.com.tw/v1/exchangeReport/TWT48U_ALL"
if($r){
  foreach($row in $r){
    $c="$($row.Code)".Trim()
    if($codes -contains $c){
      $ds="$($row.Date)"
      if($ds.Length -eq 7){
        $y=[int]$ds.Substring(0,3)+1911; $mo=[int]$ds.Substring(3,2); $da=[int]$ds.Substring(5,2)
        $exDate=Get-Date -Year $y -Month $mo -Day $da
        if($exDate -ge $today.Date){ $divMap[$c]="$mo/$da 除息" }
      }
    }
  }
}
Write-Host "  div notes: $($divMap.Count) upcoming"

Write-Host "[5/6] compute holdings-context.json (small, for AI to read) + HOLDINGS_META..."
$HOLDINGS_META=[ordered]@{}
$context=@()
foreach($h in $hj.holdings){
  $c="$($h.code)"
  $HOLDINGS_META[$c]=[ordered]@{ name=$h.name; type=$h.type; theme=$h.theme; lots=$h.lots; color=$h.color; techLike=$(if($h.PSObject.Properties['techLike']){[bool]$h.techLike}else{$false}); divNote=$(if($divMap.ContainsKey($c)){$divMap[$c]}else{$null}) }
  $ser=@($DASH[$c].series | ForEach-Object { $_.c })
  if($ser.Count -lt 1){ continue }
  $last=$DASH[$c].series[$DASH[$c].series.Count-1]
  $ma20=SMAlast $ser 20; $ma60=SMAlast $ser 60
  $ma20p = if($ser.Count -ge 25){ SMAlast ($ser[0..($ser.Count-6)]) 20 } else { $null }
  $n40=[math]::Min(40,$ser.Count); $hi40=($ser[($ser.Count-$n40)..($ser.Count-1)] | Measure-Object -Maximum).Maximum
  $inst=$DASH[$c].inst; $fSum=($inst | ForEach-Object {$_.f} | Measure-Object -Sum).Sum; $fLast2 = if($inst.Count -ge 2){ @($inst[-2].f,$inst[-1].f) } else { @() }
  $mg = if($DASH[$c].margin.Count){ $DASH[$c].margin[$DASH[$c].margin.Count-1] } else { $null }
  $marginDelta = if($mg){ $mg.fin-$mg.finPrev } else { $null }
  $context += [pscustomobject]@{
    code=$c; name=$h.name
    price=$last.c; chg=$last.chg; pct=[math]::Round($last.chg/($last.c-$last.chg)*100,2)
    ma20=$(if($ma20){[math]::Round($ma20,2)}else{$null}); ma60=$(if($ma60){[math]::Round($ma60,2)}else{$null})
    ma20SlopeUp=$(if($ma20 -and $ma20p){$ma20 -gt $ma20p}else{$null})
    distFromHigh40=[math]::Round(($last.c/$hi40-1)*100,1)
    foreignSum5d=$fSum; foreignLast2=$fLast2
    marginToday=$(if($mg){$mg.fin}else{$null}); marginDelta=$marginDelta
    divNote=$(if($divMap.ContainsKey($c)){$divMap[$c]}else{$null})
  }
}
$context | ConvertTo-Json -Depth 5 | Out-File (Join-Path $root 'holdings-context.json') -Encoding UTF8
Write-Host "  wrote holdings-context.json ($($context.Count) holdings)"

Write-Host "[5b/6] stance-log.json (rule-engine stance per holding; mirrors page adviseHolding, for evaluate.ps1 validation)..."
$stancePath=Join-Path $root 'stance-log.json'
$slog=@()
if(Test-Path $stancePath){ try{ $slog=@((Get-Content $stancePath -Raw -Encoding UTF8 | ConvertFrom-Json).rows) }catch{ $slog=@() } }
$already=@($slog | Where-Object { $_.date -eq $lastDate }).Count -gt 0
if(-not $already){
  foreach($c in $codes){
    $s=@($DASH[$c].series); if($s.Count -lt 25){ continue }
    $cl=@($s | ForEach-Object { $_.c }); $L=$cl.Count; $lastB=$s[$L-1]
    $m20=SMAlast $cl 20; $m60=SMAlast $cl 60
    $m20p= if($L -ge 25){ SMAlast ($cl[0..($L-6)]) 20 } else { $null }
    $tech=0
    if($m20 -and $lastB.c -gt $m20 -and $m20p -and $m20 -gt $m20p){ $tech=1 }
    elseif($m60 -and $lastB.c -lt $m60){ $tech=-1 }
    $f=@($DASH[$c].inst | ForEach-Object { $_.f })
    $chip2=0
    if($f.Count){ $f5=($f | Measure-Object -Sum).Sum; $lf=$f[$f.Count-1]
      if($f5 -gt 0 -and $lf -gt 0){ $chip2=1 } elseif($f5 -lt 0 -and $lf -lt 0){ $chip2=-1 } }
    $mgA=@($DASH[$c].margin); $mg= if($mgA.Count){ $mgA[$mgA.Count-1] } else { $null }
    $extra=0
    if($mg -and $mg.finPrev -gt 0){ $r2=($mg.fin-$mg.finPrev)/$mg.finPrev
      if($r2 -gt 0.03 -and $chip2 -lt 0){ $extra=-1 } elseif($r2 -lt -0.02 -and $chip2 -gt 0){ $extra=1 } }
    $vAvg= if($L -ge 21){ (@($s[($L-21)..($L-2)] | ForEach-Object { $_.v }) | Measure-Object -Average).Average } else { $null }
    $vr= if($vAvg -and $vAvg -gt 0){ $lastB.v/$vAvg } else { $null }
    $rng=$lastB.h-$lastB.l
    $upW= if($rng -gt 0){ ($lastB.h-[math]::Max($lastB.o,$lastB.c))/$rng } else { 0 }
    $cp2= if($rng -gt 0){ ($lastB.c-$lastB.l)/$rng } else { 0.5 }
    $n40=[math]::Min(40,$L); $hi40=($cl[($L-$n40)..($L-1)] | Measure-Object -Maximum).Maximum
    $vp=0
    if(($lastB.c/$hi40-1) -ge -0.03 -and $vr -and $vr -ge 2 -and ($cp2 -lt 0.35 -or $upW -gt 0.6)){ $vp=-1 }
    elseif($lastB.chg -gt 0 -and $vr -and $vr -ge 1.5){ $vp=1 }
    $sc=$tech+$chip2+$extra+$vp
    $lv= if($sc -ge 2){'up'} elseif($sc -ge 0){'hold'} elseif($sc -eq -1){'trim'} else {'defend'}
    $slog += ,@{ date=$lastDate; code=$c; close=$lastB.c; score=$sc; stance=$lv }
  }
  @{ rows=$slog } | ConvertTo-Json -Depth 4 | Out-File $stancePath -Encoding UTF8
  Write-Host "  stance-log: appended rows for $lastDate (total $($slog.Count))"
} else { Write-Host "  stance-log: $lastDate already logged" }

Write-Host "[6/6] splice window.DASH / window.META / window.HOLDINGS_META into index.html..."
$idxPath=Join-Path $root 'index.html'
$enc=New-Object System.Text.UTF8Encoding($false)
$html=[IO.File]::ReadAllText($idxPath,$enc)
function Splice([string]$html,[string]$marker,[string]$payload){
  $st='<script id="'+$marker+'">'
  $i1=$html.IndexOf($st)
  if($i1 -lt 0){ Write-Host "  marker $marker not found - skip"; return $html }
  $i2=$html.IndexOf('</script>',$i1)
  return $html.Substring(0,$i1+$st.Length)+$payload+$html.Substring($i2)
}
$html = Splice $html 'dashdata' ('window.DASH='+($DASH|ConvertTo-Json -Depth 6 -Compress)+';')
$html = Splice $html 'holdingsmeta' ('window.HOLDINGS_META='+($HOLDINGS_META|ConvertTo-Json -Depth 4 -Compress)+';')
$genDate = $today.ToString('yyyy/MM/dd')
$lastTradeIso = "$($lastDate.Substring(0,4))-$($lastDate.Substring(4,2))-$($lastDate.Substring(6,2))"
$html = $html -replace 'window\.META=\{[^}]*\};', ("window.META={generated:'$genDate',lastTrade:'$lastTradeIso'};")
$html = $html -replace '報告日期：<b>[^<]*</b>', "報告日期：<b>$genDate</b>"
[IO.File]::WriteAllText($idxPath,$html,$enc)
Write-Host "DONE. lastTrade=$lastDate holdings=$($codes.Count) divNotes=$($divMap.Count)"