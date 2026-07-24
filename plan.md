# plan.md — 開發路線圖與待辦

> 活文件：待辦、待驗證、待決策都記在這。完成的移到底部「已完成」。
> 改動原則見 `CLAUDE.md`；本檔不會被每日流程覆寫。
> **改引擎/腳本後、commit 前先跑 `pwsh -File tests.ps1`**（離線迴歸測試，秒級）。

## 🌐 多使用者伺服器模式（2026-07-23 建置）

從「單人靜態站＋每日重寫 index.html」擴充為「這台機器當伺服器、每人登入看自己持股」，
同時把個人財務資料移出公開 repo。安裝與營運細節見 `SETUP.md`。

**架構決策（做成這樣的理由）**
- **行情共用、持股個人**：`0050` 的 K 線／法人／融資對誰都一樣，只有張數與交易是個人的。
  每日抓「所有 active 使用者代號的聯集」抓一次全體共用 → API 成本隨**標的數**成長，不隨人數。
- **AI 註解也依代號共用**：個股三面判讀對誰都一樣 → guest 讀 owner 當日產出的共用快取；
  組合層級傾向改用既有規則引擎 `adviseHolding`（純行情算得出來，不需 AI）。
- **token 只花在 owner 身上（硬規則）**：每日 AI 步驟的唯一輸入是 `holdings-context.json`，
  由 `-HoldingsFile`＝owner 匯出檔產生。guest 新增股票只多一次免費 TWSE 抓取，不觸發任何
  Claude 呼叫。`server/test_server.py::TestTokenIsolation` 長期守著這條。
- **Python 標準庫、零相依**：`http.server`＋`sqlite3`＋`hashlib.scrypt`＋`secrets`，
  不需 pip/venv，與前端「零外部資源」的原則一致，別人 clone 下來不必裝任何東西。
- **伺服器端 splice 而非前端 fetch**：`index.html` 在 parse 時就把 `window.*` 推導成
  `HCODES`/`H`/`hydrate()` 等 const，改成非同步載入等於重寫整個 boot 流程。改為由
  `server.py` 逐使用者把同樣的區塊 splice 進去，前端邏輯**一行未動**。

**帳號控制**：註冊 → `pending`（看不到任何資料）→ owner 在 `/admin` 核准 → `active`；
可隨時 `suspend`，因為每個請求都重查 `users.status`，**下一次請求即失效**，不必等 session 過期。

**參數**（`config.json`，範本見 `config.example.json`）：sessionDays 14／idleDays 3／
maxLoginFailures 5／lockoutMinutes 60（2026-07-24 對外開放時收緊，原 10／15）／
maxCodesPerUser 30／maxDistinctCodes 200／maxRegistrationsPerIpPerDay 3／pendingExpiryDays 30。

**營運狀態（2026-07-24 起）**：`stock-dashboard` systemd user service＋`loginctl enable-linger`，
開機自動起。對外走 **Tailscale Funnel**（`https://felix-server.tailf8b922.ts.net`，固定網址、
免網域、免費）——cloudflared 已停用（quick tunnel 網址每次重啟就換，具名 tunnel 要自有網域，
而 Cloudflare 帳號當時沒有託管網域）。`~/.local/bin/cloudflared` 保留著沒刪。

**換 tunnel 必須同步改 `proxyHeader`**（血淋淋的實例）：切到 Funnel 後 config 仍是
`CF-Connecting-IP`，而 Tailscale **不會**覆寫這個 header——實測 `curl -H 'CF-Connecting-IP: 9.9.9.9'`
原封不動送達，等於任何人每次請求換個假 IP 就繞過全部節流與註冊上限。已改 `X-Forwarded-For`
（實測 Tailscale 會覆寫它，偽造值被換掉）。這條的教訓是**「header 名稱設錯」不是無效而是開後門**。

- [x] ~~改 SKILL.md 改用 `run-daily.sh` 兩段式~~（2026-07-23 完成，該檔在 repo 外）
- [x] ~~首次對外開放前：裝 cloudflared、`secureCookie` 設回 `true`~~（2026-07-24 完成。
      `allowedOrigins` 確認**不必填**：CSRF 檢查拿請求自己的 `Host` 當同源基準）
