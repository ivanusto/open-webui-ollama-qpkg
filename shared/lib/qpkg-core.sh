#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2034,SC2317,SC3045
######################################################################
# qpkg-core.sh: generic engine for thin Container Station QPKGs
#
# Sourced by the app's service script after it has set QPKG_NAME,
# SCRIPT_NAME, CONF_NAME, CONTAINERS, WEB_ID, HEALTH_PATH, QPKG_ROOT
# (optionally OPTIONAL_CONTAINERS) and defined its hooks. Nothing in here is app-specific; if you find
# yourself editing it for one app, add a hook instead.
#
# Extracted from open-webui-ollama-qpkg v1.0.7. Each safeguard below
# answers a failure that was actually observed on QTS.
#
# Test overrides (never set on a NAS): QPKG_ROOT_OVERRIDE, QPKG_CONF,
# QTS_SBIN.
######################################################################

SBIN="${QTS_SBIN:-/sbin}"
CONF="${QPKG_CONF:-/etc/config/qpkg.conf}"
APP_CONF="$QPKG_ROOT/$CONF_NAME"
LOCK_FILE="$QPKG_ROOT/images.lock"
LOG_DIR="$QPKG_ROOT/logs"
LOG_FILE="$LOG_DIR/$(basename "$SCRIPT_NAME" .sh).log"
PULL_LOG="$LOG_DIR/pull.log"
WEB_DIR="$QPKG_ROOT/web"
STATUS_JSON="$WEB_DIR/status.json"

mkdir -p "$LOG_DIR" 2>/dev/null

# A detached job can inherit a deleted cwd (App Center's temporary
# extract dir), which makes every subshell print getcwd errors.
cd / 2>/dev/null || true

# ================================================================ utils

log() {
    # $1 = message, $2 = QTS event level (1=Error, 2=Warning, 4=Information)
    "$SBIN/write_log" "[$QPKG_NAME] $1" "${2:-4}" 2>/dev/null
    case "${2:-4}" in 1) LVL=ERROR ;; 2) LVL=WARN ;; *) LVL=INFO ;; esac
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LVL] $1" >> "$LOG_FILE"
}

# Uppercase a container id: app -> APP.
id_upper() {
    echo "$1" | tr '[:lower:]-' '[:upper:]_'
}

# Read a per-container variable: cvar app IMAGE -> $APP_IMAGE.
cvar() {
    eval "echo \"\${$(id_upper "$1")_$2}\""
}

has_func() {
    command -v "$1" >/dev/null 2>&1
}

# Stop order is the reverse of start order.
containers_reversed() {
    REV=""
    for C in $CONTAINERS; do REV="$C $REV"; done
    echo "$REV"
}

# A container is enabled unless the app defines app_enabled_<id> and it
# returns non-zero. A disabled container is not downloaded, created,
# listed on the status page or waited for, but its image must still be
# pinned in images.lock: switched off is not the same as absent.
container_enabled() {
    has_func "app_enabled_$1" || return 0
    "app_enabled_$1"
}

# Ids in OPTIONAL_CONTAINERS may fail to start without failing the app.
container_optional() {
    case " $OPTIONAL_CONTAINERS " in *" $1 "*) return 0 ;; esac
    return 1
}

enabled_containers() {
    EC=""
    for EC_ID in $CONTAINERS; do
        container_enabled "$EC_ID" && EC="$EC $EC_ID"
    done
    echo "$EC"
}

# QTS has no system docker; Container Station ships the CLI. Prefer the
# plain docker binary so containers stay visible in the Container Station
# UI, and fall back to system-docker.
find_docker() {
    CS_DIR=$("$SBIN/getcfg" container-station Install_Path -f "$CONF" 2>/dev/null)
    for BIN in \
        "$CS_DIR/bin/docker" \
        /usr/local/bin/docker \
        /usr/local/bin/system-docker \
        "$CS_DIR/bin/system-docker"
    do
        [ -n "$CS_DIR" ] || case "$BIN" in /bin/*) continue ;; esac
        [ -x "$BIN" ] && { echo "$BIN"; return 0; }
    done
    command -v docker 2>/dev/null && return 0
    return 1
}

# Map the QTS timezone to an IANA name (best effort).
detect_tz() {
    TZNAME=$("$SBIN/getcfg" System "Time Zone" -f /etc/config/uLinux.conf 2>/dev/null)
    case "$TZNAME" in
        */*) echo "$TZNAME" ;;
        *)   echo "UTC" ;;
    esac
}

