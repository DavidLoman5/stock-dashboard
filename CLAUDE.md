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
1. **Claude token 預設只花在 owner 身上，例外要走預算閘門**：每日 AI 步驟的主要輸入是 `holdings-context.json`，只由 owner 的持股產生。guest 新增股票只會多一次免費的 TWSE 抓取，**絕不可**因此觸發任何 Claude 呼叫。guest 看到的內容有兩個來源，都不花 Claude token：owner 當日產出的共用欄位，＋ **Gemini**（`server/gnotes.py` → `guest-notes.json`，free tier）補上 `rec` 與 owner 沒持有的代號。合併規則在 `payload.notes_for()`：Claude 欄位優先、Gemini 補洞、`rec` 通常也只用 Gemini（owner 的 rec 是為 owner 投組寫的，永不外流）。
   **唯一例外（2026-07-25 起）**：owner 在 `/admin` 頁面把某人升級為 **guest_plus**（`server/auth.set_tier`），這位使用者「owner 本來就沒持有」的持股代碼會**額外**被排進 Claude 的每日分析批次（SKILL.md「步驟三附加」），寫法與 Gemini 的 guest 分析一樣單檔獨立、不知道誰持有什麼、不提投組——差別只是模型換成 Claude。這仍然不違反「guest 的行為不能觸發 Claude 呼叫」：guest_plus 是 **owner 主動授予**的狀態，不是 guest 自己的動作觸發的，且有 `cfg["guestPlusCodeBudget"]`（預設 15 檔，`payload.guest_plus_codes_in_budget()`）硬性上限，超過上限的升級會被 `auth.set_tier` 直接拒絕，事後新增的持股若把上限打滿則靜默留在 Gemini 品質、不報錯。`payload.notes_for()` 用「這個代碼是不是 owner 自己的持股」（不是身分別）決定 `rec` 能不能分享，所以 guest_plus 代碼的 rec 也可能被同代碼的一般 guest 看到——這是刻意的，跟 tech/chip/fund 現有的按代碼共用邏輯一致。
2. **使用者輸入絕不進 AI prompt**：別人自填的股票名稱／備註是不可信輸入；AI 只讀腳本消化過的數值。這條對 Gemini 一樣成立——`data/codes-context.json` 的 name 取自 `data/names.json`（證交所全市場對照表），不是 DB 裡使用者打的字。這條同時擋掉 prompt injection 通往自動 `git push` 的路徑。guest_plus 的額外代碼一樣只給代號清單（`data/guestplus-codes.json`），不含「誰持有」，不違反這條

## 執行環境：Ubuntu + pwsh 7.6（2026-07-22 起，不再是 Windows PS5.1）
- 一律 `pwsh -File xxx.ps1`；`-ExecutionPolicy` 在 Linux 無作用；路徑大小寫敏感；`$env:TEMP` 為空（用 `[IO.Path]::GetTempPath()`）
- PS7 差異（刻意不改程式）：`Out-File -Encoding UTF8` 不寫 BOM（新 JSON 無 BOM、舊檔有，兩者皆可讀）；`ConvertFrom-Json` 陣列 pipeline 陷阱已修，`@()` 包裹留著當跨版本保險
- 排程：crontab `0 20 * * 1-5 /home/felix/run-stock-briefing.sh`（該 wrapper 以 `claude -p --output-format json --permission-mode auto` 跑 SKILL.md，日誌 `~/stock-briefing-cron.log`）；20:00 已收盤，當日流程用的是**當日**收盤資料。
  SKILL.md 步驟四被排程專用提示詞要求用 `run-daily.sh --phase publish --no-push`（commit 但不 push）；`claude -p` 結束後 wrapper 解析 `--output-format json` 讀到今日 token 用量，呼叫 `finish-daily-push.ps1`（deterministic、非 AI）把用量 amend 進那個還沒推的 commit 並完成 push——這樣「今日 token 用量」才能跟今日的儀表板更新同一個 commit 出去，見 `lib/publish-gate.ps1` 的 `-NoPush` 與 `plan.md` 2026-07-25。互動執行（非排程）仍走一般 `--phase publish`，會直接 push，不受影響

