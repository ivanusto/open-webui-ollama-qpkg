# NOTICE

[English](#english)

## 來源

本專案為原創。管理腳本的通用部分（`shared/lib/qpkg-core.sh`、狀態頁、`scripts/`）來自同一作者的 [qpkg-template](https://github.com/ivanusto/qpkg-template)，而該範本最初就是從本專案 v1.0.7 抽出的。套件結構參考 QNAP 官方的 [qnap-dev/containerized-qpkg](https://github.com/qnap-dev/containerized-qpkg)。本專案的授權（Apache-2.0，見 [LICENSE](LICENSE)）僅涵蓋本 repo 內的檔案。

## 關係聲明

本專案為非官方的社群維護套件，與 QNAP Systems, Inc. 及下列上游專案均無隸屬、維護或背書關係。

## 上游軟體

本套件僅自動化部署下列官方未經修改的 image，不重新散布任何上游軟體。實際使用的版本記錄在 `shared/images.lock`。

- [ollama/ollama](https://github.com/ollama/ollama)：MIT 授權（[LICENSE](https://github.com/ollama/ollama/blob/main/LICENSE)）。
- [ghcr.io/open-webui/open-webui](https://github.com/open-webui/open-webui)：Open WebUI License（[LICENSE](https://github.com/open-webui/open-webui/blob/main/LICENSE)）。這是 BSD-3-Clause 加上一條品牌條款：除非 30 天內的終端使用者不超過 50 人、取得著作權人書面同意或企業授權，否則不得移除或變更「Open WebUI」的名稱、標誌與識別。本套件不修改 Open WebUI 的任何品牌元素。
- 狀態頁使用 [busybox](https://hub.docker.com/_/busybox)（GPL-2.0），同樣不重新散布。

使用本套件即表示接受上述各自的授權。

## 商標

Ollama、Open WebUI 與 NVIDIA 為其各自所有者的商標。QNAP、QTS、QuTS hero 與 Container Station 為 QNAP Systems, Inc. 的商標。

---

## English

**Origin.** This project is original work. The generic parts of the management scripts (`shared/lib/qpkg-core.sh`, the status page, `scripts/`) come from [qpkg-template](https://github.com/ivanusto/qpkg-template) by the same author, which was itself extracted from v1.0.7 of this project. The package layout follows QNAP's [qnap-dev/containerized-qpkg](https://github.com/qnap-dev/containerized-qpkg). This project's license (Apache-2.0, see [LICENSE](LICENSE)) covers only the files in this repository.

**Affiliation.** This is an unofficial, community-maintained package. It is not affiliated with, maintained or endorsed by QNAP Systems, Inc. or the upstream projects named below.

**Upstream software.** The package only automates the deployment of the official, unmodified images below and does not redistribute any upstream software. The exact versions are recorded in `shared/images.lock`.

- [ollama/ollama](https://github.com/ollama/ollama): MIT License.
- [ghcr.io/open-webui/open-webui](https://github.com/open-webui/open-webui): Open WebUI License, which is BSD-3-Clause plus a branding clause: the "Open WebUI" name, logo and identifiers may not be removed or altered unless the deployment has at most 50 end users in any rolling 30-day period, or with written permission or an enterprise license. This package does not alter any Open WebUI branding.
- The status page uses [busybox](https://hub.docker.com/_/busybox) (GPL-2.0), likewise not redistributed.

Using this package means accepting each of these licenses.

**Trademarks.** Ollama, Open WebUI and NVIDIA are trademarks of their respective owners. QNAP, QTS, QuTS hero and Container Station are trademarks of QNAP Systems, Inc.
