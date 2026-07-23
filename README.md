# 台股投資報告 Dashboard

每個交易日更新的台股投資儀表板：持股三面分析（籌碼／技術／基本）、量化選股引擎（上市＋上櫃）、ETF 動能榜、績效與風險指標、推薦追蹤問責、歸因週報與走前驗證回測。

- **線上網址**：https://davidloman5.github.io/stock-dashboard/
- **資料來源**：台灣證券交易所＋櫃買中心官方 API（漲跌、法人、融資、月營收、本益比、除權息皆以此為準）
- **執行方式**：使用者電腦（Ubuntu）上的 Claude Code 跑每日流程 → 抓資料 → 分析 → `git push` → GitHub Pages 更新

---

## 給「被找來幫忙改這個專案的 AI」：先讀這段

這個 repo 每天被自動化流程重寫，不是普通靜態網站。改之前務必分清**哪些檔案／區塊能手改、哪些會被覆寫**，否則你的修改隔天就不見。

### 每日管線（誰產生什麼）

```
update-holdings.ps1  抓持股行情(上市/上櫃自動路由) → splice DASH/META/HOLDINGS_META → 產出 holdings-context.json、附加 stance-log.json
      ↓ AI 讀 holdings-context.json + lessons.md → Write holdings-notes.json（含 _market 市場風向）
screen.ps1           全市場篩選評分 → splice PICKS_KLINE/PICKS_DATA → 產出 screen-summary.json、維護 picks-log.json（20日結案、含息、移動停利）
      ↓ AI 讀 screen-summary.json → Write picks-notes.json + ai-tags.json
evaluate.ps1         （週五）歸因分組勝率 → eval-report.json → splice evaldata → AI 更新 lessons.md
publish.ps1          splice 兩份 notes → git add/commit/push（壞檔跳過該檔續行、>15h 舊檔不 splice）
backtest.ps1         （每月手動）走前驗證網格 v2.1，已對齊生產選股 → splice backtest 卡
tests.ps1            （改腳本後、commit 前必跑）離線迴歸測試，秒級
```

### 檔案地圖

| 檔案 | 作用 | 可以手改嗎 |
|---|---|---|
| `index.html` | 單檔的整個儀表板（自足、CSP 強制）| ⚠️ 部分，見下方分區 |
| `screen.ps1` | 選股引擎（規則見頁面「📐 現行邏輯」卡）| ✅ **改了要同步 logicCard＋plan.md，並跑 tests.ps1** |
| `update-holdings.ps1` | 持股官方資料抓取＋splice＋判級日誌 | ✅ 同上 |
| `publish.ps1`／`evaluate.ps1`／`backtest.ps1` | 發佈／週歸因／月回測 | ✅ 同上 |
| `tests.ps1` | 離線迴歸測試（語法/BOM/配息上限/快取/防清空）| ✅ 歡迎加測項 |
| `holdings.json` | 持股**唯一事實來源**：張數＋`trades[]`（含成交價，使用者同意公開）；績效曲線依 trades 以 TWR 計算 | ✅ |
| `holdings-notes.json`／`picks-notes.json`／`ai-tags.json` | AI 每日判讀與標籤 | ❌ 每天覆寫 |
| `holdings-context.json`／`screen-summary.json` | 給 AI 讀的精簡數據（幾 KB）| ❌ 自動產生 |
| `picks-log.json`／`stance-log.json` | 推薦追蹤與判級**歷史**（讀取失敗 FATAL 保護、絕不清空）| ❌ 引擎維護 |
| `eval-report.json`／`backtest-result.json` | 歸因週報／回測輸出 | ❌ 自動產生 |
| `lessons.md` | 歸因驗證過的教訓（週五更新，餵回每日分析）| ⚠️ 由週報流程管理 |
| `plan.md` | 路線圖＋參數改動紀錄 | ✅ |
| `screen-result.json`、`kline-cache/`、`backtest-cache/`（gitignored）| 完整輸出／月級快取，可重建 | ❌ |

### index.html 分區：哪些是「機器管的」

