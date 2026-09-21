# Changelog

## v2.0.0

遷回 [qpkg-template](https://github.com/ivanusto/qpkg-template) v0.2.1 的骨架。服務腳本從 785 行的單檔拆成 App 層 `shared/openwebui-ollama.sh` 與範本核心 `shared/lib/qpkg-core.sh`。`QPKG_NAME` 不變，App Center 原地升級。

升級時請注意：

- **映像改為以 digest 鎖定**：`ollama/ollama:0.34.2` 與 `ghcr.io/open-webui/open-webui:v0.11.3`，記錄在 `shared/images.lock`。1.0.x 追的是 `latest` 與 `main`，之後 `update` 不再自動換到最新版；`update --check` 可比對上游是否有新版。
- **第一次啟動會在背景下載新映像，然後兩個容器各重建一次。** 設定指紋的算法與 1.0.x 不同，核心會判定設定已變更。下載期間網頁埠顯示狀態頁，模型與聊天資料不受影響。
- 設定檔保留。`WEBUI_PORT` 仍有效（新鍵名 `WEB_PORT`），`WEBUI_SECRET_KEY` 沿用，網路名稱維持 `owui-net`，停止逾時維持 60 秒。

新功能：

- `ENABLE_OLLAMA=false`：不下載、不建立本機 Ollama 容器，推論全部交給 `OLLAMA_BASE_URLS` 指定的其他機器。
- `OLLAMA_BASE_URLS` 成為獨立設定鍵（原本要寫在 `WEBUI_EXTRA_ARGS`）。本機 Ollama 開著時會接在清單最後當備援。Open WebUI 只在首次啟動時讀取這些位址，之後以其資料庫為準。
- 供應鏈：Release 附 `SHA256SUMS`、`images.lock`、`NOTICE.md` 與 build provenance attestation；CI 的 Actions 與 QDK 釘 commit SHA，建置用的 Ubuntu 與 shellcheck image 釘 digest；tag 必須與 `QPKG_VER` 一致。
- `tests/lifecycle.sh`：兩容器生命週期測試，涵蓋 `ENABLE_OLLAMA` 開關、`OLLAMA_BASE_URLS`、GPU 自我修復與 CPU 退回（以假的 docker 模擬）、以及從 v1.0.8 原地升級，共 84 項。
- `NOTICE.md`：上游授權（Ollama 為 MIT，Open WebUI 為 Open WebUI License）與商標。

GPU 行為不變：自動偵測、開機時 runtime 晚註冊的自我修復、`auto` 模式失敗退回 CPU。差別在名稱衝突與埠衝突改由核心先處理，不可能再被誤判為 GPU 啟動失敗。

## v1.0.8

- 安裝後 `chown -R 0:0` 安裝目錄；移除通用的 repo zip release workflow。

## v1.0.7 以前

見 [Releases](https://github.com/ivanusto/open-webui-ollama-qpkg/releases)。