## 共用模組（2026-07-25 起，`lib/` 與 `page-contract.json`）
從前每支腳本各自帶一份同樣的邏輯，改一處要記得改六處。現在有單一來源：

| 檔案 | 是什麼 | 誰用 |
|---|---|---|
| `page-contract.json` | 頁面資料契約：每個 `<script id>` 對應的 `window.*` 名稱與 JSON depth，＋ 筆記欄位隱私政策（`noteFields.guest` / `noteFields.ownerOnly`） | 下面三個 lib＋`server/pagedata.py` |
| `lib/pagedata.ps1` | `Set-PageBlocks` / `Get-PageBlockText`：唯一的 splice 實作 | 六支 .ps1 全部 |
| `lib/publish-gate.ps1` | `Invoke-PublishGate`：唯一的對外出口（allowlist 上架＋內容掃描＋commit/push） | `publish.ps1` |
| `lib/stance.ps1` | `Get-StanceGrade`：唯一的判級公式 | `update-holdings.ps1`；頁面只顯示結果 |
| `lib/feed.ps1` | 唯一的抓取／快取／欄位索引／民國日期／politeness。**十一個端點都在這裡解析**（`Get-FeedIndexHistory`／`Get-FeedInstitutional`／`Get-FeedMargin`／`Get-FeedMarketInstAmount`／`Get-FeedMarketQuotes`／`Get-FeedDailySeries`／`Get-FeedIssuedShares`），快取目錄的建立與清理也是（`Get-FeedCacheDir`／`Invoke-FeedCachePrune`）。市值排序 `Select-FeedTopByMarketCap` 是純函式、不抓資料 | `screen.ps1`、`update-holdings.ps1`、`backtest.ps1` |
| `lib/score.ps1` | **唯一的選股規則**：`Get-RegimeLight`／`Get-ChipStats`／`Test-ChipGate`／`Get-ChipScore`／`Get-TechScore`／`Get-FundScore`／`Get-TotalReturnSeries`／`Test-ExitRules`。股票與 ETF 是同一組函式的兩個 **profile**（`$ScreenProfiles`），不是兩份程式 | `screen.ps1`、`backtest.ps1`（回測直接呼叫生產規則，不再手抄） |
| `lib/picks-log.ps1` | `picks-log.json` 的唯一讀寫者：retry＋FATAL 保護、`[ordered]` key 順序、保留期封存、`-ErrorAction Stop` | `screen.ps1`、`publish.ps1` |
| `lib/stance-log.ps1` | `stance-log.json` 的唯一讀寫者＋`Get-PrevStanceMap`（純函式） | `update-holdings.ps1` |
| `tools/boot-check.js` | jsdom 實跑 index.html 並斷言（33 項：`window.ANALYTICS` 純函式、三個 modal、圖表投影往返、boot 冪等、逸出、canvas 色彩 token 解析得出來、封面圖視窗與標註同源） | 改前端後手動跑 |
| `server/pagedata.py` | 同一份 `page-contract.json` 的 Python 端（含 `noteFields` 隱私政策，`payload.py` 實際讀它） | `server/server.py`、`payload.py` |

