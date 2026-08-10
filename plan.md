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
maxLoginFailuresPerUser 20（2026-07-24 新增：IP 與帳號分開計，擋掉「5 次錯密碼把 owner 鎖在門外」的反向 DoS）／
maxCodesPerUser 30／maxDistinctCodes 200／maxRegistrationsPerIpPerDay 3／pendingExpiryDays 30。

**營運狀態（2026-07-24 起）**：`stock-dashboard` systemd user service＋`loginctl enable-linger`，
開機自動起。對外走 **Tailscale Funnel**（`https://<機器>.<tailnet>.ts.net`，固定網址、
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

- [x] 首次歸因週報：2026-07-24（五）完成。closed n=8、勝率 75%、avgRet −1.92%、avgAlpha +0.51%。
  **全部分組 n<10，依鐵律只寫進 `lessons.md` 的「初步觀察」、無一條升格為教訓。**
  最值得追的兩點：①「跌破月線」出場 n=2 avgRet −10.1%／alpha −4.19%，vs「外資連2日轉賣」
  n=6 avgRet +0.82%／alpha +2.08%／勝率 83%——與 v2 回測「外資連2賣過度敏感」的結論方向**相反**，
  兩者都不可信（樣本皆過小），但 8/18 v2.2 重跑時要特別看這組對比。
  ② AI `sust` 標籤：sustainable n=3 alpha +3.02%／勝率 100% vs one-off n=2 alpha −0.97%——
  差異出現在 alpha 而非絕對報酬（one-off 的 avgRet 反而較高），若後續成立，代表 sust 的價值在弱勢盤。
- [ ] 累積 ~30 筆帶因子快照的結案樣本後，第一次認真解讀分組差異（預估 2026-09 初）

### 每月參數檢視儀式（backtest v2.2 走前驗證）
`backtest.ps1` v2.2（2026-07-24）：200 面板日（~120 評估日）、6 排序權重 × **4 出場規則共 24 組合**、
前 60% 樣本內找最優／後 40% 樣本外驗證、空頭區分組；面板逐日快取（backtest-cache/，gitignored）。
v2.2 相對 v2.1 的升級（**數字不可與 v2.1 比較**）：
1. **面板快取 v2**：改存 O/H/L/C/量/值/帶號漲跌（同一 MI_INDEX 回應、不多打 API）。
   舊 v1 快取視為 miss，**下次跑會一次性重抓 200 天（約 30-60 分鐘，之後照舊只補新日期）**
2. **含息回放**：出場模擬與報酬全用含息序列（同生產 DivSumSince 公式＋10% 上限）——
   除息跳空不再誤觸停損（smoke 實測 3 天面板就有 24 檔除息特徵日）
3. **量價因子回放**：出貨 K 剔除、量增價揚 +4/+2、高檔長上影 −5、低檔長下影 +2，對齊生產 techS
4. **新增 stopTrail 出場**＝prod 拿掉外資連 2 賣（候選規則「外資連2賣僅在跌破月線時生效」
   在日頻下等價於拿掉該規則——跌破月線本來就會觸發停損），8/18 重跑直接對比 prod vs stopTrail
5. **統計**：avgAlphaNet（扣 0.585% 來回成本）、medAlpha（中位數）、nDistinct（同代號 20 日內
   重複進場只計一次＝真實樣本數，回應 overlapping windows 灌水 n 的舊註記）
仍不可回放：基本面因子、綠燈動能 +3（需逐日 instNet/漲跌家數）、ETF 榜；僅上市。
- [ ] 每月第一個週末手動跑一次 `backtest.ps1`（需人在場、電腦勿休眠；**首次 v2.2 跑要留 1 小時**）
- [ ] 調權重門檻：樣本外顯著優於現行組合＋空頭區不劣化 → 才改 screen.ps1，改動記錄於此
- [ ] 下次檢視：2026-08-18 前後（空頭樣本累積滿月），**以 v2.2 重跑為準**（v2.1 結論作廢）

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
  （2026-07-24：已以 `stopTrail` 出場規則進 v2.2 網格，8/18 重跑即得樣本外對比）

## 🐛 待修：資料新鮮度不一致（2026-07-24 排程中發現，非阻斷、先記錄）

- [ ] **`codes-context.json` 疑似漏掉非 owner 使用者的代號**（2026-07-25 /grill-with-docs 節流討論中查到，
  非阻斷、未查根因）：真實 guest 帳號 `yianchen960630` 持有 18 檔（多數非 owner 持股，如 2330/2454/6919 等），
  `active-codes.json` 正確抓到 21 碼聯集，但 `data/codes-context.json`（`gnotes.py` 餵給 Gemini 的唯一輸入）
  當天只有 5 筆＝剛好等於 owner 的持股。若屬實，代表這個 guest 的多數持股在 `guest-notes.json` 裡永遠是
  「尚無分析」，Gemini 補洞的機制沒有真正生效。問題應該在 `update-holdings.ps1` 產生 `$allContext`
  那段（`$codes = $ownCodes + $extraCodes` 之後、逐碼呼叫 `CodeContext` 那個迴圈），還沒查是
  `$extraCodes` 本身是空的，還是 `CodeContext` 對這些代號回傳 null。下次排程時可先加一行 debug 輸出確認。

- [ ] **`codes-context.json` 的櫃買（TPEx）代號整列停更**（2026-07-31 排程中發現，非阻斷）：
  當日 27 筆 context 中，恰好三檔櫃買股 3211 順達、4749 新應材、**4946 辣椒** 的
  `foreignLast2` 與 `marginToday` 皆為 null；其中 4946 的 `price`(104.5)／`ma20`(106.4)／`ma60`(107.88)
  與**前一日完全相同**，但當天大盤暴漲 7.97%、其餘 21 檔漲逾 5%——整列是隔日沿用的舊資料，不是真的沒漲。
  影響：4946 是目前唯一的 guest_plus 代碼，當日 SKILL 步驟三附加因無法取得可信數字而**整檔略過**
  （寫不出正確的價位與籌碼敘述，略過優於編造），該使用者當天退回 Gemini 品質。
  推測與上面那條同源（`CodeContext` 對櫃買代號的處理），但症狀不同：不是「查不到」而是「回傳過期值」。
  候選解法：`CodeContext` 對 TPEx 代號改走 `lib/feed.ps1` 的 TPEx dailyTrade 路徑；
  在 `codes-context.json` 每列加 `asOf` 欄位，讓下游（AI 與 `gnotes.py`）能辨識並自行略過過期列。
  **2026-08-10 二度確認、非單次意外**：`price`(104.5)／`ma20`(106.4)／`pct`(-0.95%) 與 7/31 那次記錄
  的數字**逐位元相同**，`foreignLast2` 仍是 null，而當天大盤大漲 1.59%、三大法人買超 731.67 億元——
  同一檔、同一種停更症狀，跨越至少兩次排程未修復。步驟三附加當天再次整檔略過 4946。優先度應提高。

- [ ] **`BFI82U`（三大法人買賣金額統計，`regime.instNet` 的來源）疑似落後/誤讀，且會反向影響燈號**
  （2026-08-10 排程中發現，非阻斷、未查根因）：當日 `screen-summary.json` 的 `regime.instNet=-429`
  （億元，賣超），但新聞查證當天三大法人實際**買超 731.67 億元**（外資+517.14、投信+29.84、自營商+184.68），
  方向完全相反；也不match前一交易日 8/7 的實際值（賣超 101.76 億元）——不是單純晚一天的落後，
  懷疑是解析或抓取層面的錯誤（欄位錯位或快取讀到不相干的值），待查。
  **後果不只是文字敘述失準**：`lib/score.ps1` 的 `Get-RegimeLight` 把 `InstNet -gt 0` 當三分之一權重，
  當天 `idx(44928.76) > ma20(43595.98)` 且 `up(1268) > down(926)` 均成立、只差 `instNet` 這一分，
  若 `instNet` 正確地是正值，當天燈號應為 **green** 而非目前顯示的 **yellow**——即整個 regime 燈號
  當天可能因這個上游數字錯誤而誤判一整級。當日已在 `_market.wind` 改用新聞查證後的正確買賣超數字寫作，
  未使用可能有誤的 `instNet`。候選解法：先加一支離線測試餵入已知 BFI82U 回應、比對
  `Get-FeedInstitutional`／`Get-FeedMarketInstAmount` 解析出的 instNet 是否與已知正確值相符，
  藉此判斷是解析欄位錯位還是抓取到舊快取。

兩處「同一份頁面混用兩個交易日」的問題，都不影響數字正確性，但會讓文字敘述失準：

- [ ] **選股基準日落後行情一天**：`screen.ps1:96` 的 `$lastDate` 取自 OpenAPI `STOCK_DAY_ALL`，
  20:00 執行時該端點仍只有前一日（7/23），而月報式 `STOCK_DAY` 端點已有當日（7/24）——
  於是同一次執行裡，`regime.idx` 是 7/24 的 43,654.84（紅燈），
  但所有個股評分／收盤價與 `screen-summary.date` 都是 7/23，觸發滿版
  `warn ... series stale ... scores use previous bar`。
  後果：大盤 −2.67% 的當天，Top5 分數完全沒反映這根長黑；今日短評已逐檔手動加註「評分基準為7/23收盤」，
  但這應該由頁面自動標示，不該靠 AI 每天記得寫。
  候選解法：`$lastDate` 改取「已抓到的個股序列最大日期」與 STOCK_DAY_ALL 日期的較大者，
  或在 `screen-summary` 加 `regimeDate` 欄位、頁面於兩者不一致時顯示提示帶。**動到選股主流程，要先跑 tests.ps1。**
- [ ] **融資資料落後一天**：MI_MARGN 在 20:00 尚未出當日檔，`update-holdings.ps1:248` 取 margin 陣列
  最後一筆＝前一日，於是 `holdings-context.json` 的 `marginToday`/`marginDelta` 是 7/23 值。
  2026-07-24 這天五檔的融資數字與前一日**完全相同**，若沒察覺會寫出「今日融資減碼」的錯誤敘述。
  候選解法：`holdings-context.json` 增一個 `marginDate` 欄位讓 AI 與頁面都能辨識，
  頁面融資欄位在落後時標註日期。
  **2026-07-31 這條真的咬到了，而且是最壞的形式**：當天 18:20 提前跑，MI_MARGN 只到 7/30；
  同日 23:20 重跑時 7/31 已出，五檔的融資數字**三檔方向相反**——
  0050 +4,684→**-298**、00947 -113→**+1,821**、00990A -524→**+888**，
  00981A +11,460→**+136,523**（差 12 倍）。當天發佈的頁面與 AI 分析都用了 7/30 的值當今日，
  而且有多條 rec 的條件句是建立在融資方向上的（「法人買進、融資減碼的健康結構」實際是融資大增）。
  這說明「落後一天」不只是數字舊，是**會讓結論反向**。優先度應提高：
  在補上 `marginDate` 之前，至少要讓 `holdings-context.json` 帶上 margin 的實際日期，
  好讓 AI 在日期不等於 lastTrade 時直接不寫融資敘述。

## ✅ 2026-07-31 完成：權值股清單（成分股視角不再依賴 guest 名單）

投組五檔全是 ETF，要寫「成分股在發生什麼」時唯一的免費官方數字來源，竟是 `data/codes-context.json`
裡**其他使用者碰巧持有的代號**（當天 27 檔裡 21 檔屬 guest，其中 12 檔剛好是成分或同族群權值股）。
那個檔案本來是 `gnotes.py` 餵 Gemini 的輸入（union 對它是正確語意），是 repo 外的 SKILL.md
叫 Claude 也去讀，才讓 owner 的分析品質對「誰註冊了、誰買了什麼」產生未宣告的依賴。

