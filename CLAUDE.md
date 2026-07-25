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

- `holdings.json` 已**不再是真實持股**。真實部位在 DB，用網頁「編輯持股」或 `python3 -m server.admin import-holdings` 維護
- **數量單位是「股」不是「張」**（2026-07-24 起，1 張＝1000 股，可填零股）：DB 欄位 `holdings.shares`／`trades.shares`，`holdings.json` 用 `shares`。舊的 `lots` 欄位讀得到、會自動 ×1000 轉換（`db.lots_to_shares()`／`SharesOf()`／`admin._shares_of()`）。**法人買賣超、融資融券、成交量仍是「張」**——那是證交所的單位，別跟著改
- 使用者回報交易時仍**同步改 shares 並 append trades**，但目標是 DB，不是 `holdings.json`；localStorage 成本輸入仍可覆寫頁面損益

## 多使用者的兩條硬規則
1. **Claude token 只花在 owner 身上**：每日 AI 步驟的唯一輸入是 `holdings-context.json`，而它只由 owner 的持股產生。guest 新增股票只會多一次免費的 TWSE 抓取，**絕不可**因此觸發任何 Claude 呼叫。guest 看到的內容有兩個來源，都不花 Claude token：owner 當日產出的共用欄位，＋ **Gemini**（`server/gnotes.py` → `guest-notes.json`，free tier）補上 `rec` 與 owner 沒持有的代號。合併規則在 `payload.notes_for()`：Claude 欄位優先、Gemini 補洞、`rec` 一律用 Gemini（owner 的 rec 是為 owner 投組寫的，永不外流）
2. **使用者輸入絕不進 AI prompt**：別人自填的股票名稱／備註是不可信輸入；AI 只讀腳本消化過的數值。這條對 Gemini 一樣成立——`data/codes-context.json` 的 name 取自 `data/names.json`（證交所全市場對照表），不是 DB 裡使用者打的字。這條同時擋掉 prompt injection 通往自動 `git push` 的路徑

## 執行環境：Ubuntu + pwsh 7.6（2026-07-22 起，不再是 Windows PS5.1）
- 一律 `pwsh -File xxx.ps1`；`-ExecutionPolicy` 在 Linux 無作用；路徑大小寫敏感；`$env:TEMP` 為空（用 `[IO.Path]::GetTempPath()`）
- PS7 差異（刻意不改程式）：`Out-File -Encoding UTF8` 不寫 BOM（新 JSON 無 BOM、舊檔有，兩者皆可讀）；`ConvertFrom-Json` 陣列 pipeline 陷阱已修，`@()` 包裹留著當跨版本保險
- 排程：crontab `0 20 * * 1-5 /home/felix/run-stock-briefing.sh`（該 wrapper 以 `claude -p --permission-mode auto` 跑 SKILL.md，日誌 `~/stock-briefing-cron.log`）；20:00 已收盤，當日流程用的是**當日**收盤資料

## 共用模組（2026-07-25 起，`lib/` 與 `page-contract.json`）
從前每支腳本各自帶一份同樣的邏輯，改一處要記得改六處。現在有單一來源：

| 檔案 | 是什麼 | 誰用 |
|---|---|---|
| `page-contract.json` | 頁面資料契約：每個 `<script id>` 對應的 `window.*` 名稱與 JSON depth，＋ 筆記欄位隱私政策（`noteFields.guest` / `noteFields.ownerOnly`） | 下面三個 lib＋`server/pagedata.py` |
| `lib/pagedata.ps1` | `Set-PageBlocks` / `Get-PageBlockText`：唯一的 splice 實作 | 六支 .ps1 全部 |
| `lib/publish-gate.ps1` | `Invoke-PublishGate`：唯一的對外出口（allowlist 上架＋內容掃描＋commit/push） | `publish.ps1` |
| `lib/stance.ps1` | `Get-StanceGrade`：唯一的判級公式 | `update-holdings.ps1`；頁面只顯示結果 |
| `lib/feed.ps1` | `Get-FeedJson`／`Get-FeedDailySeries`／`$FeedCols`：唯一的抓取、快取與欄位索引 | `screen.ps1`、`update-holdings.ps1`、`backtest.ps1` |
| `tools/boot-check.js` | jsdom 實跑 index.html 並斷言（含 `window.ANALYTICS` 純函式） | 改前端後手動跑 |
| `server/pagedata.py` | 同一份 `page-contract.json` 的 Python 端 | `server/server.py`、`payload.py` |

- **splice 一律用 `Set-PageBlocks`**，別再手寫 `IndexOf('<script id=...')`。找不到 marker 或不認識的 block id 都會 throw（以前只警告然後照樣寫檔）
- **`window.META` 是一般 block**，不再是對 HTML 做正則取代；報告日期由頁面從 META 帶出
- **判級公式只改 `lib/stance.ps1`**，頁面 `adviseHolding` 只把分數翻成文字、不得再寫一份門檻
- **抓官方資料一律走 `lib/feed.ps1`**：`Get-FeedJson`（重試＋UTF-8 手動解碼）、`Get-FeedDailySeries`（含完成月快取與 TWSE/TPEx 路由）。欄位索引在 `$FeedCols`——**T86（上市）與 TPEx dailyTrade（上櫃）欄位不同**（trust/total 是 10/18 vs 13/23），別混用。測試用 `Set-FeedTransport` 換掉傳輸層即可離線驗真正的解析路徑
- **頁面的財務計算放在 `computeEquity()`**（純函式、不碰 DOM，掛在 `window.ANALYTICS`）；`buildEquity()` 只負責畫。新增計算照這個分法，才驗得動
- **新增每日產出檔 → 預設不會被發佈**。要公開必須明確加進 `lib/publish-gate.ps1` 的 `$PublishAllowlist`；`tests.ps1` [8] 會擋下「已被 git 追蹤但不在 allowlist」的檔案

