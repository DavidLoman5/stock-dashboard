# 台股投資報告 Dashboard

每個交易日自動更新的台股投資儀表板：持股三面分析（籌碼／技術／基本）、量化選股引擎（上市＋上櫃）、ETF 動能榜、績效與風險指標、推薦追蹤問責、歸因週報與走前驗證回測。

- **線上網址（每日自動更新）**：https://davidloman5.github.io/stock-dashboard/
- **資料來源**：台灣證券交易所＋櫃買中心官方 API（漲跌、法人、融資、月營收、本益比、除權息皆以此為準）
- **執行方式**：使用者電腦上的 Claude Code 排程，每交易日 08:30 自動跑 → 抓資料 → 分析 → `git push` → GitHub Pages 更新

---

## 給「被找來幫忙改這個專案的 AI」：先讀這段

這個 repo 是一個**每天被自動化程式重寫**的專案，不是普通靜態網站。改之前務必分清楚**哪些檔案／區塊能手改、哪些會被每日排程覆寫**，否則你的修改隔天就會不見。

### 每日管線（誰產生什麼）

```
update-holdings.ps1  抓持股行情(上市/上櫃自動路由) → splice DASH/META/HOLDINGS_META → 產出 holdings-context.json、附加 stance-log.json
      ↓ AI 讀 holdings-context.json + lessons.md → Write holdings-notes.json（含 _market 市場風向）
screen.ps1           全市場篩選評分 → splice PICKS_KLINE/PICKS_DATA → 產出 screen-summary.json、維護 picks-log.json（20日結案、含息、移動停利）
      ↓ AI 讀 screen-summary.json → Write picks-notes.json + ai-tags.json
evaluate.ps1         （每週五）歸因分組勝率 → eval-report.json → splice evaldata → AI 更新 lessons.md
publish.ps1          splice 兩份 notes → git add/commit/push（notes 壞檔會跳過該檔續行、>15h 舊檔不 splice）
backtest.ps1         （每月手動）走前驗證網格，v2.1 已對齊生產選股 → splice backtest 卡
tests.ps1            （改腳本後、commit 前必跑）離線迴歸測試，秒級
```

### 檔案地圖

| 檔案 | 作用 | 可以手改嗎 |
|---|---|---|
| `index.html` | 單一檔案的整個儀表板（HTML+CSS+JS，自足、無外部相依、CSP 強制）| ⚠️ 部分可改，見下方分區 |
| `screen.ps1` | 量化選股引擎（評分/出場規則見頁面「📐 現行邏輯」卡）| ✅ 可改邏輯（**必須同步更新 logicCard 與 plan.md，改完跑 tests.ps1**）|
| `update-holdings.ps1` | 持股官方資料抓取＋splice＋判級日誌 | ✅ 同上 |
| `publish.ps1` / `evaluate.ps1` / `backtest.ps1` | 發佈／週歸因／月回測 | ✅ 同上 |
| `tests.ps1` | 離線迴歸測試（語法/BOM/配息上限/快取/防清空守門）| ✅ 新增測項歡迎 |
| `holdings.json` | 使用者持股**唯一事實來源**：張數＋`trades[]` 交易紀錄（**含成交價**，使用者同意公開）。回報交易時同步改 lots 並 append trades；績效曲線依 trades 以 TWR 計算 | ✅ 可改 |
| `holdings-notes.json` / `picks-notes.json` / `ai-tags.json` | AI 每日判讀文字與標籤（隔日重寫）| ❌ 排程每天覆寫 |
| `holdings-context.json` / `screen-summary.json` | 給 AI 讀的精簡數據（幾 KB）| ❌ 自動產生 |
| `picks-log.json` / `stance-log.json` | 推薦追蹤與判級**歷史**（讀取失敗會 FATAL 保護、絕不清空）| ❌ 引擎維護，勿手改 |
| `eval-report.json` / `backtest-result.json` | 歸因週報／回測輸出 | ❌ 自動產生 |
| `lessons.md` | 歸因驗證過的教訓（每週五 AI 更新，餵回每日分析）| ⚠️ 由週報流程管理 |
| `plan.md` | 路線圖＋參數改動紀錄（做完事記得更新）| ✅ |
| `screen-result.json`（gitignored）| 引擎完整輸出，debug 用 | ❌ |
| `kline-cache/` / `backtest-cache/`（gitignored）| 已完結月份 K 線快取／回測面板快取，可重建、自動清理 | ❌ |

