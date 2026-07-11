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

# ------------------------------------------------------------- docker readiness

wait_for_docker() {
    # Wait up to 120 seconds (40 attempts * 3 seconds) for the Docker daemon to become responsive.
    attempts=40
    count=0
    while [ $count -lt $attempts ]; do
        if "$DOCKER" info >/dev/null 2>&1; then
            return 0
        fi
        count=$((count + 1))
        sleep 3
    done
    return 1
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
    mkdir -p "$OLLAMA_DATA_PATH"
    GARGS=$(gpu_args)
    OUT=$(run_ollama_once "$GARGS" 2>&1 >/dev/null)
    RC=$?
    if [ $RC -ne 0 ] && [ -n "$GARGS" ]; then
        log "Starting Ollama with GPU pass-through failed ($OUT); retrying CPU-only." 2
        "$DOCKER" rm -f "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
        OUT=$(run_ollama_once "" 2>&1 >/dev/null)
        RC=$?
    fi
    [ $RC -eq 0 ] || log "Failed to start the Ollama container: $OUT" 1
    return $RC
}

run_webui() {
    mkdir -p "$WEBUI_DATA_PATH"
    OUT=$("$DOCKER" run -d \
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
        "$WEBUI_IMAGE" 2>&1 >/dev/null)
    RC=$?
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
    "$DOCKER" run -d \
        --name "$LANDING_NAME" \
        --restart unless-stopped \
        -p "$WEBUI_PORT":80 \
        -v "$WEB_DIR":/www:ro \
        busybox:stable httpd -f -p 80 -h /www >/dev/null 2>&1
}

stop_landing() {
    "$DOCKER" rm -f "$LANDING_NAME" >/dev/null 2>&1
}

# ---------------------------------------------------------------- flow

pull_images() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') pulling $OLLAMA_IMAGE" >> "$PULL_LOG"
    "$DOCKER" pull "$OLLAMA_IMAGE" >> "$PULL_LOG" 2>&1 || return 1
    echo "$(date '+%Y-%m-%d %H:%M:%S') pulling $WEBUI_IMAGE" >> "$PULL_LOG"
    "$DOCKER" pull "$WEBUI_IMAGE" >> "$PULL_LOG" 2>&1 || return 1
}

# Spawn a fully detached background pull. setsid puts the job in its
# own session so it survives App Center killing the install/start
# script's process group (plain nohup children can be reaped with it,
# leaving the pull never actually running).
spawn_bgpull() {
    SELF="$QPKG_ROOT/openwebui-ollama.sh"
    if command -v setsid >/dev/null 2>&1; then
        setsid "$SELF" _bg_pull </dev/null >/dev/null 2>&1 &
    else
        nohup "$SELF" _bg_pull </dev/null >/dev/null 2>&1 &
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
        write_status "running"
        log "Images downloaded; Ollama and Open WebUI containers created and started (port $WEBUI_PORT, GPU: $(ollama_gpu_active && echo yes || echo no))." 4
    else
        write_status "error"
        log "Images downloaded but a container failed to start. See $LOG_FILE." 1
    fi
}

do_start() {
    # Wait for the docker daemon to become responsive before doing anything.
    if ! wait_for_docker; then
        log "Docker daemon did not become responsive within 120 seconds. Please ensure Container Station is running." 1
        write_status "error"
        return 1
    fi

    ensure_network
    write_status "starting"

    if container_exists "$OLLAMA_CONTAINER_NAME" && container_exists "$WEBUI_CONTAINER_NAME"; then
        stop_landing
        container_running "$OLLAMA_CONTAINER_NAME" || "$DOCKER" start "$OLLAMA_CONTAINER_NAME" >/dev/null 2>&1
        container_running "$WEBUI_CONTAINER_NAME" || "$DOCKER" start "$WEBUI_CONTAINER_NAME" >/dev/null 2>&1
        write_status "running"
        log "Open WebUI + Ollama started (port $WEBUI_PORT)." 4
        return 0
    fi

    if image_present "$OLLAMA_IMAGE" && image_present "$WEBUI_IMAGE"; then
        stop_landing
        run_ollama || { write_status "error"; return 1; }
        run_webui  || { write_status "error"; return 1; }
        write_status "running"
        log "Containers created and started (port $WEBUI_PORT, GPU: $(ollama_gpu_active && echo yes || echo no))." 4
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
    log "Container Station docker CLI not found. Please install/enable Container Station and restart this app." 1
    write_status "no-container-engine"
    [ "$1" = "start" ] && exit 1
fi

load_conf

case "$1" in
    start)
        ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
        [ "$ENABLED" = "TRUE" ] || { echo "$QPKG_NAME is disabled."; exit 1; }
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        do_start
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
    _bg_pull)
        # internal, runs detached: pull with live progress for the landing page
        if ! wait_for_docker; then
            log "Docker daemon did not become responsive within 120 seconds. Pull aborted." 1
            write_status "error"
            exit 1
        fi
        PIDFILE="$LOG_DIR/pull.pid"
        if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            exit 0  # a pull is already running
        fi
        echo $$ > "$PIDFILE"
        write_status "downloading-image"
        ( pull_images; echo $? > "$LOG_DIR/pull.rc" ) &
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