- [x] ~~前端 JS 尚未在真實瀏覽器驗證~~（2026-07-24 以 jsdom 驗過 owner／guest 兩種頁面：
      10 個 script 區塊零語法錯誤、boot 後 console 零錯誤、accountMode() 有跑（帳號列解除 hidden）、
      圖表 2810 次 canvas 繪製呼叫。**仍未在真實瀏覽器確認 CSP 與觸控互動**——jsdom 不做 CSP）
- [ ] 把 `felix` 密碼從 `0304` 換掉：4 位數字＝10,000 組，站已對外
- [ ] **根因修掉「AI 文字帶出其他持股」**：每日 notes 是在「看得到整個投組」的情境下寫的，
      所以 `_market.wind` 會寫「投組今日明顯分化：00990A(+0.96%)與00981A…」、個股 `fund` 會寫
      「成分股與0050/00947/00981A高度重疊」——都會洩漏 owner 的真實部位。
      目前用**白名單＋比對 owner 實際代號**擋掉（`payload.MARKET_PUBLIC_FIELDS`、
      `payload._mentions_other_holding`、`build-demo.ps1` 同規則），代價是偶爾少一段文字。
      正解是改 SKILL.md 的 prompt：個股註解寫成**與投組無關的單檔敘述**，投組層級的話另放
      owner-only 欄位。改完之後過濾器就幾乎不會觸發（但**不要移除**，它是 fail-closed 的保險）。

## 🔁 自我改進閉環（2026-07-18 上線）

架構：進場記因子快照（picks-log）＋AI 判讀標籤（ai-tags→掛回 log）＋持股判級日誌（stance-log）
→ 每週五 `evaluate.ps1` 歸因（勝率按 出場原因/燈號/籌碼分/技術分/基本分/YoY/AI標籤/產業 分組
＋判級 20 日前瞻驗證）→ AI 讀 eval-report.json 更新 `lessons.md`（餵回每日分析）
→ 候選引擎規則寫本檔待 backtest walk-forward 驗證後才上線。
鐵律：單組樣本 <10 只算初步觀察；權重每月最多調一次；所有參數改動記錄於此。

- [ ] 首次歸因週報：2026-07-24（五）
- [ ] 累積 ~30 筆帶因子快照的結案樣本後，第一次認真解讀分組差異（預估 2026-09 初）

### 每月參數檢視儀式（backtest v2.1 走前驗證）
`backtest.ps1` v2.1（2026-07-19）：200 面板日（~120 評估日）、6 排序權重 × 3 出場規則共 18 組合、
前 60% 樣本內找最優／後 40% 樣本外驗證、空頭區分組；面板逐日快取（backtest-cache/，gitignored），
月跑只補新日期、幾十秒完成。**v2.1 已對齊生產選股**（T86 ≥4/5 天、跌破季線剔除、技術分含季線
+8＝27/30、40 日高、ma20p 窗口對齊、evalLo=60）；量價/出貨 K 與基本面因子仍不可回放。
- [ ] 每月第一個週末手動跑一次 `backtest.ps1`（需人在場、電腦勿休眠）
- [ ] 調權重門檻：樣本外顯著優於現行組合＋空頭區不劣化 → 才改 screen.ps1，改動記錄於此
- [ ] 下次檢視：2026-08-18 前後（空頭樣本累積滿月），**以 v2.1 重跑為準**

**首跑結論（2026-07-18，v2 舊版，⚠ 已被 v2.1 取代、數字不可直接比較）**
**（IS 2025/09–2026/03、OOS 2026/03–07、每組 OOS n=310）**：
1. 排序權重：混合優於單一——OOS 勝率 chip+0.5t 56.5% ≈ chip+2t 55.8% ≈ **chip+t(現行) 55.5%**
   > 只籌碼 52.9% > 只技術 50.3%。v1「只看技術 60%」在長窗口不成立，**現行權重維持不動**。
2. 出場規則：hold20 勝率 55% > 破月線停損 46% > 現行出場 41%（含外資連2賣）。
   有持有期偏誤（α 不能直接比），但勝率差距指向「外資連2日轉賣」過度敏感。
3. 空頭分組 n=5 無統計意義 → 一切結論等 8/18 空頭樣本複驗。

