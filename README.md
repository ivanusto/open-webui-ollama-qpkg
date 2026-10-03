# Open WebUI + Ollama QPKG for QNAP (Containerized App)

[![Build QPKG](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)

English | [繁體中文](README.zh-TW.md)

Packages the [official Ollama Docker image](https://github.com/ollama/ollama) (`ollama/ollama`) and the [official Open WebUI image](https://github.com/open-webui/open-webui) (`ghcr.io/open-webui/open-webui`) as a QPKG that installs from QNAP App Center.

**The package contains only management scripts and a first-run status page. It bundles no images or models and does not use docker-compose.**
After installation it calls Container Station's `docker` CLI in the background to download the official images and creates the containers with `docker run`; the installation itself takes a few seconds.

Since 2.0.0 the generic lifecycle logic (waiting for Container Station, background downloads, configuration fingerprints, digest pinning, the status page, `diag`) comes from the core of [qpkg-template](https://github.com/ivanusto/qpkg-template), `shared/lib/qpkg-core.sh`. This project's `shared/openwebui-ollama.sh` only describes the two containers and the GPU behaviour. The template was originally extracted from version 1.0.7 of this project.

```
App Center installs the QPKG (scripts + status page, < 1 MB)
        │
        ▼
package_routines ──► background docker pull of the two images pinned in images.lock
        │             (a busybox status page holds the web port and shows progress)
        ▼
openwebui-ollama.sh start
        ├──► docker network create owui-net (private bridge network)
        ├──► docker run ollama/ollama@sha256:…   --network owui-net [--gpus all] (auto-detected)
        └──► docker run open-webui@sha256:…      --network owui-net -p <port>:8080
                                                   -e OLLAMA_BASE_URL=http://owui-ollama:11434
```

## System requirements

| Item | Requirement |
|---|---|
| NAS architecture | **x86_64 (amd64)** |
| QTS | 5.0 or later |
| Dependency | **Container Station 3.0+** (checked through `QPKG_REQUIRE`) |
| Memory | 8 GB or more recommended (depends on the models you run) |
| Storage | A single model can be tens of GB; make sure the volume holding the model path has room |
| GPU (optional) | A model with a discrete GPU plus the official NVIDIA GPU Driver QPKG; detected automatically, CPU inference otherwise |

## Installation

1. Download `OpenWebUIOllama_x.y.z_x86_64.qpkg` from [Releases](../../releases). You can check it against the `SHA256SUMS` of the same release first (see "Verifying a download").
2. App Center → "Install Manually" (top right) → choose the .qpkg file. The package is not signed; if App Center refuses it, allow unsigned apps under "App Center → Settings → General".
3. The images download **in the background** (minutes to tens of minutes depending on your connection). Open the app from App Center right away to watch progress; once Open WebUI answers `/health`, the same address switches to the real interface.
4. **The first account registered in Open WebUI becomes the administrator.** `OLLAMA_BASE_URL` already points at the bundled Ollama container, so you can download models from the interface and start chatting.

## Upgrading from 1.0.x

`QPKG_NAME` is unchanged, so App Center upgrades in place. During the upgrade:

- **Your configuration is kept.** `WEBUI_PORT` from 1.0.x still works (the new key is `WEB_PORT`), and `WEBUI_SECRET_KEY` is reused, so login sessions stay valid.
- **Images are now pinned.** 1.0.x followed `ollama/ollama:latest` and `open-webui:main`; from 2.0.0 the digests pinned in `images.lock` are used, and `update` no longer moves to the newest release. If you set `OLLAMA_IMAGE` or `WEBUI_IMAGE` in your `.conf`, your setting wins.
- **The first start downloads the new images in the background, then recreates each container once.** Since 2.0.2 the existing containers keep running on the previous version during the download and are replaced only when the new images are complete; if the download fails, the previous version stays up and the log says so. Models and chat data live in the mounted folders and are not affected.
- **Remote Ollama has its own key.** `-e OLLAMA_BASE_URLS=...` inside `WEBUI_EXTRA_ARGS` still works; `OLLAMA_BASE_URLS="..."` is the recommended form. An Open WebUI that is already in use keeps the connections stored in its database, so both forms only matter on its first start.

## Design notes

### 1. Images pinned by digest

`shared/images.lock` records each image as `repository:tag@sha256:digest`. The tag is for humans; the digest is what runs, so an upstream tag being moved does not affect an installed package. The status page and `diag` show the pin state (`pinned-ok`, `unpinned`, `pinned-mismatch`). `update --check` only compares against upstream and leaves the containers alone.

### 2. GPU auto-detection, self-heal after late runtime registration, CPU fallback

- The NVIDIA runtime is detected through `docker info` / `nvidia-smi`; only then is `--gpus all` added. `GPU_MODE` forces it on or off.
- At boot the NVIDIA runtime can register after Container Station, and an Ollama container created at that moment has no GPU. A later start that detects the GPU while the existing container lacks it recreates the container (models are kept).
- With `GPU_MODE=auto`, a failed start with the GPU falls back to CPU and logs a warning; with `GPU_MODE=on` there is no fallback and the error is reported. Name and port conflicts are handled by the core first, so they are never mistaken for a GPU failure.

### 3. The "downloading" experience on first install

While the images download, a throwaway busybox status page holds the web port and shows progress. It hands over only after Open WebUI answers `/health`; the address does not change.

On an upgrade that changes a pin, the status page is not used: the existing containers keep serving the previous version until the new images are complete (a registry CDN can be slow for days after a release), and a failed download leaves them running.

## Configuration (openwebui-ollama.conf)

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_IMAGE` / `WEBUI_IMAGE` | from `images.lock` | Set only to run another version; a floating tag works but is flagged as unpinned |
| `ENABLE_OLLAMA` | `true` | `false`: no local Ollama is downloaded or created; a running one is stopped (not removed) |
| `OLLAMA_BASE_URLS` | (empty) | Ollama on other machines, semicolon-separated, e.g. a DGX Spark |
| `OLLAMA_DATA_PATH` | `<default volume>/OpenWebUIOllama/ollama` | Model storage, mounted at `/root/.ollama` |
| `OLLAMA_PUBLISH_PORT` | (empty = not published) | Publish the Ollama API (11434) to the LAN |
| `OLLAMA_NUM_PARALLEL` / `OLLAMA_MAX_LOADED_MODELS` | (empty = Ollama default) | Parallel requests / models kept loaded |
| `OLLAMA_EXTRA_ARGS` | (empty) | Extra `docker run` arguments |
| `GPU_MODE` | `auto` | `auto` / `on` / `off` |
| `WEBUI_DATA_PATH` | `<default volume>/OpenWebUIOllama/webui` | Chats, documents and the RAG vector store, mounted at `/app/backend/data` |
| `WEB_PORT` | `3000` | Web port; the App Center icon link follows it (the old key `WEBUI_PORT` still works) |
| `WEBUI_SECRET_KEY` | generated on first start | Session signing key, written back to the file |
| `WEBUI_PIDS_LIMIT` | `512` | Process limit inside the container |
| `WEBUI_EXTRA_ARGS` | (empty) | Extra `docker run` arguments, split on spaces |
| `NETWORK_NAME` | `owui-net` | Private bridge network shared by both containers |
| `TZ` | QTS time zone | IANA time zone name |
| `STOP_TIMEOUT` | `60` | Stop timeout in seconds |
| `CS_WAIT_TIMEOUT` | `900` | Seconds to wait for Container Station at boot (in the background) |

After editing, run `sudo /etc/init.d/openwebui-ollama.sh restart` or restart the app from App Center. Only containers whose settings changed are recreated; models and data are kept. The file survives upgrades and reinstalls.

## Using remote GPU nodes (Ollama on other machines)

Open WebUI can send inference to Ollama running elsewhere, such as a desktop with an NVIDIA card or a DGX Spark.

**1. Let the remote Ollama listen on the LAN.** Ollama listens on `127.0.0.1` by default.

- Windows: set the system environment variable `OLLAMA_HOST=0.0.0.0:11434`, restart Ollama and allow inbound TCP 11434 in Windows Firewall.
- Linux (systemd): run `sudo systemctl edit ollama`, add `Environment="OLLAMA_HOST=0.0.0.0:11434"` under `[Service]`, then `sudo systemctl restart ollama`.
- Check from the NAS: `docker exec owui-frontend curl -s http://<node IP>:11434/api/tags` should return the model list.

The Ollama API has no authentication; expose port 11434 to the LAN only.

**2. Put the nodes in the configuration file.**

```sh
OLLAMA_BASE_URLS="http://192.168.1.20:11434;http://192.168.1.30:11434"
# No local Ollama needed on the NAS:
ENABLE_OLLAMA="false"
```

Then run `sudo /etc/init.d/openwebui-ollama.sh restart`. Notes:

- Once `OLLAMA_BASE_URLS` is set, Open WebUI ignores `OLLAMA_BASE_URL`, so with `ENABLE_OLLAMA=true` the package appends the local container to the list; it stays available when the remote nodes are off.
- **Open WebUI reads the Ollama addresses on its first start only.** It stores them in its database and uses those from then on, even if they were never saved in the interface (tested with v0.11.3). These keys therefore suit new installs; on an install already in use, add or remove nodes under "Admin Settings → Connections → Ollama API". Editing the file only recreates the container and leaves the list unchanged. The same applies to `ENABLE_OLLAMA=false`: remove the local entry in the interface.
- When a node in the list is unreachable, the model list waits for it to time out (about 10 seconds in our test).
- For nodes serving an OpenAI-compatible API (vLLM, LiteLLM, llama.cpp server), add `http://<node IP>:<port>/v1` under "Connections → OpenAI API" instead.

**Several Ollama instances sharing one model folder.** Pointing `OLLAMA_DATA_PATH` at an NFS share or another shared folder works, but Ollama's `pull` has no lock across instances. When two instances pull the same model at once, one of them fails and leaves `*-partial*` files in `models/blobs/`. After that every pull of the same model fails, on any instance, and restarting Ollama does not clear them; delete the files by hand. Let only one instance run `pull`. The others can mount the folder read-only: listing and loading models works, and `pull` reports a read-only file system.

## Operations

Run these as `admin` (for example with `sudo`). Accounts in the administrators group can drive Docker without root, so the commands appear to succeed, but the QTS event log and the App Center link port are not updated.

```sh
/etc/init.d/openwebui-ollama.sh status          # status
/etc/init.d/openwebui-ollama.sh restart         # restart, applying configuration changes
/etc/init.d/openwebui-ollama.sh update --check  # compare the pins with upstream, touch nothing
/etc/init.d/openwebui-ollama.sh update          # pull the pinned images again, recreate what changed (data kept)
/etc/init.d/openwebui-ollama.sh pull            # download the images only
/etc/init.d/openwebui-ollama.sh diag            # GPU, pin state and network diagnostics
```

Removing the package deletes the containers and the private network but **keeps** the data under `OLLAMA_DATA_PATH` and `WEBUI_DATA_PATH`.

## Verifying a download

Each release carries `SHA256SUMS` and a GitHub build provenance attestation:

```sh
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify OpenWebUIOllama_2.0.4_x86_64.qpkg --repo ivanusto/open-webui-ollama-qpkg --source-ref refs/tags/v2.0.4
```

## Building and testing

```sh
make            # build/OpenWebUIOllama_<version>_x86_64.qpkg (needs Docker)
make test       # shellcheck, pin checks, two-container lifecycle test (including the upgrade from v1.0.8)
make pin        # re-resolve the tags in images.lock to digests
```

The lifecycle test runs `traefik/whoami` in place of both upstream images and fakes the GPU with a docker wrapper, so it also runs on runners without a GPU. GitHub Actions and QDK are pinned by commit SHA; pushing a `v*` tag checks it against `QPKG_VER` and publishes a release.

## Layout

```
├── qpkg.cfg                         # QPKG metadata
├── package_routines                 # install/remove hooks: background download, keep config and data, chown root
├── shared/
│   ├── openwebui-ollama.sh          # app layer: docker run for both containers, GPU hooks, status fields
│   ├── openwebui-ollama.conf.default
│   ├── images.lock                  # image digest pins
│   ├── lib/qpkg-core.sh             # generic core (qpkg-template)
│   └── web/index.html               # first-run status page
├── scripts/                         # pin-images, check-pins, check-ci-pins
├── tests/                           # lifecycle test and QTS command stubs
├── icons/  x86_64/
├── Dockerfile / Makefile            # QDK build environment (pinned)
└── .github/                         # CI and Dependabot
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "No digital signature" | The package is not signed by QNAP; allow unsigned apps in App Center settings. |
| The icon opens nothing | Make sure the app is running; if the web port is taken, set `WEB_PORT` and restart. |
| The status page stays at "downloading" | Run `diag` to check DNS, registry access and the pull log, then `restart`. |
| Open WebUI cannot reach Ollama / empty model list | Check that both containers run (`diag`), then check the addresses in "Admin Settings → Connections"; after the first start the file's Ollama addresses no longer apply. |
| Is the GPU used? | `diag` shows whether the NVIDIA runtime is detected and whether the Ollama container has the GPU; the status page has a "GPU acceleration" field. |
| Model downloads keep failing with `remove ...-partial-0: no such file or directory` | Several Ollama instances wrote to the model folder at once; delete the `*-partial*` files under `models/blobs/` and retry. |

## License and trademarks

The management scripts are licensed under the Apache License 2.0. Upstream licenses and trademarks are listed in [NOTICE.md](NOTICE.md). This project is not affiliated with Ollama, Open WebUI or QNAP.