做法：`screen.ps1` 每週依**真市值**（`已發行普通股數` × 收盤）算出前 30 大寫 `data/heavyweights.json`，
`update-holdings.ps1` 隔次執行讀它、抓同一組數字寫 `data/heavyweights-context.json`。

- **新端點**：`t187ap03_L`（上市）＋ `mopsfin_t187ap03_O`（上櫃），`lib/feed.ps1` 的
  `Get-FeedIssuedShares`；欄位名放新的 `$FeedFields`（`$FeedCols` 是位置索引，混用是類別錯誤）
- **必須用 `已發行普通股數`，不可用「實收資本額 ÷ 面額」**：21 家上市面額不是 10 元
  （2327 國巨是 2.5），少算四倍會把真權值股擠出榜外。`tests.ps1` [13] 有回歸測試
- **必須排除創新板**（`-創`）：6949 沛爾生醫-創 實測 10,362 億、會排第 16。TDR（91xx）也排除
  （股數是國外母公司的、價格是台幣存託憑證），但實測 9105 只有 777 億，是防禦性而非關鍵
- **上櫃不能省**：5274 信驊實測就排第 30，只抓上市會拿到錯的最後一名
- **每週鍵用 ISO 週而非「今天是不是週一」**：週一放假才不會整週不重算。週鍵同時是重試機制——
  閘門沒過就不更新 `asOfWeek`，隔天自動再試
- **`codes-context.json` 一個位元組都沒動**（實測仍 27 檔）：`gnotes.py` `BATCH=40`，
  混進去會讓 Gemini 從 1 次請求變 2 次
- **FATAL guard 順手修掉一個既有的可用性地雷**：原本 `$codes`（含全體 guest 持股）任一檔 K 線
  < 25 根就整支 abort，等於**任何 guest 買一檔新上市股就會讓 owner 整天不更新**。
  改成 owner 持股仍 FATAL、其餘 skip-with-warning。從未觸發過，但只差有人買新股
- **`quotes.json` 的回歸已修**：權值股一度進了它，180KB→331KB，而那些代號依定義沒人持有，
  伺服器每次載入白背 150KB。已改成只倒 `TAIEX + $codes`，`tests.ps1` [13] 有防回歸斷言

待辦：repo 外的 `~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md` 尚未更新——
步驟二要加「Read `data/heavyweights-context.json`」，步驟三附加要改成不再讀 `codes-context.json`。
**那個檔案不在 repo 內，改動不會被 tests 或 publish gate 涵蓋**，這正是本次問題的根因。

## ⏳ 待驗證（需要時間累積數據，不用寫程式）

- [ ] **空頭回測**（目標日：2026-08-18 之後）：7/17 崩跌起算累積滿一個月空頭樣本後，
  手動跑 `backtest.ps1`（約 5 分鐘）。回測卡會自動顯示多空分組勝率，據此決定
  「技術面權重是否調高」（首次回測：多頭區技術 60% > 現行 51.8%，樣本不足暫不調）。
- [ ] **燈號分組勝率**：2026-07-17 起新推薦已記錄進場燈號，結案後自動分組。
  累積約 20 筆結案後檢視：紅燈日推薦若持續劣於綠燈日 → 考慮紅燈日停止進場。
- [ ] **移動停利效果**：新規則（獲利 15%+ 破 10 日線結案）上線，觀察出場原因分布
  是否真的保住更多獲利（對照「20日到期」出場的平均報酬）。
- [ ] **候選規則：籌碼分過高是否反而是反指標**（2026-07-31 歸因週報發現，**先回測、不要改 `lib/score.ps1`**）：
  `eval-report.json` 的 `byChip` 顯示 chip38+ 這組 n=1、勝率 0%、avgAlpha **-7.69%**，
  而 chip30-37 這組 n=8、勝率 75%、avgAlpha +2.66%。n=1 完全不能下結論，
  但假說明確且可測：籌碼分衝到頂時外資往往已買到滿，後續缺乏增量買盤，等於買在法人動能的末端。
  驗證方式：`backtest.ps1` 直接呼叫生產規則，可在回測裡把 chip 分數切成 30-37 / 38+ 兩組比較，
  累積至各組 n≥10 再判斷是否要在 `Get-ChipScore` 加高分遞減或設上限。
  在有回測結論之前，只在短評文字上加註（見 lessons.md 同日條目），不動引擎。

## 🤔 待決策（需要使用者拍板）

- [x] **🔴 `holdings-notes.json` / `holdings-context.json` 本身就在公開 repo 裡（2026-07-24 發現，2026-07-25 修法 (a) 已做）**：
  上一則記的是「index.html 被 splice 蓋回去」，已修；但那只堵住一條路。`publish.ps1:103` 是 `git add -A`，
  而它的 fail-closed 隱私檢查（`publish.ps1:73`）**只看 index.html**，所以這兩個檔每個交易日照樣被推上公開 repo：
  - `holdings-notes.json`：owner 五檔的 `rec` 全文、`_market.wind`、持股代號
  - `holdings-context.json`：owner 的完整投組（代號＋名稱＋現價＋均線＋籌碼）
  也就是說**現在任何人在 GitHub 上看到的，比登入後的 guest 看到的還多**——`build-demo.ps1`
  那套 demo 替換等於被繞過。
  已確認**沒有東西需要它們在 git 裡**：build-demo.ps1／publish.ps1／payload.py／run-daily.sh
  全部讀工作目錄的本機檔。
  修法分兩段：
  (a) **往前不再外洩**（低風險、與現有設計一致）：把這兩個檔（含 `ai-tags.json` 要不要一起）
      加進 `.gitignore` ＋ `git rm --cached`，並把 publish.ps1 的隱私檢查從「只掃 index.html」
      擴大成「掃所有 staged 檔案」，否則下次再多一個檔又會重演；
  (b) **既有歷史**：與上一則同一個決策，force push 改寫公開歷史，未經授權不做。

  **2026-07-25 已做 (a)，做法與當初設想不同**：沒有把「再多列幾個檔名」當解法，而是把出口本身
  變成模組（`lib/publish-gate.ps1`）。`publish.ps1` 不再 `git add -A`，改成只上架
  `$PublishAllowlist` 列出的路徑，並在 commit 前做三件事：
  (1) 檢查**每個被 git 追蹤的檔案**都在 allowlist 上；(2) 只 stage allowlist；
  (3) 掃描實際 staged 的 JSON/HTML 內容有沒有 owner-only 欄位（遞迴找 key，抓得到 `_market.wind`）。
  結果第一次跑就多抓到一個當初沒列到的檔：**`stance-log.json`**——它逐日記錄 owner 五檔的判級，
  等於持續公開 owner 持有哪些代號。三個檔（notes／context／stance-log）已 `git rm --cached`
  ＋ 進 `.gitignore`，檔案本身留在磁碟，流程照常讀工作目錄。
  這就是 denylist 與 allowlist 的差別：前者只擋想得到的，後者連想不到的都預設不出去。
  `tests.ps1` [8] 的斷言也跟著改成「每個被追蹤的檔案都在 allowlist 上」。
  **副作用（已知、可接受）**：`stance-log.json` 不再有 git 當異地備份，只存在本機磁碟。

- [ ] **🔴 已外洩的 git 歷史要不要改寫（需使用者拍板）**：2026-07-24 排程執行中發現，
  `run-daily.sh` 的 publish 階段把 `build-demo.ps1` 排在 `publish.ps1` **之前**，
  而 publish.ps1 會把 `holdings-notes.json` 原封不動 splice 進 `holdingsnotes` 區塊——
  於是 demo 過濾後的頁面又被owner 完整註解蓋回去。**已修復並加測試**（見下方「已完成」），
  但下列 commit 已推上公開 repo，內容仍在 GitHub 歷史裡：
  - `dc82411`（2026-07-24 本次流程的第一次推送，已由 `c470555` 修正當前檔案）
  - `68ab685`、`d7313a2`（2026-07-23 兩次 daily update）
  外洩內容：owner 五檔**持股代號**（0050／00935／00947／00981A／00990A）、
  每檔的 `rec` 操作建議全文、`_market.wind`（內含逐檔漲跌點名）。
  **未外洩**：張數／成本／交易紀錄（`holdingsmeta` 一直只有 demo 的 2 檔、lots 皆為 demo 值），
  也沒有帳號、密碼或 `data/` 任何檔案。
  選項：(a) 不處理——代號本身敏感度低，且 0050／00935 本來就在公開 demo 裡；
  (b) `git filter-repo` 改寫這 3 個 commit 的 index.html＋force push（會改變所有 commit hash，
  且 GitHub 可能仍留有舊 object 快取，需另外向 GitHub 申請清除）。
  **未經授權不做 (b)**：force push 改寫公開歷史屬不可逆且對外可見的操作。
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
- [ ] 大盤紅綠燈納入前夜美股/費半因子。**2026-08-02 更新**：資料層已備妥
      （`overnight-context.json` 有費半、那斯達克期貨、台積電 ADR 溢價的數字），
      但 `Get-RegimeLight` 的公式**刻意未改**——那是評分規則變更，會連動選股與週五歸因統計，
      照慣例要先用 `backtest.ps1` 驗證。要做的是「用哪個因子、門檻多少、對勝率的影響」
- [ ] 上櫃大盤指數（櫃買指數）納入行情基準（屬策略變更，走月度回測儀式）
- [ ] v14 稽核發現：~~screen.ps1 `splice()` 找不到 marker 時只警告不阻擋寫檔~~（2026-07-25 已修：
  splice 統一到 `lib/pagedata.ps1`，marker 不存在或 block id 不認識都 throw）；
  degenerate candle fallback 選錯 curMode（cosmetic，未處理）。~~holdings.json 讀取失敗靜默吞掉~~（2026-07-24 已改為警告）

## ✅ 已完成

### 2026-08-02 找資料系統：加上前瞻層與隔夜美股

使用者指出「美股會影響台股但有時候沒搜到」，並問為什麼 7/30 沒能預見 7/31 的大漲。
查證後這**不是預測問題，是資料與搜尋協定的問題**。

**7/30 的關鍵資訊當時已公開 16 小時。** 微軟 FY26Q4 的 IR 新聞稿日期是 2026-07-29（美東盤後）
＝**台灣 7/30 凌晨 04:05**。20:00 執行時它已存在 16 小時，但當天 commit（`9c04c2f`）寫的是
`windLead: 費半本週因FOMC升息疑慮持續破底` / `sox: -10.1%` / `moodK: bear`。
當晚費半 +8.19%、台積電 ADR +7.64%，隔日台股 +3,186.45 點（+7.97%，史上最大單日漲點）。
台股自己的盤也給了訊號：7/28 −2,030 → 7/29 −1,564 → **7/30 僅 −105.88，成交量 11,469 億**
（該段第二大），連續重挫後帶量止跌。但 `_market` 四個欄位全部描述「今天」，沒有一個承接「明天」。

**根因：整套搜尋協定是後照鏡。** 20:00 執行時美股當日還沒開盤（21:30 才開），最近一個美股
收盤已被當日台股消化完；真正還沒被定價的是盤後財報與期貨，而那三樣東西
（美股期貨／盤前、台指期夜盤、今晚排定事件）在 SKILL.md 裡完全不存在。
且美股被寫成「一次搜『美股 AI』→ **覆蓋 00990A**」，降格成單一持股的題材。