## 別手改：每日流程會覆寫的部分
- `guest-notes.json`（Gemini 每日產出，gitignore）；`prev-recs.json`（每日由 holdings-notes.json 抽出，gitignore）
- splice 區塊全部：`<script id>` = `dashdata`、`holdingsmeta`、`holdingsnotes`（含 `_market` 市場風向）、`pkdata`、`pkline`、`pknotes`、`evaldata`（週五）、`backtest`（月跑）、`meta`（報告日期／行情基準日）、`appuser`（伺服器逐使用者注入，committed 檔案內**必須留空**）
- Hero 市值/損益/整體傾向（heroStance）、大盤數字、市場風向區（windBox/miSox/miMood）、權重、今日訊號、績效曲線 → 頁面 JS 自動算或 `_market` 覆寫，勿寫死；HTML 內殘留文字只是 JS 失敗時的 fallback

## 可以安全改
CSS／版面、圖表函式（priceChart/candleChart/volChart）、互動邏輯、渲染器、`screen.ps1` 選股演算法、`holdings.json`

## 硬性慣例（違反會壞）
- `screen.ps1`／`update-holdings.ps1`／`publish.ps1`／`build-demo.ps1`／`lib/*.ps1` 存 **UTF-8 with BOM**（pwsh 7 不需要，保留是為了在 Windows PS5.1 也能解析中文字面值；`tests.ps1` [2] 驗證）
- **repo 只放 `$PublishAllowlist` 列出的檔案**（`lib/publish-gate.ps1`；`tests.ps1` [8] 驗證「每個被追蹤的檔案都在 allowlist 上」）。`data/`、`*.db`、`config.json`、`holdings-notes.json`、`holdings-context.json`、`stance-log.json` 都不在上面——前三個一直如此，後三個是 2026-07-25 才停止外洩的（見 plan.md）；推上 GitHub 的 `index.html` 一律由 `build-demo.ps1` 用 demo 持股重建，**不可**直接推 `update-holdings.ps1` 產出的版本——那裡面是 owner 的真實部位
- 伺服器只綁 `127.0.0.1`，對外一律經 tunnel（目前 Tailscale Funnel）；不要改成 `0.0.0.0` 或在路由器開埠
- 換 tunnel 必須同步改 `config.json` 的 `proxyHeader`（Funnel=`X-Forwarded-For`、cloudflared=`CF-Connecting-IP`）——設錯不是無效，是讓所有按 IP 的節流可被偽造繞過
- 抓官方 API 用 `Invoke-WebRequest`+手動 UTF-8 解碼（`Invoke-RestMethod` 會亂碼）；用現成的 `GetJson()`
- `index.html` 要有 `<!DOCTYPE html>`＋`<meta charset="utf-8">`＋viewport；CSP `default-src 'none'` → 圖表 Canvas 手繪、零外部資源
- **台股紅漲綠跌**（--up 紅、--down 綠）；證交所日期是民國年（西元−1911）
- picks-log／stance-log 讀取失敗**絕不可用空資料覆寫**（FATAL/skip 防護勿移除）
- **改選股/評分/出場（`screen.ps1`）或判級（`lib/stance.ps1`）規則 → 必須同步更新 index.html 的「📐 現行選股與評價邏輯」卡（`id="logicCard"`）與 plan.md**

## 測試與部署
- 預覽 `python3 -m http.server 8000`｜引擎 `pwsh -File screen.ps1`｜伺服器 `python3 -m server.server`
- **改任何腳本後、commit 前必跑 `pwsh -File tests.ps1`**（離線、秒級）；**改 `server/` 下任何東西則必跑 `python3 -m unittest discover -s server -t .`**
- **改 `index.html` 的 JS 後**：`D=$(mktemp -d) && (cd "$D" && npm install jsdom canvas)` 然後 `NODE_PATH="$D/node_modules" node tools/boot-check.js index.html`。少了 canvas 套件 `getContext('2d')` 回 null，boot() 第一步就斷，後面全部不會執行——「沒有錯誤」會是假的。另驗 `HOLDINGS_META` 缺 `stance` 與空投組 `{"_trades":[]}` 兩種變體（腳本第三、四個參數可換掉某個 block）
- **發佈前想看會推什麼**：`pwsh -File publish.ps1 -DryRun`（跑完整流程但不 commit/push）
- 每日完整流程：`./run-daily.sh --phase fetch` →（AI 寫 notes）→ `./run-daily.sh --phase publish`
- 部署：push `main`（2026-07-21 起使用者授權 Claude 自主 push，測試通過即可推）

## 定位
資訊整理與決策輔助，非投資建議、非個股推介；傾向/訊號/評分皆情境參考、非下單指令，保留頁尾免責。

## 每日流程指令不在此 repo
在本機 `~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md`：改程式邏輯會自動被沿用，改流程本身要改該檔。該檔已是 `run-daily.sh` 兩段式（`--phase fetch` → AI 寫 notes → `--phase publish`），跳過條件也已改為「`window.META.lastTrade` 等於官方最新交易日才跳過」。

## Agent skills

### Issue tracker

Issues live in GitHub Issues (DavidLoman5/stock-dashboard), via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default label vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
