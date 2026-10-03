# Open WebUI + Ollama QPKG for QNAP（Container Station 容器化套件）

[![Build QPKG](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

[English](README.md) | 繁體中文

把 [Ollama 官方 Docker 映像](https://github.com/ollama/ollama)（`ollama/ollama`）與
[Open WebUI 官方映像](https://github.com/open-webui/open-webui)（`ghcr.io/open-webui/open-webui`）
包裝成 QNAP App Center 可安裝的 QPKG。

**本套件只包含管理指令碼與首次啟動狀態頁，不內含任何映像檔或模型本體，也不依賴 docker-compose。**
使用者在 App Center 點選安裝後，套件在背景呼叫 Container Station 的 `docker` CLI 下載官方映像並以
`docker run` 建立容器，安裝流程本身數秒即完成。

2.0.0 起，通用的生命週期邏輯（等待 Container Station、背景下載、設定指紋、digest 鎖定、狀態頁、`diag`）
改由 [qpkg-template](https://github.com/ivanusto/qpkg-template) 的核心 `shared/lib/qpkg-core.sh` 提供，
本專案的 `shared/openwebui-ollama.sh` 只描述兩個容器與 GPU 行為。那個範本最初就是從本專案 1.0.7 抽出的。

```
App Center 安裝 QPKG（僅指令碼 + 狀態頁，< 1 MB）
        │
        ▼
package_routines ──► 背景 docker pull images.lock 鎖定的兩個映像
        │                     （下載期間 busybox 狀態頁佔住網頁埠顯示進度）
        ▼
openwebui-ollama.sh start
        ├──► docker network create owui-net（私有橋接網路）
        ├──► docker run ollama/ollama@sha256:…   --network owui-net [--gpus all]（自動偵測）
        └──► docker run open-webui@sha256:…      --network owui-net -p <埠>:8080
                                                   -e OLLAMA_BASE_URL=http://owui-ollama:11434
```

## 系統需求

| 項目 | 需求 |
|---|---|
| NAS 架構 | **x86_64（amd64）** |
| QTS | 5.0 以上 |
| 相依套件 | **Container Station 3.0+**（`QPKG_REQUIRE` 自動檢查） |
| 記憶體 | 建議 8 GB 以上（依使用的模型大小而定） |
| 儲存 | 模型檔案單一可達數十 GB，請確保儲存路徑所在磁碟區空間充足 |
| GPU（可選） | 支援獨立顯示卡的機型 + 官方 NVIDIA GPU Driver QPKG，自動偵測，沒有就退回 CPU 推論 |

## 安裝

1. 從 [Releases](../../releases) 下載 `OpenWebUIOllama_x.y.z_x86_64.qpkg`，可先以同一個 Release 的 `SHA256SUMS` 校驗（見下方「驗證下載」）。
2. App Center → 右上角「手動安裝」→ 選擇 qpkg 檔。套件未簽章，若 App Center 拒絕安裝，
   到「App Center → 設定 → 一般」允許安裝未經簽署的應用程式。
3. 安裝完成後，映像檔會於**背景**下載（視網速數分鐘到數十分鐘）。點 App Center 圖示可立即開啟
   狀態頁看進度；Open WebUI 的 `/health` 回應正常後，同一網址會自動換成真正的介面。
4. 開啟 Open WebUI 後，**第一個註冊的帳號會自動成為管理員**。`OLLAMA_BASE_URL` 已預先指向套件內部的
   Ollama 容器，登入後直接在介面下載模型即可開始對話。

## 從 1.0.x 升級

`QPKG_NAME` 沒有改變，App Center 會原地升級。升級時會發生下列事情：

- **設定檔保留。** 1.0.x 的 `WEBUI_PORT` 仍然有效（新鍵名為 `WEB_PORT`），`WEBUI_SECRET_KEY` 沿用，登入 session 不會失效。
- **映像改為鎖定版本。** 1.0.x 追的是 `ollama/ollama:latest` 與 `open-webui:main`；2.0.0 起使用 `images.lock` 裡以 digest 鎖定的版本，`update` 不再自動換到最新版。若 `.conf` 裡自行設定過 `OLLAMA_IMAGE`／`WEBUI_IMAGE`，以你的設定為準。
- **第一次啟動會在背景下載新映像，然後兩個容器各重建一次。** 2.0.2 起，下載期間既有容器繼續以舊版服務，新映像完整下載後才替換；下載失敗時維持舊版並在記錄中說明。模型與聊天資料在掛載的目錄裡，不受影響。
- **遠端 Ollama 有了獨立的設定鍵。** 原本寫在 `WEBUI_EXTRA_ARGS` 裡的 `-e OLLAMA_BASE_URLS=...` 仍然有效，建議改寫成 `OLLAMA_BASE_URLS="..."`。已經在用的 Open WebUI 以資料庫裡的連線設定為準，這兩種寫法都只影響首次啟動。

## 設計重點

### 1. 映像以 digest 鎖定

`shared/images.lock` 記錄每個映像的 `repository:tag@sha256:digest`。tag 給人看，實際執行的是 digest，
所以上游把 tag 換掉也不會影響已安裝的套件。狀態頁與 `diag` 會標示鎖定狀態（`pinned-ok`、`unpinned`、`pinned-mismatch`）。
`update --check` 只比對上游是否有新 digest，不動容器。

### 2. GPU 自動偵測、開機晚註冊的自我修復、失敗退回 CPU

- 以 `docker info`／`nvidia-smi` 偵測 NVIDIA runtime，偵測到才加 `--gpus all`。可用 `GPU_MODE` 強制開或關。
- 開機時 NVIDIA runtime 可能比 Container Station 晚註冊，那時建出的 Ollama 容器沒有 GPU。之後的啟動若偵測得到 GPU 而既有容器沒有掛，會重建它（模型保留）。
- `GPU_MODE=auto` 時，帶 GPU 啟動失敗會退回 CPU 並記錄警告；`GPU_MODE=on` 時不退回，直接回報錯誤。名稱衝突與埠衝突由核心先處理，不會被誤判成 GPU 失敗。

### 3. 首次安裝的「下載中」體驗

映像下載期間，一次性的 busybox 狀態頁容器先佔住網頁埠顯示進度，Open WebUI 的 `/health` 回應後才換手，
網址不變。

升級而換了鎖定版本時不使用狀態頁：既有容器繼續以舊版服務，新映像完整下載後才替換（上游發版後的數天內，映像站的 CDN 可能很慢）；下載失敗時舊版照常運作。

## 設定檔（openwebui-ollama.conf）

| 變數 | 預設 | 說明 |
|---|---|---|
| `OLLAMA_IMAGE` / `WEBUI_IMAGE` | 讀 `images.lock` | 要換版本才需要設定；浮動 tag 可用但會標示為 unpinned |
| `ENABLE_OLLAMA` | `true` | 設 `false` 時不下載、不建立本機 Ollama 容器，已在執行的會停止（不刪除） |
| `OLLAMA_BASE_URLS` | （空） | 其他機器上的 Ollama，以分號分隔，例如 DGX Spark |
| `OLLAMA_DATA_PATH` | `<預設磁碟區>/OpenWebUIOllama/ollama` | 模型儲存，掛到容器 `/root/.ollama` |
| `OLLAMA_PUBLISH_PORT` | （空 = 不對外開放） | 是否把 Ollama API（11434）發布到區網 |
| `OLLAMA_NUM_PARALLEL` / `OLLAMA_MAX_LOADED_MODELS` | （空 = 用 Ollama 預設） | 平行請求數／同時載入模型數 |
| `OLLAMA_EXTRA_ARGS` | （空） | 額外的 `docker run` 參數 |
| `GPU_MODE` | `auto` | `auto`／`on`／`off` |
| `WEBUI_DATA_PATH` | `<預設磁碟區>/OpenWebUIOllama/webui` | 聊天記錄、文件、RAG 向量庫，掛到容器 `/app/backend/data` |
| `WEB_PORT` | `3000` | 網頁埠，App Center 圖示連結自動跟隨（舊鍵名 `WEBUI_PORT` 仍有效） |
| `WEBUI_SECRET_KEY` | 首次啟動自動產生 | Session 簽章金鑰，產生後寫回設定檔 |
| `WEBUI_PIDS_LIMIT` | `512` | 容器內處理程序數上限 |
| `WEBUI_EXTRA_ARGS` | （空） | 額外的 `docker run` 參數，依空白切分 |
| `NETWORK_NAME` | `owui-net` | 兩容器共用的私有橋接網路 |
| `TZ` | 自動偵測 QTS 時區 | IANA 時區名稱 |
| `STOP_TIMEOUT` | `60` | 停止時的逾時秒數 |
| `CS_WAIT_TIMEOUT` | `900` | 開機時等待 Container Station 就緒的秒數（背景等待，不拖慢開機） |

修改後執行 `sudo /etc/init.d/openwebui-ollama.sh restart` 或從 App Center 重啟套件。
只有設定有變動的容器會重建，模型與資料保留。設定檔在升級與重裝時會保留。

## 使用遠端 GPU 節點（其他機器上的 Ollama）

Open WebUI 可以把推論交給其他機器上的 Ollama，例如裝有 NVIDIA 顯示卡的桌機或 DGX Spark。

**1. 讓遠端節點的 Ollama 對區網開放。** Ollama 預設只聽 `127.0.0.1`。

- Windows：設定系統環境變數 `OLLAMA_HOST=0.0.0.0:11434`，重新啟動 Ollama，並在 Windows 防火牆放行 TCP 11434 輸入。
- Linux（systemd）：執行 `sudo systemctl edit ollama`，在 `[Service]` 下加入
  `Environment="OLLAMA_HOST=0.0.0.0:11434"`，再執行 `sudo systemctl restart ollama`。
- 從 NAS 驗證：`docker exec owui-frontend curl -s http://<節點IP>:11434/api/tags` 應回傳模型清單。

Ollama API 沒有認證機制，11434 埠請只開放給區網。

**2. 在設定檔寫入節點。**

```sh
OLLAMA_BASE_URLS="http://192.168.1.20:11434;http://192.168.1.30:11434"
# NAS 上不需要本機 Ollama 時：
ENABLE_OLLAMA="false"
```

接著執行 `sudo /etc/init.d/openwebui-ollama.sh restart`。注意事項：

- Open WebUI 只要看到 `OLLAMA_BASE_URLS` 就不再讀 `OLLAMA_BASE_URL`，所以 `ENABLE_OLLAMA=true` 時套件會把本機容器接在清單最後，遠端節點關機時仍有本機可用。
- **Open WebUI 只在首次啟動時讀取 Ollama 位址**，寫進自己的資料庫後就以資料庫為準，即使從未在介面儲存過也一樣（v0.11.3 實測）。所以這兩個設定鍵適合新安裝；已經在用的安裝請到「管理員設定 → Connections → Ollama API」增減節點，改設定檔只會重建容器，介面上的清單不變。`ENABLE_OLLAMA` 改成 `false` 時同理，要在介面刪掉本機那一筆。
- 清單中有節點連不上時，模型清單會等到該節點逾時才回來（實測約 10 秒）。
- 若節點提供的是 OpenAI 相容 API（vLLM、LiteLLM、llama.cpp server），請改在「Connections → OpenAI API」新增 `http://<節點IP>:<埠>/v1`。

**多個 Ollama 共用同一個模型目錄。** 把 `OLLAMA_DATA_PATH` 指到 NFS 等共用目錄在技術上可行，但 Ollama 的
`pull` 沒有跨實例的鎖：兩個實例同時下載同一個模型時會有一邊失敗，並在 `models/blobs/` 留下 `*-partial*` 檔，
之後任何實例再下載同一個模型都會失敗，重啟 Ollama 也不會清掉，要手動刪除這些檔案。
共用時請只讓一個實例執行 `pull`；其餘實例可以用唯讀掛載，唯讀時列出與載入模型都正常，`pull` 會回報 read-only file system。

## 維運指令

請以 `admin` 身分執行（例如加上 `sudo`）。administrators 群組的一般帳號不需要 root 也能操作 Docker，
指令看起來會成功，但 QTS 事件記錄與 App Center 圖示連結的埠不會更新。

```sh
/etc/init.d/openwebui-ollama.sh status          # 狀態
/etc/init.d/openwebui-ollama.sh restart         # 重啟，套用設定變更
/etc/init.d/openwebui-ollama.sh update --check  # 比對上游是否有新 digest，不動容器
/etc/init.d/openwebui-ollama.sh update          # 重新下載鎖定的映像並重建有變動的容器（資料保留）
/etc/init.d/openwebui-ollama.sh pull            # 僅下載映像
/etc/init.d/openwebui-ollama.sh diag            # 診斷 GPU、映像鎖定狀態、網路連線
```

移除套件時會刪除容器與私有網路，但**保留** `OLLAMA_DATA_PATH` 與 `WEBUI_DATA_PATH` 下的資料。

## 驗證下載

每個 Release 附 `SHA256SUMS` 與 GitHub 的 build provenance attestation：

```sh
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify OpenWebUIOllama_2.0.4_x86_64.qpkg --repo ivanusto/open-webui-ollama-qpkg --source-ref refs/tags/v2.0.4
```

## 從原始碼建置與測試

```sh
make            # 產出 build/OpenWebUIOllama_<版本>_x86_64.qpkg（需要 Docker）
make test       # shellcheck、鎖定檢查、兩容器生命週期測試（含從 v1.0.8 升級）
make pin        # 重新解析 images.lock 的 tag 為 digest
```

生命週期測試以 `traefik/whoami` 代替兩個上游映像，GPU 以假的 docker 包裝器模擬，所以在沒有 GPU 的 runner 上也能跑。
GitHub Actions 的 Actions 與 QDK 都釘在 commit SHA，推送 `v*` 標籤時檢查標籤與 `QPKG_VER` 一致後發佈 Release。

## 專案結構

```
├── qpkg.cfg                         # QPKG 中繼資料
├── package_routines                 # 安裝／移除掛勾：背景下載、保留設定與資料、chown root
├── shared/
│   ├── openwebui-ollama.sh          # App 層：兩個容器的 docker run、GPU 鉤子、狀態頁欄位
│   ├── openwebui-ollama.conf.default
│   ├── images.lock                  # 映像 digest 鎖定
│   ├── lib/qpkg-core.sh             # 通用核心（qpkg-template）
│   └── web/index.html               # 首次啟動狀態頁
├── scripts/                         # pin-images、check-pins、check-ci-pins
├── tests/                           # 生命週期測試與 QTS 指令替身
├── icons/  x86_64/
├── Dockerfile / Makefile            # QDK 建置環境（版本鎖定）
└── .github/                         # CI 與 Dependabot
```

## 疑難排解

| 症狀 | 原因與解法 |
|---|---|
| 顯示「沒有數位簽章」 | 本套件未經 QNAP 簽署，屬正常現象；於 App Center 設定允許未簽章應用程式即可。 |
| 點圖示打不開任何頁面 | 確認套件已啟動；網頁埠被占用時改設 `WEB_PORT` 後重啟。 |
| 狀態頁一直卡在「下載中」 | 執行 `diag` 檢查 DNS、registry 連線與 pull 記錄，完成後 `restart`。 |
| Open WebUI 連不到 Ollama／模型清單是空的 | 確認兩個容器都在執行（`diag`），再到「管理員設定 → Connections」確認位址；首次啟動之後，設定檔的 Ollama 位址不再生效。 |
| 想確認有沒有吃到 GPU | `diag` 顯示是否偵測到 NVIDIA runtime 以及 Ollama 容器是否掛上 GPU；狀態頁也有「GPU 加速」欄位。 |
| 下載模型一直失敗，訊息是 `remove ...-partial-0: no such file or directory` | 模型目錄被多個 Ollama 同時寫入過，刪除 `models/blobs/` 下的 `*-partial*` 檔後重試。 |

## 授權與商標

管理指令碼以 Apache License 2.0 授權。上游軟體的授權與商標見 [NOTICE.md](NOTICE.md)。
本專案與 Ollama、Open WebUI、QNAP 皆無隸屬關係。
