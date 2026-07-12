#!/bin/sh
######################################################################
# Open WebUI + Ollama QPKG service script
#
# Thin management shell around the official Ollama and Open WebUI
# Docker images. The QPKG itself ships no binaries: on start it asks
# the system container engine (Container Station) to pull/create the
# containers, no docker-compose dependency required.
#
# Two containers are managed on a private bridge network so they can
# reach each other by name:
#   * $OLLAMA_CONTAINER_NAME   ollama/ollama — the inference backend.
#                     GPU acceleration is auto-detected (NVIDIA runtime
#                     via Container Station); falls back to CPU with a
#                     logged warning when no GPU is available.
#   * $WEBUI_CONTAINER_NAME  open-webui — the web UI, published on
#                     WEBUI_PORT. It IS the app's UI, so App Center's
#                     "Open" button goes straight to it.
#
# While images are still downloading, a throwaway busybox httpd
# ("landing" container) occupies WEBUI_PORT and shows progress, so
# clicking "Open" during first install doesn't hit connection-refused.
# It is removed the moment the real Open WebUI container comes up.
#
# Usage: openwebui-ollama.sh {start|stop|restart|status|pull|bgpull|update|remove|diag}
######################################################################

CONF="/etc/config/qpkg.conf"
QPKG_NAME="OpenWebUIOllama"
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f "$CONF")
APP_CONF="$QPKG_ROOT/openwebui-ollama.conf"
LOG_DIR="$QPKG_ROOT/logs"
LOG_FILE="$LOG_DIR/openwebui-ollama.log"
PULL_LOG="$LOG_DIR/pull.log"
WEB_DIR="$QPKG_ROOT/web"
STATUS_JSON="$WEB_DIR/status.json"

mkdir -p "$LOG_DIR" 2>/dev/null

# The detached _bg_pull job can inherit a deleted cwd (App Center's
# temp extract dir), which makes every subshell print getcwd errors.
cd / 2>/dev/null

# ---------------------------------------------------------------- utils

log() {
    # $1 = message, $2 = QTS event level (1=Error, 2=Warning, 4=Information)
    /sbin/write_log "[$QPKG_NAME] $1" "${2:-4}" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$([ "${2:-4}" = 1 ] && echo ERROR || { [ "${2:-4}" = 2 ] && echo WARN || echo INFO; })] $1" >> "$LOG_FILE"
}

# Locate the docker CLI provided by Container Station. We prefer the
# regular "docker" binary so the containers stay visible/manageable in
# the Container Station UI, and fall back to system-docker.
find_docker() {
    CS_DIR=$(/sbin/getcfg container-station Install_Path -f "$CONF" 2>/dev/null)
    for BIN in \
        "$CS_DIR/bin/docker" \
        /usr/local/bin/docker \
        /usr/local/bin/system-docker \
        "$CS_DIR/bin/system-docker"
    do
        [ -n "$BIN" ] && [ -x "$BIN" ] && { echo "$BIN"; return 0; }
    done
    command -v docker 2>/dev/null && return 0
    return 1
}