每日覆寫（手改必被蓋掉）：

- 八個 splice 區塊：`<script id="dashdata">`、`holdingsmeta`、`holdingsnotes`（含 `_market`）、`pkdata`、`pkline`、`pknotes`、`evaldata`（週五）、`backtest`（月跑）
- 頁面 JS 從資料自動算（別寫死）：Hero 市值/損益/**整體傾向**（heroStance）、大盤數字、**市場風向區**（windBox/miSox/miMood ← `_market`）、權重、今日訊號、績效曲線、集中度警示
- HTML 內殘留的行情文字只是 JS 失敗時的 fallback

✅ **可安全手改**：CSS、版面、圖表函式（`priceChart`/`candleChart`/`volChart`）、互動邏輯、渲染器、「📐 現行選股與評價邏輯」卡（logicCard，**規則改動時必須同步**）、免責文字。

### 執行環境與平台慣例

- **pwsh 7.6 on Ubuntu**（2026-07-22 由 Windows PS5.1 遷移）：一律 `pwsh -File xxx.ps1`；`-ExecutionPolicy` 在 Linux 無作用；路徑大小寫敏感；`$env:TEMP` 為空，暫存目錄用 `[IO.Path]::GetTempPath()`。
- PS7 差異（已知、刻意不改）：`Out-File -Encoding UTF8` **不寫 BOM**（新產出 JSON 無 BOM、舊檔有，`Get-Content -Raw -Encoding UTF8` 兩者皆可正確讀）；`ConvertFrom-Json` 的「陣列被當單一物件送 pipeline」陷阱在 7 已修，程式裡的 `@()` 包裹保留為跨版本保險（`tests.ps1` [5] 仍守著這個形狀）。
- `screen.ps1`、`update-holdings.ps1`、`publish.ps1` 維持 **UTF-8 with BOM**：pwsh 7 不需要，但保留可讓含中文字面值的檔案在 Windows PS5.1 也能解析（`tests.ps1` [2] 驗證）。
- 抓官方 API 一律 `Invoke-WebRequest` + 手動 UTF-8 解碼（`Invoke-RestMethod` 會亂碼）；用現成的 `GetJson()`。
- `index.html` 要有 `<!DOCTYPE html>`＋`<meta charset="utf-8">`＋viewport；CSP `default-src 'none'`，**任何外部資源都會被擋**——圖表 Canvas 手繪、保持自足。
- 台股配色**紅漲綠跌**（`--up` 紅、`--down` 綠）；證交所日期是**民國年**（西元−1911）；TWSE 量能單位是股（÷1000＝張）、TPEx 月成交端點已是張。
- 歷史檔（picks-log/stance-log）**讀取失敗絕不能用空資料覆寫**——FATAL/skip 防護勿移除。
- 改選股/評分/出場/判級規則 → 同步 logicCard＋plan.md；改任何腳本 → commit 前 `pwsh -File tests.ps1`。

### 定位與免責（改內容時請維持）

**資訊整理與決策輔助，非投資建議、非個股推介**。傾向／訊號／評分皆情境參考、非下單指令。頁尾免責聲明請保留。

---

## 每日流程指令在哪（重要）

讓每天的 Claude「做什麼」的指令**不在這個 repo**，而在使用者本機 `~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md`。所以**只看 GitHub 的 AI 改得到「程式與資料」，改不到「流程指令本身」**。

排程現況：舊機（Windows）的自動排程未隨遷移重建，Ubuntu 上目前**沒有 cron／systemd timer**，每日流程由使用者手動觸發 Claude Code（見 `plan.md` 待決策）。

## 技術棧

- 前端：單檔 HTML + 原生 JS + Canvas（無框架、無相依、離線可開、CSP 強制自足）
- 引擎：PowerShell 7.6（pwsh on Ubuntu；TWSE OpenAPI／rwd JSON＋TPEx API，月級磁碟快取）
- 部署：GitHub Pages（`main` 分支根目錄）
- 品質：`tests.ps1` 離線迴歸＋每週歸因（evaluate）＋每月走前驗證（backtest v2.1）