**順帶修掉的 bug：`heavyweights-context.json` 少了台積電。**
`update-holdings.ps1` 的 `$hwCodes` 排除的是 `$codes`（**全使用者聯集**）而非 `$ownCodes`，
所以只要任何 guest 持有某檔權值股，它就從「成分股視角」消失。當天實測 **30 檔只剩 22 檔**，
少掉 2330／2454／2308／3711／2408／7769／2327／2887——包含 7/31 單日貢獻 1,746 點的台積電。
`c9d36e3`（「成分股視角不再依賴 guest 名單」）修的正是這一類，這是殘留的同款相依。
改成只扣 `$ownCodes`，`$fetchCodes` 補 `Select-Object -Unique`（兩個清單現在會合法重疊，
不去重等於同一檔抓兩次）。

**做了什麼**

1. **`overnight.ps1` → `overnight-context.json`**（gitignore，不在 `$PublishAllowlist` 上）。
   在 `run-daily.sh` 的 fetch 階段**最後**執行（`|| true`）——nq/tsm/twd 是即時報價，越晚越準。
   抓 `^SOX`／`NQ=F`／`TSM`／`TWD=X`，算出費半當日與**本週累計**%、那斯達克期貨對前一收盤的%、
   台積電 ADR 換算台幣後對 2330 收盤的溢價。
   - **全專案唯一的第三方來源**（Yahoo chart API）。抓取層放進 `lib/feed.ps1` 檔尾
     （`Get-FeedUsChart`＋`$FeedUsSymbols`），為的是共用 `Set-FeedTransport` 這個 seam——
     解析路徑因此測得到，這正是該檔存在的理由；另開一支等於重建它當初消滅的「兩份 GetJson」
   - **變動%一律從日 K 陣列自己算**：`previousClose` 在指數上是空的，`chartPreviousClose`
     是整個 range 之前的收盤。把後者當「昨收」會算出看起來合理的錯數字
   - **fail-open**：任一 symbol 失敗就略過該區塊；全部失敗**刪掉舊檔**再退出 0。
     過期的期貨報價比沒有更危險——AI 分不出來。實測用死掉的 proxy 跑過，行為正確
   - 週累計的基準線是「**本週一之前的最後一個收盤**」，不是五根 K 之前。7/30 手打的
     −10.1% 實際應為 **−11.60%**；`tests.ps1` [14] 用那一週的真實收盤把這條釘住
2. **SKILL.md 搜尋協定拆成兩層**：回顧層（今天為什麼這樣，2-3 次）＋**前瞻層（今晚與明天，
   必做 1-2 次）**。前瞻層先讀 `overnight-context.json`（先驗 `asOf` 是今天）再決定搜什麼，
   附「今晚催化劑檢查表」（美股大型科技股財報／20:30 總經數據／FOMC／台指期結算日／台積電法說）。
   **背離門檻**把「有時候沒搜到」變成有數字的規則：期貨或費半與台股當日方向相反且任一
   ≥1%，或 ADR 溢價絕對值 ≥3% → 必須加搜並在 `wind`／`night` 明說。7/30 會直接命中
3. **`_market.night`**（owner 專屬）：頁面市場風向區下方新增一塊隔夜前瞻，`buildWind()` 渲染，
   沒值就整塊隱藏、**刻意不留 HTML fallback**（過期的前瞻比沒有更糟）。
   `page-contract.json` 的 `noteFields.ownerOnly` 加 `night` 即全部生效——`build-demo.ps1`、
   `server/payload.py`、`lib/publish-gate.ps1` 都讀同一份契約，零程式碼改動。
   `mood`（收盤情緒）與 `night`（前瞻）**明文允許不同向**；7/30 的正解是 `mood: 恐慌趨緩`
   ＋ `night` 指出財報利多尚未反映
4. **昨日市場判斷納入問責**：`run-daily.sh` 產 `prev-recs.json` 時一併帶出昨日 `_market`
   （`windLead`/`mood`/`moodK`/`night`）。SKILL.md 要求昨日 `night` 的條件發生或明確沒發生時，
   今天 `wind` 第一句必須交代；昨日 `moodK` 與今日走勢明顯相反要直說看錯什麼。
   和 `picks-log` 對選股、`prev-recs` 對 `rec` 是同一個機制
5. **順手修掉一個測試漏洞**：`tests.ps1` 檢查「index.html at rest 不含 owner-only 欄位」
   用的是手抄的 `@('"rec"','"wind"','"news"')`，加了 `night` 也不會被檢查。改成從
   `page-contract.json` 的 `noteFields.ownerOnly` 推導——這正是那份契約存在的目的

**驗證**：`tests.ps1` 新增 [14] 一整節（US chart 解析、null 收盤、空 result、未知 shape、
429／離線、週線基準線、fail-open 的接線）；`boot-check.js` 新增 night 五項（有值渲染、
無值隱藏、只有空白也隱藏、HTML 逸出、標籤）；server 端 93 項通過。

### 2026-08-02 手機一律深色（四頁）

使用者要求「手機版改成只有深色模式」。四頁（`index.html` ＋ `server/static/` 三頁）在觸控裝置上
不再跟隨系統偏好，固定用深色那組值。

**判定條件用裝置能力不是視窗寬度**：`@media(hover:none) and (pointer:coarse)`。
用 `max-width:768px` 的話手機橫放（iPhone 橫式 ~844px）會閃回淺色，而桌機把視窗拉窄反而
被迫變深色——兩邊都錯。現行條件下桌機縮視窗仍照系統偏好走，平板則跟手機一樣固定深色。

**兩頁家族的寫法不同，是因為結構不同**：
- `index.html` 用「值對＋映射」，所以新增第三份**映射**（仍然沒有色值，改色仍是改一處）。
  選擇器刻意寫成 `:root,:root[data-theme]` 而不是單一 `:root`：後者的 (0,1,0) 贏不過上面
  `[data-theme=…]` 的 (0,2,0)，手動指定的 light 會在手機上贏回淺色。頁面現在沒有主題切換鈕，
  這是為了將來加了也不破功。`color-scheme:dark` 一起寫在裡面，否則系統是淺色的手機上
  input 與捲軸還是亮的。
- `server/static/` 三頁是直接色值（沒有 `data-theme`），所以把條件**加進既有 dark media query
  的清單**（`@media(prefers-color-scheme:dark),(hover:none) and (pointer:coarse)`，逗號＝OR）——
  兩種情境共用同一份色值，不會多出第三份色碼要同步。`admin.html` 頁面內那組狀態徽章色
  （`--chip-ok`/`--chip-wait`/`--chip-stop`/`--chip-plus`）也要跟著改，否則深色頁配淺色版
  前景色（`#0a6b49` 這種特意壓深的）就沒對比了。

**順手**：四頁補 `<meta name="theme-color" content="#0e121b" media="(hover:none) and (pointer:coarse)">`，
讓 iOS Safari 的工具列跟頁面同色；`media` 屬性讓桌機維持原本行為。

**驗證**：`tests.ps1` 全綠（[12] 三頁 token 區塊仍 byte-identical、與 index 色值一致）、
`server` 93 項 unittest 全綠、boot-check 33 項全綠。另外把手機區塊的媒體查詢外殼拆掉跑一次
boot-check，確認「手機那條映射」本身解得出真顏色（jsdom 不套用 media query，不然驗不到）：
`--bg=#0e121b --surface=#161c28 --ink=#e7eaf1 --accent=#d9ad57 --up=#ff5d51 --down=#34c48d`，
且 `data-theme` 為 none／light／dark 三種狀態都是深色。

**待驗**：真機（jsdom 不做 media query 也不做 CSP）。

### 2026-07-31 Funnel 靜默失效（手機連不上）＋ 發佈閘門補主機名掃描

使用者回報「手機看不到了，電腦可以」。**「電腦可以」是誤導性的對照組**——電腦走 tailnet
內網（`100.x`），手機不在 tailnet 裡走的是公網 Funnel，兩條完全不同的路徑。

**根因**：當天 08:15 tailscaled 記錄到 `LinkChange: major`（預設路由改走 WiFi）之後，
`Hostinfo.IngressEnabled` 沒有重新推給控制平面。Tailscale 的 ingress 收到連線、讀完 SNI
找不到對應節點就直接關閉 → 外部看到的是 **TLS 握手失敗**，伺服器日誌**當天零筆**公網請求。

三個讓人查錯方向的點：`tailscale funnel status` 顯示一切正常；憑證有效到 10/22；
直接 `curl` 主機名也是通的（本機 DNS 會解析成 tailnet IP，驗不到公網那條路）。

**修法**：`tailscale down && tailscale up`。只重推 serve 設定（`funnel off` 再 `on`）
**無效**——實測過，listener 會重建但 ingress 仍不認得，必須整個節點重新註冊。
驗證要用 `curl --resolve <host>:443:<ingress IP>` 強制走公網：壞的時候 `000`，好的時候 `302`。
排查步驟已寫進 `SETUP.md`。

**順手發現兩件事**：

① `:8443` 那條 Funnel 指向 `127.0.0.1:3000`，而該埠有一個 Next.js dev server 綁在
`*:3000` 跑著——等於一個開發伺服器正對全世界開放。已 `tailscale funnel --https=8443 off`。

② **`plan.md` 從 07-24 起就寫著 owner 的真實 Funnel 主機名**，而 plan.md 是被追蹤、
已公開的。站台有登入保護所以不是憑證外洩，但等於把私人入口網址交給掃描機器人
（存取日誌看得到 `/.env`、`/.git/config` 這類探測）。兩處已改成佔位符。

**閘門補強**：`Test-FileForOwnerContent` 原本只開 `.json`（比對 key 名）和 `.html`
（逐 block 比對），**`.md` 從來沒被掃過**，所以這個洩漏永遠不會被攔到。現在加上
`$TailnetHostPattern`，對**所有文字副檔名**做原文掃描。規則刻意要求 `.ts.net` 前面有
**兩個真實 label** 才算命中，所以 SETUP.md 記錄的 `<機器>.<tailnet>.ts.net` 佔位符與
散文裡提到的 `.ts.net` 都不會誤判——誤判在這裡的代價是擋掉未來每一次發佈。

`tests.ps1` [8] 加三項：repo 內不得出現具體 tailnet 主機名、掃描抓得到 `.md` 裡的主機名、
掃描不會對佔位符誤判。測試裡的假主機名**用字串拼接組出來**，否則它自己就會被第一項抓到。

**當天下午復發，補上自動恢復守衛**：使用者人在外面時又回報一次（這次錯誤訊息是憑證相關的
「connection is not secure」，但伺服器端證據與早上完全相同）。查下去發現這不是單一事件——
**`LinkChange: major` 當天已經 8 次，過去一週每天 5–8 次**，日誌顯示是 WiFi 真的斷開重連
（`Gained carrier`、重新跟 AP 關聯、重拿 DHCP），不是省電模式（power save 本來就是 off），
而且這台機器**沒有有線網路介面**，插網路線不是選項。

⚠️ **早上「`down/up` 就是修法」那句話對，但成因說得太單純**。實際上有兩種故障疊在一起：
**短暫閃斷**（WiFi 重連當下，幾十秒內自己好）與**持續失聯**（ingress 註冊掉了，不會自己好）。
分辨方式是連續探測——復發當下連測 15 次全過，代表那次只是閃斷。

於是加 `tools/funnel-watchdog.sh` ＋ systemd user timer（每 5 分鐘）。三個刻意的設計，
每一個都對應一個當天踩過的坑：**① 從公網 ingress 探測而不是探主機名**（本機解析主機名會拿到
自己的 tailnet IP，那條路在整個故障期間都是通的，探它永遠回報健康）；**② 連續兩次失敗才動作**
（否則每天為了會自己好的閃斷重啟通道好幾次）；**③ 冷卻期內即使不健康也不修**（若是 Tailscale
自己的 ingress 出事，每 5 分鐘 `down/up` 只會把對方的故障變成自己的）。

