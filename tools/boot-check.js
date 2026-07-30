// Executes index.html's inline JS in jsdom and asserts the page actually booted.
// runScripts:"dangerously" + the canvas package are both required: without canvas,
// getContext('2d') returns null and boot() dies on its first chart, so every later
// assertion would pass vacuously.
const fs = require('fs');
const { JSDOM } = require('jsdom');

const file = process.argv[2];
if (!file) { console.error('usage: node tools/boot-check.js <index.html> [blockId] [json]'); process.exit(2); }
let html = fs.readFileSync(file, 'utf8');

// optional mutation: node boot-check.js <file> <blockId> <json>
if (process.argv[3] && process.argv[4]) {
  const id = process.argv[3], payload = process.argv[5] || process.argv[4];
  // page-contract.json is the source of truth for block id -> window.* name (server/pagedata.py
  // already reads it). This used to be a hand-copied 3-of-11 subset, so mutating any other
  // block silently emitted `window.pkdata=...` - a no-op that PASSED.
  const contract = JSON.parse(fs.readFileSync(
    require('path').join(__dirname, '..', 'page-contract.json'), 'utf8'));
  const block = contract.blocks[id];
  if (!block) {
    console.error(`unknown block '${id}'. known: ${Object.keys(contract.blocks).join(', ')}`);
    process.exit(2);
  }
  const varName = block.global;
  const st = `<script id="${id}">`;
  const i1 = html.indexOf(st), i2 = html.indexOf('</script>', i1);
  html = html.slice(0, i1 + st.length) + `window.${varName}=${payload};` + html.slice(i2);
}

const errors = [];
const dom = new JSDOM(html, {
  runScripts: 'dangerously',
  url: 'https://x.test/',
  pretendToBeVisual: true,
  beforeParse(w) {
    w.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
    w.addEventListener('error', e => errors.push('window.onerror: ' + (e.error && e.error.stack || e.message)));
  },
});
dom.virtualConsole.on('jsdomError', e => errors.push('jsdomError: ' + (e.stack || e.message)));

const w = dom.window;
const results = [];
function check(name, fn) {
  try { const v = fn(); results.push([!!v, name, typeof v === 'string' ? v : '']); }
  catch (e) { results.push([false, name, 'threw: ' + e.message]); }
}
// The documented variants (HOLDINGS_META with no stance, and the empty portfolio
// {"_trades":[]}) deliberately remove the data most assertions are about. Those runs exist to
// prove the page still BOOTS, so holdings-dependent checks skip rather than report a failure
// that means nothing - a wall of red there trains you to ignore the output.
const EMPTY = w.eval('typeof H === "undefined" || H.length === 0');
const UNGRADED = !EMPTY && w.eval('H.some(h => !h.auto)');
const skipIf = (cond, why, fn) => () => cond ? `skipped: ${why}` : fn();

check('H array built', () => w.eval('typeof H !== "undefined" && Array.isArray(H)') && `H.length=${w.eval('H.length')}`);
check('every holding graded (h.auto non-null)', skipIf(EMPTY || UNGRADED, 'no graded holdings in this variant', () => w.eval('H.every(h => h.auto !== null)')));
check('stance level comes from the engine', skipIf(EMPTY || UNGRADED, 'no graded holdings in this variant', () => {
  const got = w.eval('JSON.stringify(H.map(h => [h.code, h.auto && h.auto.level, h.stanceKey]))');
  const arr = JSON.parse(got);
  return arr.every(([, lvl, key]) => lvl && lvl === key) && got;
}));
check('level is one of the six engine levels', skipIf(EMPTY || UNGRADED, 'no graded holdings in this variant', () =>
  w.eval('H.every(h => ["add","addwatch","hold","cutwatch","cut","exit"].includes(h.auto.level))')));
check('score matches HOLDINGS_META.stance.score', skipIf(EMPTY || UNGRADED, 'no graded holdings in this variant', () =>
  w.eval('H.every(h => h.auto.score === HOLDINGS_META[h.code].stance.score)')));
check('stance badge text rendered', skipIf(EMPTY || UNGRADED, 'no graded holdings in this variant', () => w.eval('H.every(h => h.auto.lv && h.auto.lv[1].length > 0)')));
check('hero market value filled', skipIf(EMPTY, 'empty portfolio shows a dash by design', () => {
  const t = w.document.getElementById('heroVal');
  return t && t.textContent.trim() !== '' && t.textContent.trim() !== '—' && 'heroVal=' + t.textContent.trim();
}));
check('heroStance filled from grades', () => {
  const t = w.document.getElementById('heroStance');
  return t && t.textContent.trim().length > 0 && 'heroStance=' + t.textContent.trim();
});
check('報告日期 set from META block', () => {
  const t = w.document.getElementById('genDate');
  return t && t.textContent.trim() === w.eval('META.generated') && 'genDate=' + t.textContent.trim();
});
check('行情基準 set from META block', () => {
  const t = w.document.getElementById('baseDate');
  return t && t.textContent.includes('收盤') && 'baseDate=' + t.textContent.trim();
});
check('stance transition badge computed', () =>
  w.eval('H.some(h => h.stanceChanged) ? JSON.stringify(H.filter(h=>h.stanceChanged).map(h=>h.stanceChanged)) : "none (ok if prevStance == stance)"'));
