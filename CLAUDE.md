# CLAUDE.md — 台股投資報告 Dashboard

每交易日被自動化流程重寫的台股儀表板（線上：https://davidloman5.github.io/stock-dashboard/）。架構、管線圖、完整檔案地圖見 `README.md`；待辦與參數改動紀錄在 `plan.md`（做完事記得更新）。

## 這是什麼
- 單檔 `index.html`（HTML+CSS+原生JS+Canvas，自足、無外部相依）= 整個儀表板
- `screen.ps1` = 選股引擎：每天抓上市＋上櫃全市場→篩選評分→拼回 index.html；報酬含息（除權息自動還原）、出場含移動停利
- `holdings.json` = 持股唯一事實來源（1張=1000股）；`trades[]` 含**成交價**（使用者已拍板公開）。使用者回報交易時**同步改 lots 並 append trades**；localStorage 成本輸入仍可覆寫頁面損益

## 執行環境：Ubuntu + pwsh 7.6（2026-07-22 起，不再是 Windows PS5.1）
- 一律 `pwsh -File xxx.ps1`；`-ExecutionPolicy` 在 Linux 無作用；路徑大小寫敏感；`$env:TEMP` 為空（用 `[IO.Path]::GetTempPath()`）
- PS7 差異（刻意不改程式）：`Out-File -Encoding UTF8` 不寫 BOM（新 JSON 無 BOM、舊檔有，兩者皆可讀）；`ConvertFrom-Json` 陣列 pipeline 陷阱已修，`@()` 包裹留著當跨版本保險
- 排程：Ubuntu 上尚未設 cron／systemd timer，每日流程目前手動觸發（plan.md 待決策）

## 別手改：每日流程會覆寫的部分
- splice 區塊全部：`<script id>` = `dashdata`、`holdingsmeta`、`holdingsnotes`（含 `_market` 市場風向）、`pkdata`、`pkline`、`pknotes`、`evaldata`（週五）、`backtest`（月跑）
- Hero 市值/損益/整體傾向（heroStance）、大盤數字、市場風向區（windBox/miSox/miMood）、權重、今日訊號、績效曲線 → 頁面 JS 自動算或 `_market` 覆寫，勿寫死；HTML 內殘留文字只是 JS 失敗時的 fallback

## 可以安全改
CSS／版面、圖表函式（priceChart/candleChart/volChart）、互動邏輯、渲染器、`screen.ps1` 選股演算法、`holdings.json`

## 硬性慣例（違反會壞）
- `screen.ps1`／`update-holdings.ps1`／`publish.ps1` 存 **UTF-8 with BOM**（pwsh 7 不需要，保留是為了在 Windows PS5.1 也能解析中文字面值；`tests.ps1` [2] 驗證）
- 抓官方 API 用 `Invoke-WebRequest`+手動 UTF-8 解碼（`Invoke-RestMethod` 會亂碼）；用現成的 `GetJson()`
- `index.html` 要有 `<!DOCTYPE html>`＋`<meta charset="utf-8">`＋viewport；CSP `default-src 'none'` → 圖表 Canvas 手繪、零外部資源
- **台股紅漲綠跌**（--up 紅、--down 綠）；證交所日期是民國年（西元−1911）
- picks-log／stance-log 讀取失敗**絕不可用空資料覆寫**（FATAL/skip 防護勿移除）
- **改選股/評分/出場或 `adviseHolding` 判級規則 → 必須同步更新 index.html 的「📐 現行選股與評價邏輯」卡（`id="logicCard"`）與 plan.md**

## 測試與部署
- 預覽 `python3 -m http.server 8000`｜引擎 `pwsh -File screen.ps1`｜**改任何腳本後、commit 前必跑 `pwsh -File tests.ps1`**（離線、秒級）
- 部署：push `main`（2026-07-21 起使用者授權 Claude 自主 push，測試通過即可推）

## 定位
資訊整理與決策輔助，非投資建議、非個股推介；傾向/訊號/評分皆情境參考、非下單指令，保留頁尾免責。

## 每日流程指令不在此 repo
在本機 `~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md`：改程式邏輯會自動被沿用，改流程本身要改該檔。
