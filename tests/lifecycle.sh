#!/bin/sh
# shellcheck disable=SC2016,SC2034 # check() evals its single-quoted condition later
# Lifecycle test for the two-container app against the local docker
# daemon, with QTS commands stubbed out. Both containers run a small
# stand-in image (traefik/whoami answers /health) instead of the multi-GB
# Ollama and Open WebUI images; what is tested is the service script, not
# the upstream software.
#
# GPU detection and pass-through are faked through a docker wrapper that
# plays Container Station's CLI, so the result is the same on a GPU
# workstation and on a GitHub runner:
#   fake GPU "absent": docker info shows no nvidia runtime, nvidia-smi fails
#   fake GPU "broken": the runtime is reported, but --gpus makes docker run fail
#
# Usage: tests/lifecycle.sh        (TEST_PORT=18290 by default)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT="${TEST_PORT:-18290}"
PORT2=$((PORT + 1))
PREFIX="owui-test"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/owui-qpkg-test.XXXXXX")
PASS=0
FAIL=0

export QPKG_ROOT_OVERRIDE="$WORK/root"
export QPKG_CONF="$WORK/qpkg.conf"
export QTS_SBIN="$ROOT/tests/stubs"
export TEST_EVENT_LOG="$WORK/event.log"

QPKG_NAME=$(sed -n 's/^QPKG_NAME="\(.*\)"/\1/p' "$ROOT/qpkg.cfg")
APP="$QPKG_ROOT_OVERRIDE/openwebui-ollama.sh"
CONF_FILE="$QPKG_ROOT_OVERRIDE/openwebui-ollama.conf"
STATUS="$QPKG_ROOT_OVERRIDE/web/status.json"
IMAGE="traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44"
# A second pinned image for the upgrade scenario; never present at start.
ALT_IMAGE="traefik/whoami:v1.11.0@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab"
C_OLLAMA="$PREFIX-ollama"
C_WEBUI="$PREFIX-frontend"
NET="$PREFIX-net"
# v1.0.x default network name, which 2.0.0 keeps.
LEGACY_NET="owui-net"

ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

state() { sed -n 's/.*"state": "\([^"]*\)".*/\1/p' "$STATUS" 2>/dev/null; }
created() { docker inspect -f '{{.Created}}' "$1" 2>/dev/null; }
running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true; }
env_of() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null; }
http_ok() { curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$1$2"; }
gpu() { echo "$1" > "$WORK/fake-gpu"; }
logged() { grep -c "$1" "$QPKG_ROOT_OVERRIDE/logs/"*.log 2>/dev/null | awk -F: '{s += $NF} END {print s + 0}'; }

wait_for() {
    # $1 = description, $2 = condition, $3 = timeout seconds
    W=0
    while ! eval "$2"; do
        W=$((W + 1))
        [ "$W" -ge "$3" ] && { bad "$1 (timed out after $3 s)"; return 1; }
        sleep 1
    done
    ok "$1"
}

LEGACY_NET_OURS=0
cleanup() {
    docker rm -f "$C_OLLAMA" "$C_WEBUI" "$C_WEBUI-landing" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    [ "$LEGACY_NET_OURS" = 1 ] && docker network rm "$LEGACY_NET" >/dev/null 2>&1
    docker rmi "$ALT_IMAGE" "${ALT_IMAGE%@*}" "${IMAGE%@*}" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

install_files() {
    # What App Center leaves in the install dir: package files, the
    # kept .conf file untouched.
    cp -R "$ROOT/shared/." "$QPKG_ROOT_OVERRIDE/"
    chmod +x "$APP"
    # The shipped pins are the real multi-GB images; point both at the
    # stand-in.
    sed -i "s|^OLLAMA_IMAGE=.*|OLLAMA_IMAGE=$1|; s|^WEBUI_IMAGE=.*|WEBUI_IMAGE=$1|" "$QPKG_ROOT_OVERRIDE/images.lock"
}

echo "== setup ($WORK)"
docker rm -f "$C_OLLAMA" "$C_WEBUI" "$C_WEBUI-landing" >/dev/null 2>&1
docker network rm "$NET" >/dev/null 2>&1
mkdir -p "$WORK/cs/bin" "$WORK/bin" "$QPKG_ROOT_OVERRIDE"
REAL_DOCKER=$(command -v docker)

# Container Station's docker CLI, with the GPU faked.
cat > "$WORK/cs/bin/docker" <<EOF
#!/bin/sh
G=\$(cat "$WORK/fake-gpu" 2>/dev/null || echo absent)
case "\$1" in
    info)
        "$REAL_DOCKER" "\$@" | grep -vi nvidia
        [ "\$G" = absent ] || echo " Runtimes: nvidia runc"
        exit 0
        ;;
    run)
        case " \$* " in *" --gpus "*)
            echo 'docker: Error response from daemon: could not select device driver "" with capabilities: [[gpu]].' >&2
            exit 125 ;;
        esac
        ;;