- **splice 一律用 `Set-PageBlocks`**，別再手寫 `IndexOf('<script id=...')`。找不到 marker 或不認識的 block id 都會 throw（以前只警告然後照樣寫檔）
- **`window.META` 是一般 block**，不再是對 HTML 做正則取代；報告日期由頁面從 META 帶出
- **判級公式只改 `lib/stance.ps1`**，頁面 `adviseHolding` 只把分數翻成文字、不得再寫一份門檻
- **抓官方資料一律走 `lib/feed.ps1`**，包括**解析**：呼叫端不可以再自己寫 `$row[10]` 這種位置索引。欄位索引全部在 `$FeedCols`——**T86（上市）與 TPEx dailyTrade（上櫃）欄位不同**（trust/total 是 10/18 vs 13/23），別混用。**兩張欄位表**：`$FeedCols` 是陣列的 0-based 位置，`$FeedFields` 是物件式 openapi 端點的**欄位名稱**（公司基本資料），別把名稱放到吃索引的地方。取發行股數一律用 `已發行普通股數`／`IssueShares`，**永遠不要用「實收資本額 ÷ 面額」**——有 21 家上市公司面額不是 10 元（2327 國巨是 2.5），那個算法會少算四倍、把真正的權值股擠出榜外。民國年轉換只有 `ConvertFrom-FeedRocDate` 一份（以前五份，其中兩份靠 API 自己補零）。測試用 `Set-FeedTransport` 換掉傳輸層即可離線驗真正的解析路徑
- **選股／評分／出場規則只改 `lib/score.ps1`**，且股票與 ETF 用 profile 區分而不是複製一份。`backtest.ps1` 直接呼叫同一組函式，所以「回測跟生產一致」是結構保證、不再是註解裡的承諾。單位注意：`Get-FeedInstitutional` 回傳**股**（交易所原始單位），頁面顯示的**張**由呼叫端自己除 1000
- **`picks-log.json`／`stance-log.json` 一律經各自的 lib 模組讀寫**，別再自己 `Get-Content`＋`Out-File`：retry、FATAL 保護、`[ordered]` key 順序、封存與 `-ErrorAction Stop` 都在模組裡
- **頁面的財務計算放在 `computeEquity()`**（純函式、不碰 DOM，掛在 `window.ANALYTICS`）；`buildEquity()` 只負責畫。新增計算照這個分法，才驗得動
- **新增每日產出檔 → 預設不會被發佈**。要公開必須明確加進 `lib/publish-gate.ps1` 的 `$PublishAllowlist`；`tests.ps1` [8] 會擋下「已被 git 追蹤但不在 allowlist」的檔案

## 別手改：每日流程會覆寫的部分
- `guest-notes.json`（Gemini 每日產出，gitignore）；`prev-recs.json`（每日由 holdings-notes.json 抽出，gitignore）
- `data/heavyweights.json`（市值前 30 大，`screen.ps1` **每週重算一次**、當週固定，gitignore）與 `data/heavyweights-context.json`（`update-holdings.ps1` 每日重寫，gitignore）。想改名單大小改 `screen.ps1` 的 `$hwTopN`，不要手改 JSON——長度不符會被判定為過期、下次執行就整份重算蓋掉
- splice 區塊全部：`<script id>` = `dashdata`、`holdingsmeta`、`holdingsnotes`（含 `_market` 市場風向）、`pkdata`、`pkline`、`pknotes`、`evaldata`（週五）、`backtest`（月跑）、`meta`（報告日期／行情基準日）、`tokenusage`（`finish-daily-push.ps1` 寫，非 AI）、`appuser`（伺服器逐使用者注入，committed 檔案內**必須留空**）
- Hero 市值/損益/整體傾向（heroStance）、大盤數字、市場風向區（windBox/miSox/miMood）、權重、今日訊號、績效曲線 → 頁面 JS 自動算或 `_market` 覆寫，勿寫死；HTML 內殘留文字只是 JS 失敗時的 fallback

## 可以安全改
CSS／版面、圖表函式（priceChart/candleChart/volChart）、互動邏輯、渲染器、`screen.ps1` 選股演算法、`holdings.json`

### 改圖表前要知道的三件事（2026-07-30 起）
- **封面圖（`.spark`／`#mchart`）刻意只有一條價格線**。均線與「期間起點」基準線都試過並**拿掉了**——在 58px 的小圖上它們是雜訊不是資訊。要加線之前先想清楚：均線、K 線、十字準星都已經在 modal 裡了。期間與漲跌一律走圖下方的 `.chart-meta` 文字
- **封面只畫近 `COVER_DAYS`（60）日，完整序列留給 modal**。視窗一律經 `computeCoverWindow()`（純函式、在 `window.ANALYTICS` 上），圖下方的標註也用它回傳的 `from`／`n`／`pct`——**圖與標註必須同一個來源**，否則標註會描述一個沒被畫出來的區間。boot-check 的 `cover-window:` 那組斷言守這條
- **同一張圖上的多條線要用顏色＋線型雙重區分**（`chartOverlays` 的 `o.dash`，預設實線）。目前只有權益曲線是多線圖：金色實線＝投組、灰色虛線＝加權指數，圖例在 canvas 下方的 `.chart-meta`（`.sw-line`／`.sw-line.dash` 用 CSS border 畫線段，**不要用 `━`／`┄` 這類 box-drawing 字元**，中文字型下的粗細與對齊不可靠）。只靠顏色分在色弱與黑白列印下會失效