# Default volume mount point (/share/CACHEDEV1_DATA, /share/ZFS530_DATA, ...).
default_volume() {
    DEFVOL=$("$SBIN/getcfg" SHARE_DEF defVolMP -f /etc/config/def_share.info 2>/dev/null)
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

# Update (or add) KEY="VALUE" in the app's .conf file.
set_conf_value() {
    touch "$APP_CONF"
    if grep -q "^$1=" "$APP_CONF" 2>/dev/null; then
        sed -i "s|^$1=.*|$1=\"$2\"|" "$APP_CONF"
    else
        echo "$1=\"$2\"" >> "$APP_CONF"
    fi
}

# Generate a secret once and persist it, so it survives restarts and
# upgrades. Usage in app_defaults: ensure_secret APP_SECRET_KEY
ensure_secret() {
    [ -n "$(eval "echo \"\${$1}\"")" ] && return 0
    SECRET="$(gen_secret)"
    eval "$1=\"\$SECRET\""
    set_conf_value "$1" "$SECRET"
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'
}

# App Center builds the icon's "Open" link from Web_Port in qpkg.conf,
# which QDK fills from QPKG_WEB_PORT at install time. Keep it in step
# with WEB_PORT.
sync_web_port() {
    [ "$("$SBIN/getcfg" "$QPKG_NAME" Web_Port -f "$CONF" 2>/dev/null)" = "$WEB_PORT" ] && return 0
    SYNC_OUT=$("$SBIN/setcfg" "$QPKG_NAME" Web_Port "$WEB_PORT" -f "$CONF" 2>&1)
    SYNC_RC=$?
    # Read it back: without root setcfg fails, and nothing else notices.
    SYNC_NOW=$("$SBIN/getcfg" "$QPKG_NAME" Web_Port -f "$CONF" 2>/dev/null)
    [ "$SYNC_NOW" = "$WEB_PORT" ] && return 0
    log "Could not point the App Center link at port $WEB_PORT (setcfg rc=$SYNC_RC${SYNC_OUT:+, $SYNC_OUT}; Web_Port is still ${SYNC_NOW:-unset}; uid $(id -u)). The app itself runs on port $WEB_PORT; open it at that port directly." 2
    return 1
}

# ================================================================ images

# Value of KEY in images.lock. Parsed, never sourced.
lock_value() {
    [ -f "$LOCK_FILE" ] || return 0
    sed -n "s/^$1=//p" "$LOCK_FILE" | tail -n 1 | tr -d '"'"'"' \r'
}

# repository part of a reference: registry:5000/a/b:tag@sha256:x -> registry:5000/a/b
ref_repo() {
    R="${1%@*}"
    LAST="${R##*/}"
    case "$LAST" in *:*) R="${R%:*}" ;; esac
    echo "$R"
}

# Strip the implicit Docker Hub prefixes so references compare equal.
repo_normalize() {
    echo "$1" | sed 's|^docker\.io/||; s|^index\.docker\.io/||; s|^library/||'
}

# sha256:... of a reference, empty when it is a floating tag.
ref_digest() {
    case "$1" in *@sha256:*) echo "${1##*@}" ;; esac
}

# Registry host of a reference (for diag DNS checks).
ref_registry() {
    FIRST="${1%%/*}"
    case "$1" in
        */*) case "$FIRST" in *.*|*:*|localhost) echo "$FIRST"; return ;; esac ;;
    esac
    echo "registry-1.docker.io"
}

# Reference that resolves on the local daemon. An image imported with
# "docker save" / "docker load" keeps its tag but loses RepoDigests, so a
# repository:tag@sha256 reference no longer resolves (inspect and run both
# report "No such image"). Fall back to the bare tag, but only when that
# image carries no repo digest at all: a tag that was pulled at another
# digest must never stand in for the pin.
local_ref() {
    "$DOCKER" image inspect "$1" >/dev/null 2>&1 && { echo "$1"; return 0; }
    [ -n "$(ref_digest "$1")" ] || return 1
    LR_TAG="${1%@*}"
    case "${LR_TAG##*/}" in *:*) ;; *) return 1 ;; esac
    "$DOCKER" image inspect "$LR_TAG" >/dev/null 2>&1 || return 1
    [ -z "$("$DOCKER" image inspect -f '{{range .RepoDigests}}{{.}}{{end}}' "$LR_TAG" 2>/dev/null)" ] || return 1
    echo "$LR_TAG"
}

image_present() {
    local_ref "$1" >/dev/null
}

# Point <ID>_IMAGE at the locally resolvable reference. Call it inside the
# same subshell as the app_run hook, so the configured value is untouched.
use_local_image() {
    ULI_REF=$(local_ref "$(cvar "$1" IMAGE)") || return 0
    eval "$(id_upper "$1")_IMAGE=\"\$ULI_REF\""
}

# Digest the local image was pulled by, for the given repository.
local_repo_digest() {
    # $1 = reference
    WANT_REPO=$(repo_normalize "$(ref_repo "$1")")
    for RD in $("$DOCKER" image inspect -f '{{range .RepoDigests}}{{.}} {{end}}' "$1" 2>/dev/null); do
        if [ "$(repo_normalize "${RD%@*}")" = "$WANT_REPO" ]; then
            echo "${RD##*@}"
            return 0
        fi
    done
}

