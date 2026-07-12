# 台股投資報告 Dashboard

每個交易日自動更新的台股投資儀表板：持股三面分析（籌碼／技術／基本）、量化選股引擎、ETF 動能榜、績效與風險指標、推薦追蹤問責。

- **線上網址（每日自動更新）**：https://davidloman5.github.io/stock-dashboard/
- **資料來源**：台灣證券交易所官方 API（漲跌、法人、融資、月營收、本益比、除權息皆以此為準）
- **執行方式**：使用者電腦上的 Claude Code 排程，每交易日 08:30 自動跑 → 抓資料 → 分析 → `git push` → GitHub Pages 更新

---

## 給「被找來幫忙改這個專案的 AI」：先讀這段

這個 repo 是一個**每天被自動化程式重寫**的專案，不是普通靜態網站。改之前務必分清楚**哪些檔案／區塊能手改、哪些會被每日排程覆寫**，否則你的修改隔天就會不見。

### 檔案地圖

| 檔案 | 作用 | 可以手改嗎 |
|---|---|---|
| `index.html` | 單一檔案的整個儀表板（HTML+CSS+JS，自足、無外部相依）| ⚠️ 部分可改，見下方「index.html 分區」 |
| `screen.ps1` | 量化選股引擎（PowerShell）。抓全市場資料→篩選→評分→把結果拼回 index.html | ✅ **可自由改邏輯**（改完隔天生效）|
| `holdings.json` | 使用者持股的**唯一事實來源**（張數、成本不放這）| ✅ 可改（改張數/新增持股）|
| `picks-log.json` | 選股推薦的追蹤紀錄（引擎自動維護，20 交易日結案）| ❌ 引擎自動寫，別手改 |
| `screen-result.json` | 引擎每次輸出的完整結果（給人看／debug）| ❌ 自動產生 |
| `README.md` | 就是本檔 | ✅ |

### index.html 分區：哪些是「機器管的」

index.html 裡有幾個區塊由**每日排程或引擎自動覆寫**，手改會被蓋掉：

- `window.DASH = {...}` — 持股與大盤的行情資料（排程每天覆寫）
- `const H = [...]` 裡的**數字欄位**與三面分析**文字**（排程每天覆寫）；但 price/chg/dd/weight 等數字其實由頁面 JS 自動算，別手填
- `<script id="pkdata">` / `<script id="pkline">` — 選股引擎 `screen.ps1` 自動拼接，**絕對不要手改**
- `<script id="pknotes">` — 排程每天寫入（Top5＋ETF 短評）
- Hero 市值/損益、大盤指數數字、權重、今日訊號、績效曲線 — **全部由頁面 JS 從 DASH 自動計算**，不是寫死的

✅ **可以安全手改的**：CSS 樣式、版面結構、圖表繪製函式（`priceChart`/`candleChart`/`volChart`）、互動邏輯（彈窗、均線開關、十字查價）、各種渲染器函式、免責文字。這些「程式邏輯」排程不會動，改了會保留並生效。

### 你的修改如何「生效到每日排程」

1. 改 `screen.ps1`（選股邏輯）或 `index.html`（版面/圖表/互動）或 `holdings.json`（持股）
2. 本機測試：`cd` 到專案資料夾，`python -m http.server 8000`，開 `http://localhost:8000` 看效果
3. commit → **使用者** push 到 `main`（只有他能推）
4. 下一個交易日 08:30，排程會：讀 holdings.json → 跑 screen.ps1 → 重寫 index.html 的機器區塊 → push。你對「程式邏輯」的改動會被沿用，對「機器區塊」的改動會被當天資料覆寫。

### 硬性慣例（不遵守會壞）

- **`screen.ps1` 必須存成 UTF-8 **with BOM**（PowerShell 5.1 才能正確讀中文字面值）。
- **抓證交所 API 一律用 `Invoke-WebRequest` + 手動 UTF-8 解碼**（`Invoke-RestMethod` 會把回應誤判成 CP1252 → 中文亂碼）。現有 `GetJson()` 已處理，照用。
- **`index.html` 開頭要有 `<meta charset="utf-8">`**。
- 圖表用 Canvas 手繪，**無任何外部函式庫／CDN**（CSP 會擋）；保持自足。
- 台股慣例配色：**紅漲綠跌**（`--up` 紅、`--down` 綠）。別套用歐美的綠漲紅跌。
- 證交所日期是**民國年**（ROC，西元-1911），代碼裡都有轉換，注意別弄錯。

### 定位與免責（改內容時請維持）

本專案是**資訊整理與決策輔助**，**非投資建議、非個股推介**。所有「操作傾向／多空訊號／評分」都是情境參考、非下單指令。頁尾免責聲明請保留。

---

## 排程指令在哪（重要）

讓每天的 Claude「做什麼」的那份指令**不在這個 repo**，而在使用者本機：
`C:\Users\felix\.claude\scheduled-tasks\daily-tw-stock-briefing\SKILL.md`

所以：**只看 GitHub 的 AI 改得到「程式與資料」，但改不到「排程指令本身」**。若要調整排程的行為（做什麼、幾點跑），需在使用者本機的 Claude Code 操作，或見下方 `schedule-directives.md` 機制（若已啟用）。

---

## 技術棧

- 前端：單檔 HTML + 原生 JS + Canvas（無框架、無相依、離線可開）
- 引擎：PowerShell（`screen.ps1`），呼叫 TWSE OpenAPI 與 rwd JSON
- 部署：GitHub Pages（`main` 分支根目錄）
- 自動化：Claude Code 本機排程，cron `30 8 * * 1-5`（台灣時間，交易日）