### 改 CSS 前要知道的四件事（2026-07-30 起）
- **顏色值只在 `:root` 的 `--l-*`／`--d-*` 值對裡寫一次**，三個主題情境（`:root`／dark media／`[data-theme=dark]`）只做重新指向。加新顏色要照這個寫，別直接往 dark 區塊塞色值
- **`cssv()` 讀出來的字串直接進 `ctx.fillStyle`，無效顏色不會 throw、canvas 會沿用上一個顏色**（靜默失敗）。所以：`var()` 間接層由 `cssv()` 自己解（瀏覽器會解、**jsdom 不會**）；**不可以用 `light-dark()`**（在 custom property 裡不會被解析成單一顏色）。boot-check 的「every JS-read colour token resolves」那項守這條
- **字級／圓角／間距／動效都有 token**（`--fs-*`／`--r-*`／`--pad-*`／`--tr`）。新規則用既有級距，不要再引入新的字面值；膠囊形狀用 `--r-full`，真圓才用 `50%`
- **弱化文字用 `.faint` class，不要用 inline `style="color:…"`**——inline style 永遠贏過後來設的 `up-txt`/`down-txt`，這正是損益顏色曾經永遠是灰的原因
- **`server/static/` 三頁的 `SHARED-TOKENS-START…END` 區塊必須三頁完全相同**，且色值要與 `index.html` 一致（`tests.ps1` [12] 會驗）。CSP 擋外部 CSS，四頁只能各帶一份