② 與 ③ 都寫了測試才安裝：用不可路由的 TEST-NET-1 模擬探測失敗，確認冷卻期內拒絕修復、
單次失敗重試成功後不修復，兩次驗證全程都沒有真的動到通道。

### 2026-07-30 封面圖：60 日視窗＋圖下標註（單線）；權益曲線補圖例

起因是使用者問「持股卡的圖和大盤的圖代表什麼」，追下去發現兩張封面圖都是 `priceChart()`
畫的**全期間 82 個交易日收盤價**，沒有刻度、沒有基準、沒有期間標示，大盤圖在桌機還被
`.market{grid-template-columns:1.1fr 1fr}` 擠成半個卡片寬、只有 96px 高。

**⚠️ 這一則記錄的是最終狀態，中間繞了一圈**：第一版在兩張封面圖上加了**均線**與**期間起點
基準線**，使用者看過實際畫面後判定那些線是雜訊，全部移除。留下的教訓寫進 CLAUDE.md
「改圖表前要知道的三件事」第一條——**要加線之前先想清楚：均線、K 線、十字準星都已經在
modal 裡了**，58px 的小圖裝不下第二層資訊。

**① 封面只畫尾段 60 日**（`COVER_DAYS`），完整序列留給 modal 的 K 線圖。新增純函式
`computeCoverWindow(series,n)`（掛進 `window.ANALYTICS`）回傳 `vals`／`from`／`n`／`pct`。
**圖與圖下方的標註必須同一個來源**——否則標註會描述一個沒被畫出來的區間。
boot-check 新增 5 項 `cover-window:` 斷言守這條（總數 33）。

**② 兩張封面圖都只有一條價格線**：持股小圖用每檔自己的配色（與權重條、圖例、卡片左側色條
同一個識別，不是漲跌色），大盤圖用 `--ink-soft`。大盤主線原本寫死 `--down` 綠——它不隨大盤
漲跌變色，在紅漲綠跌的頁面上本身就是誤讀來源，所以換成中性色（modal 折線模式同一個）。

**③ 版面與標註**：`.market` 改單欄、圖整列 96→126px；`.spark` 44→58px（560 斷點 104→118／
52→64）。圖下方重用既有的 `.chart-meta` 標出「起始日 · 近 60 日 · 期間漲跌%」。
**沒有新增任何顏色值**，所以 `tests.ps1` [12] 的九個共用色與 `server/static/` 三頁的
`SHARED-TOKENS` 都不必動。

**④ 權益曲線補圖例**（使用者接著指出的第二個問題：投組總覽那張圖畫了兩條線卻沒說哪條是哪條）。
`chartOverlays` 新增 `o.dash`（預設實線），加權指數那條改成灰色**虛線**、投組維持金色實線，
canvas 下方加 `.chart-meta` 圖例。**用顏色＋線型雙重區分**：只靠顏色分，在色弱與黑白列印下
會失效。圖例的線段色塊用 CSS `border-top` 畫（`.sw-line`／`.sw-line.dash`），
**不用 `━`／`┄` 這類 box-drawing 字元**——中文字型下的粗細與基線對齊都不可靠。

**⑤ 順手修掉兩處期間不一致**（同一個「看不清楚」的根因）：`h.dd` 其實是**近 40 日**高點的
回撤（`cl.slice(-40)`），但卡片與 modal 都只寫「距高」→ 改成「距40日高」；modal 的
「波段高 X（−Y%）」把**全 82 日**高點與**40 日**的 `h.dd` 並排，兩個數字互相矛盾 →
高點改用近 40 日，與 `h.dd` 同期間。

**未做**：不改 `update-holdings.ps1` 的抓取月數（`computeIndexStats` 的「距波段高」與
`computeEquity` 都吃全長 TAIEX，動它會改變既有顯示數字的語意）；不在 canvas 內畫價格
文字（與「太擠」的主訴相反）；封面不加 hover（手機無效，細節留給 modal）。
選股／評分／出場／判級規則一律未動，故 `logicCard` 不需更新。

**驗證**：boot-check 三變體各 33 PASS／0 FAIL／無頁面錯誤、`tests.ps1` 全綠、server 93 tests OK。
Chrome 連不到本機 http server（不同網路環境），改用 **jsdom＋node-canvas 把三張圖輸出成 PNG
實際看**（jsdom 的 canvas 預設 0×0，要先蓋掉 `clientWidth/clientHeight` 才畫得出東西），
淺／深兩主題都驗過。**這一步不是形式**：第一版的「基準線被漸層填色染色」與「持股配色
`#1971c2` 跟 `--ma20` 撞色」都是這樣抓到的，光讀程式不會發現——canvas 是靜默失敗。

### 2026-07-30 UI 優化：手機版面 ＋ design token 收斂（保守精修，不動視覺語言）

兩個動機：**手機從沒被真正設計過**（整份 CSS 只有 560／640 兩層斷點，560 以下什麼都沒有——
360px 手機拿到的是 559px 的版面），以及**token 已經漂掉**（配色被寫了四次、20 種字級、
11 種圓角、0 個間距 token、三個伺服器頁各抄一份）。範圍限定這兩軸，保留金色 accent＋
中性灰底、卡片骨架與區塊順序；**沒有做**無障礙工程（語意標題／landmark／canvas 替代文字／
提高 `--ink-faint` 對比）與資訊架構改動（區塊導覽、windBox 折疊、深淺切換按鈕）。

**① 配色改成單一來源（值對＋映射）** — `:root` 裡每個顏色只寫一次成 `--l-*`／`--d-*` 一對，
三個主題情境（`:root`／dark media／`[data-theme=dark]`）只做「重新指向」、不含色值。
改一個顏色從**三處變一處**。`[data-theme=light]` 那條 700 字元的整行刪掉了：
dark media query 改成 `:root:not([data-theme="light"])` 之後它就是多餘的。
另補 `color-scheme:light dark`（四頁原本都沒有，深色模式的 input 與捲軸還是亮的）。

**⚠️ 這裡有一個會靜默失敗的陷阱，值得記住**：`cssv()` 讀出來的字串是直接餵進
`ctx.fillStyle` 的，而**無效顏色不會 throw、canvas 只會沿用上一個顏色**。瀏覽器會在
computed-value 時把 `var()` 代入（CSS Variables L1），但**jsdom 不會**——實測
`getPropertyValue('--bg')` 回傳字面的 `var(--d-bg)`。也就是說間接層在生產環境沒事，
但 boot-check 會靜默上錯色。所以 `cssv()` 自己解掉間接層（4 層上限），
兩個環境結果一致、也不必依賴 spec 行為。**同理不可以用 `light-dark()`**：它在 custom
property 裡不會被解析成單一顏色，canvas 一樣靜默拒絕。
boot-check 新增第 28 項斷言守這件事（10 個被 JS 讀的 token 都要解析成真顏色），
並先在「還是純 hex」的狀態下驗證這條斷言**抓得到**問題，才動配色。

**② 尺度 token** — 18 種字級收成 10 級、10 種圓角收成 7 級 ＋ `--r-full`（膠囊）、
動效收成 `--tr`、間距按「卡片家族」收成 8 個 token（刻意不硬湊成線性尺度，
目的是讓斷點能一次縮全頁密度）。字級位移只有兩個規則超過 0.5px：
`.m-close` 17→16、`.hero .v2` 19→20。
**驗法**：寫了一支把兩版 CSS 的 `var()` 全部展開後逐條比對的腳本，確認
108 處差異全部落在「已知且刻意」的類別裡、`UNEXPECTED` 為 0。這比看截圖可靠。

**③ 修掉三個真的 bug（都是這次要收斂的模式造成的）**
- **modal 價格被關閉鈕蓋住**：`.m-close` 是不透明的（`--surface-2`、`z-index:2`）、
  絕對定位 `right:18px` 寬 32px，而 `.m-price` 靠右貼齊 `.m-body` 的 22px 內距——
  價格最右邊約 28px **在所有寬度下**都被蓋掉，不只窄螢幕。補 `.m-head{padding-right:40px}`
- **損益永遠是灰的**：`index.html` 的 `#pfPLpct` 帶 inline `style="color:var(--ink-faint)"`，
  `updatePL()` 卻是設 `className`——inline style 永遠贏。個股卡片同樣毛病：
  沒成本時設 `el.style.color`，之後**從不清掉**，所以使用者輸入成本價後
  `up-txt`/`down-txt` 被殘留的 inline 灰壓掉。兩處都改用 `.faint` class
- **`.mlabel` 完全沒有 CSS 規則**（`openPickModal` 三處在用），併進 `.subhd` 的選擇器

**④ 手機／RWD** — 新增 768 與 400 兩層（沒有加平板層：`.wrap` 上限 960px，
640～960 本來就等同桌機，硬加一層只是裝飾）。密度靠改 `:root` 的 token 而非逐條覆寫。
- hero 三格擠兩欄的孤兒格 → 第三格 `grid-column:1/-1`；≤400px 單欄
- `.hero .tot` 改 `clamp(21px,5.6vw,var(--fs-3xl))`：26px 的「12,345,678」在 360px 手機上
  約 140px，剛好撐破格子。**≥465px 與改動前完全相同**
- `.bigchart` `touch-action:none` → `pan-y`：原本手機在那張 180px 圖上完全無法往下捲。
  **連帶必須補 `pointercancel`**——瀏覽器收回手勢時發的是它不是 `pointerleave`，
  少了十字準線會卡住
- 六個橫向溢出的表格收成一個 `.tblwrap`（純 CSS scroll-shadow，`background-attachment:local`
  讓提示只在那一側真的還有內容時出現；iOS 不理 `::-webkit-scrollbar`）
- `.ov` 補 `overscroll-behavior:contain`（iOS scroll chaining）
- `.legend .nm` 補 ellipsis（`.editor td.nm` 早就有，legend 漏了）
- `.picks`/`.cats` 的 `minmax` 改 `min(280px,100%)`：auto-fill 軌道不再可能超出容器

**⑤ 三個伺服器頁** — `login`/`admin`/`pending` 改帶一段**完全相同**的
`SHARED-TOKENS-START…END` 區塊，`--err`/`--ok`/`--warn` 換成 `--up`/`--down`/`--hold`
（實測值本來就一樣，零視覺變化），`#fff` 換 `--on-accent`。
**這三頁刻意不用 index 的「值對」寫法**：那個結構是為三個主題情境存在的，
這三頁只有兩個情境，用值對反而多寫一層。
`admin.html` 的狀態徽章底色接上 token，但**前景色留在頁面內**——淺色模式那幾個是
特意壓深的版本（`#0a6b49` vs `#12885e`），併過去會真的變色；改成頁面內 token 之後
原本第二個 dark media query 就不需要了。另外 admin 的表格**本來完全沒有捲動容器**，
手機上會把整頁推歪，也補上 `.tblwrap`。

**⑥ 防漂移的測試** — CSP（`style-src 'unsafe-inline'`、沒有 `'self'`）連同源外部 CSS 都擋，
四頁只能各帶一份 token，所以**重複是沒得選的**——那就讓漂移看得見。
`tests.ps1` 新增 [12]：三頁的 token 區塊必須位元組相同、且每個共用色值仍與 `index.html` 一致。
兩條都做過反向驗證（故意改壞一個值／讓一頁分歧，確認會紅）。