**候選規則（待 8/18 複驗後才考慮上線）**：
- [ ] 外資連2日轉賣出場改附加條件（例：僅當價格已跌破月線時才生效），
  降低多頭中被雜訊洗出場的頻率——需在空頭樣本中確認不犧牲回撤保護

## ⏳ 待驗證（需要時間累積數據，不用寫程式）

- [ ] **空頭回測**（目標日：2026-08-18 之後）：7/17 崩跌起算累積滿一個月空頭樣本後，
  手動跑 `backtest.ps1`（約 5 分鐘）。回測卡會自動顯示多空分組勝率，據此決定
  「技術面權重是否調高」（首次回測：多頭區技術 60% > 現行 51.8%，樣本不足暫不調）。
- [ ] **燈號分組勝率**：2026-07-17 起新推薦已記錄進場燈號，結案後自動分組。
  累積約 20 筆結案後檢視：紅燈日推薦若持續劣於綠燈日 → 考慮紅燈日停止進場。
- [ ] **移動停利效果**：新規則（獲利 15%+ 破 10 日線結案）上線，觀察出場原因分布
  是否真的保住更多獲利（對照「20日到期」出場的平均報酬）。

## 🤔 待決策（需要使用者拍板）

- [ ] **「今日已跑過就跳過」的判斷要不要改用 lastTrade**：2026-07-23 出現實例——上午 11:06 手動跑
  （盤中，用 07/22 收盤），20:00 排程觸發後以「今天已執行過」為由跳過，結果當日頁面 lastTrade
  停在 2026-07-22、07/23 收盤沒進頁面。建議把 wrapper／SKILL.md 的跳過條件改成
  「`window.META.lastTrade` 已等於最新交易日才跳過」，而非「今天有沒有 commit 過」。
  （屬本機 wrapper／SKILL.md 改動，不在此 repo）
- [ ] **picks-log 去重鍵是「序列基準日」，同日跑兩次會讓後跑的 Top5 追蹤不到**：2026-07-23 實例——
  上午 11:06 盤中跑一次，基準日 20260722、當時快照為盤中價，記錄的新標的是 2801／1590；
  晚上 20:00 收盤後重跑，基準日仍是 20260722（月度端點落後一天）但快照已是 7/23 收盤，
  Top5 變成 2027／2615／2637／3706／2801，引擎因「date 20260722 already logged」不再 append，
  於是**當日發佈的 Top5 有三檔沒進追蹤問責**（2027／2615／3706）。
  根因：評分同時吃「落後一天的月度序列」＋「即時快照」，快照隨盤中時間變動。
  選項：(a) 去重鍵改為 基準日＋標的（同日可補記新標的）；(b) 盤中不跑選股、只在收盤後跑
  （20:00 排程＋修好的跳過條件已大致達成）；(c) 保持現狀但在推薦追蹤卡標示「當日未記錄」。
  影響：週五歸因報告的樣本會少掉這類標的，須在解讀時知道。
- [ ] **補登歷史交易**（使用者動作）：把五檔持股的實際買進「日期＋成交價」告訴 Claude 補入
  holdings.json trades[]，TWR 績效曲線與成本自動帶入即全面生效；未補前曲線退回舊假設。

## 💡 Backlog（有價值但未排程）

- [ ] 月營收公布週提醒（每月 10 日前後，持股相關成分股營收 YoY 變化）
- [ ] 週一「週報模式」：彙總上週勝率、判級變化、出場事件
- [ ] 大盤紅綠燈納入前夜美股/費半因子（目前僅由 AI 在文字面提及）
- [ ] 上櫃大盤指數（櫃買指數）納入行情基準（屬策略變更，走月度回測儀式）
- [ ] v14 稽核發現、尚未處理：screen.ps1 `splice()` 找不到 marker 時只警告不阻擋寫檔；
  holdings.json 讀取失敗靜默吞掉（空 catch）；degenerate candle fallback 選錯 curMode（cosmetic）

## ✅ 已完成