# pinned-ok | pinned-mismatch | unpinned | unverifiable | missing
digest_state() {
    DS_LOCAL=$(local_ref "$1") || { echo missing; return; }
    WANT=$(ref_digest "$1")
    [ -n "$WANT" ] || { echo unpinned; return; }
    # Resolved only through the bare tag: imported, no digest to compare.
    [ "$DS_LOCAL" = "$1" ] || { echo unverifiable; return; }
    [ "$(local_repo_digest "$1")" = "$WANT" ] && echo pinned-ok || echo pinned-mismatch
}

all_images() {
    for C in $(enabled_containers); do cvar "$C" IMAGE; done
}

all_images_present() {
    for IMG in $(all_images); do image_present "$IMG" || return 1; done
}

pull_images() {
    for IMG in $(all_images); do
        echo "$(date '+%Y-%m-%d %H:%M:%S') pulling $IMG" >> "$PULL_LOG"
        "$DOCKER" pull "$IMG" >> "$PULL_LOG" 2>&1 || return 1
    done
}

# Warn about images that are not pinned or do not match their pin.
report_digests() {
    for C in $(enabled_containers); do
        IMG=$(cvar "$C" IMAGE)
        case "$(digest_state "$IMG")" in
            unpinned)        log "Image for '$C' is a floating tag ($IMG); it can change on the next pull. Pin it with @sha256." 2 ;;
            pinned-mismatch) log "Image for '$C' does not match its pinned digest ($IMG; local $(local_repo_digest "$IMG"))." 1 ;;
            unverifiable)    log "Image for '$C' was imported (docker load) and has no registry digest, so its pin cannot be verified ($IMG). Prefer a private registry." 2 ;;
        esac
    done
}

# ================================================================ config

load_conf() {
    # shellcheck disable=SC1090
    [ -f "$APP_CONF" ] && . "$APP_CONF"

    has_func app_defaults && app_defaults

    NETWORK_NAME="${NETWORK_NAME:-$(echo "$QPKG_NAME" | tr '[:upper:]' '[:lower:]')-net}"
    TZ="${TZ:-$(detect_tz)}"
    STOP_TIMEOUT="${STOP_TIMEOUT:-30}"
    CS_WAIT_TIMEOUT="${CS_WAIT_TIMEOUT:-900}"
    HEALTH_PATH="${HEALTH_PATH:-/}"

    # Images: the .conf file overrides images.lock.
    CONF_ERR=""
    for C in $CONTAINERS; do
        U=$(id_upper "$C")
        if [ -z "$(cvar "$C" IMAGE)" ]; then
            V=$(lock_value "${U}_IMAGE")
            eval "${U}_IMAGE=\"\$V\""
        fi
        [ -n "$(cvar "$C" IMAGE)" ] || CONF_ERR="$CONF_ERR ${U}_IMAGE"
    done
    LANDING_IMAGE="${LANDING_IMAGE:-$(lock_value LANDING_IMAGE)}"
    LANDING_IMAGE="${LANDING_IMAGE:-busybox:stable}"

    WEB_CONTAINER_NAME=$(cvar "$WEB_ID" CONTAINER_NAME)
    LANDING_NAME="${WEB_CONTAINER_NAME}-landing"
}

# ================================================================ status

write_status() {
    # $1 = state
    mkdir -p "$WEB_DIR" 2>/dev/null
    {
        echo "{"
        echo "  \"state\": \"$(json_escape "$1")\","
        echo "  \"app\": \"$(json_escape "$DISPLAY_NAME")\","
        echo "  \"web_port\": \"$(json_escape "$WEB_PORT")\","
        echo "  \"health_path\": \"$(json_escape "$HEALTH_PATH")\","
        echo "  \"script\": \"$(json_escape "/etc/init.d/$SCRIPT_NAME")\","
        echo "  \"containers\": ["
        SEP=""
        for C in $(enabled_containers); do
            N=$(cvar "$C" CONTAINER_NAME)
            IMG=$(cvar "$C" IMAGE)
            if [ -n "$DOCKER" ]; then
                RUN=$(container_running "$N" && echo true || echo false)
                DS=$(digest_state "$IMG")
            else
                RUN=false
                DS=unknown
            fi
            OPT=$(container_optional "$C" && echo true || echo false)
            printf '%s    {"id": "%s", "name": "%s", "image": "%s", "running": %s, "optional": %s, "digest": "%s"}' \
                "$SEP" "$(json_escape "$C")" "$(json_escape "$N")" "$(json_escape "$IMG")" "$RUN" "$OPT" "$DS"
            SEP=",
"
        done
        echo ""
        echo "  ],"
        echo "  \"fields\": ["
        SEP=""
        if has_func app_status_fields; then
            app_status_fields | while IFS='|' read -r EN ZH VAL; do
                printf '%s    {"en": "%s", "zh": "%s", "value": "%s"}' \
                    "$SEP" "$(json_escape "$EN")" "$(json_escape "$ZH")" "$(json_escape "$VAL")"
                SEP=",
"
            done
        fi
        echo ""
        echo "  ],"
        echo "  \"tz\": \"$(json_escape "$TZ")\","
        echo "  \"updated_at\": \"$(date '+%Y-%m-%d %H:%M:%S')\""
        echo "}"
    } > "$STATUS_JSON.tmp" && mv -f "$STATUS_JSON.tmp" "$STATUS_JSON"
}

