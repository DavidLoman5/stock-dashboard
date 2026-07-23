# plan.md — 開發路線圖與待辦

> 活文件：待辦、待驗證、待決策都記在這。完成的移到底部「已完成」。
> 改動原則見 `CLAUDE.md`；本檔不會被每日流程覆寫。
> **改引擎/腳本後、commit 前先跑 `pwsh -File tests.ps1`**（離線迴歸測試，秒級）。

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