// NOT "eqHead is non-empty": #eqHead ships with fallback copy in the static HTML, so that
// assertion passed even when buildEquity() never ran. #riskRow has NO fallback markup - it is
// empty in the file and only buildEquity() can fill it - so it is the honest witness.
check('equity curve built (riskRow is JS-only output)', skipIf(EMPTY, 'no series to chart', () => {
  const t = w.document.getElementById('riskRow');
  return t && t.children.length === 5 && /年化波動度/.test(t.textContent) &&
    `riskRow children=${t.children.length}`;
}));
check('risk contribution ranked', () => {
  const t = w.document.getElementById('riskContrib');
  return t && (t.textContent.includes('風險貢獻') || '(no contribution data in this build)');
});
check('boot() reported no failed section', () => {
  const f = w.__bootFailed;
  return Array.isArray(f) && f.length === 0 ? 'all sections ok' : 'FAILED: ' + JSON.stringify(f);
});
check('boot() is re-runnable and idempotent', () => {
  const ids = ['holdings', 'allocBar', 'legend', 'catsWrap', 'etfWrap', 'signalsBox'];
  const snap = () => ids.map(id => {
    const e = w.document.getElementById(id);
    return id + ':' + (e ? e.children.length : '-');
  }).join(' ');
  const before = snap();
  w.boot();
  const after = snap();
  return before === after ? before : `NOT idempotent: ${before} -> ${after}`;
});
// The two biggest functions in the file (10.9 KB between them) and nothing had ever executed
// them. openModal takes an INDEX into H; openPickModal takes a pick object.
check('holding modal opens without throwing', skipIf(EMPTY || UNGRADED, 'no graded holding to open', () => {
  if (!w.eval('H.length')) return 'no holdings to open';
  w.eval('openModal(0)');
  const open = w.document.getElementById('ov').classList.contains('open');
  const title = (w.document.getElementById('mTitle') || {}).textContent || '';
  w.eval('closeModal()');
  return open && title.length > 0 && `mTitle=${title.trim()}`;
}));
check('pick modal opens without throwing', () => {
  const has = w.eval('!!(window.PICKS_DATA && PICKS_DATA.picks && PICKS_DATA.picks.length)');
  if (!has) return 'no picks in this build';
  w.eval('openPickModal(PICKS_DATA.picks[0])');
  const open = w.document.getElementById('ov').classList.contains('open');
  w.eval('closeModal()');
  return open && 'openPickModal ok';
});
// The chart owns its projection now; assert the inverse actually inverts, for BOTH charts.
// This is the bug class the old code invited: attachChartHover re-derived X(i) by hand with a
// curMode branch, so a padding change in one chart silently desynchronised hover from the bars.
check('chart geometry round-trips (candle + line)', () => {
  if (!w.eval('H.length')) return 'skipped: no series';
  const report = w.eval(`(function(){
    const cv = document.createElement('canvas');
    Object.defineProperty(cv, 'clientWidth',  {value: 400});
    Object.defineProperty(cv, 'clientHeight', {value: 120});
    document.body.appendChild(cv);
    const ser = DASH[H[0].code].series.slice(-30);
    const out = [];
    for (const [label, geom] of [
      ['candle', candleChart(cv, ser, {pad:{t:10,r:10,b:10,l:10}})],
      ['line',   priceChart(cv, ser.map(s=>s.c), '#112233', {pad:{t:8,r:6,b:8,l:6}})],
    ]) {
      if (!geom || !geom.indexAt) { out.push(label + ':NO-GEOM'); continue; }
      let bad = 0;
      const pad = geom.padL, w2 = 400;
      const span = w2 - geom.padL - geom.padR;
      for (let i = 0; i < ser.length; i++) {
        const fx = label === 'candle'
          ? pad + (span / ser.length) * (i + 0.5)
          : pad + span * (i / (ser.length - 1));
        if (geom.indexAt(fx, w2) !== i) bad++;
      }
      out.push(label + ':' + (bad === 0 ? 'ok' : bad + ' mismatches'));
    }
    cv.remove();
    return out.join(' ');
  })()`);
  return /^candle:ok line:ok$/.test(report) ? report : 'BAD ' + report;
});
check('category modal opens without throwing', () => {
  const ind = w.eval('Object.keys(CATS || {})[0] || null');
  if (!ind) return 'no categories in this build';
  w.eval(`openCatModal(${JSON.stringify(ind)})`);
  const open = w.document.getElementById('ov').classList.contains('open');
  w.eval('closeModal()');
  return open && `openCatModal(${ind}) ok`;
});
check('user text is escaped, never injected as markup', skipIf(EMPTY, 'no holding to rename', () => {
  // buildCostPanel was the one name site of twelve that interpolated raw; in server mode the
  // name is a string another user typed
  w.eval(`H[0].name = '<img src=x onerror=alert(1)>'`);
  w.eval('buildCostPanel()');
  const p = w.document.getElementById('costPanel');
  const clean = p && !p.querySelector('img') && p.innerHTML.includes('&lt;img');
  w.eval('boot()');   // restore the page from the real data
  return clean && 'escaped';
}));
// cssv() feeds these straight into ctx.fillStyle/strokeStyle at 13 sites. An unparseable colour
// does NOT throw - canvas silently keeps the previous style - so nothing else here would notice.
// This matters because the palette resolves through a var() indirection layer (--bg:var(--l-bg)),
// and jsdom's getComputedStyle does NOT substitute var() in custom properties the way browsers
// do; cssv() resolves the indirection itself so both environments agree.
check('every JS-read colour token resolves to a real colour', () => {
  const names = ['--accent','--ink-faint','--ink-soft','--grid','--surface',
                 '--up','--down','--ma5','--ma20','--ma60'];
  const bad = names.filter(n => !/^(#[0-9a-f]{3,8}|rgba?\()/i.test(w.eval(`cssv('${n}')`)));
  return bad.length === 0 && `${names.length} tokens resolve`;
});

let failed = 0;
for (const [ok, name, detail] of results) {
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? '  [' + detail + ']' : ''}`);
}
if (errors.length) { failed += errors.length; console.log('\n--- page errors ---'); errors.forEach(e => console.log(e)); }
console.log(failed === 0 ? '\nBOOT OK' : `\nBOOT FAILED (${failed})`);
process.exitCode = failed === 0 ? 0 : 1;

// --- analytics seam: computeEquity is pure, so it can be fed fixtures directly ---
(function analyticsFixtures(){
  const A = w.ANALYTICS && w.ANALYTICS.computeEquity;
  if (!A) { console.log('FAIL window.ANALYTICS.computeEquity exposed'); process.exitCode = 1; return; }
  const days = n => Array.from({length:n}, (_,i) => `1/${i+1}`);
  const mkSeries = (n, f) => days(n).map((d,i) => ({d, o:f(i), h:f(i), l:f(i), c:f(i), chg:0, v:100}));
  const flat = n => mkSeries(n, () => 10);
  const dash = {TAIEX: days(30).map((d,i) => ({d, c:1000, chg:0, amt:1}))};
  dash['A'] = {series: flat(30), inst: [], margin: []};
  const holdings = [{code:'A', weight:100}];
  const shares = {A: 1000};

  const r1 = A(holdings, dash, [], shares, '2026-01-30');
  const ok = [];
  ok.push(['flat portfolio returns 0%', Math.abs(r1.pRet) < 1e-9, r1.pRet]);
  ok.push(['flat portfolio has 0 volatility', Math.abs(r1.vol) < 1e-9, r1.vol]);
  ok.push(['flat portfolio has 0 drawdown', Math.abs(r1.mdd) < 1e-9, r1.mdd]);

  // doubling the price doubles the TWR index
  const dash2 = {TAIEX: dash.TAIEX, A: {series: mkSeries(30, i => 10 * (1 + i/29)), inst: [], margin: []}};
  const r2 = A(holdings, dash2, [], shares, '2026-01-30');
  ok.push(['+100% price -> +100% return', Math.abs(r2.pRet - 100) < 1e-6, r2.pRet]);

  // a mid-window purchase is a cash flow, not a return: TWR must stay flat
  const trades = [{d:'2026-01-15', side:'buy', code:'A', shares:1000, price:10}];
  const r3 = A(holdings, dash, trades, shares, '2026-01-30');
  ok.push(['mid-window buy does not fake a return (TWR)', Math.abs(r3.pRet) < 1e-9, r3.pRet]);
  ok.push(['trades detected', r3.hasWinTrades === true, r3.hasWinTrades]);

  // too little history returns null rather than NaN-filled output
  const dashShort = {TAIEX: dash.TAIEX.slice(0,5), A: {series: flat(5), inst: [], margin: []}};
  ok.push(['<10 usable days returns null', A(holdings, dashShort, [], shares, '2026-01-30') === null, '']);

  let bad = 0;
  for (const [name, pass, val] of ok) {
    if (!pass) bad++;
    console.log(`${pass ? 'PASS' : 'FAIL'} analytics: ${name}${val === '' ? '' : '  [' + val + ']'}`);
  }
  if (bad) process.exitCode = 1;
})();