# ================================================================ docker

# True once the daemon answers queries against its object store.
# "docker info" alone is NOT enough: right after Container Station starts
# it answers info while inspect/images still come up empty, which makes
# existing containers look missing.
docker_ready() {
    [ -n "$DOCKER" ] || DOCKER=$(find_docker)
    [ -n "$DOCKER" ] || return 1
    "$DOCKER" info >/dev/null 2>&1 && "$DOCKER" ps -q >/dev/null 2>&1
}

# Wait up to $1 seconds (default CS_WAIT_TIMEOUT). Requires two
# consecutive successful polls 10 s apart, so a daemon that is up but
# still settling does not slip through.
wait_docker_ready() {
    LIMIT="${1:-$CS_WAIT_TIMEOUT}"
    WAITED=0
    OK=0
    while :; do
        if docker_ready; then
            OK=$((OK + 1))
            [ "$OK" -ge 2 ] && return 0
        else
            OK=0
            [ "$WAITED" -ge "$LIMIT" ] && return 1
        fi
        sleep 10
        WAITED=$((WAITED + 10))
    done
}

# Fully detached background job ($1 = internal command). setsid puts it
# in its own session so it survives App Center killing the install or
# start script's process group; plain nohup children get reaped with it
# and the job never actually runs.
spawn_detached() {
    SELF="$QPKG_ROOT/$SCRIPT_NAME"
    if command -v setsid >/dev/null 2>&1; then
        setsid "$SELF" "$1" </dev/null >/dev/null 2>&1 &
    else
        nohup "$SELF" "$1" </dev/null >/dev/null 2>&1 &
    fi
}

ensure_network() {
    "$DOCKER" network inspect "$NETWORK_NAME" >/dev/null 2>&1 || "$DOCKER" network create "$NETWORK_NAME" >/dev/null 2>&1
}

container_exists() {
    "$DOCKER" inspect "$1" >/dev/null 2>&1
}