# Map the QTS timezone to an IANA name for the container (best effort).
detect_tz() {
    TZNAME=$(/sbin/getcfg System "Time Zone" -f /etc/config/uLinux.conf 2>/dev/null)
    case "$TZNAME" in
        */*) echo "$TZNAME" ;;
        *)   echo "UTC" ;;
    esac
}

# Default volume mount point (e.g. /share/CACHEDEV1_DATA, /share/ZFS530_DATA).
default_volume() {
    DEFVOL=$(/sbin/getcfg SHARE_DEF defVolMP -f /etc/config/def_share.info 2>/dev/null)
    [ -n "$DEFVOL" ] && echo "$DEFVOL" || echo "/share/CACHEDEV1_DATA"
}

gen_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    elif [ -r /dev/urandom ]; then
        od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n'
    else
        date '+%s%N' | sha256sum 2>/dev/null | cut -c1-64
    fi
}

# Update (or add) KEY="VALUE" in openwebui-ollama.conf.
set_conf_value() {
    touch "$APP_CONF"
    if grep -q "^$1=" "$APP_CONF" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$APP_CONF"
    else
        echo "$1=\"$2\"" >> "$APP_CONF"
    fi
}

load_conf() {
    [ -f "$APP_CONF" ] && . "$APP_CONF"

    OLLAMA_IMAGE="${OLLAMA_IMAGE:-ollama/ollama:latest}"
    OLLAMA_CONTAINER_NAME="${OLLAMA_CONTAINER_NAME:-owui-ollama}"
    OLLAMA_DATA_PATH="${OLLAMA_DATA_PATH:-$(default_volume)/OpenWebUIOllama/ollama}"
    OLLAMA_PUBLISH_PORT="${OLLAMA_PUBLISH_PORT:-}"
    OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-}"
    OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-}"
    OLLAMA_EXTRA_ARGS="${OLLAMA_EXTRA_ARGS:-}"
    GPU_MODE="${GPU_MODE:-auto}"

    WEBUI_IMAGE="${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
    WEBUI_CONTAINER_NAME="${WEBUI_CONTAINER_NAME:-owui-frontend}"
    WEBUI_DATA_PATH="${WEBUI_DATA_PATH:-$(default_volume)/OpenWebUIOllama/webui}"
    WEBUI_PORT="${WEBUI_PORT:-3000}"
    WEBUI_PIDS_LIMIT="${WEBUI_PIDS_LIMIT:-512}"
    WEBUI_EXTRA_ARGS="${WEBUI_EXTRA_ARGS:-}"

    NETWORK_NAME="${NETWORK_NAME:-owui-net}"
    TZ="${TZ:-$(detect_tz)}"
    STOP_TIMEOUT="${STOP_TIMEOUT:-60}"
    CS_WAIT_TIMEOUT="${CS_WAIT_TIMEOUT:-900}"

    LANDING_NAME="${WEBUI_CONTAINER_NAME}-landing"

    # Generate once, on the very first load, and persist it so the
    # signing key survives restarts/upgrades.
    if [ -z "$WEBUI_SECRET_KEY" ]; then
        WEBUI_SECRET_KEY="$(gen_secret)"
        set_conf_value WEBUI_SECRET_KEY "$WEBUI_SECRET_KEY"
    fi
}

# ------------------------------------------------------------- GPU

# True (0) if Container Station's docker exposes an NVIDIA runtime, or
# nvidia-smi works on the host — either way a GPU pass-through is usable.
detect_gpu() {
    "$DOCKER" info 2>/dev/null | grep -qi nvidia && return 0
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && return 0
    return 1
}

gpu_args() {
    case "$GPU_MODE" in
        off) echo "" ;;
        on)  echo "--gpus all" ;;
        *)   if detect_gpu; then echo "--gpus all"; else echo ""; fi ;;
    esac
}

# Whether the *running* Ollama container actually has the GPU attached —
# detection alone can be true while the container fell back to CPU
# (e.g. nvidia runtime registered but the driver library is missing).
ollama_gpu_active() {
    REQ=$("$DOCKER" inspect -f '{{.HostConfig.DeviceRequests}}' "$OLLAMA_CONTAINER_NAME" 2>/dev/null)
    [ -n "$REQ" ] && [ "$REQ" != "[]" ] && [ "$REQ" != "<no value>" ]
}

gpu_state_label() {
    if ollama_gpu_active; then echo "nvidia"; else echo "none"; fi
}

# ------------------------------------------------------------- status

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_status() {
    # $1 = state string
    # Prefer the real container state; fall back to detection before the
    # container exists (e.g. while images are still downloading).
    if container_exists "$OLLAMA_CONTAINER_NAME"; then
        GPU_STATE=$(gpu_state_label)
    elif [ "$GPU_MODE" != "off" ] && detect_gpu; then
        GPU_STATE="nvidia"
    else
        GPU_STATE="none"
    fi
    mkdir -p "$WEB_DIR" 2>/dev/null
    cat > "$STATUS_JSON" <<EOF
{
  "state": "$(json_escape "$1")",
  "ollama_image": "$(json_escape "$OLLAMA_IMAGE")",
  "webui_image": "$(json_escape "$WEBUI_IMAGE")",
  "ollama_container": "$(json_escape "$OLLAMA_CONTAINER_NAME")",
  "webui_container": "$(json_escape "$WEBUI_CONTAINER_NAME")",
  "webui_port": "$(json_escape "$WEBUI_PORT")",
  "gpu_mode": "$(json_escape "$GPU_MODE")",
  "gpu": "$(json_escape "$GPU_STATE")",
  "ollama_data": "$(json_escape "$OLLAMA_DATA_PATH")",
  "webui_data": "$(json_escape "$WEBUI_DATA_PATH")",
  "tz": "$(json_escape "$TZ")",
  "updated_at": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
}

# ------------------------------------------------------------- network

ensure_network() {
    "$DOCKER" network inspect "$NETWORK_NAME" >/dev/null 2>&1 || "$DOCKER" network create "$NETWORK_NAME" >/dev/null 2>&1
}

# ------------------------------------------------------------- containers

image_present() {
    [ -n "$("$DOCKER" images -q "$1" 2>/dev/null)" ]
}

container_exists() {
    "$DOCKER" inspect "$1" >/dev/null 2>&1
}

container_running() {
    [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

run_ollama_once() {
    # $1 = extra GPU args ("--gpus all" or "")
    "$DOCKER" run -d \
        --name "$OLLAMA_CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        --restart unless-stopped \
        -e TZ="$TZ" \
        ${OLLAMA_NUM_PARALLEL:+-e OLLAMA_NUM_PARALLEL="$OLLAMA_NUM_PARALLEL"} \
        ${OLLAMA_MAX_LOADED_MODELS:+-e OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED_MODELS"} \
        -v "$OLLAMA_DATA_PATH":/root/.ollama \
        ${OLLAMA_PUBLISH_PORT:+-p "$OLLAMA_PUBLISH_PORT":11434} \
        $1 \
        $OLLAMA_EXTRA_ARGS \
        "$OLLAMA_IMAGE"
}

run_ollama() {
    # Idempotent: never "docker run" over an existing container — that
    # yields a name Conflict (and the GPU retry would then needlessly
    # recreate a GPU container as CPU-only).
    if container_exists "$OLLAMA_CONTAINER_NAME"; then
        container_running "$OLLAMA_CONTAINER_NAME" && return 0
        # GPU self-heal: a container recreated during an early boot (before
        # the NVIDIA runtime registered with docker) is stuck CPU-only.
        # While it is stopped anyway, recreate it with the GPU attached.
        if [ "$GPU_MODE" != "off" ] && detect_gpu && ! ollama_gpu_active; then
            log "GPU is available but not attached to the existing Ollama container; recreating it with GPU pass-through (models are kept)." 4
            "$DOCKER" rm "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
        else
            "$DOCKER" start "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1 && return 0
            log "Existing Ollama container failed to start; recreating it (models are kept)." 2
            "$DOCKER" rm -f "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
        fi
    fi
    mkdir -p "$OLLAMA_DATA_PATH"
    GARGS=$(gpu_args)
    OUT=$(run_ollama_once "$GARGS" 2>&1 >/dev/null)
    RC=$?
    if [ $RC -ne 0 ] && name_conflict "$OUT"; then
        # the container was there all along, just invisible to inspect
        "$DOCKER" start "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1 && return 0
    fi
    if [ $RC -ne 0 ] && [ -n "$GARGS" ] && ! name_conflict "$OUT"; then
        log "Starting Ollama with GPU pass-through failed ($OUT); retrying CPU-only." 2
        "$DOCKER" rm -f "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
        OUT=$(run_ollama_once "" 2>&1 >/dev/null)
        RC=$?
    fi
    [ $RC -eq 0 ] || log "Failed to start the Ollama container: $OUT" 1
    return $RC
}

run_webui_once() {
    "$DOCKER" run -d \
        --name "$WEBUI_CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        --restart unless-stopped \
        -p "$WEBUI_PORT":8080 \
        --pids-limit "$WEBUI_PIDS_LIMIT" \
        -e OLLAMA_BASE_URL="http://$OLLAMA_CONTAINER_NAME:11434" \
        -e WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" \
        -e TZ="$TZ" \
        -v "$WEBUI_DATA_PATH":/app/backend/data \
        $WEBUI_EXTRA_ARGS \
        "$WEBUI_IMAGE"
}

# Port WEBUI_PORT can stay bound for a few seconds after the landing
# container is removed (docker-proxy teardown lag) — treat bind errors
# as transient and retry instead of misreading them as a broken container.
port_conflict() {
    echo "$1" | grep -qi "address already in use\|port is already allocated"
}

# "docker run" hit an existing container with our name: right after boot
# the object store can hide a container from inspect for a while, so the
# exists-guard misses it and run collides. The container is fine — start it.
name_conflict() {
    echo "$1" | grep -qi "is already in use by container"
}

run_webui() {
    # Idempotent, same reason as run_ollama.
    if container_exists "$WEBUI_CONTAINER_NAME"; then
        container_running "$WEBUI_CONTAINER_NAME" && return 0
        OUT=$("$DOCKER" start "$WEBUI_CONTAINER_NAME" 2>&1 >/dev/null) && return 0
        if port_conflict "$OUT"; then
            stop_landing
            sleep 5
            "$DOCKER" start "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1 && return 0
        fi
        log "Existing Open WebUI container failed to start ($OUT); recreating it (data is kept)." 2
        "$DOCKER" rm -f "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1
    fi
    mkdir -p "$WEBUI_DATA_PATH"
    stop_landing
    OUT=$(run_webui_once 2>&1 >/dev/null)
    RC=$?
    if [ $RC -ne 0 ] && name_conflict "$OUT"; then
        # the container was there all along, just invisible to inspect
        "$DOCKER" start "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1 && return 0
    fi
    if [ $RC -ne 0 ] && port_conflict "$OUT"; then
        "$DOCKER" rm -f "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1
        sleep 5
        OUT=$(run_webui_once 2>&1 >/dev/null)
        RC=$?
    fi
    [ $RC -eq 0 ] || log "Failed to start the Open WebUI container: $OUT" 1
    return $RC
}

# ----- landing page container (busybox httpd on WEBUI_PORT) ----------
# Stateless placeholder shown only while images are downloading /
# missing, so App Center's "Open" button never hits connection-refused
# on a fresh install. Removed as soon as the real containers are up.

start_landing() {
    "$DOCKER" rm -f "$LANDING_NAME" >/dev/null 2>&1
    if [ -z "$("$DOCKER" images -q busybox:stable 2>/dev/null)" ]; then
        "$DOCKER" pull busybox:stable >> "$PULL_LOG" 2>&1 || {
            log "Could not pull busybox:stable for the status page; image download continues regardless." 2
            return 1
        }
    fi
    # Host networking on purpose: a dockerd-managed -p binding can leak
    # (dockerd keeps the port bound after the container is force-removed
    # during daemon churn, blocking the real WebUI container until the
    # daemon restarts). With --net host the socket dies with httpd.
    "$DOCKER" run -d \
        --name "$LANDING_NAME" \
        --net host \
        -v "$WEB_DIR":/www:ro \
        busybox:stable httpd -f -p "$WEBUI_PORT" -h /www >/dev/null 2>&1
}

stop_landing() {
    "$DOCKER" rm -f "$LANDING_NAME" >/dev/null 2>&1
    # A daemon hiccup can orphan the host-net httpd while removing its
    # container record, leaving WEBUI_PORT bound by a process docker no
    # longer knows about. Kill strays by their exact cmdline signature.
    # SIGKILL is required: the httpd is PID 1 of its own namespace and
    # ignores SIGTERM by default.
    for PID in $(ps 2>/dev/null | grep "httpd -f -p $WEBUI_PORT" | grep -v grep | awk '{print $1}'); do
        kill -9 "$PID" 2>/dev/null
    done
}

# ---------------------------------------------------------------- flow

pull_images() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') pulling $OLLAMA_IMAGE" >> "$PULL_LOG"
    "$DOCKER" pull "$OLLAMA_IMAGE" >> "$PULL_LOG" 2>&1 || return 1
    echo "$(date '+%Y-%m-%d %H:%M:%S') pulling $WEBUI_IMAGE" >> "$PULL_LOG"
    "$DOCKER" pull "$WEBUI_IMAGE" >> "$PULL_LOG" 2>&1 || return 1
}

# Spawn a fully detached background job ($1 = internal command). setsid
# puts the job in its own session so it survives App Center killing the
# install/start script's process group (plain nohup children can be
# reaped with it, leaving the job never actually running).
spawn_detached() {
    SELF="$QPKG_ROOT/openwebui-ollama.sh"
    if command -v setsid >/dev/null 2>&1; then
        setsid "$SELF" "$1" </dev/null >/dev/null 2>&1 &
    else
        nohup "$SELF" "$1" </dev/null >/dev/null 2>&1 &
    fi
}

spawn_bgpull() {
    spawn_detached _bg_pull
}

# True once Container Station's docker daemon answers queries against
# its object store. "docker info" alone is NOT enough: right after CS
# starts it can answer info while inspect/images still come up empty,
# which made us misjudge existing containers as missing.
docker_ready() {
    [ -n "$DOCKER" ] || DOCKER=$(find_docker)
    [ -n "$DOCKER" ] || return 1
    "$DOCKER" info >/dev/null 2>&1 && "$DOCKER" ps -q >/dev/null 2>&1
}

# Wait up to $1 seconds (default CS_WAIT_TIMEOUT) for the docker daemon.
# Needed at boot: this init script can run before Container Station has
# finished starting, and docker CLI calls fail until then. Requires two
# consecutive successful polls 10s apart so a daemon that is up but
# still settling doesn't slip through.
wait_docker_ready() {
    LIMIT="${1:-$CS_WAIT_TIMEOUT}"
    WAITED=0
    OK=0
    while :; do
        if docker_ready; then
            OK=$((OK + 1))
            [ "$OK" -ge 2 ] && return 0
            # mid-confirmation: never abort on the timeout boundary here
        else
            OK=0
            [ "$WAITED" -ge "$LIMIT" ] && return 1
        fi
        sleep 10
        WAITED=$((WAITED + 10))
    done
}

# Start now if the container engine is up; otherwise finish the start
# in a detached background job once it is (never block the QTS boot
# sequence, and never mistake "daemon not up yet" for "images missing").
start_or_defer() {
    if docker_ready; then
        do_start
    else
        write_status "waiting-for-container-station"
        log "Container Station is not ready yet; Open WebUI + Ollama will start automatically as soon as it is." 4
        spawn_detached _bg_start
    fi
}

# Pull in the background, then create + start both containers.
# Used on first start so App Center installation returns immediately.
pull_and_run_bg() {
    write_status "downloading-image"
    start_landing
    log "Ollama/Open WebUI images not present yet. Container Station is downloading them in the background; the app will start automatically when ready (progress: $PULL_LOG)." 4
    spawn_bgpull
}

finish_after_pull() {
    # settings may have changed while the images were downloading
    [ -f "$APP_CONF" ] && . "$APP_CONF"
    load_conf
    ensure_network
    stop_landing
    if run_ollama && run_webui; then
        touch "$QPKG_ROOT/.images-ready"
        write_status "running"
        log "Images downloaded; Ollama and Open WebUI containers created and started (port $WEBUI_PORT, GPU: $(ollama_gpu_active && echo yes || echo no))." 4
    else
        write_status "error"
        log "Images downloaded but a container failed to start. See $LOG_FILE." 1
    fi
}

# Only ever called with the docker daemon confirmed up (start_or_defer /
# _bg_start / finish_after_pull gate on docker_ready first).
do_start() {
    ensure_network
    write_status "starting"

    # run_ollama/run_webui are idempotent: existing containers are
    # started (or recreated if broken), otherwise created from the image.
    if { container_exists "$OLLAMA_CONTAINER_NAME" && container_exists "$WEBUI_CONTAINER_NAME"; } \
        || { image_present "$OLLAMA_IMAGE" && image_present "$WEBUI_IMAGE"; }; then
        stop_landing
        run_ollama || { write_status "error"; return 1; }
        run_webui  || { write_status "error"; return 1; }
        touch "$QPKG_ROOT/.images-ready"
        write_status "running"
        log "Open WebUI + Ollama started (port $WEBUI_PORT, GPU: $(ollama_gpu_active && echo yes || echo no))." 4
    else
        pull_and_run_bg
    fi
}

do_stop() {
    container_exists "$OLLAMA_CONTAINER_NAME" && "$DOCKER" stop -t "$STOP_TIMEOUT" "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
    container_exists "$WEBUI_CONTAINER_NAME"  && "$DOCKER" stop -t "$STOP_TIMEOUT" "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1
    stop_landing
    write_status "stopped"
    log "Open WebUI + Ollama stopped." 4
}

do_remove() {
    "$DOCKER" rm -f "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
    "$DOCKER" rm -f "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1
    stop_landing
    rm -f "$QPKG_ROOT/.images-ready"
    "$DOCKER" network rm "$NETWORK_NAME" >/dev/null 2>&1
    log "Containers and network removed. Ollama models ($OLLAMA_DATA_PATH) and Open WebUI data ($WEBUI_DATA_PATH) were kept." 4
}

do_update() {
    log "Updating Ollama and Open WebUI images..." 4
    pull_images || { log "Image update failed; keeping current containers. See $PULL_LOG." 1; return 1; }
    "$DOCKER" rm -f "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
    "$DOCKER" rm -f "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1
    ensure_network
    if run_ollama && run_webui; then
        write_status "running"
        log "Updated and restarted (data kept)." 4
    fi
}

do_status() {
    if container_running "$OLLAMA_CONTAINER_NAME" && container_running "$WEBUI_CONTAINER_NAME"; then
        echo "$QPKG_NAME is running (ollama: $OLLAMA_CONTAINER_NAME, webui: $WEBUI_CONTAINER_NAME on port $WEBUI_PORT)."
        exit 0
    else
        echo "$QPKG_NAME is not running."
        exit 1
    fi
}

# --------------------------------------------------------------- main

DOCKER=$(find_docker)
if [ -z "$DOCKER" ]; then
    # Not fatal for start/restart: at boot the CLI may not be reachable
    # yet — start_or_defer waits for Container Station in the background.
    case "$1" in
        start|restart|_bg_start) ;;
        *)
            log "Container Station docker CLI not found. Please install/enable Container Station and restart this app." 1
            write_status "no-container-engine"
            ;;
    esac
fi

load_conf

case "$1" in
    start)
        ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
        [ "$ENABLED" = "TRUE" ] || { echo "$QPKG_NAME is disabled."; exit 1; }
        start_or_defer
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        start_or_defer
        ;;
    status)
        do_status
        ;;
    pull)
        # synchronous pull (CLI use)
        { image_present "$OLLAMA_IMAGE" && image_present "$WEBUI_IMAGE"; } || pull_images
        ;;
    bgpull)
        # detached background pull; returns immediately (App Center use)
        { image_present "$OLLAMA_IMAGE" && image_present "$WEBUI_IMAGE"; } || spawn_bgpull
        ;;
    update)
        do_update
        ;;
    remove)
        do_remove
        ;;
    diag)
        echo "docker CLI     : $DOCKER"
        "$DOCKER" version 2>&1 | head -n 6
        echo "--- GPU ---"
        detect_gpu && echo "NVIDIA runtime detected (GPU_MODE=$GPU_MODE)" || echo "No NVIDIA runtime detected (GPU_MODE=$GPU_MODE, CPU inference)"
        if container_exists "$OLLAMA_CONTAINER_NAME"; then
            ollama_gpu_active && echo "Ollama container: GPU attached (--gpus all)" || echo "Ollama container: CPU-only (GPU start failed or disabled)"
        fi
        echo "--- registry DNS ---"
        nslookup registry.ollama.ai 2>&1 | head -n 6
        nslookup ghcr.io 2>&1 | head -n 6
        echo "--- images ---"
        "$DOCKER" images 2>/dev/null | grep -E 'REPOSITORY|ollama|open-webui|busybox'
        echo "--- containers ---"
        "$DOCKER" ps -a 2>/dev/null | grep -E 'CONTAINER|owui'
        echo "--- network ---"
        "$DOCKER" network inspect "$NETWORK_NAME" 2>&1 | head -n 20
        echo "--- data paths ---"
        echo "OLLAMA_DATA_PATH=$OLLAMA_DATA_PATH"
        echo "WEBUI_DATA_PATH=$WEBUI_DATA_PATH"
        echo "--- last pull log ($PULL_LOG) ---"
        tail -n 20 "$PULL_LOG" 2>/dev/null || echo "(no pull log yet)"
        ;;
    _bg_start)
        # internal, runs detached from start/restart when the container
        # engine is not up yet (typically during boot): wait for it,
        # then do the real start.
        if wait_docker_ready; then
            # The daemon answers ps/info while its object store is still
            # loading, making existing containers/images look missing
            # (observed to last 2+ minutes after boot). The .images-ready
            # marker proves this app ran successfully before, so in that
            # case absence can only mean "store not loaded yet" — keep
            # waiting instead of falling into the download path.
            SETTLE=0
            LIMIT=60
            [ -f "$QPKG_ROOT/.images-ready" ] && LIMIT="$CS_WAIT_TIMEOUT"
            while [ "$SETTLE" -lt "$LIMIT" ]; do
                container_exists "$OLLAMA_CONTAINER_NAME" && break
                image_present "$OLLAMA_IMAGE" && break
                sleep 10
                SETTLE=$((SETTLE + 10))
            done
            do_start
        else
            write_status "no-container-engine"
            log "Container Station did not become ready within ${CS_WAIT_TIMEOUT}s. Start this app from App Center once Container Station is running." 1
        fi
        ;;
    _bg_pull)
        # internal, runs detached: pull with live progress for the landing page
        if ! wait_docker_ready; then
            write_status "no-container-engine"
            log "Container Station did not become ready within ${CS_WAIT_TIMEOUT}s; image download not started. Start this app from App Center once Container Station is running." 1
            exit 1
        fi
        PIDFILE="$LOG_DIR/pull.pid"
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            exit 0  # a pull is already running
        fi
        echo $$ > "$PIDFILE"
        write_status "downloading-image"
        # Registry access / DNS can still be settling right after boot —
        # retry transient pull failures before declaring defeat.
        ( ATTEMPT=1
          while :; do
              pull_images && { echo 0 > "$LOG_DIR/pull.rc"; break; }
              [ "$ATTEMPT" -ge 3 ] && { echo 1 > "$LOG_DIR/pull.rc"; break; }
              ATTEMPT=$((ATTEMPT + 1))
              echo "$(date '+%Y-%m-%d %H:%M:%S') pull failed; retry $ATTEMPT/3 in 30s" >> "$PULL_LOG"
              sleep 30
          done ) &
        PULL_JOB=$!
        while kill -0 "$PULL_JOB" 2>/dev/null; do
            tail -n 15 "$PULL_LOG" > "$WEB_DIR/pull-progress.txt" 2>/dev/null
            sleep 5
        done
        rm -f "$PIDFILE"
        if [ "$(cat "$LOG_DIR/pull.rc" 2>/dev/null)" = "0" ]; then
            rm -f "$WEB_DIR/pull-progress.txt"
            finish_after_pull
        else
            tail -n 15 "$PULL_LOG" > "$WEB_DIR/pull-progress.txt" 2>/dev/null
            write_status "pull-failed"
            log "Downloading the Ollama/Open WebUI images failed. Run '$QPKG_ROOT/openwebui-ollama.sh diag' to check DNS/registry access, then restart the app. Details: $PULL_LOG" 1
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|pull|bgpull|update|remove|diag}"
        exit 1
        ;;
esac

exit 0
