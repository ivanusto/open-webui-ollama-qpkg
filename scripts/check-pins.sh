#!/bin/sh
# Fail unless every image in shared/images.lock is pinned by digest and
# every container id in the service script has an entry. Used by CI.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCK="$ROOT/shared/images.lock"
FAIL=0

[ -f "$LOCK" ] || { echo "missing $LOCK" >&2; exit 1; }

N=0
while IFS= read -r LINE; do
    case "$LINE" in ''|'#'*) continue ;; esac
    N=$((N + 1))
    if ! echo "$LINE" | grep -Eq '^[A-Z0-9_]+_IMAGE=[^@[:space:]]+:[^@/[:space:]]+@sha256:[0-9a-f]{64}$'; then
        echo "not pinned as repository:tag@sha256:<64 hex>: $LINE" >&2
        FAIL=1
    fi
done < "$LOCK"
[ "$N" -gt 0 ] || { echo "no entries in $LOCK" >&2; FAIL=1; }

for SCRIPT in "$ROOT"/shared/*.sh; do
    CONTAINERS=$(sed -n 's/^CONTAINERS="\(.*\)"/\1/p' "$SCRIPT" | head -n 1)
    for C in $CONTAINERS LANDING; do
        KEY="$(echo "$C" | tr '[:lower:]-' '[:upper:]_')_IMAGE"
        grep -q "^$KEY=" "$LOCK" || { echo "$(basename "$SCRIPT"): no $KEY in images.lock" >&2; FAIL=1; }
    done
done

[ "$FAIL" -eq 0 ] && echo "images.lock: $N entries, all pinned"
exit "$FAIL"
