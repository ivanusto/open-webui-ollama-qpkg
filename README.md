# Open WebUI + Ollama QPKG for QNAP (Containerized App)

[![Build QPKG](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

English | [繁體中文](README.zh-TW.md)

Based on the [qnap-dev/containerized-qpkg](https://github.com/qnap-dev/containerized-qpkg) architecture (inheriting the implementation and experience of the [roon-qpkg](https://github.com/ivanusto/roon-qpkg) project), this project packages the [official Ollama Docker image](https://github.com/ollama/ollama) (`ollama/ollama`) and the [official Open WebUI image](https://github.com/open-webui/open-webui) (`ghcr.io/open-webui/open-webui`) into an installable QPKG for QNAP App Center.

**This package only contains management scripts and a first-launch status page (UI wrapper). It does not contain any images or model files, nor does it rely on docker-compose.**
Once installed in the App Center, the package runs in the background calling the system's container engine (Container Station's `docker` CLI) to download official images and create containers using `docker run`. The installation process itself takes only a few seconds.

```
App Center installs QPKG (scripts + status page only, < 1 MB)
        │
        ▼
package_routines ──► Background docker pull ollama/ollama & ghcr.io/open-webui/open-webui
        │             (A temporary busybox status page is started on the web port to show progress)
        ▼
openwebui-ollama.sh start
        ├──► docker network create owui-net (Private bridge network)
        ├──► docker run ollama/ollama          --network owui-net [--gpus all] (Auto-detected)
        └──► docker run open-webui             --network owui-net -p <Port>:8080
                                                 -e OLLAMA_BASE_URL=http://owui-ollama:11434
```

## System Requirements

| Item | Requirement |
|---|---|
| NAS Architecture | **x86_64 (amd64)** |
| QTS | 5.0 or above |
| Dependencies | **Container Station 3.0+** (`QPKG_REQUIRE` auto-check) |
| Memory | 8 GB or more recommended (depends on the models you run) |
| Storage | Models can be tens of gigabytes; ensure the volume of the storage path has sufficient space |
| GPU (Optional) | Models with discrete graphics cards + official NVIDIA GPU Driver QPKG. Automatically detected; falls back to CPU inference if not available |

## Installation

1. Download `OpenWebUIOllama_x.y.z_x86_64.qpkg` from [Releases](../../releases).
2. Go to App Center → "Install Manually" in the top right → select the qpkg file. Since the package is unsigned, if App Center refuses to install, go to "App Center → Settings → General" to allow installing unsigned applications.
3. Once installation completes, the image downloads in the **background** (takes minutes to tens of minutes depending on network speed). Click the App Center/desktop icon to open the status page and see the progress. After download completes, the page automatically switches to the actual Open WebUI interface, requiring no manual actions.
4. When Open WebUI opens, **the first registered account automatically becomes the administrator**. `OLLAMA_BASE_URL` is pre-configured to point to the internal Ollama container. Simply log in and start searching and downloading models directly in the interface.

## Three Key Designs

### 1. No docker-compose, direct `docker` CLI management
Container Station guarantees the presence of the `docker` CLI, but not the compose plugin. The package uses `docker network create` + two `docker run` commands. The containers connect to each other via container names on a private bridge network (`owui-net`). The behavior is equivalent to compose but removes a layer of dependencies. This approach is proven in the roon-qpkg project.

### 2. Auto-detect GPU rather than hardcoding declarations
Before startup, `docker info` / `nvidia-smi` are used to check if the NVIDIA runtime is available. If found, `--gpus all` is added. If `docker run` fails after adding it (e.g., if drivers are not properly installed), it automatically falls back to CPU mode, retries, and logs a warning. This ensures the same QPKG starts correctly on models with or without discrete graphics cards. You can force GPU on/off using the `GPU_MODE` configuration.

### 3. "Downloading" experience during initial installation
During the image download, a temporary single-use busybox status page container occupies the web port to display download progress. This prevents users from getting a connection refused error when clicking "Open" before the download completes. Once download is done and the real containers start, the status page container is removed, and Open WebUI takes over the same port, keeping the URL identical.

## Configuration File (openwebui-ollama.conf)

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_IMAGE` | `ollama/ollama:latest` | Official Ollama image |
| `OLLAMA_DATA_PATH` | `<default volume>/OpenWebUIOllama/ollama` | Model storage → maps to container `/root/.ollama` |
| `OLLAMA_PUBLISH_PORT` | (Empty = Not exposed) | Whether to publish Ollama API (11434) to the local network |
| `OLLAMA_NUM_PARALLEL` / `OLLAMA_MAX_LOADED_MODELS` | (Empty = Ollama default) | Number of parallel requests / concurrent loaded models |
| `GPU_MODE` | `auto` | `auto` / `on` / `off` |
| `WEBUI_IMAGE` | `ghcr.io/open-webui/open-webui:main` | Official Open WebUI image |
| `WEBUI_DATA_PATH` | `<default volume>/OpenWebUIOllama/webui` | Chat history / Documents / RAG vector database → maps to container `/app/backend/data` |
| `WEBUI_PORT` | `3000` | Web port (App Center icon link follows this automatically) |
| `WEBUI_SECRET_KEY` | Auto-generated on first launch | Session signing key, generated randomly and stored locally, not hardcoded |
| `WEBUI_PIDS_LIMIT` | `512` | Max process limit inside the container (prevents runaways from hogging NAS resources) |
| `NETWORK_NAME` | `owui-net` | Shared private bridge network |
| `TZ` | Auto-detect QTS timezone | IANA timezone name |
| `STOP_TIMEOUT` | `60` | Timeout in seconds when stopping |
| `CS_WAIT_TIMEOUT` | `900` | Timeout in seconds to wait for Container Station to be ready at boot (waits in background, does not slow down boot) |

Modify variables and run `/etc/init.d/openwebui-ollama.sh restart` or restart the package from App Center. Configuration files are preserved during upgrade/reinstallation.

## Operations Commands

```sh
/etc/init.d/openwebui-ollama.sh status    # Status
/etc/init.d/openwebui-ollama.sh restart   # Restart
/etc/init.d/openwebui-ollama.sh update    # Pull new official images and rebuild containers (data preserved)
/etc/init.d/openwebui-ollama.sh pull      # Pull images only
/etc/init.d/openwebui-ollama.sh diag      # Diagnose GPU / images / network connections
```

Removing the package deletes the containers and private network, but **preserves** data under `OLLAMA_DATA_PATH` and `WEBUI_DATA_PATH` to prevent accidental deletion of downloaded models and chat history.

## Building from Source

```sh
# Requires Docker (any platform)
make            # Outputs build/OpenWebUIOllama_<version>_x86_64.qpkg

# Or build using QDK directly on Ubuntu
git clone https://github.com/qnap-dev/QDK && cd QDK && sudo ./InstallToUbuntu.sh install
cd <this-project> && qbuild --build-arch x86_64
```

GitHub Actions builds QPKG artifacts on every push, and automatically releases them when tags matching `v*` are pushed.

## Project Structure

```
├── qpkg.cfg                    # QPKG metadata (CS dependency, WebUI URL)
├── package_routines             # Install/Remove hooks: pull images in background, preserve config and data
├── shared/
│   ├── openwebui-ollama.sh      # Service script: find docker CLI, GPU detection, dual container management, status page
│   ├── openwebui-ollama.conf.default  # Default user configuration template
│   └── web/index.html           # Initial download status page (replaced by Open WebUI after startup)
├── icons/                       # App Center icons
├── x86_64/                      # qbuild architecture tag (the package itself contains scripts only)
├── Dockerfile / Makefile        # QDK build environment
└── .github/workflows/           # CI: build and release
```

## Troubleshooting

| Symptom | Cause & Solution |
|---|---|
| Shows "No digital signature" | This package is not digitally signed by QNAP. This is normal. Go to App Center Settings to allow unsigned apps. |
| Clicking icon does not open any page | Ensure the package is started. If the web port is occupied, change `WEBUI_PORT` and restart. |
| Status page is stuck at "Downloading" | SSH and run `/etc/init.d/openwebui-ollama.sh diag` to check DNS, registry connectivity, and pull logs. You can also run `docker pull` manually to see errors, then run `restart` when done. |
| Open WebUI cannot connect to Ollama / model list is empty | Ensure both containers are running (`diag`). `OLLAMA_BASE_URL` is automatically configured to point to the container name; do not manually point it to the NAS IP. |
| Want to check if GPU is utilized | `/etc/init.d/openwebui-ollama.sh diag` displays whether the NVIDIA runtime is detected. You can also check the "GPU Acceleration" field on the status page. |
| Notification "Failed to pull image" shows after reboot | Versions prior to 1.0.2 might start earlier than Container Station and misreport. Since 1.0.3, the start script runs in the background waiting for Container Station to be ready (up to `CS_WAIT_TIMEOUT` seconds) before starting, preventing false alarms. |

## License and Disclaimer

The management scripts are licensed under the MIT License. Ollama and Open WebUI are products of their respective upstream projects, and their software and images are subject to their respective licenses. This project is not affiliated with Ollama, Open WebUI, or QNAP.
