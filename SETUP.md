# 安裝與自架

這個專案有**兩種跑法**。先決定你要哪一種：

| | 單人靜態模式 | 多人伺服器模式 |
|---|---|---|
| 誰能看 | 產出一個 `index.html`，你自己開或推上 GitHub Pages | 每人登入自己的帳號、看自己的持股 |
| 需要什麼 | pwsh 7 | pwsh 7＋Python 3.9+ |
| 持股放哪 | `holdings.json` | 伺服器 DB `data/app.db`（不進 repo） |
| 要一直開著嗎 | 不用 | 要（伺服器要常駐） |

原始專案就是單人模式，多人模式是加上去的、可以完全不用。

---

## 需求

- **PowerShell 7**（`pwsh`）——選股與行情引擎。Ubuntu：`sudo apt install powershell` 或用 Microsoft 的套件庫。
- **Python 3.9 以上**——只有多人模式需要。**不需要 pip、venv 或任何套件**，全部走標準庫。
- 對外連線：台灣證交所（TWSE）與櫃買中心（TPEx）的公開 API。沒有金鑰、不用註冊。

---

## 單人靜態模式

```bash
git clone https://github.com/DavidLoman5/stock-dashboard.git
cd stock-dashboard

# 1. 改成你自己的持股（1 張 = 1000 股）
$EDITOR holdings.json

# 2. 抓行情、跑選股（第一次會比較久，之後有月級快取）
pwsh -File update-holdings.ps1
pwsh -File screen.ps1

# 3. 看結果
python3 -m http.server 8000     # 然後開 http://localhost:8000
```

`index.html` 是自足的單一檔案——可以直接用瀏覽器開、也可以丟到任何靜態空間。

頁面上的三面分析文字（籌碼／技術／基本）是由 AI 每天寫進 `holdings-notes.json` 的；沒有那一步的話，那些欄位會顯示「（尚無分析，等待下次更新）」，其餘的行情、損益、選股榜、規則引擎判級都照常運作。

---

## 多人伺服器模式

### 1. 設定

```bash
cp config.example.json config.json
$EDITOR config.json          # 至少把 allowedOrigins 改成你的網址
```

本機測試（純 http）時要把 `secureCookie` 設成 `false`，正式上線經 HTTPS 時務必改回 `true`。

### 2. 建立資料庫與管理者帳號

```bash
python3 -m server.admin init
```

會問你 owner 的帳號與密碼。**owner 就是管理者**：只有 owner 能核准別人、暫停帳號，也只有 owner 看得到完整的 AI 分析。

把你原本的持股搬進 DB：

```bash
python3 -m server.admin import-holdings holdings.json <你的帳號>
```

（做完之後 `holdings.json` 就只剩公開 demo 的用途了，不要再放真實部位進去。）

### 3. 抓資料、啟動

```bash
./run-daily.sh --phase fetch     # 匯出代號 → 抓行情 → 跑選股
python3 -m server.server         # 預設 http://127.0.0.1:8787
```

開瀏覽器登入即可。owner 帳號另有 `/admin` 頁可以核准與管理帳號。

### 4. 別人怎麼加入

1. 對方在你的網址點「申請帳號」，填帳號、密碼、一句自我介紹。
2. 帳號建立時是 **`pending`**：他登入後只看得到「等待核准」頁，**拿不到任何行情或分析資料**。
3. 你到 `/admin`（或 `python3 -m server.admin users` 看清單）按**核准**。
4. 想擋掉誰就按**暫停**——對方**下一次點任何東西就立刻失效**，不必等登入階段過期。

不想開放公開申請的話，把 `config.json` 的 `registrationOpen` 設成 `false`，改用 `python3 -m server.admin invite` 產一次性邀請碼發給指定的人。

### 5. 每天自動更新

把 crontab 指到 `run-daily.sh`：

```
0 20 * * 1-5  /path/to/stock-dashboard/run-daily.sh >> ~/stock-briefing-cron.log 2>&1
```

20:00 是台股收盤後，所以當天的收盤資料當天就會進頁面。

⚠️ **如果你是用 Claude Code 的排程流程跑 AI 分析**：那份 SKILL.md 必須改成呼叫 `run-daily.sh --phase fetch`（AI 寫 notes 之前）與 `run-daily.sh --phase publish`（寫完之後），而不是直接叫個別腳本。否則 `export-owner` / `export-codes` 不會跑，`update-holdings.ps1` 會拿到過期的持股清單，新使用者的股票也不會被抓。

---

## 對外開放（Cloudflare Tunnel）

伺服器**只監聽 `127.0.0.1`**，這是刻意的：外面唯一進得來的路是 tunnel。不要改成 `0.0.0.0` 然後在路由器開 port——那會直接把你家 IP 和這台機器暴露出去。

```bash
# 安裝 cloudflared（見 Cloudflare 官方文件），然後：
cloudflared tunnel login
cloudflared tunnel create stock-dashboard
cloudflared tunnel route dns stock-dashboard stock.你的網域
```

`~/.cloudflared/config.yml`：

```yaml
tunnel: stock-dashboard
credentials-file: /home/你/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: stock.你的網域
    service: http://127.0.0.1:8787
  - service: http_status:404
```

這樣就有 HTTPS、不用開防火牆埠、不會曝光家用 IP。設定好之後記得把 `config.json` 的 `allowedOrigins` 改成 `["https://stock.你的網域"]`、`secureCookie` 設回 `true`。

### 開機自動啟動

`~/.config/systemd/user/stock-dashboard.service`：

```ini
[Unit]
Description=Stock dashboard server
After=network-online.target

[Service]
WorkingDirectory=/path/to/stock-dashboard
ExecStart=/usr/bin/python3 -m server.server
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user enable --now stock-dashboard
sudo loginctl enable-linger $USER      # 沒登入也要跑
```

cloudflared 同理做一份。

⚠️ **如果這是筆電**：闔上蓋子就等於網站掛掉。要嘛設定 `HandleLidSwitch=ignore`（`/etc/systemd/logind.conf`），要嘛接受它只在你開著的時候能用。自架站的可用性就是這台機器的可用性。

---

## 測試

改任何東西之後、commit 之前：

```bash
pwsh -File tests.ps1                        # 引擎迴歸（離線、秒級）
python3 -m unittest discover -s server -t . # 伺服器：認證、權限、隔離
```

兩個都是離線的，不會打任何 API。

---

## 資料放在哪、什麼會被 commit

| 路徑 | 內容 | 進 repo？ |
|---|---|---|
| `data/app.db` | **所有使用者的帳號與持股** | ❌ 已 gitignore，權限 600 |
| `data/*.json` | 每日產出的共用行情、選股（可重建） | ❌ |
| `config.json` | 你的部署設定 | ❌ |
| `holdings.json` | **公開 demo 的範例持股** | ✅ 這是刻意公開的假資料 |
| `index.html` | 公開展示頁，由 `build-demo.ps1` 用 demo 持股重建 | ✅ |

`tests.ps1 [8]` 會擋住這幾條被改壞——因為改壞的後果是把真人的持股推上 GitHub。

---

## 給使用者的隱私承諾（請照做）

- 本站**只**儲存使用者自行輸入的股票代號、張數與成交價。
- **絕不**蒐集券商帳號、密碼或 API 金鑰。任何要求這些資訊的頁面都不是本站。
- 使用者要求刪除時，`python3 -m server.admin delete <帳號>` 會連同持股與交易紀錄一併刪除。
- 資料庫備份如果要離開這台機器，**必須先加密**。
- 這是資訊整理與決策輔助工具，**非投資建議、非個股推介**。