**沒做但記在這**：`publish.ps1 -DryRun` 這次沒跑——它會重寫 index.html 的資料塊並換成
demo 持股，對驗證 CSS/JS 改動沒有幫助，只會把工作區弄亂。**發佈前要跑**。

### 2026-07-29 架構整理第二輪（`/improve-codebase-architecture` 八個候選全做）

起點是第二次架構檢視。這輪的主題不是「同一件事寫很多份」（那是 7/25 那輪），而是
**7/25 建好的模組沒有被真正接上**——接縫做出來了，呼叫端還是繞過去走。

**① 行情解析真的收進 `lib/feed.ps1`（候選 1）** — `$FeedCols` 當時只被自己的
`Get-FeedMonthBars` 讀，**生產端零呼叫者**：T86/TPEx 法人、MI_MARGN/TPEx 融資、FMTQIK、
BFI82U、MI_INDEX 共九個端點仍在三支腳本裡各自手寫 `$row[10]`、`$row[18]`。
模組註解寫的「欄位一改，改這裡就好」當時是**假的**。現在九個端點都是具名函式
（`Get-FeedIndexHistory` / `Get-FeedInstitutional` / `Get-FeedMargin` /
`Get-FeedMarketInstAmount` / `Get-FeedMarketQuotes`），民國年轉換從五份收成一份
（其中兩份原本靠 API 自己補零才對），politeness 從 11 個 `Start-Sleep`（兩種常數）
收進模組。**因為 `Set-FeedTransport` 已經存在，這些解析路徑一次全變成可離線測試**——
新增 20 項 fixture 斷言，另以真實網路對 7/28 驗過七個端點（2330 的
`tot-f-t-de = 0`，確認 T86 欄位對齊）。

**② 選股規則收成 `lib/score.ps1`（候選 3）** — 同一套漏斗原本有三份：`screen.ps1` 個股迴圈、
`screen.ps1` ETF 迴圈（同樣 68 行、變數加後綴）、`backtest.ps1` 的重放（註解寫
"same order and thresholds as production"）。**驗證策略的回測驗的是生產規則的手抄本**。
現在股票／ETF 是同一組函式的兩個 profile，`backtest.ps1` 直接呼叫生產函式。
**這是純重構**：用 135,000 組隨機輸入把「舊的 inline 版」與新模組逐一比對，
含 15,995 次 drop 路徑，**零差異**。
- 已知且刻意保留的差異：回測傳 `-Light 'na'`，所以綠燈日的 +3 動能獎勵在回測裡仍不生效
  （原本手抄版就沒有這段）。現在打開只要改一個字，但那會改動回測數字，**留給月度參數檢視決定**。
- `backtest.ps1` 的**出場模擬**沒有併過去：它是容忍缺漏的滾動重放（`n20>=15`／`n10>=8`），
  與 `Test-ExitRules` 需要連續序列的形狀不同，硬合併會改變行為。

**③ 兩個歷史檔各有自己的模組（候選 2）** — `picks-log.json` 原本有**兩個寫入者**，而
`publish.ps1` 那個用裸 `Get-Content` 讀、沒有 retry／沒有 `[ordered]`／沒有 `-ErrorAction Stop`
就寫回去；那個檔寫壞會讓隔天早上的選股直接 FATAL。現在兩邊都走 `lib/picks-log.ps1`。
`stance-log.json` 則是**當場抓到規則已經被違反**：`update-holdings.ps1:310` append 的是
plain `@{}`，磁碟上的檔案當時有**六種 key 順序**（只因為它是 gitignore 才沒有天天洗 diff——
而那也代表 git 沒有幫它留備份）。已收進 `lib/stance-log.ps1` 並把 70 筆就地正規化成一種順序
（值逐欄比對完全相同）。`Get-PrevStanceMap` 順手變成可測的純函式。

**④ `page-contract.json` 在 Python 端變成真的（候選 5）** — `server/pagedata.py` 宣告了
`guest_note_fields()` / `owner_only_fields()` 但**全 repo 零呼叫者**，`payload.py` 另外硬寫同一份
清單；契約檔裡「server/payload.py applies both」是**假敘述**。`MARKET_PUBLIC_FIELDS` 更是
`build-demo.ps1` 與 `payload.py` 各一份、契約裡根本沒有。後果：往 `noteFields.guest` 加一個
欄位會改變 demo 產出與發佈閘門，**對線上伺服器卻毫無作用**。現在契約是雙語唯一來源
（新增 `noteFields.marketPublic`），並補上三道以前沒有的失敗：
- `splice()` 找不到 marker 改成 **throw**（PowerShell 端一直是 fail-closed，Python 移植時退化成
  fail-open——正是 `6fc268a` 那個 tokenusage 空白的失敗模式）
- `BLOCK_SOURCES` 與契約在 **import 時**互相校驗，漏接一個 block 直接起不來
- `render_page` 對「宣告要渲染卻沒拿到的 key」改成 raise，不再靜默跳過

**⑤ 隱私接縫：`notes_for` 不可能忘記（候選 4）** — 簽名是
`notes_for(tier, codes, all_notes, private_codes=(), ...)`，而 `private_codes=()` 的語意是
**「沒有東西是私密的」**：`code not in ()` 恆真、`_mentions_other_holding` 掃空集合恆偽，
兩道檢查同時放行。生產端當時是對的，但**整份測試沒有任何一項在守它**——1,057 行裡
`holdingsNotes` 出現 0 次。根因是 `payload.bootstrap()` 用 `config.ROOT` 直接解析
`holdings-notes.json`，測試沒辦法餵 fixture。
做法：先加 `notesDir` 設定把路徑變成可注入的接縫，**先補上那個缺了的測試**，再把
`private_codes` 改成必填、並提供 `notes_for_reader(conn, reader, ...)` 自己去查 owner 持股。
新測試經反向驗證：把接線改回 `()`，它會紅。

**⑥ 頁面：`window.ANALYTICS` 從 1 個成員變成 8 個，`boot()` 真的成為進入點（候選 6）** —
`computeEquity` 證明了這個分法可行，但 heroStance 六級收三群、過期平日數、集中度 40/80、
今日訊號 44 行、移動停利全都還熔在 DOM builder 裡。更根本的問題是**`boot()` 根本不是進入點**：
七個 top-level IIFE 在 parse 時就把持股卡、權重條、整個選股區塊畫完了，`renderAll()` 只重畫
canvas——所以這個頁面**沒辦法用第二份資料再渲染一次**，測試自然餵不進去。
現在計算是純函式、渲染只負責畫，七個 IIFE 變成 `boot()` 依序呼叫的函式（每段獨立 try/catch，
一段爆掉不會靜默吃掉後面全部）。驗證：新舊兩版在 jsdom 跑完後**28 個渲染區塊逐字元相同**。

**⑦ 圖表自己擁有投影（候選 8）** — `priceChart`／`candleChart` 原本只共用 `setup()`；
scale、grid、crosshair 是逐字元重複，overlay 只差變數名。兩者都回傳 `{padL,padR}`，
然後由 `attachChartHover` **自己反推 X(i)**，還帶一個 `curMode` 分支和一行把正向投影再抄一次的
註解。現在圖表回傳 `indexAt()`，hover 不必知道自己在跟哪張圖說話；boot-check 新增
往返斷言（對每個 i 驗 `indexAt(X(i)) === i`，兩張圖都過）。`openModal`／`openPickModal`
之間 ~25 行相同的圖表接線收成 `maChipsHtml()`＋`wireModalChart()`——兩個 modal 的產出
markup 逐字元相同（4511／1825 字元）。

**⑧ 逸出只有一種寫法（候選 7）** — 十二個 `${...name}` 插值裡**有一個沒逸出**：
`buildCostPanel`（`index.html:649`）。在伺服器模式那是別的使用者自己打的字串，而
`server/validate.py` 只剝控制字元、上限 30 字（`<img src=x onerror=alert(1)>` 是 28 字），
逸出責任明確委託給頁面。已修，並加入預設就逸出的 `` html`` `` tagged template
（要插入自製 markup 才用 `raw()`），`tests.ps1` 加了「每個 `${...name}` 不是 `esc()` 就是在
`` html`` `` 裡」的來源斷言。
**沒做的部分（受既有硬性設計限制，刻意不動）**：三個 HTML 檔的 design token 與 `call()`
各一份。四個頁面的 CSP 都是 `script-src 'unsafe-inline'` 且沒有 `'self'`，外部 JS/CSS 一律被擋；
`index.html` 更必須維持單檔自足。要共用就得放寬 CSP，那是拿一條真實的安全邊界換
重複度，不划算——留作已知重複並記在這裡。

**其他一併修掉的**：
- `api.change_password` **完全沒有節流**：帶著 session 可以無限次猜當前密碼，不留紀錄
  （`set_password` 的 audit 只在成功時寫）。改走 `auth.verify_current_password`，與登入同一套預算
- `api.py:52` 的裸 `DELETE FROM users` 改走 `auth.rollback_registration`（只肯刪 pending 的 guest）
- `FakeCtx` 原本是 `server.Ctx` 授權邏輯的**手抄複本**，所以每個「guest 不能進 admin」的測試
  驗的都是那份複本。改成真的子類別後，把 `require_owner` 反向改寫會有 2 個測試轉紅（原本 0 個）
- `tests.ps1` [2] 的 BOM 檢查從手寫檔名清單改成**算出來的不變式**，第一次跑就抓到
  `evaluate.ps1`（18 個非 ASCII 位元組、無 BOM，而它自己的檔頭寫著 "ASCII source only"）
- `kline-cache/` 有兩個房客（`h-` 前綴與否）卻只有 `screen.ps1` 會清，而它的 regex 兩種都刪，
  且 `screen.ps1` 若提早 FATAL 就完全不清。改由 `lib/feed.ps1` 擁有建立與清理
- `index.html:867` 的 `catch(e){}` 會把 load 那一輪 buildEquity 的例外完全消音，改成記進
  `__bootFailed`
- `tools/boot-check.js` 的 block id→global 對照表原本是契約 11 個裡的手抄 3 個，
  `node boot-check.js index.html pkdata '{}'` 會寫出 `window.pkdata=...` 這種**靜默 no-op 然後 PASS**。
  改讀 `page-contract.json`，不認識的 block 直接報錯

**測試**：`tests.ps1` 從 91 項增至 **239 項**（新增 feed 解析、score 規則、picks-log／stance-log
行為、cache、逸出、BOM 不變式）；`server/test_server.py` 從 83 增至 **93**；
`tools/boot-check.js` 從 19 增至 **27** 項斷言，且新增的變體（無 stance／空投組／pkdata）
四種都 BOOT OK。三個等價性證明：scoring 135k 組零差異、DOM 28 區塊逐字元相同、
兩個 modal markup 逐字元相同。

### 2026-07-29 iOS 主畫面圖示（apple-touch-icon）

使用者把儀表板加到 iPhone 主畫面，想換掉那個「網頁截圖」預設圖示。

三個限制決定了做法：

1. **不能用 data: URI。** 本來最合站台調性（CSP 只開 `img-src data:`、零外部資源），但查下來 iOS 對
   apple-touch-icon 的 data URI 支援不可靠，做了可能靜默沒效果。改成真的放一個 `apple-touch-icon.png`，
   CSP 跟著放寬成 `img-src 'self' data:`（只多開同源，沒開外部主機）
2. **`<link>` 標籤是必要的，不能靠 iOS 自己找。** iOS 沒看到 link 時只會去抓「網域根目錄」的
   `/apple-touch-icon.png`——在 GitHub Pages 上那是 `davidloman5.github.io/`，不是我們的 `/stock-dashboard/`