esac
exec "$REAL_DOCKER" "\$@"
EOF
cat > "$WORK/bin/nvidia-smi" <<EOF
#!/bin/sh
[ "\$(cat "$WORK/fake-gpu" 2>/dev/null)" = broken ]
EOF
chmod +x "$WORK/cs/bin/docker" "$WORK/bin/nvidia-smi"
export PATH="$WORK/bin:$PATH"
gpu absent

cat > "$QPKG_CONF" <<EOF
[$QPKG_NAME]
Name = $QPKG_NAME
Version = test
Enable = TRUE
Install_Path = $QPKG_ROOT_OVERRIDE
Web_Port = 3000

[container-station]
Install_Path = $WORK/cs
EOF
install_files "$IMAGE"
cp "$QPKG_ROOT_OVERRIDE/openwebui-ollama.conf.default" "$CONF_FILE"
cat >> "$CONF_FILE" <<EOF
OLLAMA_CONTAINER_NAME="$C_OLLAMA"
WEBUI_CONTAINER_NAME="$C_WEBUI"
OLLAMA_DATA_PATH="$WORK/data/ollama"
WEBUI_DATA_PATH="$WORK/data/webui"
WEBUI_EXTRA_ARGS="-e WHOAMI_PORT_NUMBER=8080"
NETWORK_NAME="$NET"
WEB_PORT="$PORT"
TZ="UTC"
STOP_TIMEOUT="1"
EOF
docker rmi "$IMAGE" "${IMAGE%@*}" "$ALT_IMAGE" "${ALT_IMAGE%@*}" >/dev/null 2>&1
docker image inspect "$IMAGE" >/dev/null 2>&1 && echo "  note: $IMAGE still present (in use elsewhere); download path not exercised"

echo "== 1. first start downloads in the background, then runs both"
"$APP" start 2>/dev/null
check "start returns with downloading-image or running" '[ "$(state)" = downloading-image ] || [ "$(state)" = running ]'
if [ "$(state)" = downloading-image ]; then
    wait_for "status page answers on port $PORT" 'http_ok "$PORT" /status.json' 30
fi
wait_for "state becomes running" '[ "$(state)" = running ]' 180
wait_for "web UI answers /health on port $PORT" 'http_ok "$PORT" /health' 30
check "ollama container runs" 'running "$C_OLLAMA"'
check "webui container runs" 'running "$C_WEBUI"'
check "status page container is gone" '! docker inspect "$C_WEBUI-landing" >/dev/null 2>&1'
check "status.json lists both containers" 'grep -q "\"id\": \"ollama\"" "$STATUS" && grep -q "\"id\": \"webui\"" "$STATUS"'
check "status.json reports the pins as verified" '[ "$(grep -c "\"digest\": \"pinned-ok\"" "$STATUS")" -ge 2 ]'
check "status.json has the GPU field" 'grep -q "GPU_MODE=auto" "$STATUS"'
check "fingerprints recorded for both" '[ -s "$QPKG_ROOT_OVERRIDE/.conf-$C_OLLAMA" ] && [ -s "$QPKG_ROOT_OVERRIDE/.conf-$C_WEBUI" ]'
check "App Center port synced" '[ "$("$QTS_SBIN/getcfg" "$QPKG_NAME" Web_Port -f "$QPKG_CONF")" = "$PORT" ]'
check "secret generated and saved" 'grep -Eq "^WEBUI_SECRET_KEY=\"?[A-Za-z0-9]{16,}" "$CONF_FILE"'
check "webui points at the local ollama" 'env_of "$C_WEBUI" | grep -qx "OLLAMA_BASE_URL=http://$C_OLLAMA:11434"'
check "no GPU detected: ollama runs CPU-only" '[ "$(docker inspect -f "{{.HostConfig.DeviceRequests}}" "$C_OLLAMA")" = "[]" ]'
check "status exits 0" '"$APP" status >/dev/null'
SECRET=$(sed -n 's/^WEBUI_SECRET_KEY=//p' "$CONF_FILE")