container_running() {
    [ "$("$DOCKER" inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# Port can stay bound for a few seconds after the landing container goes
# away (docker-proxy teardown lag): transient, retry.
port_conflict() {
    echo "$1" | grep -qi "address already in use\|port is already allocated"
}

# Right after boot the object store can hide a container from inspect, so
# the exists-guard misses it and run collides. The container is fine.
name_conflict() {
    echo "$1" | grep -qi "is already in use by container"
}

# ================================================================ fingerprints
# "docker start" reuses a container exactly as it was created, so edits
# to the .conf file would never reach an existing container. Every value
# on the docker run line is hashed and recorded once the container is up;
# a start recreates a container whose hash changed. Runtime detection
# (e.g. GPU state) stays out on purpose, so boot ordering never triggers
# a recreate; use the app_needs_recreate_<id> hook for that.

fingerprint() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum | cut -c1-32
    else
        cksum | awk '{print $1 "-" $2}'
    fi
}

container_fingerprint() {
    # $1 = id
    {
        cvar "$1" IMAGE
        echo "$NETWORK_NAME"
        echo "$TZ"
        "app_fingerprint_$1"
    } | fingerprint
}

fingerprint_file() {
    # $1 = container name
    echo "$QPKG_ROOT/.conf-$1"
}

# No record (container created by an older version) counts as unchanged:
# the container is adopted as-is and recorded on this start.
config_changed() {
    # $1 = container name, $2 = fingerprint
    [ -f "$(fingerprint_file "$1")" ] && [ "$(cat "$(fingerprint_file "$1")" 2>/dev/null)" != "$2" ]
}

save_fingerprint() {
    echo "$2" > "$(fingerprint_file "$1")"
}

# True if the container runs a different image than the reference now
# resolves to locally (a floating tag that was pulled again).
image_changed() {
    # $1 = container name, $2 = reference
    CUR=$("$DOCKER" inspect -f '{{.Image}}' "$1" 2>/dev/null)
    NEW=$("$DOCKER" image inspect -f '{{.Id}}' "$(local_ref "$2")" 2>/dev/null)
    [ -n "$CUR" ] && [ -n "$NEW" ] && [ "$CUR" != "$NEW" ]
}

# ================================================================ containers

# Idempotent create-or-start for container id $1. Never "docker run" over
# an existing container: that yields a name conflict, which a retry path
# (such as a GPU fallback) would misread as a real failure.
# RECREATE_RUNNING=1 also recreates a running container that changed.
run_container() {
    RC_ID="$1"
    RC_NAME=$(cvar "$RC_ID" CONTAINER_NAME)
    RC_IMG=$(cvar "$RC_ID" IMAGE)
    RC_FP=$(container_fingerprint "$RC_ID")

    if container_exists "$RC_NAME"; then
        RC_WHY=""
        if config_changed "$RC_NAME" "$RC_FP"; then
            RC_WHY="settings changed"
        elif image_changed "$RC_NAME" "$RC_IMG"; then
            RC_WHY="image changed"
        fi

        if container_running "$RC_NAME"; then
            if [ -z "$RC_WHY" ] || [ "$RECREATE_RUNNING" != "1" ]; then
                [ -f "$(fingerprint_file "$RC_NAME")" ] || save_fingerprint "$RC_NAME" "$RC_FP"
                return 0
            fi
            log "Recreating '$RC_ID' ($RC_WHY); data is kept." 4
            "$DOCKER" stop -t "$STOP_TIMEOUT" "$RC_NAME" >/dev/null 2>&1
            "$DOCKER" rm -f "$RC_NAME" >/dev/null 2>&1
        elif [ -n "$RC_WHY" ]; then
            log "Recreating '$RC_ID' ($RC_WHY); data is kept." 4
            "$DOCKER" rm -f "$RC_NAME" >/dev/null 2>&1
        elif has_func "app_needs_recreate_$RC_ID" && "app_needs_recreate_$RC_ID"; then
            log "Recreating '$RC_ID' (requested by the app); data is kept." 4
            "$DOCKER" rm -f "$RC_NAME" >/dev/null 2>&1
        else
            RC_OUT=$("$DOCKER" start "$RC_NAME" 2>&1 >/dev/null) && {
                save_fingerprint "$RC_NAME" "$RC_FP"
                return 0
            }
            if [ "$RC_ID" = "$WEB_ID" ] && port_conflict "$RC_OUT"; then
                stop_landing
                sleep 5
                "$DOCKER" start "$RC_NAME" >/dev/null 2>&1 && {
                    save_fingerprint "$RC_NAME" "$RC_FP"
                    return 0
                }
            fi
            log "Existing '$RC_ID' container failed to start ($RC_OUT); recreating it (data is kept)." 2
            "$DOCKER" rm -f "$RC_NAME" >/dev/null 2>&1
        fi
    fi

    RC_DATA=$(cvar "$RC_ID" DATA_PATH)
    [ -n "$RC_DATA" ] && mkdir -p "$RC_DATA"
    [ "$RC_ID" = "$WEB_ID" ] && stop_landing

    RC_OUT=$( { use_local_image "$RC_ID"; "app_run_$RC_ID"; } 2>&1 >/dev/null)
    RC=$?
    if [ $RC -ne 0 ] && name_conflict "$RC_OUT"; then
        "$DOCKER" start "$RC_NAME" >/dev/null 2>&1 && return 0
    fi
    if [ $RC -ne 0 ] && port_conflict "$RC_OUT"; then
        "$DOCKER" rm -f "$RC_NAME" >/dev/null 2>&1
        sleep 5
        RC_OUT=$( { use_local_image "$RC_ID"; "app_run_$RC_ID"; } 2>&1 >/dev/null)
        RC=$?
    fi
    if [ $RC -ne 0 ] && has_func "app_run_fallback_$RC_ID"; then
        "$DOCKER" rm -f "$RC_NAME" >/dev/null 2>&1
        RC_OUT=$( { use_local_image "$RC_ID"; "app_run_fallback_$RC_ID" "$RC_OUT"; } 2>&1 >/dev/null)
        RC=$?
    fi
    if [ $RC -eq 0 ]; then
        save_fingerprint "$RC_NAME" "$RC_FP"
    else
        log "Failed to start the '$RC_ID' container: $RC_OUT" 1
    fi
    return $RC
}

# Disabled containers are stopped, not removed, so switching one back on
# reuses it. An optional container that fails is logged and skipped.
run_all() {
    for C in $CONTAINERS; do
        if ! container_enabled "$C"; then
            RA_NAME=$(cvar "$C" CONTAINER_NAME)
            if container_running "$RA_NAME"; then
                "$DOCKER" stop -t "$STOP_TIMEOUT" "$RA_NAME" >/dev/null 2>&1
                log "Stopped '$C' because it is switched off in $CONF_NAME." 4
            fi
            continue
        fi
        run_container "$C" && continue
        container_optional "$C" || return 1
        log "Optional container '$C' did not start; $DISPLAY_NAME runs without it." 2
    done
}

# Running as far as QTS is concerned: every enabled, required container.
all_running() {
    for C in $(enabled_containers); do
        container_optional "$C" && continue
        container_running "$(cvar "$C" CONTAINER_NAME)" || return 1
    done
}

# ================================================================ status page
# A throwaway busybox httpd occupies WEB_PORT while images download, so
# App Center's "Open" never hits connection-refused on a fresh install.

start_landing() {
    "$DOCKER" rm -f "$LANDING_NAME" >/dev/null 2>&1
    if ! image_present "$LANDING_IMAGE"; then
        "$DOCKER" pull "$LANDING_IMAGE" >> "$PULL_LOG" 2>&1 || {
            log "Could not pull $LANDING_IMAGE for the status page; the image download continues regardless." 2
            return 1
        }
    fi
    # Host networking on purpose: a dockerd-managed -p binding can leak
    # (dockerd keeps the port bound after the container is force-removed
    # during daemon churn, blocking the real app until the daemon
    # restarts). With --net host the socket dies with httpd.
    "$DOCKER" run -d \
        --name "$LANDING_NAME" \
        --net host \
        -v "$WEB_DIR":/www:ro \
        "$LANDING_IMAGE" httpd -f -p "$WEB_PORT" -h /www >/dev/null 2>&1
}

stop_landing() {
    "$DOCKER" rm -f "$LANDING_NAME" >/dev/null 2>&1
    # A daemon hiccup can orphan the host-net httpd while removing its
    # container record, leaving WEB_PORT bound by a process docker no
    # longer knows. Match the exact cmdline (port followed by space or end
    # of line, so 819 never matches 8190). SIGKILL: httpd is PID 1 of its
    # namespace and ignores SIGTERM.
    for PID in $({ ps -eo pid,args 2>/dev/null || ps w 2>/dev/null; } | grep -E "httpd -f -p $WEB_PORT( |\$)" | grep -v grep | awk '{print $1}'); do
        kill -9 "$PID" 2>/dev/null
    done
}

# ================================================================ flow

# Start now if the engine is up; otherwise finish in a detached job once
# it is. Never block the QTS boot sequence, and never mistake "daemon not
# up yet" for "images missing".
start_or_defer() {
    if docker_ready; then
        do_start
    else
        write_status "waiting-for-container-station"
        log "Container Station is not ready yet; $DISPLAY_NAME will start automatically as soon as it is." 4
        spawn_detached _bg_start
    fi
}

# A container can start without its image only if it already exists and
# will not be recreated (docker start needs no image, docker run does).
# At boot the object store may list containers before their images, so
# existing containers must not send the app into the download path; but a
# container that has to be recreated for a new pin must not either, or
# docker run pulls the image in the foreground and App Center waits.
container_startable() {
    image_present "$(cvar "$1" IMAGE)" && return 0
    CS_NAME=$(cvar "$1" CONTAINER_NAME)
    container_exists "$CS_NAME" || return 1
    ! config_changed "$CS_NAME" "$(container_fingerprint "$1")"
}

all_startable() {
    for C in $(enabled_containers); do
        container_startable "$C" || return 1
    done
}

do_start() {
    ensure_network
    write_status "starting"
    if all_startable; then
        stop_landing
        run_all || { write_status "error"; return 1; }
        touch "$QPKG_ROOT/.images-ready"
        write_status "running"
        report_digests
        log "$DISPLAY_NAME started (port $WEB_PORT)." 4
    else
        write_status "downloading-image"
        start_landing
        log "Images not present yet. Container Station is downloading them in the background; the app starts automatically when ready (progress: $PULL_LOG)." 4
        spawn_detached _bg_pull
    fi
}

do_stop() {
    for C in $(containers_reversed); do
        N=$(cvar "$C" CONTAINER_NAME)
        container_exists "$N" && "$DOCKER" stop -t "$STOP_TIMEOUT" "$N" >/dev/null 2>&1
    done
    stop_landing
    write_status "stopped"
    log "$DISPLAY_NAME stopped." 4
}

do_remove() {
    for C in $(containers_reversed); do
        N=$(cvar "$C" CONTAINER_NAME)
        "$DOCKER" rm -f "$N" >/dev/null 2>&1
        rm -f "$(fingerprint_file "$N")"
    done
    stop_landing
    rm -f "$QPKG_ROOT/.images-ready"
    "$DOCKER" network rm "$NETWORK_NAME" >/dev/null 2>&1
    log "Containers and network removed. Application data was kept." 4
}

# Pull what the configuration references, then recreate only the
# containers whose image or settings actually changed. With pinned
# digests this changes nothing until someone edits images.lock or the
# .conf file, which is the point.
do_update() {
    log "Updating $DISPLAY_NAME images..." 4
    pull_images || { log "Image update failed; keeping current containers. See $PULL_LOG." 1; return 1; }
    ensure_network
    stop_landing
    RECREATE_RUNNING=1
    if run_all; then
        write_status "running"
        report_digests
        log "Update finished (data kept)." 4
    else
        write_status "error"
        log "Images updated but a container failed to start, so the app is not running. Fix the cause (see $LOG_FILE), then restart the app." 1
        return 1
    fi
}

# Report whether each pinned tag has moved upstream. Pulls the bare tag
# (the download you would need anyway) but never touches containers.
do_update_check() {
    CHK_RC=0
    for C in $(enabled_containers); do
        IMG=$(cvar "$C" IMAGE)
        PIN=$(ref_digest "$IMG")
        TAGREF="${IMG%@*}"
        case "${TAGREF##*/}" in *:*) ;; *) TAGREF="$TAGREF:latest" ;; esac
        if ! "$DOCKER" pull "$TAGREF" >> "$PULL_LOG" 2>&1; then
            echo "$C: cannot pull $TAGREF (see $PULL_LOG)"
            CHK_RC=1
            continue
        fi
        NOW=$(local_repo_digest "$TAGREF")
        if [ -z "$PIN" ]; then
            echo "$C: unpinned $TAGREF, currently $NOW"
        elif [ "$PIN" = "$NOW" ]; then
            echo "$C: pinned $TAGREF, up to date ($PIN)"
        else
            echo "$C: pinned $TAGREF, upstream moved"
            echo "    pinned  : $PIN"
            echo "    upstream: $NOW"
        fi
    done
    return $CHK_RC
}