3. **伺服器模式本來完全沒有靜態檔路由**（`serve_static` 還只讀 UTF-8 文字，放不了二進位）。加了
   `ICON_PATH` 一條路由，從 `index.html` 隔壁讀檔案送 `image/png`——兩種模式因此共用同一份圖檔

圖是 `tools/make-icon.py` 產的：純標準庫（zlib+struct 手寫 PNG，這台機器沒有 PIL／ImageMagick），
4× 超取樣再降採樣當抗鋸齒，深藍底＋三根上升金色 K 線（配 `--accent` #d9ad57）。1.2KB。
改圖案就改那支腳本重跑，不必手動開圖形軟體。

`apple-touch-icon.png` 已加進 `$PublishAllowlist`（發佈閘門的內容掃描只看 `.json`／`.html`，PNG 自然略過）。
測試：tests.ps1、server 83 個測試（新增兩個：圖示要能未登入取得且是 bytes、檔案不存在時 404 不是 500）、
jsdom boot-check 全過。

**注意**：iOS 會快取 webclip 圖示，換圖後必須把主畫面舊捷徑刪掉重加，原地重整不會變。

### 2026-07-29 推薦追蹤止血：JSON key 排序、保留期＋封存、法人天數對齊、殭屍部位

使用者問「推薦追蹤會變無限長怎麼解決」。量完之後發現**體積不是主要問題，churn 才是**。

`picks-log.json` 的每筆記錄在 `screen.ps1` 是用 `@{}` 建的。pwsh 7 的 .NET 字串雜湊每個 process 都重新隨機化，所以同一份資料連跑三次，key 順序三種：

```
retFinal,name,status,alphaFinal,score,closedOn,days,reason,code,exit,date,price
code,score,name,retFinal,date,closedOn,days,status,price,exit,reason,alphaFinal
exit,price,score,retFinal,status,closedOn,name,date,reason,alphaFinal,days,code
```

於是 `git show c452aec -- picks-log.json` 是 **250 insertions / 158 deletions**，那天實際只新增 4 筆。等於每天把整個歷史重寫一次推上去，diff 也完全沒法看。同樣問題在 `screen-summary.json`、`eval-report.json`、以及 index.html 內的 `regime`／`meta`／`perf` 三個子物件。

做了四件事：

1. **輸出一律 `[ordered]@{}`**（`screen.ps1` 的 `$o`／`$perfSummary`／`$byLight`／`$regimeObj`／`$metaObj`／`$out`／`$summaryOut`／`$kd`，`evaluate.ps1` 的 `Grp()`）。實測：同輸入、兩個獨立 process，輸出 byte-identical；新增一筆的 diff 從 408 行降到 **12 行**。
   踩到的坑：`[ordered]@{}` 是 `OrderedDictionary`，**只有 `.Contains()` 沒有 `.ContainsKey()`**，`$o.ContainsKey('alphaFinal')` 那幾處會直接 InvalidOperation。
   另一個坑：`publish.ps1` 的 ai-tags 是用 `Add-Member` 接在**尾端**，而 normalize 原本把 `aiSust`/`aiRisk` 排在 `ind` 後面 → 每個被標記的部位隔天都會被搬回去，churn 又回來。所以 normalize 的正規順序也把這兩個欄位移到最後，與 publish 對齊。已用「normalize → publish 掛標籤 → 隔天 normalize」三段模擬驗過 byte-identical（要先把現有標籤剝掉才測得到，否則 tagged=0 是假通過）。

2. **保留期＋封存**：`FoldPicksToArchive`（抽成具名函式，好讓 `tests.ps1 [3]` 用 AST 抓出來測）。log 只留全部 open ＋ 最近 120 筆已結案，更舊的 append 進 `data/picks-archive.jsonl`（`data/` 已 gitignored，只 append 不重寫，不必動 allowlist）。`evaluate.ps1` 讀 log ＋ archive 並以 `date|code` 去重，所以**終身歸因統計完全不受保留期影響**。
   安全性論證在順序：先 append、再把整個 archive 讀回來核對，**每一筆都確認在裡面了才**從 log 移除。中途死掉 → 下次重跑同樣那幾筆，`date|code` 讓 append 冪等，不重複也不遺失。任何一步失敗就原封不動回傳（`-ErrorAction Stop` 是必要的：腳本跑在 `$ErrorActionPreference='Continue'` 下，沒有它寫入失敗只會印訊息然後**繼續往下刪**）。

3. **法人天數改按日期定位**（`screen.ps1` [3/8]）。T86／TPEx 只列出當天有法人進出的股票，原本用 `+=` 累積 → 冷門股的序列會**變短**，於是 `f[-1]`／`f[-2]`（「外資連 2 日轉賣」）比的可能不是最近兩天，`tPos>=3` 也可能是 3/3 而不是 3/5。改成先收成 `code→date→值`，再按**該股自己市場**的成功日清單展開、缺席補 0（`.n` 另存實際出現天數，接手原本 `$t.Count -lt 4` 的資料充足度守門）。按市場分開很重要：否則 TPEx 某天抓失敗會把全部上櫃股在那天補 0，悄悄壓到閘門以下。
   **這會改變選股與出場輸出**——是資料對齊的 bug fix，不是參數調整，但 8/18 檢視時要記得這條在期間內生效。

4. **殭屍部位**：`screen.ps1` 原本遇到查不到報價的代號直接 `continue`，該筆就**永遠停在 open**——頁面看不到、永遠不結案、還一直佔著去重鍵擋住重新進場（下市、長期停牌、或某天 TPEx 抓取失敗都會踩到）。改為超過 25 個交易日仍無報價則標記 `status='void'`／`reason='資料中斷'`：沒有價格就沒有誠實的報酬，所以不進勝率統計，但也不再佔名額。

頁面端 `perfBox` 把「持有中」與「已結案」拆成兩張表（持有中預設展開、已結案收合且新到舊），以前 17 列混在一起、只靠最後一欄文字區分。

測試：`tests.ps1` 新增 [10] 共 16 項——折疊的集合恆等（log＋archive == 輸入）、open 永不被封存、冪等、crash-then-retry 不產生重複、archive 寫不進去時一筆都不掉，加上「兩個 process 輸出 byte-identical」的實證（先斷言兩個檔案真的產生了，否則兩個 null 也會比對成功）。

**本次未動任何選股／評分／出場參數**，`plan.md` 的每月儀式照舊 2026-08-18。

### 2026-07-28 判級引擎四級改六級（加碼／加碼觀察／續抱／減碼觀察／減碼／清倉）＋ rec 拿掉「非買賣指令。」

使用者要的錨點：**股價同時站上 5/10/20/60 均線就加碼、反之清倉**，另外「評分可以更細」。

四級改六級不能只換切點：舊分數是四個 ±1 訊號加總（−4~+4），0 與 ±1 佔掉絕大多數樣本，
硬切六格會有兩三級長年掛零。所以評分本身改細，且 `tech` 必須是主導項——只有它單獨就能
打到兩端，均線排列的錨點才成立。

**評分（`lib/stance.ps1`，範圍 −8~+8）**：原本的 ±1 條件全部原封不動保留，新的 ±2/±3 疊在外圈，
所以舊行為是新公式的子集。`tech` ±3（全站上/全跌破 5/10/20/60）、±2（站上 5/10/20 未過季線／
跌破 10/20/60）、±1（原規則）；`chip` ±2 需「5 日每一日同向」——刻意用連續性而不是
「買超佔成交量比例」，後者要混用 `$Inst.f`（張）與 `$Series.v`，單位判斷一旦錯掉門檻就靜默失效；
`vp` ±2 是同形狀更重的量（≥3× 出貨／≥2.5× 且收高）；`extra` 維持 ±1（它只是修飾項）。
±2/±3 全部要季線，K 不足 60 根時自動退回 ±1 行為，不必提高 25 根的下限去犧牲新股。

**切點**：≥+3 加碼／+1~+2 加碼觀察／0 續抱／−1 減碼觀察／−2 減碼／≤−3 清倉。
因為是加總不是覆寫，籌碼或量價反向時會把 ±3 拉回一格——均線排列**不會**壓過壞掉的盤面。

**兩日確認**：六級比四級敏感得多，同一個新級別要連續兩個交易日成立才換級。`Get-StanceGrade`
多收 `$PrevLevel`/`$PrevRaw` 兩個參數、**維持純函式**（讀檔仍在 `update-holdings.ps1`）；
stance-log 每列多寫一個 `raw`（今日未確認讀數），`stance` 仍是確認級，所以 prevStance 與
「判級轉變」徽章語意不變。

**踩到的兩個坑**（都在 boot-check 才現形）：
1. 改制當下 `index.html` 裡已 splice 的 `HOLDINGS_META` 還是舊四級字串，`LEVEL_VIEW` 查不到
   → 整頁每一檔判級直接消失，要等隔天排程重跑才恢復。解法是 `LEGACY_LEVEL` 正規化，且**放在
   `adviseHolding` 單一入口**，下游（fillTop 計數、stanceKey、轉變比對）只需認得六個 key。
2. `prevStance` 也要過同一張表，否則「防守→減碼」這種純換名字的假轉變會灑滿改制當天整頁。

**順手修掉**：`fillTop()` 原本是拿**顯示文字**反推級別（`t==='減碼觀察'`），措辭一改就靜默失準，
六級之後更禁不起——改成直接數 `h.auto.level`。週評的 `SN` 對照表刪掉、改用唯一的 `STANCE_NM`。
`lib/stance.ps1` 開頭那句「與 page-contract.json 的 `stanceLevels` 同步」是錯的，該 key 從來不存在。

**舊歷史**：`evaluate.ps1` 只統計有 `raw` 欄位的列（＝新制度後才寫的），用欄位有無當切換點、
不寫死日期。代價是每檔要累積 21 列才有前瞻報酬，週五「持股判級驗證」會先空約一個月——已知並接受。

**非買賣指令**：那句是寫在 `rec` **資料**裡的（Gemini prompt 要求＋`gnotes.py` 強制補上），不是畫面
模板，所以改的是產生端。只停止產生，既有 notes 檔的句子留到下次重跑消失。repo 外的
`~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md` 也要同步（owner 的 rec 由它產生），
順便把該檔的判級說明改成六級。`index.html` 集中度警示那句「非買賣指令」是另一個元件，保留。

### 2026-07-25 每日 Claude token 用量公開顯示（同一次 commit 帶真實數字，不落後一天）

背景：想在 index.html 公開顯示當天跑 `claude -p`（`~/run-stock-briefing.sh`）實際花的 token。
實作中途發現時序問題：SKILL.md 步驟四（git commit/push）**在 `claude -p` 行程裡面跑**，
wrapper 要等那個行程結束、用 `--output-format json` 讀輸出，才知道今天真正的用量——這時候正常
流程早就 push 完了。拍板結果（使用者：「20:00 自動發上去後包含那次 token 用量」，即同一個
commit，不要落後一天、也不要每天兩次推播）：

- **`lib/publish-gate.ps1::Invoke-PublishGate` 新增 `-NoPush`**：只 commit、不 push。
  `publish.ps1`／`run-daily.sh --phase publish --no-push` 逐層透傳。SKILL.md 步驟四的排程專用
  提示詞（僅 wrapper 呼叫時，互動執行不受影響）改用這個旗標，把「今天的 commit」留在本機不推。