echo "== 2. restart without changes reuses both containers"
O1=$(created "$C_OLLAMA"); W1=$(created "$C_WEBUI")
"$APP" restart 2>/dev/null
check "running after restart" '"$APP" status >/dev/null'
check "ollama not recreated" '[ "$(created "$C_OLLAMA")" = "$O1" ]'
check "webui not recreated" '[ "$(created "$C_WEBUI")" = "$W1" ]'
check "secret unchanged" '[ "$(sed -n "s/^WEBUI_SECRET_KEY=//p" "$CONF_FILE")" = "$SECRET" ]'

echo "== 3. an Ollama setting recreates only Ollama"
echo 'OLLAMA_NUM_PARALLEL="2"' >> "$CONF_FILE"
"$APP" restart 2>/dev/null
check "ollama recreated" '[ "$(created "$C_OLLAMA")" != "$O1" ]'
check "webui not recreated" '[ "$(created "$C_WEBUI")" = "$W1" ]'
check "setting reaches the container" 'env_of "$C_OLLAMA" | grep -qx "OLLAMA_NUM_PARALLEL=2"'

echo "== 4. OLLAMA_BASE_URLS recreates only the web UI"
O2=$(created "$C_OLLAMA")
echo 'OLLAMA_BASE_URLS="http://192.0.2.10:11434;http://192.0.2.11:11434"' >> "$CONF_FILE"
"$APP" restart 2>/dev/null
check "webui recreated" '[ "$(created "$C_WEBUI")" != "$W1" ]'
check "ollama not recreated" '[ "$(created "$C_OLLAMA")" = "$O2" ]'
check "remote endpoints passed, local one appended" 'env_of "$C_WEBUI" | grep -qx "OLLAMA_BASE_URLS=http://192.0.2.10:11434;http://192.0.2.11:11434;http://$C_OLLAMA:11434"'
check "status page shows the remote endpoints" 'grep -q "192.0.2.10" "$STATUS"'

echo "== 5. ENABLE_OLLAMA=false: web UI only"
echo 'ENABLE_OLLAMA="false"' >> "$CONF_FILE"
"$APP" restart 2>/dev/null
check "app running" '[ "$(state)" = running ] && "$APP" status >/dev/null'
check "ollama stopped, not removed" 'docker inspect "$C_OLLAMA" >/dev/null 2>&1 && ! running "$C_OLLAMA"'
check "web UI no longer points at the local ollama" '! env_of "$C_WEBUI" | grep -q "^OLLAMA_BASE_URL=" && env_of "$C_WEBUI" | grep -qx "OLLAMA_BASE_URLS=http://192.0.2.10:11434;http://192.0.2.11:11434"'
check "ollama not on the status page" '! grep -q "\"id\": \"ollama\"" "$STATUS"'
check "status page says it is switched off" 'grep -q "ENABLE_OLLAMA=false" "$STATUS"'
OUT=$("$APP" diag 2>&1)
check "diag marks ollama disabled" 'echo "$OUT" | grep -q "^ollama: .*disabled"'
check "diag shows ENABLE_OLLAMA" 'echo "$OUT" | grep -qx "ENABLE_OLLAMA=false"'

echo "== 6. ENABLE_OLLAMA=true again reuses the stopped container"
sed -i 's/^ENABLE_OLLAMA=.*/ENABLE_OLLAMA="true"/' "$CONF_FILE"
"$APP" restart 2>/dev/null
check "ollama running again" 'running "$C_OLLAMA"'
check "ollama container reused" '[ "$(created "$C_OLLAMA")" = "$O2" ]'
check "web UI points at the local ollama again" 'env_of "$C_WEBUI" | grep -qx "OLLAMA_BASE_URL=http://$C_OLLAMA:11434"'
sed -i '/^OLLAMA_BASE_URLS=/d; /^ENABLE_OLLAMA=/d' "$CONF_FILE"
"$APP" restart 2>/dev/null

echo "== 7. WEBUI_PORT from a v1.0.x .conf is honoured"
sed -i "/^WEB_PORT=/d" "$CONF_FILE"
echo "WEBUI_PORT=\"$PORT2\"" >> "$CONF_FILE"
"$APP" restart 2>/dev/null
wait_for "web UI answers on $PORT2" 'http_ok "$PORT2" /health' 30
check "App Center port follows" '[ "$("$QTS_SBIN/getcfg" "$QPKG_NAME" Web_Port -f "$QPKG_CONF")" = "$PORT2" ]'
sed -i "/^WEBUI_PORT=/d" "$CONF_FILE"
echo "WEB_PORT=\"$PORT\"" >> "$CONF_FILE"
"$APP" restart 2>/dev/null