- 2026-07-24 **v17 站台上線＋前端首次實證驗證**：
  1. **站沒起來的原因是根本沒常駐**：伺服器一直是手動前景跑，關掉就沒了。改成 systemd user
     service（`Restart=on-failure`、`UMask=0077`、`ProtectHome=read-only`）＋`enable-linger`，
     另一支 service 跑 cloudflared quick tunnel，現在開機自動有公開 HTTPS 網址
  2. **前端首次真正跑起來驗證**（先前只有 curl 看 HTML，等於沒驗證 JS）：本機裝 Node＋jsdom，
     把伺服器實際吐的頁面 boot 起來。發現 jsdom 缺 `matchMedia` 會讓腳本停在 1115 行、
     其後的 `accountMode()` 整段不執行——shim 掉之後 owner/guest 兩種頁面 console 全零錯誤
  3. **修兩個空投組 bug**（新 guest 第一次登入必踩，curl 測不出來）：`最近交易日損益` 0/0
     算出 `NaN%`；`heroStance` 的 `if(tot>0)` 沒有 else，空投組會沿用 HTML fallback 那句
     「全數觸發防守 · 系統性重挫」——對還沒加股票的人是全錯的訊息
  4. 對外開放的加固：`maxLoginFailures` 10→5、`lockoutMinutes` 15→60、`secureCookie` 開
  5. **顯示名稱與登入帳號分離**：`display_name` 欄位（`db.MIGRATIONS` 補既有 DB）。登入 id 仍受
     `USERNAME_RE` 限制（英數/底線/連字號），顯示名稱可含空白與中文；空值退回帳號名
  6. **對外改用 Tailscale Funnel**＋修掉 `proxyHeader` 沒跟著換造成的節流繞過（見上）
  7. git 歷史：34 個 commit 的作者 email 改寫成 noreply（`--mailmap`＋force push，改寫前留
     bundle 備份）。**舊持股仍在歷史的 index.html 裡**（00990A 9 個 commit、00981A 8 個、
     00947 5 個）——要清得砍掉整個 38 commit 歷史，經評估後決定保留歷史
- 2026-07-23 **v15 遷移 Ubuntu 後的文件與腳本對齊**（Windows→Linux 遷移於 07-22 完成，本輪補齊漂移）：
  1. **修復 `tests.ps1` 在 Linux 全滅**：第 57 行用 `$env:TEMP`（Linux 為空）→ Join-Path 綁定失敗，
     測項 [5] 拋錯中止整個檔案，[5]~[7] 從未執行、也不印摘要（exit 1）。改 `[IO.Path]::GetTempPath()`，
     現 20 項全通過。等於「commit 前必跑 tests.ps1」的守門自 07-22 起一直是壞的
  2. 文件對齊實際環境：README／CLAUDE.md 的「PowerShell 5.1」改 pwsh 7.6 on Ubuntu、
     指令改 `pwsh -File`（`-ExecutionPolicy` 在 Linux 無作用）、`python`→`python3`、
     SKILL.md 路徑由 `C:\Users\felix\...` 改 `~/.claude/scheduled-tasks/...`
  3. 記錄 PS7 行為差異（刻意不改程式）：`Out-File -Encoding UTF8` 在 7 不寫 BOM
     （新產出 JSON 無 BOM、舊檔有，`Get-Content -Encoding UTF8` 兩者皆可讀）；
     `ConvertFrom-Json` 陣列 pipeline 陷阱在 7 已修，`@()` 包裹保留為跨版本保險；
     .ps1 的 BOM 慣例從「PS5.1 必需」改述為「保留以便 Windows 仍可解析」（tests [2] 續守）
  4. 移除已失效的 OneDrive 語境：screen/update-holdings/evaluate 的重試註解改為平台中立
     （重試邏輯保留，讀取失敗防清空仍是硬規則）
  5. 修正本檔 v14 第 8 點的過時描述：`.claude/settings.json` 的 Windows 帳號名稱／OneDrive 路徑
     已於 e741e72 改為 Linux 路徑；其餘未處理項移入 Backlog
  6. 排程敘述更正為實況：使用者 crontab `0 20 * * 1-5 /home/felix/run-stock-briefing.sh`
     （wrapper 跑 `claude -p --permission-mode auto`＋SKILL.md，日誌 `~/stock-briefing-cron.log`），
     時段由舊機 08:30（前一日收盤）改為收盤後 20:00；README 原本寫的 `30 8 * * 1-5` 已不適用
