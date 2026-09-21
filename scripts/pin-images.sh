#!/bin/sh
# Resolve image tags to digests and write them to shared/images.lock.
# Runs on the developer machine or in CI, not on the NAS.
#
#   scripts/pin-images.sh                       re-resolve every tag in the lock
#   scripts/pin-images.sh KEY=repository:tag    set or change one entry
#
# The digest is the manifest list (index) digest, so the same pin works
# on x86_64 and ARM models.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCK="$ROOT/shared/images.lock"

resolve() {
    # $1 = repository:tag  ->  sha256:...
    D=$(docker buildx imagetools inspect "$1" 2>/dev/null | awk '/^Digest:/ {print $2; exit}')
    case "$D" in
        sha256:*) echo "$D" ;;
        *) echo "cannot resolve $1 (is docker buildx available and the tag correct?)" >&2; return 1 ;;
    esac
}

set_entry() {
    # $1 = KEY, $2 = repository:tag@sha256:...
    if grep -q "^$1=" "$LOCK"; then
        TMP="$LOCK.tmp"
        awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$LOCK" > "$TMP"
        mv "$TMP" "$LOCK"
    else
        echo "$1=$2" >> "$LOCK"
    fi
}

pin() {
    # $1 = KEY, $2 = reference with or without digest
    TAGREF="${2%@*}"
    case "${TAGREF##*/}" in *:*) ;; *) echo "$1: $TAGREF has no tag; name the version explicitly" >&2; return 1 ;; esac
    DIGEST=$(resolve "$TAGREF")
    OLD=$(sed -n "s/^$1=//p" "$LOCK" | tail -n 1)
    NEW="$TAGREF@$DIGEST"
    set_entry "$1" "$NEW"
    if [ "$OLD" = "$NEW" ]; then
        echo "$1 unchanged  $NEW"
    else
        echo "$1 ${OLD:-<new>}"
        echo "   -> $NEW"
    fi
}

if [ $# -gt 0 ]; then
    for ARG in "$@"; do
        case "$ARG" in
            [A-Z]*_IMAGE=*) pin "${ARG%%=*}" "${ARG#*=}" ;;
            *) echo "expected KEY_IMAGE=repository:tag, got $ARG" >&2; exit 2 ;;
        esac
    done
else
    grep -E '^[A-Z0-9_]+_IMAGE=' "$LOCK" | while IFS='=' read -r KEY REF; do
        pin "$KEY" "$REF"
    done
fi