echo "== 8. GPU self-heal and CPU fallback"
# The runtime shows up after the container was created CPU-only (late
# registration at boot). The restart asks for a recreate with the GPU;
# here --gpus fails, so auto mode falls back to CPU.
O3=$(created "$C_OLLAMA"); W3=$(created "$C_WEBUI")
gpu broken
"$APP" restart 2>/dev/null
check "self-heal logged" '[ "$(logged "GPU is available but not attached")" -ge 1 ]'
check "fallback logged" '[ "$(logged "retrying CPU-only")" -ge 1 ]'
check "ollama recreated and running CPU-only" '[ "$(created "$C_OLLAMA")" != "$O3" ] && running "$C_OLLAMA"'
check "webui untouched" '[ "$(created "$C_WEBUI")" = "$W3" ]'
check "app running" '"$APP" status >/dev/null'
FB=$(logged "retrying CPU-only")
echo 'GPU_MODE="on"' >> "$CONF_FILE"
"$APP" restart 2>/dev/null
check "GPU_MODE=on does not fall back" '[ "$(logged "retrying CPU-only")" = "$FB" ]'
check "GPU_MODE=on failure is an error" '[ "$(state)" = error ] && ! "$APP" status >/dev/null'
sed -i 's/^GPU_MODE=.*/GPU_MODE="off"/' "$CONF_FILE"
"$APP" restart 2>/dev/null
check "GPU_MODE=off: running without self-heal" '"$APP" status >/dev/null && [ "$(logged "GPU is available but not attached")" = 1 ]'
sed -i '/^GPU_MODE=/d' "$CONF_FILE"
gpu absent
"$APP" restart 2>/dev/null

echo "== 9. update"
O4=$(created "$C_OLLAMA"); W4=$(created "$C_WEBUI")
"$APP" update 2>/dev/null
RC=$?
check "update exits 0" '[ "$RC" -eq 0 ]'
check "update with pinned digests recreates nothing" '[ "$(created "$C_OLLAMA")" = "$O4" ] && [ "$(created "$C_WEBUI")" = "$W4" ]'
OUT=$("$APP" update --check 2>&1)
check "update --check reports the pins" '[ "$(echo "$OUT" | grep -c pinned)" -ge 2 ]'

echo "== 10. diag"
OUT=$("$APP" diag 2>&1)
RC=$?
check "diag exits 0" '[ "$RC" -eq 0 ]'
for S in package docker "registry DNS" images containers network configuration app; do
    check "diag has section '$S'" 'echo "$OUT" | grep -q -- "--- $S ---"'
done
check "diag checks registry.ollama.ai" 'echo "$OUT" | grep -q "^registry.ollama.ai: "'
check "diag reports the GPU state" 'echo "$OUT" | grep -q "^GPU_MODE=auto"'

echo "== 11. stop and remove"
"$APP" stop 2>/dev/null
check "stopped" '! "$APP" status >/dev/null'
check "state stopped" '[ "$(state)" = stopped ]'
"$APP" remove 2>/dev/null
check "containers removed" '! docker inspect "$C_OLLAMA" >/dev/null 2>&1 && ! docker inspect "$C_WEBUI" >/dev/null 2>&1'
check "network removed" '! docker network inspect "$NET" >/dev/null 2>&1'
check "fingerprints removed" '[ ! -f "$QPKG_ROOT_OVERRIDE/.conf-$C_OLLAMA" ] && [ ! -f "$QPKG_ROOT_OVERRIDE/.conf-$C_WEBUI" ]'
check "configuration kept" '[ -f "$CONF_FILE" ]'
check "data kept" '[ -d "$WORK/data/ollama" ] && [ -d "$WORK/data/webui" ]'

echo "== 12. in-place upgrade from v1.0.8"
if ! git -C "$ROOT" cat-file -e v1.0.8:shared/openwebui-ollama.sh 2>/dev/null; then
    echo "  skip: tag v1.0.8 not available (shallow clone?)"
elif docker network inspect "$LEGACY_NET" >/dev/null 2>&1; then
    echo "  skip: network $LEGACY_NET already exists on this machine"