## 硬性慣例（違反會壞）
- **任何含非 ASCII 位元組的 `.ps1` 都必須存 UTF-8 with BOM**（pwsh 7 不需要，保留是為了在 Windows PS5.1 也能解析中文字面值）。`tests.ps1` [2] 是**算出來的**不變式（「有非 ASCII → 必須有 BOM」），不再是手寫檔名清單——舊清單早就漏了 `evaluate.ps1`
- **repo 只放 `$PublishAllowlist` 列出的檔案**（`lib/publish-gate.ps1`；`tests.ps1` [8] 驗證「每個被追蹤的檔案都在 allowlist 上」）。`data/`、`*.db`、`config.json`、`holdings-notes.json`、`holdings-context.json`、`stance-log.json` 都不在上面——前三個一直如此，後三個是 2026-07-25 才停止外洩的（見 plan.md）；推上 GitHub 的 `index.html` 一律由 `build-demo.ps1` 用 demo 持股重建，**不可**直接推 `update-holdings.ps1` 產出的版本——那裡面是 owner 的真實部位
- **`$PublishAllowlist` 的項目要逐項個別 `git add`，不可合成一次 `git add -A -- $PublishAllowlist`**：清單裡任何一個 pathspec（含萬用字元）當下若一個檔案都沒對到，git 會整包 fatal、什麼都不 stage——`Invoke-PublishGate` 接著會誤判「沒東西可 commit」而回報成功，等於當天整個發佈悄悄失敗（2026-07-25 加 `token-usage.json` 時差點踩到，見 plan.md；`tests.ps1` [9] 有防回歸測試）。新增 allowlist 項目時留意這點
- 伺服器只綁 `127.0.0.1`，對外一律經 tunnel（目前 Tailscale Funnel）；不要改成 `0.0.0.0` 或在路由器開埠
- 換 tunnel 必須同步改 `config.json` 的 `proxyHeader`（Funnel=`X-Forwarded-For`、cloudflared=`CF-Connecting-IP`）——設錯不是無效，是讓所有按 IP 的節流可被偽造繞過
- 抓官方 API 用 `Invoke-WebRequest`+手動 UTF-8 解碼（`Invoke-RestMethod` 會亂碼）；用現成的 `GetJson()`
- `index.html` 要有 `<!DOCTYPE html>`＋`<meta charset="utf-8">`＋viewport；CSP `default-src 'none'` → 圖表 Canvas 手繪、零外部資源
- **台股紅漲綠跌**（--up 紅、--down 綠）；證交所日期是民國年（西元−1911）
- picks-log／stance-log 讀取失敗**絕不可用空資料覆寫**（FATAL/skip 防護勿移除）
- **每天被重寫的 JSON 一律用 `[ordered]@{}` 建**（`picks-log.json`／`screen-summary.json`／`eval-report.json`／splice 進頁面的 `regime`/`meta`/`perf`）。pwsh 的 `@{}` 每個 process 的列舉順序都不同，`ConvertTo-Json` 會把 key 重新洗牌 → 每日 commit 整檔重寫（實測 4 筆新增造成 408 行 diff）。注意 `[ordered]@{}` 只有 `.Contains()`、**沒有 `.ContainsKey()`**；另外 `publish.ps1` 用 `Add-Member` 把 ai-tags 接在尾端，所以 `screen.ps1` normalize 的正規順序也必須把 `aiSust`/`aiRisk` 排最後，否則隔天又被搬動。`tests.ps1` [10] 驗證
- **`picks-log.json` 有保留期**：只留全部 open ＋ 最近 120 筆已結案，更舊的由 `FoldPicksToArchive` append 進 `data/picks-archive.jsonl`（gitignored、只 append）。`evaluate.ps1` 讀 log ＋ archive 合併去重，統計不受保留期影響。折疊順序是安全性本身：**先 append 並整份讀回核對，全部確認在檔案裡才從 log 移除**；檔案操作要加 `-ErrorAction Stop`（腳本跑在 `$ErrorActionPreference='Continue'` 下，否則寫入失敗只會印訊息然後繼續刪）
- **改選股/評分/出場（`screen.ps1`）或判級（`lib/stance.ps1`）規則 → 必須同步更新 index.html 的「📐 現行選股與評價邏輯」卡（`id="logicCard"`）與 plan.md**
- **升降 guest_plus 一律走 `auth.set_tier`（網頁走 `/admin` 或 `python3 -m server.admin tier`），不要直接 `UPDATE users SET tier`**：那個函式是唯一做 Claude 代碼預算檢查（`cfg["guestPlusCodeBudget"]`）的地方，繞過它等於繞過每日 Claude 成本的唯一硬上限

## 測試與部署
- 預覽 `python3 -m http.server 8000`｜引擎 `pwsh -File screen.ps1`｜伺服器 `python3 -m server.server`
- **改任何腳本後、commit 前必跑 `pwsh -File tests.ps1`**（離線、秒級）；**改 `server/` 下任何東西則必跑 `python3 -m unittest discover -s server -t .`**
- **改 `index.html` 的 JS 後**：`D=$(mktemp -d) && (cd "$D" && npm install jsdom canvas)` 然後 `NODE_PATH="$D/node_modules" node tools/boot-check.js index.html`。少了 canvas 套件 `getContext('2d')` 回 null，boot() 第一步就斷，後面全部不會執行——「沒有錯誤」會是假的。另驗 `HOLDINGS_META` 缺 `stance` 與空投組 `{"_trades":[]}` 兩種變體（腳本第三、四個參數可換掉某個 block）。**兩個變體都是換 `holdingsmeta`**：拿 `dashdata` 當變體會把行情資料一起清掉，`DASH[code].series` 變 undefined，於是「權益曲線」與「圖表投影往返」兩項必然紅——那是叫錯用法，不是回歸
- **jsdom 的 CSS 剖析器有兩個要知道的限制**（都不是頁面的 bug，別去「修」）：① 不解析 custom property 裡的 `var()` 間接層（回傳字面的 `var(--x)`）——`cssv()` 已自己處理；② **整條丟掉含 `clamp()` 或 `min()` 的宣告**，所以 `h1`／`.market .idx-val`／`.hero .tot` 的 font-size 在 boot-check 裡「看不到」。要驗這幾條只能開真的瀏覽器
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