### index.html 分區：哪些是「機器管的」

由排程或引擎**每日覆寫**（手改必被蓋掉）：

- 八個 splice 區塊：`<script id="dashdata">`、`holdingsmeta`、`holdingsnotes`（含 `_market`）、`pkdata`、`pkline`、`pknotes`、`evaldata`（週五）、`backtest`（月跑）
- 由頁面 JS 從資料自動算（別寫死）：Hero 市值/損益/**整體傾向**（heroStance，規則引擎判級統計）、大盤數字、**市場風向區**（windBox/miSox/miMood ← `_market`）、權重、今日訊號、績效曲線、集中度警示
- HTML 內殘留的行情文字只是 JS 失敗時的 fallback

✅ **可以安全手改的**：CSS、版面結構、圖表函式（`priceChart`/`candleChart`/`volChart`）、互動邏輯、渲染器、「📐 現行選股與評價邏輯」卡（logicCard，**規則改動時必須同步**）、免責文字。

### 硬性慣例（不遵守會壞）

- `screen.ps1`、`update-holdings.ps1`、`publish.ps1` 必須存 **UTF-8 with BOM**（PS5.1 讀中文字面值需要；tests.ps1 會驗）。
- 抓官方 API 一律用 `Invoke-WebRequest` + 手動 UTF-8 解碼（`Invoke-RestMethod` 會亂碼）。現有 `GetJson()` 已處理，照用。
- **PS5.1 陷阱**：`ConvertFrom-Json` 會把 JSON 陣列當單一物件送 pipeline——先賦值再 `@()` 迭代（tests.ps1 有回歸測項）。
- `index.html` 開頭要有 `<meta charset="utf-8">`；CSP 為 `default-src 'none'`，**任何外部資源都會被擋**——圖表用 Canvas 手繪、保持自足。
- 台股慣例配色：**紅漲綠跌**（`--up` 紅、`--down` 綠）。
- 證交所日期是**民國年**（西元−1911）；TWSE 量能單位是股（÷1000＝張）、TPEx 月成交端點已是張。
- 歷史檔（picks-log/stance-log）**讀取失敗絕不能用空資料覆寫**——現有 FATAL/skip 防護勿移除。
- 改選股/評分/出場/判級規則 → 同步更新 logicCard＋plan.md；改任何腳本 → commit 前跑 `tests.ps1`。

### 定位與免責（改內容時請維持）

本專案是**資訊整理與決策輔助**，**非投資建議、非個股推介**。所有「操作傾向／多空訊號／評分」都是情境參考、非下單指令。頁尾免責聲明請保留。

---

## 排程指令在哪（重要）

讓每天的 Claude「做什麼」的那份指令**不在這個 repo**，而在使用者本機：
`C:\Users\felix\.claude\scheduled-tasks\daily-tw-stock-briefing\SKILL.md`

所以：**只看 GitHub 的 AI 改得到「程式與資料」，但改不到「排程指令本身」**。若要調整排程行為（做什麼、幾點跑），需在使用者本機的 Claude Code 操作。排程屬**本機任務**（要跑本機 PowerShell 與 git），不會出現在 claude.ai 的雲端 Routines 清單；電腦在觸發時段（平日 08:30–09:00）需保持喚醒。

## 技術棧

- 前端：單檔 HTML + 原生 JS + Canvas（無框架、無相依、離線可開、CSP 強制自足）
- 引擎：PowerShell 5.1（TWSE OpenAPI／rwd JSON＋TPEx API，月級磁碟快取）
- 部署：GitHub Pages（`main` 分支根目錄）
- 自動化：Claude Code 本機排程，cron `30 8 * * 1-5`（台灣時間，交易日）
- 品質：`tests.ps1` 離線迴歸測試＋每週歸因（evaluate）＋每月走前驗證（backtest v2.1）
