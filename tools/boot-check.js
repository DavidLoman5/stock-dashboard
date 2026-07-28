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
  const varName = { holdingsmeta: 'HOLDINGS_META', dashdata: 'DASH', meta: 'META' }[id] || id;
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

check('H array built', () => w.eval('typeof H !== "undefined" && H.length > 0') && `H.length=${w.eval('H.length')}`);
check('every holding graded (h.auto non-null)', () => w.eval('H.every(h => h.auto !== null)'));
check('stance level comes from the engine', () => {
  const got = w.eval('JSON.stringify(H.map(h => [h.code, h.auto && h.auto.level, h.stanceKey]))');
  const arr = JSON.parse(got);
  return arr.every(([, lvl, key]) => lvl && lvl === key) && got;
});
check('level is one of the six engine levels', () =>
  w.eval('H.every(h => ["add","addwatch","hold","cutwatch","cut","exit"].includes(h.auto.level))'));
check('score matches HOLDINGS_META.stance.score', () =>
  w.eval('H.every(h => h.auto.score === HOLDINGS_META[h.code].stance.score)'));
check('stance badge text rendered', () => w.eval('H.every(h => h.auto.lv && h.auto.lv[1].length > 0)'));
check('hero market value filled', () => {
  const t = w.document.getElementById('heroVal');
  return t && t.textContent.trim() !== '' && t.textContent.trim() !== '—' && 'heroVal=' + t.textContent.trim();
});
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
check('equity curve built', () => w.eval('!!document.getElementById("eqHead") && document.getElementById("eqHead").textContent.trim().length > 0'));

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
