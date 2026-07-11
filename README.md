# Open WebUI + Ollama QPKG for QNAP（Container Station 容器化套件）

[![Build QPKG](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

以 [qnap-dev/containerized-qpkg](https://github.com/qnap-dev/containerized-qpkg) 的架構（沿用
[roon-qpkg](https://github.com/ivanusto/roon-qpkg) 專案的作法與經驗），把
[Ollama 官方 Docker 映像](https://github.com/ollama/ollama)（`ollama/ollama`）與
[Open WebUI 官方映像](https://github.com/open-webui/open-webui)（`ghcr.io/open-webui/open-webui`）
包裝成 QNAP App Center 可安裝的 QPKG。

**本套件只包含管理指令碼與首次啟動狀態頁（UI 外殼），不內含任何映像檔或模型本體，也不依賴 docker-compose。**
使用者在 App Center 點選安裝後，套件會在背景呼叫系統的容器引擎（Container Station 的 `docker` CLI）
直接下載官方映像並以 `docker run` 建立容器，安裝流程本身數秒即完成。

```
App Center 安裝 QPKG（僅指令碼 + 狀態頁，< 1 MB）
        │
        ▼
package_routines ──► 背景 docker pull ollama/ollama、ghcr.io/open-webui/open-webui
        │                     （安裝當下先起 busybox 狀態頁佔住網頁埠顯示進度）
        ▼
openwebui-ollama.sh start
        ├──► docker network create owui-net（私有橋接網路）
        ├──► docker run ollama/ollama          --network owui-net [--gpus all]（自動偵測）
        └──► docker run open-webui             --network owui-net -p <埠>:8080
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
| GPU（可選） | 支援獨立顯示卡的機型 + 官方 NVIDIA GPU Driver QPKG，自動偵測，沒有就自動退回 CPU 推論 |

## 安裝

1. 從 [Releases](../../releases) 下載 `OpenWebUIOllama_x.y.z_x86_64.qpkg`。
2. App Center → 右上角「手動安裝」→ 選擇 qpkg 檔。套件未簽章，若 App Center 拒絕安裝，
   到「App Center → 設定 → 一般」允許安裝未經簽署的應用程式。
3. 安裝完成後，映像檔會於**背景**下載（視網速數分鐘到數十分鐘）。點 App Center／桌面圖示可立即開啟
   狀態頁看進度；下載完成後同一網址會自動換成真正的 Open WebUI 介面，不需要手動操作。
4. 開啟 Open WebUI 後，**第一個註冊的帳號會自動成為管理員**。`OLLAMA_BASE_URL` 已預先指向套件內部的
   Ollama 容器，登入後直接在介面搜尋、下載模型即可開始對話。

## 三個關鍵設計

### 1. 不用 docker-compose，直接用 `docker` CLI 管兩個容器

Container Station 保證有 `docker` CLI，但不保證有 compose plugin；套件改用 `docker network create` +
兩次 `docker run`，容器彼此以容器名稱透過私有橋接網路（`owui-net`）互相連線，行為與 compose 等價但
不多一層相依。這也是 roon-qpkg 專案驗證過的作法。

### 2. GPU 自動偵測，而非寫死宣告

啟動前用 `docker info` / `nvidia-smi` 偵測 NVIDIA runtime 是否可用，偵測到才加
`--gpus all`；若加了之後 `docker run` 失敗（例如驅動未正確安裝），會自動退回 CPU 模式重試並記錄警告，
確保同一個 QPKG 在有無獨立顯示卡的機型上都能正常啟動。可用 `GPU_MODE` 強制開/關。

### 3. 首次安裝的「下載中」體驗

映像檔下載期間，一個一次性的 busybox 狀態頁容器會先佔住網頁埠顯示下載進度，
避免使用者在下載完成前點「開啟」得到連線被拒。下載完成、真正的容器啟動後，
狀態頁容器會被移除、同一埠改由 Open WebUI 本身服務，網址不變。

## 設定檔（openwebui-ollama.conf）

| 變數 | 預設 | 說明 |
|---|---|---|
| `OLLAMA_IMAGE` | `ollama/ollama:latest` | Ollama 官方映像 |
| `OLLAMA_DATA_PATH` | `<預設磁碟區>/OpenWebUIOllama/ollama` | 模型儲存 → 容器 `/root/.ollama` |
| `OLLAMA_PUBLISH_PORT` | （空 = 不對外開放） | 是否把 Ollama API（11434）發布到區網 |
| `OLLAMA_NUM_PARALLEL` / `OLLAMA_MAX_LOADED_MODELS` | （空 = 用 Ollama 預設） | 平行請求數／同時載入模型數 |
| `GPU_MODE` | `auto` | `auto`／`on`／`off` |
| `WEBUI_IMAGE` | `ghcr.io/open-webui/open-webui:main` | Open WebUI 官方映像 |
| `WEBUI_DATA_PATH` | `<預設磁碟區>/OpenWebUIOllama/webui` | 聊天記錄／文件／RAG 向量庫 → 容器 `/app/backend/data` |
| `WEBUI_PORT` | `3000` | 網頁埠（App Center 圖示連結自動跟隨） |
| `WEBUI_SECRET_KEY` | 首次啟動自動產生 | Session 簽章金鑰，隨機產生後落地保存，不會寫死 |
| `WEBUI_PIDS_LIMIT` | `512` | 容器內處理程序數上限（防止失控佔用 NAS 資源） |
| `NETWORK_NAME` | `owui-net` | 兩容器共用的私有橋接網路 |
| `TZ` | 自動偵測 QTS 時區 | IANA 時區名稱 |
| `STOP_TIMEOUT` | `60` | 停止時的逾時秒數 |

修改後執行 `/etc/init.d/openwebui-ollama.sh restart` 或從 App Center 重啟套件。設定檔在升級／重裝時會保留。

## 維運指令

```sh
/etc/init.d/openwebui-ollama.sh status    # 狀態
/etc/init.d/openwebui-ollama.sh restart   # 重啟
/etc/init.d/openwebui-ollama.sh update    # 拉取新版官方映像並重建容器（資料保留）
/etc/init.d/openwebui-ollama.sh pull      # 僅下載映像
/etc/init.d/openwebui-ollama.sh diag      # 診斷 GPU / 映像檔 / 網路連線
```

移除套件時會刪除容器與私有網路，但**保留** `OLLAMA_DATA_PATH` 與 `WEBUI_DATA_PATH` 下的資料，
避免誤刪已下載的模型與聊天記錄。

## 從原始碼建置

```sh
# 需要 Docker（任何平台）
make            # 產出 build/OpenWebUIOllama_<版本>_x86_64.qpkg

# 或在 Ubuntu 上直接使用 QDK
git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
cd <本專案> && qbuild --build-arch x86_64
```

GitHub Actions 會在每次 push 建置 qpkg 工件，推送 `v*` 標籤時自動發佈 Release。

## 專案結構

```
├── qpkg.cfg                    # QPKG 中繼資料（相依 Container Station、WebUI 位置）
├── package_routines             # 安裝/移除掛勾：背景 pull 映像、保留設定與資料
├── shared/
│   ├── openwebui-ollama.sh      # 服務腳本：找 docker CLI、GPU 偵測、雙容器管理、狀態頁
│   ├── openwebui-ollama.conf.default  # 使用者設定範本
│   └── web/index.html           # 首次啟動狀態頁（下載完成後由 Open WebUI 本身取代）
├── icons/                       # App Center 圖示
├── x86_64/                      # qbuild 架構標記（套件本身為純腳本）
├── Dockerfile / Makefile        # QDK 建置環境
└── .github/workflows/           # CI：建置與 Release
```

## 疑難排解

| 症狀 | 原因與解法 |
|---|---|
| 顯示「沒有數位簽章」 | 本套件未經 QNAP 簽署，屬正常現象；於 App Center 設定允許未簽章應用程式即可。 |
| 點圖示打不開任何頁面 | 確認套件已啟動；網頁埠被占用時改設 `WEBUI_PORT` 後重啟。 |
| 狀態頁一直卡在「下載中」 | SSH 執行 `/etc/init.d/openwebui-ollama.sh diag` 檢查 DNS／registry 連線與 pull 記錄；也可手動 `docker pull` 觀察錯誤，完成後 `restart`。 |
| Open WebUI 連不到 Ollama / 模型清單是空的 | 確認兩個容器都在執行中（`diag`）；`OLLAMA_BASE_URL` 由套件自動設定為容器名稱，不需要手動指向 NAS IP。 |
| 想確認有沒有吃到 GPU | `/etc/init.d/openwebui-ollama.sh diag` 會顯示是否偵測到 NVIDIA runtime；也可在狀態頁看「GPU 加速」欄位。 |

## 授權與商標

管理指令碼以 MIT 授權。Ollama 與 Open WebUI 為各自上游專案的產品，其軟體與映像檔適用各自的授權條款。
本專案與 Ollama、Open WebUI、QNAP 皆無隸屬關係。
