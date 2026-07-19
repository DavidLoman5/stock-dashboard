# CLAUDE.md — 台股投資報告 Dashboard

這是一個**每交易日被自動化排程重寫**的台股投資儀表板。動手前先讀 `README.md`（完整架構與協作指南）；待辦與路線圖在 `plan.md`（做完事記得更新它）。

## 這是什麼
- 單檔 `index.html`（HTML+CSS+原生JS+Canvas，自足、無外部相依）= 整個儀表板
- `screen.ps1` = 量化選股引擎（PowerShell），每天抓上市（證交所）＋上櫃（櫃買中心）全市場資料→篩選評分→把結果拼回 index.html；追蹤報酬含息（除權息自動還原）、出場規則含移動停利
- `holdings.json` = 持股唯一事實來源（1張=1000股）。`trades[]` 記交易含**成交價**（2026-07-19 使用者拍板同意公開）；使用者回報交易時**同步改 lots 並 append trades**。瀏覽器 localStorage 成本輸入仍可覆寫頁面損益顯示
- 線上：https://davidloman5.github.io/stock-dashboard/ ｜ 排程每交易日 08:30 自動 `git push` 更新

## 改之前必知：哪些會被每日排程覆寫（別手改）
- splice 區塊全部：`<script id>` = `dashdata`（DASH）、`holdingsmeta`、`holdingsnotes`（含 `_market` 市場風向）、`pkdata`、`pkline`、`pknotes`、`evaldata`（週五）、`backtest`（月跑）
- Hero 市值/損益/整體傾向（heroStance）、大盤數字、市場風向區（windBox/miSox/miMood）、權重、今日訊號、績效曲線 → 全由頁面 JS 自動算或每日 `_market` 覆寫，勿寫死；HTML 內殘留文字僅為 JS 失敗時的 fallback

## 可以安全改（改了會保留並生效）
- CSS 樣式、版面、圖表函式（priceChart/candleChart/volChart）、互動邏輯、渲染器、`screen.ps1` 的選股演算法、`holdings.json`

## 硬性慣例（違反會壞）
- `screen.ps1` 存 **UTF-8 with BOM**（PS5.1 讀中文字面值需要）
- 抓證交所 API 用 `Invoke-WebRequest`+手動 UTF-8 解碼（`Invoke-RestMethod` 會亂碼）；用現成的 `GetJson()`
- `index.html` 開頭要有 `<meta charset="utf-8">`
- 圖表用 Canvas 手繪，**無外部函式庫/CDN**（CSP 會擋）
- **台股紅漲綠跌**（--up 紅、--down 綠），別套歐美習慣
- 證交所日期是民國年（西元-1911）
- **改 `screen.ps1` 選股/評分/出場規則或 `adviseHolding` 判級規則時，必須同步更新 index.html 的「📐 現行選股與評價邏輯」卡（`id="logicCard"`）與 plan.md**，避免文件與程式漂移

## 測試與部署
- 本機測試：`python -m http.server 8000` 開 `http://localhost:8000`
- 引擎測試：`powershell -ExecutionPolicy Bypass -File screen.ps1`
- **迴歸測試（改任何腳本後、commit 前必跑）**：`powershell -ExecutionPolicy Bypass -File tests.ps1`（離線、秒級）
- 部署：commit 後**由使用者** push 到 `main`（只有他有推送權限）→ 隔天排程沿用程式邏輯改動

## 定位
資訊整理與決策輔助，非投資建議、非個股推介。傾向/訊號/評分皆情境參考、非下單指令。保留頁尾免責。

## 排程指令不在此 repo
每天 Claude「做什麼」的指令在使用者本機 `~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md`，不在 GitHub。改程式邏輯會自動被排程沿用；要改排程行為本身需在本機操作。
