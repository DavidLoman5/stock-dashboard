# CLAUDE.md — 台股投資報告 Dashboard

每交易日被自動化流程重寫的台股儀表板（線上：https://davidloman5.github.io/stock-dashboard/）。架構、管線圖、完整檔案地圖見 `README.md`；待辦與參數改動紀錄在 `plan.md`（做完事記得更新）。

## 這是什麼
- 單檔 `index.html`（HTML+CSS+原生JS+Canvas，自足、無外部相依）= 整個儀表板
- `screen.ps1` = 選股引擎：每天抓上市＋上櫃全市場→篩選評分→拼回 index.html；報酬含息（除權息自動還原）、出場含移動停利
- `server/`（Python 標準庫，零相依）= 多使用者模式：每人登入看自己的持股。安裝與營運見 `SETUP.md`

## 兩種模式（2026-07-23 起）
| | 單人靜態 | 多人伺服器 |
|---|---|---|
| 持股來源 | `holdings.json` | `data/app.db`（**gitignore，絕不進 repo**） |
| 頁面產生 | 腳本 splice 進 `index.html` | `server.py` 逐使用者即時 splice 同樣的 `window.*` 區塊 |
| `holdings.json` 的角色 | 真實持股 | **公開 demo 假資料**，只給 GitHub Pages 與新 clone 用 |

- `holdings.json` 已**不再是真實持股**（1張=1000股的格式不變）。真實部位在 DB，用網頁「編輯持股」或 `python3 -m server.admin import-holdings` 維護
- 使用者回報交易時仍**同步改 lots 並 append trades**，但目標是 DB，不是 `holdings.json`；localStorage 成本輸入仍可覆寫頁面損益

## 多使用者的兩條硬規則
1. **token 只花在 owner 身上**：每日 AI 步驟的唯一輸入是 `holdings-context.json`，而它只由 owner 的持股產生。guest 新增股票只會多一次免費的 TWSE 抓取，**絕不可**因此觸發任何 Claude 呼叫。guest 的個股註解一律取自 owner 當日產出的共用快取（`payload.notes_for`）
2. **使用者輸入絕不進 AI prompt**：別人自填的股票名稱／備註是不可信輸入；AI 只讀腳本消化過的數值。這條同時擋掉 prompt injection 通往自動 `git push` 的路徑

## 執行環境：Ubuntu + pwsh 7.6（2026-07-22 起，不再是 Windows PS5.1）
- 一律 `pwsh -File xxx.ps1`；`-ExecutionPolicy` 在 Linux 無作用；路徑大小寫敏感；`$env:TEMP` 為空（用 `[IO.Path]::GetTempPath()`）
- PS7 差異（刻意不改程式）：`Out-File -Encoding UTF8` 不寫 BOM（新 JSON 無 BOM、舊檔有，兩者皆可讀）；`ConvertFrom-Json` 陣列 pipeline 陷阱已修，`@()` 包裹留著當跨版本保險
- 排程：crontab `0 20 * * 1-5 /home/felix/run-stock-briefing.sh`（該 wrapper 以 `claude -p --permission-mode auto` 跑 SKILL.md，日誌 `~/stock-briefing-cron.log`）；20:00 已收盤，當日流程用的是**當日**收盤資料

## 別手改：每日流程會覆寫的部分
- splice 區塊全部：`<script id>` = `dashdata`、`holdingsmeta`、`holdingsnotes`（含 `_market` 市場風向）、`pkdata`、`pkline`、`pknotes`、`evaldata`（週五）、`backtest`（月跑）、`appuser`（伺服器逐使用者注入，committed 檔案內**必須留空**）
- Hero 市值/損益/整體傾向（heroStance）、大盤數字、市場風向區（windBox/miSox/miMood）、權重、今日訊號、績效曲線 → 頁面 JS 自動算或 `_market` 覆寫，勿寫死；HTML 內殘留文字只是 JS 失敗時的 fallback

## 可以安全改
CSS／版面、圖表函式（priceChart/candleChart/volChart）、互動邏輯、渲染器、`screen.ps1` 選股演算法、`holdings.json`

## 硬性慣例（違反會壞）
- `screen.ps1`／`update-holdings.ps1`／`publish.ps1`／`build-demo.ps1` 存 **UTF-8 with BOM**（pwsh 7 不需要，保留是為了在 Windows PS5.1 也能解析中文字面值；`tests.ps1` [2] 驗證）
- **`data/`、`*.db`、`config.json` 絕不可進 repo**（`tests.ps1` [8] 驗證）；推上 GitHub 的 `index.html` 一律由 `build-demo.ps1` 用 demo 持股重建，**不可**直接推 `update-holdings.ps1` 產出的版本——那裡面是 owner 的真實部位
- 伺服器只綁 `127.0.0.1`，對外一律經 tunnel（目前 Tailscale Funnel）；不要改成 `0.0.0.0` 或在路由器開埠
- 換 tunnel 必須同步改 `config.json` 的 `proxyHeader`（Funnel=`X-Forwarded-For`、cloudflared=`CF-Connecting-IP`）——設錯不是無效，是讓所有按 IP 的節流可被偽造繞過
- 抓官方 API 用 `Invoke-WebRequest`+手動 UTF-8 解碼（`Invoke-RestMethod` 會亂碼）；用現成的 `GetJson()`
- `index.html` 要有 `<!DOCTYPE html>`＋`<meta charset="utf-8">`＋viewport；CSP `default-src 'none'` → 圖表 Canvas 手繪、零外部資源
- **台股紅漲綠跌**（--up 紅、--down 綠）；證交所日期是民國年（西元−1911）
- picks-log／stance-log 讀取失敗**絕不可用空資料覆寫**（FATAL/skip 防護勿移除）
- **改選股/評分/出場或 `adviseHolding` 判級規則 → 必須同步更新 index.html 的「📐 現行選股與評價邏輯」卡（`id="logicCard"`）與 plan.md**

## 測試與部署
- 預覽 `python3 -m http.server 8000`｜引擎 `pwsh -File screen.ps1`｜伺服器 `python3 -m server.server`
- **改任何腳本後、commit 前必跑 `pwsh -File tests.ps1`**（離線、秒級）；**改 `server/` 下任何東西則必跑 `python3 -m unittest discover -s server -t .`**
- 每日完整流程：`./run-daily.sh --phase fetch` →（AI 寫 notes）→ `./run-daily.sh --phase publish`
- 部署：push `main`（2026-07-21 起使用者授權 Claude 自主 push，測試通過即可推）

## 定位
資訊整理與決策輔助，非投資建議、非個股推介；傾向/訊號/評分皆情境參考、非下單指令，保留頁尾免責。

## 每日流程指令不在此 repo
在本機 `~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md`：改程式邏輯會自動被沿用，改流程本身要改該檔。
⚠️ 該檔目前仍直接呼叫個別腳本，**尚未**改成 `run-daily.sh` 的兩段式。在改好之前，`export-owner`／`export-codes` 不會跑（`update-holdings.ps1` 會自動偵測 `data/owner-holdings.json` 並沿用上一次的匯出，所以不會壞，但新使用者的股票不會被抓、owner 在網頁上改的持股當天不會生效）。
