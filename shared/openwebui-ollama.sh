#!/bin/sh
# shellcheck disable=SC2329 # hooks are called by lib/qpkg-core.sh
######################################################################
# Open WebUI + Ollama QPKG service script (app layer)
#
# Everything generic lives in lib/qpkg-core.sh (qpkg-template v0.2.0):
# waiting for Container Station, detached jobs, idempotent start with
# configuration fingerprints, digest verification, the status page,
# optional containers, diag. This file only says what the two
# containers are and how to run them.
#
# Containers:
#   ollama   ollama/ollama, the inference backend. GPU pass-through is
#            auto-detected; can be switched off (ENABLE_OLLAMA=false)
#            when Open WebUI talks to Ollama on other machines instead.
#   webui    ghcr.io/open-webui/open-webui, the web UI on WEB_PORT.
#
# Usage: openwebui-ollama.sh {start|stop|restart|status|pull|bgpull|update [--check]|remove|diag}
######################################################################

# ------------------------------------------------------------ settings

QPKG_NAME="OpenWebUIOllama"
DISPLAY_NAME="Open WebUI + Ollama"
SCRIPT_NAME="openwebui-ollama.sh"
CONF_NAME="openwebui-ollama.conf"

# Start order; stop runs in reverse. Ollama first so the UI finds it.
CONTAINERS="ollama webui"
# Neither is optional: a failed Ollama is a real failure unless it is
# switched off, and then it is skipped entirely (see app_enabled_ollama).
OPTIONAL_CONTAINERS=""
WEB_ID="webui"
# Open WebUI answers {"status": true} here once its migrations are done.
HEALTH_PATH="/health"
DIAG_HOSTS="registry.ollama.ai"

# ------------------------------------------------------------ hooks

app_defaults() {
    # Backwards compatibility with .conf files written by v1.0.x, where
    # the web port was WEBUI_PORT.
    WEB_PORT="${WEB_PORT:-${WEBUI_PORT:-3000}}"
    # Same network name and stop timeout as v1.0.x, so an upgrade does not
    # leave the old network behind and Ollama has time to unload models.
    NETWORK_NAME="${NETWORK_NAME:-owui-net}"
    STOP_TIMEOUT="${STOP_TIMEOUT:-60}"

    ENABLE_OLLAMA="${ENABLE_OLLAMA:-true}"
    OLLAMA_CONTAINER_NAME="${OLLAMA_CONTAINER_NAME:-owui-ollama}"
    OLLAMA_DATA_PATH="${OLLAMA_DATA_PATH:-$(default_volume)/OpenWebUIOllama/ollama}"
    OLLAMA_PUBLISH_PORT="${OLLAMA_PUBLISH_PORT:-}"
    OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-}"
    OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-}"
    OLLAMA_EXTRA_ARGS="${OLLAMA_EXTRA_ARGS:-}"
    # auto | on | off
    GPU_MODE="${GPU_MODE:-auto}"

    WEBUI_CONTAINER_NAME="${WEBUI_CONTAINER_NAME:-owui-frontend}"
    WEBUI_DATA_PATH="${WEBUI_DATA_PATH:-$(default_volume)/OpenWebUIOllama/webui}"
    WEBUI_PIDS_LIMIT="${WEBUI_PIDS_LIMIT:-512}"
    WEBUI_EXTRA_ARGS="${WEBUI_EXTRA_ARGS:-}"
    # Semicolon-separated remote Ollama endpoints (e.g. a DGX Spark).
    OLLAMA_BASE_URLS="${OLLAMA_BASE_URLS:-}"

    # Generated once, kept across restarts and upgrades.
    ensure_secret WEBUI_SECRET_KEY

    # Open WebUI reads OLLAMA_BASE_URLS instead of OLLAMA_BASE_URL whenever
    # it is set, so the local container is appended to the remote list to
    # stay available as a fallback.
    WEBUI_OLLAMA_URL=""
    [ "$ENABLE_OLLAMA" = "true" ] && WEBUI_OLLAMA_URL="http://$OLLAMA_CONTAINER_NAME:11434"
    WEBUI_OLLAMA_URLS="$OLLAMA_BASE_URLS"
    if [ -n "$OLLAMA_BASE_URLS" ] && [ -n "$WEBUI_OLLAMA_URL" ]; then
        WEBUI_OLLAMA_URLS="$OLLAMA_BASE_URLS;$WEBUI_OLLAMA_URL"
    fi
}

app_enabled_ollama() {
    [ "$ENABLE_OLLAMA" = "true" ]
}

# ----- GPU -----------------------------------------------------------

# True when Container Station's docker exposes an NVIDIA runtime, or
# nvidia-smi works on the host.
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

# Whether the existing Ollama container was created with a GPU attached.
ollama_gpu_active() {
    REQ=$("$DOCKER" inspect -f '{{.HostConfig.DeviceRequests}}' "$OLLAMA_CONTAINER_NAME" 2>/dev/null)
    [ -n "$REQ" ] && [ "$REQ" != "[]" ] && [ "$REQ" != "<no value>" ]
}