else
    LEGACY_NET_OURS=1
    rm -rf "$QPKG_ROOT_OVERRIDE" "$WORK/data"
    mkdir -p "$QPKG_ROOT_OVERRIDE/web"
    # v1.0.8 hard-codes /sbin and /etc/config/qpkg.conf.
    git -C "$ROOT" show v1.0.8:shared/openwebui-ollama.sh \
        | sed "s|/sbin/|$QTS_SBIN/|g; s|/etc/config/qpkg.conf|$QPKG_CONF|g" > "$APP"
    git -C "$ROOT" show v1.0.8:shared/web/index.html > "$QPKG_ROOT_OVERRIDE/web/index.html"
    chmod +x "$APP"
    docker pull -q "$IMAGE" >/dev/null
    docker tag "$IMAGE" "${IMAGE%@*}"
    cat > "$CONF_FILE" <<EOF
OLLAMA_IMAGE="${IMAGE%@*}"
WEBUI_IMAGE="${IMAGE%@*}"
OLLAMA_CONTAINER_NAME="$C_OLLAMA"
WEBUI_CONTAINER_NAME="$C_WEBUI"
OLLAMA_DATA_PATH="$WORK/data/ollama"
WEBUI_DATA_PATH="$WORK/data/webui"
WEBUI_EXTRA_ARGS="-e WHOAMI_PORT_NUMBER=8080"
WEBUI_PORT="$PORT"
GPU_MODE="off"
TZ="UTC"
STOP_TIMEOUT="1"
EOF
    "$APP" start 2>/dev/null
    wait_for "v1.0.8 running" 'running "$C_OLLAMA" && running "$C_WEBUI"' 60
    check "v1.0.8 uses network $LEGACY_NET" '[ "$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" "$C_WEBUI")" = "$LEGACY_NET" ]'
    check "v1.0.8 wrote its fingerprints" '[ -s "$QPKG_ROOT_OVERRIDE/.conf-$C_OLLAMA" ]'
    SECRET=$(sed -n 's/^WEBUI_SECRET_KEY=//p' "$CONF_FILE")
    O5=$(created "$C_OLLAMA"); W5=$(created "$C_WEBUI")

    # App Center: stop the old version, install the new files, run the
    # post-install bgpull, then start. The .conf file is kept; users
    # normally never set the image lines, so drop them to follow the pins.
    "$APP" stop 2>/dev/null
    sed -i '/^OLLAMA_IMAGE=/d; /^WEBUI_IMAGE=/d' "$CONF_FILE"
    install_files "$ALT_IMAGE"
    "$APP" bgpull 2>/dev/null
    T0=$(date +%s)
    "$APP" start 2>/dev/null
    T1=$(date +%s)
    check "start returns within 10 s although both images are new" '[ $((T1 - T0)) -le 10 ]'
    check "start goes to the download path" '[ "$(state)" = downloading-image ]'
    wait_for "state becomes running" '[ "$(state)" = running ]' 180
    wait_for "web UI answers on the old port" 'http_ok "$PORT" /health' 30
    check "ollama recreated once" '[ "$(created "$C_OLLAMA")" != "$O5" ]'
    check "webui recreated once" '[ "$(created "$C_WEBUI")" != "$W5" ]'
    check "both run the new pin" '[ "$(docker inspect -f "{{.Config.Image}}" "$C_OLLAMA")" = "$ALT_IMAGE" ] && [ "$(docker inspect -f "{{.Config.Image}}" "$C_WEBUI")" = "$ALT_IMAGE" ]'
    check "still on network $LEGACY_NET" '[ "$(docker inspect -f "{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" "$C_WEBUI")" = "$LEGACY_NET" ]'
    check "no second network created" '! docker network inspect openwebuiollama-net >/dev/null 2>&1'
    check "secret kept" '[ "$(sed -n "s/^WEBUI_SECRET_KEY=//p" "$CONF_FILE")" = "$SECRET" ]'
    check "exactly one recreate each" '[ "$(logged "Recreating .ollama. (settings changed)")" = 1 ] && [ "$(logged "Recreating .webui. (settings changed)")" = 1 ]'
    C6=$(created "$C_WEBUI")
    "$APP" restart 2>/dev/null
    check "second start after the upgrade recreates nothing" '[ "$(created "$C_WEBUI")" = "$C6" ]'
    "$APP" remove 2>/dev/null
    check "upgrade scenario cleaned up" '! docker network inspect "$LEGACY_NET" >/dev/null 2>&1'
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