- **新增 `finish-daily-push.ps1`**（deterministic、不經 AI，UTF-8 BOM，已排進 `tests.ps1` [1][2]）：
  wrapper 在 `claude -p` 結束、讀到真實 token 數後呼叫。合併同日多次執行（`runs` 累加，不覆蓋）→
  寫 `token-usage.json` → splice 進新的 `tokenusage` block → `git commit --amend --no-edit`
  補進今天那個還沒推的 commit → push。**絕不 force-push**：`git fetch` 比對 `origin/main`，
  若發現不是簡單的「本機領先一個 commit」（例如同一時間有別的東西推了 main），改成疊加一個
  新 commit 而不是 amend；若那次 push 仍失敗，退回「不管有沒有 token 數字、至少把今天真正的
  儀表板更新推出去」，只有在這個最後手段也失敗時才以非零 exit code 收尾、留在本機等人工處理。
  三種情境（正常 amend／真衝突 fallback／同日重跑加總）都用真的 git repo 手動驗證過。
- **`~/run-stock-briefing.sh`**：`claude -p` 改 `--output-format json`；Python 內嵌腳本解析
  `.result`（照樣寫回人類看的 log，敘事不丟失）與 `.usage.*`／`.total_cost_usd`，解析失敗一律
  退回印原始輸出、用量歸零，**但不論解析成不成功都一定呼叫 `finish-daily-push.ps1`**——因為
  SKILL.md 已經用 `--no-push` 留了一個沒推的 commit，一定要有人把它推掉。`claude -p` 本身失敗
  （exit≠0）才整段跳過，比照原本行為。
- **頁面**：`page-contract.json` 新增 `tokenusage` block（`window.TOKEN_USAGE`）；index.html
  頁尾加一段小字（`buildTokenUsage()`，token 數與 input/output/cache 都有、不顯示美金，
  依拍板決定）；`tools/boot-check.js` 驗過不影響既有三種 fixture 的既有行為。
  只顯示「今天」，不留歷史／不畫圖（拍板的最小可行版本）。
- **`lib/publish-gate.ps1` 的既有 bug，實作途中發現並修掉**：`git add -A -- $PublishAllowlist`
  是把整份清單一次丟給 git——**只要清單裡任何一個 pathspec（哪怕是萬用字元）目前一個檔案都
  沒對到，整個 `git add` 直接整包失敗、什麼都不會被 stage**，而 `Invoke-PublishGate` 接著看到
  「沒東西可 commit」就回傳成功。新增 `token-usage.json` 到 allowlist 之後這顆雷差點當場踩到：
  它在第一次 `finish-daily-push.ps1` 真正跑之前本來就不存在，會讓**當天整個發佈（含 index.html
  本體）悄悄失敗、卻回報成功**。修法：allowlist 逐項個別 `git add`（`tests.ps1` 新增
  「gate stages a real change even though most of the allowlist does not exist on disk」防
  回歸）。這個 bug 跟 token 功能本身無關，是既有程式碼裡一直存在、只是從沒被剛好踩到的地雷。

### 2026-07-25 新增 guest_plus 身分別：owner 可隨時把特定使用者升級為 Claude 品質分析，代碼數預算封頂

背景：owner 想要一個開關，能把特定使用者從「Gemini 分析」升級成「跟 owner 一樣的 Claude 分析」，
同時又要記錄每日 Claude token 用量（後者見上面「🤔 待決策」，實作中途發現時序問題卡住，先擱置）。
這與硬規則 1（「Claude token 只花在 owner 身上」）正面衝突，經 `/grill-me` 逐項拍板後的設計：

- **以代碼為單位擴大批次，不是以帳號為單位重跑**：guest_plus 使用者「owner 本來沒持有」的代碼，
  併入既有的每日 Claude 批次，成本只跟著新增代碼數成長，不跟著 guest_plus 人數線性成長。
- **接 SKILL.md 步驟三（picks 選股短評）風格，不是步驟二（owner 投組分析）**：portfolio-blind、
  單檔獨立，不需要知道誰持有什麼，也不需要把 `_mentions_other_holding` 隱私過濾器擴大到別人的
  持股——避開了整個「owner 持股外洩到別人筆記」的風險面。
- **代碼數預算硬上限（`cfg["guestPlusCodeBudget"]`，預設 15，`payload.guest_plus_codes_ranked/
  guest_plus_codes_in_budget`）**：升級時若會讓「owner 未持有的代碼聯集」超過上限，`auth.set_tier`
  直接拒絕（409），不做部分升級。已升級的人事後新增持股若把預算打滿，只有那一檔靜默留在 Gemini
  品質（不報錯、guest_plus 自己頁面上也不會標示），跟現在「還沒分析完」的使用者體感一致。
  優先序＝最早被授予 guest_plus 的人優先（`audit` 表 `set_tier` 紀錄的時間），同代碼再按代號排序。
- **`server/payload.py::notes_for()` 改成用「這代碼是不是 owner 自己的持股」而不是「讀者的身分別」
  來決定 `rec` 能不能分享**：owner 自己 5 檔的 rec 永遠不外流；guest_plus 額外代碼的 rec 因為寫法
  本來就 portfolio-blind，可以安全分享——而且是按代碼分享，不是按身分別，所以一般 guest 若剛好
  也持有同一檔，會一起沾光（跟 tech/chip/fund 現有的按代碼共用邏輯一致，不是新洞）。
- **schema 遷移**：`tier` 的 CHECK 約束多了 `guest_plus`，SQLite 的 CHECK 是建表時固定的，
  `db.migrate_tier_check()` 做標準的「重建表」遷移（保留原 id，修好 `sqlite_sequence` 避免
  之後新帳號 id 撞號）。
- **`/admin` 頁面**新增升級／降回 guest_plus 的按鈕與代碼預算用量顯示；CLI 對應
  `python3 -m server.admin tier <帳號> <guest|guest_plus>`。
- **SKILL.md 新增「步驟三附加」**：讀 `data/guestplus-codes.json`（今日預算內的代碼清單，
  由 `run-daily.sh --phase fetch` 的 `export-guestplus-codes` 匯出）＋ `data/codes-context.json`
  的對應數字，寫進同一份 `holdings-notes.json`（不開新檔）。**這步依賴 `codes-context.json`
  正確包含全部使用者的代碼聯集**——與上面「🐛 待修」那則已知 bug 共用同一份輸入，兩者按拍板
  結果各自獨立推進，未等 bug 修好。
- 測試：`server/test_server.py` 新增 `TestGuestPlusTier`／`TestGuestPlusCodeBudget`，
  `python3 -m unittest discover -s server -t .`（81 個，含既有）與 `pwsh -File tests.ps1` 皆過。

### 2026-07-25 每日流程 token 節流：評估「owner 分析交給免費模型」後拍板不做，改用兩個非換模型節流

背景：guest 的三面分析與 `rec` 已 100% 由 Gemini（`server/gnotes.py`）產出、不花 Claude token；owner 自己
5 檔的分析（步驟二 tech/chip/fund/sigFund/rec）與選股短評/ai-tags（步驟三）仍 100% 由 Claude 寫。
討論中發現一個可以零邊際成本利用的事實：`data/codes-context.json` 本來就是 union of all users（含 owner
代號），所以 `guest-notes.json` 其實**已經**在幫 owner 的 5 檔白算一份 tech/chip/fund/rec，只是
`payload.notes_for()` 目前完全丟棄它（`notes_for()` 註解原話：「Claude's fields win... they are the
better analysis」）。曾評估讓 Claude 直接採用/審閱這份既有草稿以省輸出 token。

**拍板：不做**——owner 的持股分析與選股短評/ai-tags 維持 100% Claude 寫，不引入 Gemini 草稿。理由：
(1) 品質落差是既有共識（上面那句註解），owner 自己的分析不該打折；
(2) `ai-tags.json` 的 `sust`/`risk` 會被 `evaluate.ps1` 週報拿去驗證「AI 判讀是否有超額價值」，換一個模型
寫等於污染這條長期在追蹤的指標，兩者不能混用。

改採兩個不換模型、零品質風險的節流，已落地在 `SKILL.md`（repo 外，`~/.claude/scheduled-tasks/daily-tw-stock-briefing/SKILL.md`）：
1. **步驟三 WebSearch 預算加一句共用檢查**：選股短評先看步驟二搜過的結果是否已覆蓋該檔題材（同產業鏈／
   同大盤脈絡），覆蓋到的直接引用、不重搜。
2. **步驟〇跳過條件的敘事精簡**：原本整段重述 2026-07-23 漏更新事故，砍成一句保留教訓，操作規則不變。
   精簡判準：**結論已固化成規則的講古才砍；「違反了沒有錯誤訊息會提醒你」那類敘事保留**（例如個股註解
   點名其他持股會被伺服器端 fail-closed 過濾器靜默丟掉整段——這種沒有自然回饋迴路的規則，敘事本身就是
   防呆機制，砍了品質會真的下降）。CLAUDE.md 已經是條列式、沒有明顯可砍的講古段落，這次只動了 SKILL.md。

副產品：討論過程中查到一個既有 bug，與此決策無關，已記在上面「🐛 待修」——`codes-context.json` 疑似漏掉
非 owner 使用者的代號。

### 2026-07-25 架構整理：把重複的邏輯收成模組（`/improve-codebase-architecture` 五個候選全做）

起點是一次架構檢視，發現三處「同一件事寫了很多份」，而且每一處都已經造成過實際問題。

**① 發佈閘門（`lib/publish-gate.ps1`）** — 見上面「待決策」那則的完結。原本的檢查在出口**旁邊**
（只看 index.html 的一個 block），真正的出口 `git add -A` 沒人看。改成 allowlist 上架＋內容掃描，
第一次跑就多抓到 `stance-log.json`。`publish.ps1 -DryRun` 可先看會推什麼。

**② 頁面資料契約（`page-contract.json` ＋ `lib/pagedata.ps1` ＋ `server/pagedata.py`）** —
「找到 `<script id=x>`、換掉內容、寫回檔案」原本有 9 個地方各寫一份（7 個寫入端＋2 個自己 parse
marker 的檢查），兩種語言，`dashdata`／`holdingsmeta`／`holdingsnotes` 各有兩支腳本會寫，
順序只靠 `run-daily.sh` 的呼叫次序維持。現在 block id、`window.*` 名稱、JSON depth、
筆記欄位隱私政策都在 `page-contract.json` 宣告一次，pwsh 與 Python 各一個 adapter 讀它。
順帶把 `window.META` 從「對 JS 原始碼做正則取代」改成一般 block（`<script id="meta">`），
報告日期也由頁面從 META 帶出——以前把那行 JS 重新排版就會讓報告日期永久停更。

**③ 判級只算一次（`lib/stance.ps1`）** — 判級公式原本在 pwsh 與 JS 各手抄一份，**而且已經漂移**：
分數 −1 在 `stance-log.json` 記成 `trim`、頁面卻顯示 `hold`。46 筆歷史裡有 23 筆是 `trim`，
也就是週歸因報告（`evaluate.ps1:92` 分四級統計）裡樣本最多的一格，在頁面上根本不存在。
現在引擎算完把 `{score, level, tech, chip, extra, vp}` 放進 `HOLDINGS_META[代號].stance`，
頁面 `adviseHolding` 只把分數翻成文字。`build-demo.ps1` 與 `payload.py` 都跟著帶這個欄位。

**驗證時抓到的兩個真 bug**（都是 jsdom 實跑才看得到，靜態檢查不會發現）：
- `LEVEL_VIEW` 用 `const` 宣告在 `hydrate()` **之後** → TDZ，整頁停在第一檔持股。已移到宣告區。
- `h.sig.tech` / `h.sig.chip` 只在 `if(h.auto)` 分支裡才被建立，沒判級的代號渲染卡片時
  讀 `h.sig.chip[0]` 直接整頁中斷。這是**舊有**的地雷（K 線不足 25 根就會踩到），
  只是判級改由引擎供給後更容易踩。已在 `H` 建構時給中性預設值。