- 2026-07-21 **v14 安全/隱私/bug 稽核＋修復**（3 個 subagent 分別稽核 index.html／screen.ps1＋tests.ps1／
  repo 隱私；安全性整體乾淨：無金鑰外洩、XSS 有 esc()/safeUrl()、CSP 嚴格）：
  1. 手機版跑版：補 `<meta name="viewport">`（mobile-first 斷點從未生效）＋補 `<!DOCTYPE html>`
  2. 折線圖 hover 對不準：`attachChartHover` 原本一律用 K 線座標反推，改依 `curMode` 分流
  3. screen.ps1 靜默失敗：FMTQIK 全失敗改 FATAL 中止（原本會產出假的「今日無標的」並照常覆蓋頁面）；
     TPEx 法人抓取新增 `$tpexOk` 計數＋警告；`idxOk`/`tpexOk` 寫入 meta
  4. Top5 分散化漏洞：`IsElec('')`（產業查無資料）被當「確認非電子」→ 改要求 ind 非空且非電子
  5. FMTQIK 日期補零不一致（第 125 行）統一補零
  6. 移除 screen.ps1 錯誤註解「(ASCII source only)」——檔案含中文字面值、靠 BOM 解析
  7. 隱私：commit 作者 email 改 GitHub noreply（歷史 commit 未改寫）
- 2026-07-19 **v13 trades 實際持有期間績效＋警示收緊＋無障礙**：
  1. trades[] 啟用並**記錄成交價**（使用者拍板公開）；績效曲線改 TWR 按實際持有期間計算——
     修正「7 月買的持股被回推成 4 月就持有」的失真；trades 為空時退回舊行為
  2. 成本自動帶入：未輸入 localStorage 成本時用 trades 買進均價（標注「依交易均價」，輸入永遠優先）
  3. 過期警示：>5 天改為「落後 ≥2 個平日」即亮（連假可能誤亮、文案已涵蓋）
  4. Modal focus trap＋關閉焦點還原
- 2026-07-19 **v12 市場風向自動化＋文件同步**：`_market` key＋頁面 buildWind()（原本行情文字永久停在
  7/17 崩跌語境、無更新機制）；README 重寫；CLAUDE.md 覆寫清單補全四個漏掉的 marker
- 2026-07-19 **v11 回測對齊生產＋流程收尾**：backtest v2.1 對齊生產策略（T86 ≥4/5、跌破季線剔除、
  技術分含季線、距高 40 日、ma20p 窗口、evalLo=60；v2 首跑結論作廢）；publish.ps1 單一 notes 壞檔改
  WARN＋跳過；新增 `tests.ps1` 離線迴歸測試組；update-holdings 月快取（h- 前綴與 screen 隔離）
- 2026-07-18 **v10 韌性修復＋自動化補強**：歷史檔防清空（讀不到即 FATAL／跳過，絕不以空陣列覆寫）；
  hero「整體傾向」改規則引擎自動統計；update-holdings 支援上櫃持股（價格 TPEx fallback、法人 de=tot−f−t）；
  選股序列過期警告；kline-cache 自動清理；CSP `default-src 'none'`；月營收欄位名驗證
  - 已知取捨：>10% 的股票股利/現金減資退還不計入含息報酬（寧可低估）
- 2026-07-18 **v9 健檢修復＋邏輯透明化**：出場規則改用含息還原序列（除息跳空不再誤觸）；配息還原加
  10% 上限（減資不被當配息灌水）；chgPct 統一取快照端點；停牌 null 收盤跳過（原強轉 0 毒化均線）；
  hydrate 對 chg=null 防 NaN＋innerHTML 插值補 esc()；kline-cache（API 請求減 6-7 成）；
  新增「📐 現行選股與評價邏輯」卡（logicCard）＋規則改動必須同步的慣例
  - backtest 與生產已知差距（除檔頭註明者）：tech 分數僅子集、無 ETF——解讀回測時記得
- 2026-07-18 **v8 六項優化**：含息報酬、上櫃市場整合（2384 檔）、回測多空分組、燈號分組勝率、
  移動停利、集中度自動警示；修復 color=null 中斷 renderAll 的根因
- 2026-07-17～18 早期：v7 架構重構（腳本管數字、AI 管判讀）、v7.1 安全稽核（XSS 轉義、抓資料防呆、
  隔夜舊 notes 防呆、repo 瘦身）、隱私（noindex、移除 Artifact 步驟、.git 搬出 OneDrive）