do_status() {
    if all_running; then
        echo "$QPKG_NAME is running (port $WEB_PORT)."
        exit 0
    fi
    echo "$QPKG_NAME is not running."
    exit 1
}

do_diag() {
    echo "--- package ---"
    echo "QPKG_NAME=$QPKG_NAME"
    echo "QPKG_ROOT=$QPKG_ROOT"
    echo "version=$("$SBIN/getcfg" "$QPKG_NAME" Version -f "$CONF" 2>/dev/null)"
    echo "uid=$(id -u)"
    echo "--- docker ---"
    echo "docker CLI: ${DOCKER:-not found}"
    [ -n "$DOCKER" ] && "$DOCKER" version 2>&1 | head -n 6
    echo "--- registry DNS ---"
    HOSTS=""
    for IMG in $(all_images) "$LANDING_IMAGE"; do
        H=$(ref_registry "$IMG")
        case " $HOSTS " in *" $H "*) ;; *) HOSTS="$HOSTS $H" ;; esac
    done
    for H in $HOSTS $DIAG_HOSTS; do
        if nslookup "$H" >/dev/null 2>&1; then echo "$H: resolves"; else echo "$H: DOES NOT RESOLVE"; fi
    done
    echo "--- images ---"
    for C in $CONTAINERS; do
        IMG=$(cvar "$C" IMAGE)
        container_enabled "$C" || { echo "$C: disabled ($IMG)"; continue; }
        echo "$C: $IMG$(container_optional "$C" && echo " (optional)")"
        echo "    state : $(digest_state "$IMG")"
        echo "    local : $(local_repo_digest "$IMG")"
    done
    echo "--- containers ---"
    for C in $CONTAINERS; do
        N=$(cvar "$C" CONTAINER_NAME)
        if ! container_enabled "$C"; then
            echo "$C: $N (disabled$(container_exists "$N" && echo ", container kept"))"
        elif container_exists "$N"; then
            echo "$C: $N $("$DOCKER" inspect -f 'running={{.State.Running}} created={{.Created}} restarts={{.RestartCount}}' "$N" 2>/dev/null)"
            FPF=$(fingerprint_file "$N")
            if [ ! -f "$FPF" ]; then
                echo "    settings: no record yet"
            elif [ "$(cat "$FPF")" = "$(container_fingerprint "$C")" ]; then
                echo "    settings: applied"
            else
                echo "    settings: changed, applied on next restart"
            fi
        else
            echo "$C: $N (absent)"
        fi
    done
    container_exists "$LANDING_NAME" && echo "status page container: $LANDING_NAME present"
    echo "--- network ---"
    "$DOCKER" network inspect -f '{{.Name}} {{.Driver}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME" 2>&1
    echo "--- configuration ---"
    echo "WEB_PORT=$WEB_PORT"
    echo "TZ=$TZ"
    for C in $CONTAINERS; do
        D=$(cvar "$C" DATA_PATH)
        [ -n "$D" ] && echo "$(id_upper "$C")_DATA_PATH=$D"
    done
    has_func app_diag && { echo "--- app ---"; app_diag; }
    echo "--- last pull log ($PULL_LOG) ---"
    tail -n 20 "$PULL_LOG" 2>/dev/null || echo "(no pull log yet)"
    echo "--- last service log ($LOG_FILE) ---"
    tail -n 20 "$LOG_FILE" 2>/dev/null || echo "(no service log yet)"
    return 0
}