測試：`tests.ps1` 91 項全綠（新增 [9] contract／gate／stance，[5] 改為測 feed 模組，
[8] 改為 allowlist 斷言）；`server/test_server.py` 66 項全綠；
`tools/boot-check.js` 以 jsdom 驗三種頁（正常／缺 stance／空投組）。

**④ 行情抓取模組（`lib/feed.ps1`）** — `GetJson` 原本三份、timeout 已漂移（45/45/60），
「抓一個代號的月 K、快取完成月、TWSE/TPEx 路由」兩份，其中一份的 OTC fallback **沒有快取**
（所以上櫃持股每天都重抓四個月）。TWSE 欄位索引在腳本之間手抄，註解直說
「indexes proven in screen.ps1」。現在集中成一個模組，`$FeedCols` 把欄位索引命名一次——
過程中發現 **T86（上市）與 TPEx dailyTrade（上櫃）欄位其實不同**（trust/total 是 10/18 vs 13/23），
第一版把兩者寫成同一組常數就是手抄會犯的錯，已分開並加斷言。
`backtest.ps1` 的 60 秒 timeout 保留，但改成明寫 `$FeedTimeoutSec = 60`，不再是各自帶一份的副作用。
關鍵收穫是 `Set-FeedTransport`：抓取變成可替換的接縫，**實際解析交易所回應的那條路徑第一次被測試執行到**
（以前只能 stub 成 throw 然後驗快取命中）。另以真實網路各驗一次 TWSE 與 TPEx auto-routing。

**⑤ 頁面財務計算抽離** — `buildEquity()` 原本把含息還原、TWR、波動、MDD、Beta、風險貢獻
和 `getElementById` 混在同一個函式，等於非開瀏覽器不能驗算。拆成純函式 `computeEquity()`
（掛 `window.ANALYTICS`）＋ 只負責畫的 `buildEquity()`。拆完用 jsdom 跑新舊兩版比對
riskRow／riskContrib／eqHead **輸出完全一致**，確認是純重構。
`index.html` 仍是單檔＋CSP `default-src 'none'`——這是同一段 inline script 內部的拆分，
沒有改 module、沒有 build step。
新測試驗到一條以前驗不到的性質：**期中買進是現金流不是報酬，TWR 必須維持 0%**。

**測試腳本進 repo**：`tools/boot-check.js`（jsdom 實跑＋約 19 項斷言）。以前每次都要重寫一份，
現在是 repo 的一部分；jsdom/canvas 仍不進 repo（`index.html` 必須維持零相依），
用 `NODE_PATH` 指到暫存的 node_modules。

### 2026-07-25 事故：伺服器頁面全白（服務跑舊碼＋既有 migration bug 兩層疊加）

使用者回報自架伺服器頁面幾乎空白（Hero 數字是 `—`、殘留舊新聞文字）。
用 claude-in-chrome 開真實瀏覽器讀 console 才看到，curl／jsdom 對這台伺服器都測不到——
症狀只在「登入後的個人化頁面」才會炸，靜態 demo 頁（GitHub Pages）完全正常。

**第一層、觸發原因**：`stock-dashboard.service` 是 07-24 11:31 啟動的常駐 process，但「持股單位
張改股」（commit `ef38837`）07-24 20:59 才 commit——**晚於服務啟動**。服務跑的是記憶體裡的舊碼，
`payload.holdings_meta()` 吐出的欄位還叫 `lots`，前端 JS 已經改讀 `h.shares` 去算持股卡片
（`fmt(h.shares)`），對 `undefined` 呼叫 `.toLocaleString()` 直接拋例外、把整支渲染 script 卡死。
**教訓：`server/` 的變更 push 上去不會自動生效，process 要重啟才會載入新碼**——跟 `index.html`
這種每次請求都重讀的檔案完全不同的部署模型，很容易忘記。

**第二層、重啟時炸出的既有 bug**：重啟後 `db.migrate_tier_check()`（guest_plus 那次遷移，
`server/db.py`）用 `INSERT INTO users SELECT * FROM users_pre_guest_plus`——`SELECT *` 是按
**欄位順序**而非名稱複製。但既有 DB 的 `display_name` 欄位是後來用 `ALTER TABLE ADD COLUMN`
補上去的，順序排在最後；新表的 `CREATE TABLE` 卻把它排在第 3 欄——順序對不上，每一欄的值全部
錯位塞進去，owner 那筆的 `approved_at`（NULL）錯位塞進新表 `created_at`（NOT NULL）直接撞
constraint，`INSERT` 整句被 SQLite rollback，新 `users` 表變空、舊資料孤兒在 `users_pre_guest_plus`
（**資料沒遺失，只是搬錯地方**）。`ALTER TABLE ... RENAME` 還會**自動**把 `sessions`／`invites`／
`holdings`／`trades` 裡指向 `users` 的外鍵定義改成指向 `users_pre_guest_plus`，這張表後來被
`DROP` 掉，四張表的外鍵定義變成指向不存在的表，`PRAGMA foreign_keys=ON` 一生效就整個炸開。

**修法**：
1. `server/db.py` 的 `INSERT` 改成明確列欄位名稱，不再依賴順序（已 commit）
2. 手動修復當時已損毀的 `data/app.db`：先用 `INSERT INTO users (欄位...) SELECT 欄位... FROM
   users_pre_guest_plus` 把 3 筆帳號用正確對應寫回去；再用 `PRAGMA writable_schema=ON` +
   `UPDATE sqlite_master SET sql=REPLACE(...)` 把四張表 CREATE TABLE 語句裡的表名文字改回
   `users`（**不動資料或索引**，只是修 schema 文字，比整表重建安全），`foreign_key_check`／
   `integrity_check` 皆確認乾淨
3. 備份留在 `data/app.db.bak-20260725155148`（gitignore，僅本機）

**後續要做**：`git push` 完若動到 `server/` 下的檔案，要記得 `systemctl --user restart
stock-dashboard.service`，不然會有一段時間服務跑舊碼、吐出的資料格式跟前端對不上而整頁空白
且不報錯（伺服器 log 完全正常，只有瀏覽器 console 看得到）。目前沒有部署後自動重啟的機制，
是純手動步驟，容易忘記——值得評估要不要在 `publish.ps1` 或另一支 deploy 腳本裡補上這一步
（但要小心：重啟會讓當下所有登入 session 的請求短暫中斷，服務本身無 zero-downtime 機制）。


- 2026-07-24 **v18.1 修復 demo 過濾被 publish 覆蓋（隱私事故）**：`run-daily.sh` 的 publish 階段
  順序是 `build-demo.ps1` → `publish.ps1`，但 publish.ps1 自己會 splice 未過濾的 `holdings-notes.json`，
  等於每天都把 build-demo 剛過濾掉的 `rec`／`_market.wind`／其他持股代號**原樣寫回並推上公開 repo**。
  只在「當天有重寫 notes」時觸發（notes 超過 15 小時會被 publish.ps1 跳過 splice，
  所以純開發日的 commit 是乾淨的，看起來像沒問題——這是它撐了兩天沒被發現的原因）。
  1. `publish.ps1` 改為在自己 splice 完之後，**以子行程呼叫** `build-demo.ps1`（`&` 呼叫時
     $LASTEXITCODE 在乾淨執行下是 $null，會被誤判成失敗），再 commit
  2. `publish.ps1` 新增 **fail-closed 檢查**：commit 前重讀 index.html，
     `holdingsnotes` 區塊只要仍含 `"rec"`／`"wind"`／`"news"` 就中止推送
  3. `run-daily.sh` 不再自行呼叫 build-demo.ps1（順序由 publish.ps1 結構性保證，不再靠慣例）
  4. `tests.ps1` [8] 補 4 項：publish.ps1 有 demo 重建與 fail-closed 檢查、run-daily.sh 不呼叫
     build-demo、以及**靜置狀態的 index.html 不得含 owner-only 欄位**（原本的測試只驗
     build-demo.ps1 的原始碼「會不會過濾」，完全沒驗「過濾結果有沒有活到 commit」）
  已推上公開 repo 的三個 commit 是否要改寫歷史，見上方「待決策」。
- 2026-07-24 **v18 安全檢查＋進退場訊號＋backtest v2.2**（本輪安全稽核結論：架構面乾淨——
  loopback+tunnel、scrypt、token 雜湊、SameSite+Origin、CSP、SQL 參數化、guest fail-closed 過濾；
  修掉兩個實質問題，owner 弱密碼仍待使用者動作）：
  1. **帳號鎖定反向 DoS 修復**：`is_locked_out` 原為 `(ip OR username)` 共用 5 次門檻，任何人
     5 次錯密碼即可把任意帳號（含 owner）鎖 60 分鐘。改 IP 與帳號分開計數，帳號名單獨門檻
     `maxLoginFailuresPerUser`=20——暴力破解仍被擋，鎖死真使用者的成本 ×4（test_server 兩測項守著）
  2. **prune 改每日執行**：原本只在伺服器啟動時跑一次，systemd 常駐後 login_attempts／過期
     session／逾期 pending 帳號永不清理。改為請求入口每 24h 懶執行一次（threading lock 防重複）
  3. **判級轉變提醒**（進退場的「時點」訊號）：update-holdings.ps1 從 stance-log 取每檔前一
     交易日判級寫進 HOLDINGS_META（`prevStance`＋union 版 `_prevStance` 供 server 模式 guest），
     頁面比對今日規則引擎判級，不同即在持股卡顯示轉變徽章（惡化紅／好轉bull色）、Hero 整體
     傾向列出「今日判級轉變：XX 續抱→防守」。判級分數規則不動（stance-log 歷史一致性不受影響）
  4. **持股移動停利訊號**：已知成本（輸入成本或 trades 均價）且獲利 ≥15%、收盤跌破 10 日線 →
     持股卡亮 🔔 chip＋modal 顯示細節，與選股引擎出場規則同一套；無成本不猜不顯示。
     驗證：jsdom（node-canvas）十項斷言全過——static/trans/empty 三種頁 boot 零錯誤、轉變徽章
     與 Hero 摘要渲染、強制觸發移動停利、撤成本後訊號清除（**修正 v17 驗法：當時 jsdom 用
     `outside-only` 其實沒執行任何頁內 JS，「零錯誤」是假的；本輪改 `dangerously`＋真 canvas）
  5. **backtest v2.2**：見「每月參數檢視儀式」段（面板快取 v2／含息回放／量價因子／stopTrail／
     成本與穩健統計）。smoke 驗證：3 天面板抓取＋v2 快取寫讀、v1 舊檔視為 miss 重抓一次、
     chg 帶號解析與跨日收盤差 1052/1080 完全一致（24 檔為除息特徵日，正是含息還原的目標）
  6. 文件對齊：CLAUDE.md 移除「SKILL.md 尚未兩段式」過時警告（實況已兩段式＋lastTrade 跳過條件，
     原「待決策」第一項一併結案）；index.html 頁尾 08:30→20:00；SETUP.md 補 `chmod 700 data`
     （管線寫出的共用 JSON 含 owner 持股，同機其他帳號原本讀得到）；screen.ps1 holdings.json
     讀取失敗改警告（v14 backlog 之一）
  - ⏳ 使用者動作（站已對外，越快越好）：**換掉 felix 的 4 位數密碼**（網頁「修改密碼」即可，
    新密碼需 ≥10 字元）；在 repo 目錄跑一次 `chmod 700 data`
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