gpu_state_label() {
    if container_exists "$OLLAMA_CONTAINER_NAME"; then
        if ollama_gpu_active; then echo "nvidia"; else echo "none"; fi
    elif [ "$GPU_MODE" != "off" ] && detect_gpu; then
        echo "nvidia"
    else
        echo "none"
    fi
}

# ----- ollama --------------------------------------------------------

# Every value on the docker run line. The detected GPU state stays out
# on purpose: the runtime may register late at boot, and that must not
# trigger a recreate. GPU_MODE is the user's decision and goes in.
app_fingerprint_ollama() {
    printf '%s\n' "$OLLAMA_DATA_PATH" "$OLLAMA_PUBLISH_PORT" \
        "$OLLAMA_NUM_PARALLEL" "$OLLAMA_MAX_LOADED_MODELS" \
        "$OLLAMA_EXTRA_ARGS" "$GPU_MODE"
}

run_ollama_with() {
    # $1 = GPU args ("--gpus all" or "")
    # shellcheck disable=SC2086 # $1 and OLLAMA_EXTRA_ARGS are word-split on purpose
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

app_run_ollama() {
    run_ollama_with "$(gpu_args)"
}

# GPU self-heal: a container created during an early boot, before the
# NVIDIA runtime registered with docker, is stuck CPU-only. While it is
# stopped anyway, recreate it with the GPU attached.
app_needs_recreate_ollama() {
    [ "$GPU_MODE" != "off" ] || return 1
    detect_gpu || return 1
    ollama_gpu_active && return 1
    log "GPU is available but not attached to the existing Ollama container; recreating it with GPU pass-through (models are kept)." 4
    return 0
}

# Starting with the GPU failed for a reason other than a name or port
# conflict (the core handles those): retry CPU-only. Never for GPU_MODE=on.
app_run_fallback_ollama() {
    [ "$GPU_MODE" = "auto" ] || return 1
    [ -n "$(gpu_args)" ] || return 1
    log "Starting Ollama with GPU pass-through failed ($1); retrying CPU-only." 2
    run_ollama_with ""
}

# ----- webui ---------------------------------------------------------

app_fingerprint_webui() {
    printf '%s\n' "$WEB_PORT" "$WEBUI_DATA_PATH" "$WEBUI_PIDS_LIMIT" \
        "$WEBUI_EXTRA_ARGS" "$WEBUI_SECRET_KEY" "$WEBUI_OLLAMA_URL" "$OLLAMA_BASE_URLS"
}

app_run_webui() {
    # shellcheck disable=SC2086 # WEBUI_EXTRA_ARGS is word-split on purpose
    "$DOCKER" run -d \
        --name "$WEBUI_CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        --restart unless-stopped \
        -p "$WEB_PORT":8080 \
        --pids-limit "$WEBUI_PIDS_LIMIT" \
        ${WEBUI_OLLAMA_URL:+-e OLLAMA_BASE_URL="$WEBUI_OLLAMA_URL"} \
        ${WEBUI_OLLAMA_URLS:+-e OLLAMA_BASE_URLS="$WEBUI_OLLAMA_URLS"} \
        -e WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" \
        -e TZ="$TZ" \
        -v "$WEBUI_DATA_PATH":/app/backend/data \
        $WEBUI_EXTRA_ARGS \
        "$WEBUI_IMAGE"
}

# ----- status page and diag -----------------------------------------

app_status_fields() {
    if [ "$ENABLE_OLLAMA" = "true" ]; then
        echo "GPU acceleration|GPU 加速|$(gpu_state_label) (GPU_MODE=$GPU_MODE)"
        echo "Model storage|模型儲存路徑|$OLLAMA_DATA_PATH"
    else
        echo "Local Ollama|本機 Ollama|switched off (ENABLE_OLLAMA=false)"
    fi
    [ -n "$OLLAMA_BASE_URLS" ] && echo "Remote Ollama|遠端 Ollama|$OLLAMA_BASE_URLS"
    echo "WebUI data|WebUI 資料路徑|$WEBUI_DATA_PATH"
}

app_diag() {
    echo "GPU_MODE=$GPU_MODE"
    detect_gpu && echo "NVIDIA runtime detected" || echo "No NVIDIA runtime detected (CPU inference)"
    if container_exists "$OLLAMA_CONTAINER_NAME"; then
        ollama_gpu_active && echo "Ollama container: GPU attached" || echo "Ollama container: CPU-only"
    fi
    echo "ENABLE_OLLAMA=$ENABLE_OLLAMA"
    echo "OLLAMA_BASE_URLS=${OLLAMA_BASE_URLS:-(unset)}"
    echo "OLLAMA_DATA_PATH=$OLLAMA_DATA_PATH"
    echo "WEBUI_DATA_PATH=$WEBUI_DATA_PATH"
}

# ------------------------------------------------------------ run

QPKG_ROOT="${QPKG_ROOT_OVERRIDE:-$("${QTS_SBIN:-/sbin}/getcfg" "$QPKG_NAME" Install_Path -f "${QPKG_CONF:-/etc/config/qpkg.conf}")}"
# shellcheck source=lib/qpkg-core.sh
. "$QPKG_ROOT/lib/qpkg-core.sh"
main "$@"