# ================================================================ main

main() {
    DOCKER=$(find_docker)
    load_conf

    if [ -n "$CONF_ERR" ]; then
        log "No image configured for:$CONF_ERR. Check images.lock and $APP_CONF." 1
        write_status "error"
        echo "No image configured for:$CONF_ERR" >&2
        exit 1
    fi

    if [ -z "$DOCKER" ]; then
        # Not fatal for start/restart: at boot the CLI may not be
        # reachable yet; start_or_defer waits in the background.
        case "$1" in
            start|restart|_bg_start) ;;
            *)
                log "Container Station docker CLI not found. Please install or enable Container Station and restart this app." 1
                write_status "no-container-engine"
                ;;
        esac
    fi

    # Administrators can drive docker without root, so a plain-user run
    # appears to work while write_log and the qpkg.conf update silently
    # fail. Say so up front.
    case "$1" in
        start|stop|restart|update|remove)
            if [ "$(id -u)" != "0" ]; then
                echo "Warning: run this as admin (e.g. sudo $0 $1). Without root the QTS event log and the App Center link port cannot be updated." >&2
                log "$1 was run without root (uid $(id -u)); QTS event log entries and the App Center link port may not be updated." 2
            fi
            ;;
    esac

    case "$1" in
        start|restart|_bg_start) sync_web_port ;;
    esac

    case "$1" in
        start)
            ENABLED=$("$SBIN/getcfg" "$QPKG_NAME" Enable -u -d FALSE -f "$CONF")
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
            all_images_present || pull_images
            ;;
        bgpull)
            all_images_present || spawn_detached _bg_pull
            ;;
        update)
            if [ "$2" = "--check" ]; then
                do_update_check || exit 1
            else
                do_update || exit 1
            fi
            ;;
        remove)
            do_remove
            ;;
        diag)
            do_diag
            ;;
        _bg_start)
            if wait_docker_ready; then
                # The daemon answers ps/info while its object store is
                # still loading (observed for 2+ minutes after boot). The
                # .images-ready marker proves this app ran before, so
                # absence can only mean "not loaded yet": keep waiting
                # instead of falling into the download path.
                FIRST_ID=$(enabled_containers)
                FIRST_ID="${FIRST_ID# }"
                FIRST_ID="${FIRST_ID%% *}"
                SETTLE=0
                LIMIT=60
                [ -f "$QPKG_ROOT/.images-ready" ] && LIMIT="$CS_WAIT_TIMEOUT"
                while [ "$SETTLE" -lt "$LIMIT" ]; do
                    container_exists "$(cvar "$FIRST_ID" CONTAINER_NAME)" && break
                    image_present "$(cvar "$FIRST_ID" IMAGE)" && break
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
            if ! wait_docker_ready; then
                write_status "no-container-engine"
                log "Container Station did not become ready within ${CS_WAIT_TIMEOUT}s; image download not started. Start this app from App Center once Container Station is running." 1
                exit 1
            fi
            PIDFILE="$LOG_DIR/pull.pid"
            if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
                exit 0
            fi
            echo $$ > "$PIDFILE"
            # A result left over from an earlier pull must never be read
            # as this pull's outcome.
            rm -f "$LOG_DIR/pull.rc"
            write_status "downloading-image"
            container_exists "$LANDING_NAME" || start_landing
            # Registry access and DNS can still be settling after boot.
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
                # settings may have changed while downloading
                load_conf
                ensure_network
                stop_landing
                if run_all; then
                    touch "$QPKG_ROOT/.images-ready"
                    write_status "running"
                    report_digests
                    log "Images downloaded; $DISPLAY_NAME created and started (port $WEB_PORT)." 4
                else
                    write_status "error"
                    log "Images downloaded but a container failed to start. See $LOG_FILE." 1
                fi
            else
                tail -n 15 "$PULL_LOG" > "$WEB_DIR/pull-progress.txt" 2>/dev/null
                write_status "pull-failed"
                log "Downloading the images failed. Run '/etc/init.d/$SCRIPT_NAME diag' to check DNS and registry access, then restart the app. Details: $PULL_LOG" 1
            fi
            ;;
        *)
            echo "Usage: $0 {start|stop|restart|status|pull|bgpull|update [--check]|remove|diag}"
            exit 1
            ;;
    esac
    exit 0
}
