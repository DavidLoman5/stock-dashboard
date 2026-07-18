# backtest.ps1 - validate screening weights on historical data (research tool, run manually)
# Method: rebuild chip gate + simplified tech daily over ~75 trading days; measure 20-day forward alpha vs TAIEX.
# Note: overlapping windows -> stats are indicative, not iid. Fund factor (revenue/PE history) not replayable, tested configs are chip/tech only.
$ErrorActionPreference='Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Num($s){ if($null -eq $s){return $null}; $t=("$s" -replace '[^0-9\.\-]',''); if($t -notmatch '[0-9]'){return $null}; try{ return [double]$t }catch{ return $null } }
function GetJson($url){
  for($i=0;$i -lt 3;$i++){
    try{
      $resp=Invoke-WebRequest -Uri $url -TimeoutSec 60 -UseBasicParsing
      $txt=[System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
      return ($txt | ConvertFrom-Json)
    }catch{ Start-Sleep -Milliseconds 1500 }
  }
  return $null
}

Write-Host "[1/4] trade dates + index closes (FMTQIK 5 months)..."
$months=@(); $now=Get-Date
for($m=4;$m -ge 0;$m--){ $months += $now.AddMonths(-$m).ToString('yyyyMM01') }
$dates=@(); $idxMapBT=@{}
foreach($mm in $months){
  $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/FMTQIK?date=$mm&response=json"
  if($r -and $r.stat -eq 'OK'){ foreach($d in $r.data){
    $p="$($d[0])".Split('/'); $dt=("{0}{1}{2}" -f ([int]$p[0]+1911),$p[1],$p[2])
    $dates += $dt; $idxMapBT[$dt]=[double](Num $d[4])
  } }
  Start-Sleep -Milliseconds 700
}
# regime map from the FULL 5-month window (before trim): index vs MA60 -> bull/bear per date
$datesAll=@($dates)
$idxAll=@(); foreach($d in $datesAll){ $idxAll += $idxMapBT[$d] }
$regMap=@{}
for($ri=0;$ri -lt $datesAll.Count;$ri++){
  if($ri -ge 59){
    $m=($idxAll[($ri-59)..$ri] | Measure-Object -Average).Average
    $regMap[$datesAll[$ri]]=$(if($idxAll[$ri] -ge $m){'bull'}else{'bear'})
  }
}
if($dates.Count -gt 78){ $dates=@($dates | Select-Object -Last 78) }
Write-Host "  trade dates = $($dates.Count) ($($dates[0])..$($dates[-1]))"

Write-Host "[2/4] daily panels: MI_INDEX px + T86 chips ($($dates.Count) days x2, ~4min)..."
$pxDay=@{}; $t86Day=@{}
$di=0
foreach($d in $dates){
  $di++
  # all-stock closes for the day
  $r=GetJson "https://www.twse.com.tw/rwd/zh/afterTrading/MI_INDEX?date=$d&type=ALLBUT0999&response=json"
  $pm=@{}
  if($r -and $r.tables){
    $tbl=$r.tables | Where-Object { $_.data -and $_.data.Count -gt 500 } | Select-Object -First 1
    if($tbl){ foreach($row in $tbl.data){
      $c="$($row[0])".Trim()
      if($c -match '^[1-9][0-9]{3}$'){
        $cl=Num $row[8]; $val=Num $row[4]
        if($cl -ne $null){ $pm[$c]=@{ c=$cl; val=$val } }
      }
    } }
  }
  $pxDay[$d]=$pm
  Start-Sleep -Milliseconds 700
  # chips for the day
  $r=GetJson "https://www.twse.com.tw/rwd/zh/fund/T86?date=$d&selectType=ALL&response=json"
  $tm=@{}
  if($r -and $r.stat -eq 'OK'){ foreach($row in $r.data){
    $c="$($row[0])".Trim()
    if($c -match '^[1-9][0-9]{3}$'){ $tm[$c]=@{ f=[double](Num $row[4]); t=[double](Num $row[10]) } }
  } }
  $t86Day[$d]=$tm
  Start-Sleep -Milliseconds 700
  if($di % 10 -eq 0){ Write-Host "  ...$di/$($dates.Count) days (px=$($pm.Count) chips=$($tm.Count))" }
}

Write-Host "[3/4] replay screening daily..."
function CloseAt($code,$i){ $m=$pxDay[$dates[$i]]; if($m.ContainsKey($code)){ return $m[$code].c } return $null }
$cfgs=@(
  @{ name='chip+tech (current)'; useChip=$true; useTech=$true },
  @{ name='chip only';           useChip=$true; useTech=$false },
  @{ name='tech only';           useChip=$false; useTech=$true }
)
$results=@{}; foreach($cf in $cfgs){ $results[$cf.name]=@() }
$N=$dates.Count
for($i=24; $i -le $N-21; $i++){
  $d=$dates[$i]
  $tm=$t86Day[$d]; if(-not $tm -or $tm.Count -lt 100){ continue }
  $scored=@()
  foreach($code in $tm.Keys){
    $pxm=$pxDay[$d]
    if(-not $pxm.ContainsKey($code)){ continue }
    if($pxm[$code].val -lt 1e8){ continue }
    # 5-day chip window
    $tArr=@(); $fArr=@(); $okWin=$true
    for($k=$i-4;$k -le $i;$k++){ $w=$t86Day[$dates[$k]]; if($w.ContainsKey($code)){ $tArr+=$w[$code].t; $fArr+=$w[$code].f } else { $okWin=$false; break } }
    if(-not $okWin -or $tArr.Count -lt 5){ continue }
    $tPos=($tArr|Where-Object{$_ -gt 0}).Count; $fPos=($fArr|Where-Object{$_ -gt 0}).Count
    $tSum=($tArr|Measure-Object -Sum).Sum; $fSum=($fArr|Measure-Object -Sum).Sum
    $gate=$false
    if($tPos -ge 3 -and $tSum -gt 300000){ $gate=$true }
    if($fPos -ge 4 -and $fSum -gt 3000000){ $gate=$true }
    if(-not $gate){ continue }
    $chipS=[math]::Min(25,$tPos*5)+[math]::Min(10,$fPos*2)
    # simplified tech from px panel: MA20, slope, dist40, ret5
    $cl=CloseAt $code $i; if($cl -eq $null){ continue }
    $hist=@(); $miss=$false
    for($k=$i-23;$k -le $i;$k++){ $v=CloseAt $code $k; if($v -eq $null){ $miss=$true; break }; $hist+=$v }
    if($miss){ continue }
    $ma20=($hist[($hist.Count-20)..($hist.Count-1)]|Measure-Object -Average).Average
    $ma20p=($hist[($hist.Count-24)..($hist.Count-5)]|Measure-Object -Average).Average
    $ret5=$cl/$hist[$hist.Count-6]-1
    if($ret5 -gt 0.25){ continue }
    $hi=($hist|Measure-Object -Maximum).Maximum
    $techS=0
    if($cl -gt $ma20){ $techS+=10 }
    if($ma20 -gt $ma20p){ $techS+=5 }
    if($cl/$hi-1 -ge -0.08){ $techS+=4 }
    $scored += [pscustomobject]@{ code=$code; chip=$chipS; tech=$techS; tSum=$tSum }
  }
  if($scored.Count -eq 0){ continue }
  # forward 20-day alpha
  $idx0=$idxMapBT[$d]; $idx1=$idxMapBT[$dates[$i+20]]
  foreach($cf in $cfgs){
    $ranked=$scored | Sort-Object -Property @{e={ $s=0; if($cf.useChip){$s+=$_.chip}; if($cf.useTech){$s+=$_.tech}; $s };Descending=$true}, @{e='tSum';Descending=$true}
    $top=@($ranked | Select-Object -First 5)
    foreach($p in $top){
      $c0=CloseAt $p.code $i; $c1=CloseAt $p.code ($i+20)
      if($c0 -eq $null -or $c1 -eq $null -or $c0 -le 0){ continue }
      $ret=($c1/$c0-1)*100
      $ir=($idx1/$idx0-1)*100
      $results[$cf.name] += [pscustomobject]@{ date=$d; code=$p.code; ret=[math]::Round($ret,2); alpha=[math]::Round($ret-$ir,2); regime=$(if($regMap.ContainsKey($d)){$regMap[$d]}else{'na'}) }
    }
  }
  if(($i-24) % 10 -eq 0){ Write-Host "  eval $($i-23)/$($N-44) date=$d candidates=$($scored.Count)" }
}

Write-Host "[4/4] results"
$summary=@{}
foreach($cf in $cfgs){
  $rows=$results[$cf.name]
  if($rows.Count -eq 0){ Write-Host "  $($cf.name): no samples"; continue }
  $win=($rows|Where-Object{$_.alpha -gt 0}).Count
  $avgA=[math]::Round(($rows|Measure-Object -Property alpha -Average).Average,2)
  $avgR=[math]::Round(($rows|Measure-Object -Property ret -Average).Average,2)
  $wr=[math]::Round($win/$rows.Count*100,1)
  $summary[$cf.name]=@{ n=$rows.Count; winRate=$wr; avgAlpha=$avgA; avgRet=$avgR }
  # split by regime at entry (bull/bear vs MA60) - answers "does tech weighting hold up in downtrends?"
  foreach($rg in @('bull','bear')){
    $rr=@($rows | Where-Object {$_.regime -eq $rg})
    if($rr.Count -gt 0){
      $w2=($rr | Where-Object {$_.alpha -gt 0}).Count
      $summary[$cf.name][$rg]=@{ n=$rr.Count; winRate=[math]::Round($w2/$rr.Count*100,1); avgAlpha=[math]::Round(($rr|Measure-Object -Property alpha -Average).Average,2) }
      Write-Host ("    [{0}] n={1} winRate={2}% avgAlpha={3}%" -f $rg,$rr.Count,$summary[$cf.name][$rg].winRate,$summary[$cf.name][$rg].avgAlpha)
    }
  }
  Write-Host ("  {0}: n={1} winRate={2}% avgRet={3}% avgAlpha={4}%" -f $cf.name,$rows.Count,$wr,$avgR,$avgA)
}
@{ generated=(Get-Date -Format 'yyyy-MM-dd HH:mm'); period="$($dates[0])..$($dates[-1])"; note='overlapping windows; chip/tech only (fund factor not replayable); 20-day forward; top5 daily'; summary=$summary } |
  ConvertTo-Json -Depth 4 | Out-File (Join-Path $root 'backtest-result.json') -Encoding UTF8
Write-Host "saved backtest-result.json"

# splice into dashboard <script id="backtest"> so the card auto-updates
$fmtP="{0}/{1}/{2}–{3}/{4}/{5}" -f $dates[0].Substring(0,4),$dates[0].Substring(4,2),$dates[0].Substring(6,2),$dates[-1].Substring(4,2),$dates[-1].Substring(6,2)
$sm=[ordered]@{}
$map=@{ 'chip+tech (current)'='籌碼+技術（現行）'; 'chip only'='只看籌碼'; 'tech only'='只看技術' }
foreach($cf in $cfgs){ $s=$summary[$cf.name]; if($s){ $sm[$map[$cf.name]]=@{ winRate=$s.winRate; avgAlpha=$s.avgAlpha; n=$s.n } } }
$bt=@{ period=$fmtP; generated=(Get-Date -Format 'yyyy-MM-dd'); regimeNote='多空以指數vs60日線分組'; summary=$sm }
$byReg=[ordered]@{}
foreach($rg in @('bull','bear')){
  $t2=[ordered]@{}
  foreach($cf in $cfgs){ $s=$summary[$cf.name]; if($s -and $s.ContainsKey($rg)){ $t2[$map[$cf.name]]=$s[$rg] } }
  if($t2.Keys.Count -gt 0){ $byReg[$rg]=$t2 }
}
if($byReg.Keys.Count -gt 0){ $bt.byRegime=$byReg }
$idxPath=Join-Path $root 'index.html'
if(Test-Path $idxPath){
  $enc=New-Object System.Text.UTF8Encoding($false)
  $html=[IO.File]::ReadAllText($idxPath,$enc)
  $st='<script id="backtest">'; $i1=$html.IndexOf($st)
  if($i1 -ge 0){ $i2=$html.IndexOf('</script>',$i1)
    $html=$html.Substring(0,$i1+$st.Length)+('window.BACKTEST='+($bt|ConvertTo-Json -Depth 5 -Compress)+';')+$html.Substring($i2)
    [IO.File]::WriteAllText($idxPath,$html,$enc); Write-Host "spliced backtest card into index.html" }
}