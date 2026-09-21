#!/bin/sh
# Fail unless the build itself is pinned: every GitHub Action by a full
# commit SHA, QDK by the same commit in the workflow and the Dockerfile,
# and every container image the build or lint uses by digest. Tags on
# actions and images can be moved by their owners; images.lock already
# holds the app to this rule, and the tools that build it get the same.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0

# 1. Actions: owner/repo@<40 hex>, optionally followed by "# vX.Y.Z".
for F in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
    [ -f "$F" ] || continue
    grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' "$F" | while IFS= read -r LINE; do
        REF=$(echo "$LINE" | sed -E 's/.*uses:[[:space:]]*([^[:space:]#]+).*/\1/')
        case "$REF" in ./*) continue ;; esac
        if ! echo "$REF" | grep -Eq '@[0-9a-f]{40}$'; then
            echo "$(basename "$F"):${LINE%%:*}: action not pinned to a commit SHA: $REF" >&2
            exit 1
        fi
    done || FAIL=1
done

# 2. QDK: one 40-hex commit, identical in the workflow and the Dockerfile.
WF_REF=$(sed -n 's/^[[:space:]]*QDK_REF:[[:space:]]*"\{0,1\}\([0-9a-f]*\)"\{0,1\}[[:space:]]*$/\1/p' "$ROOT/.github/workflows/build.yml" | head -n 1)
DF_REF=$(sed -n 's/^ARG QDK_REF=\([0-9a-f]*\)[[:space:]]*$/\1/p' "$ROOT/Dockerfile" | head -n 1)
for PAIR in "build.yml:$WF_REF" "Dockerfile:$DF_REF"; do
    echo "${PAIR#*:}" | grep -Eq '^[0-9a-f]{40}$' || { echo "${PAIR%%:*}: QDK_REF is not a 40-character commit SHA (${PAIR#*:})" >&2; FAIL=1; }
done
[ "$WF_REF" = "$DF_REF" ] || { echo "QDK_REF differs: build.yml $WF_REF, Dockerfile $DF_REF" >&2; FAIL=1; }
for F in "$ROOT/.github/workflows/build.yml" "$ROOT/Dockerfile"; do
    # shellcheck disable=SC2016 # matching the literal text $QDK_REF
    grep -q 'fetch -q --depth 1 origin "\$QDK_REF"' "$F" || { echo "$(basename "$F"): QDK is not fetched at \$QDK_REF" >&2; FAIL=1; }
    if grep -q 'git clone[^|&;]*QDK' "$F"; then
        echo "$(basename "$F"): clones QDK without pinning it" >&2
        FAIL=1
    fi
done

# 3. Images used to build and lint: pinned by digest.
grep -E '^FROM ' "$ROOT/Dockerfile" | while IFS= read -r LINE; do
    echo "$LINE" | grep -Eq '@sha256:[0-9a-f]{64}' || { echo "Dockerfile: base image not pinned by digest: $LINE" >&2; exit 1; }
done || FAIL=1
grep -Eq '^SHELLCHECK[[:space:]]*:=.*@sha256:[0-9a-f]{64}' "$ROOT/Makefile" || { echo "Makefile: SHELLCHECK image not pinned by digest" >&2; FAIL=1; }

[ "$FAIL" -eq 0 ] && echo "CI pins: actions by SHA, QDK at $WF_REF, build images by digest"
exit "$FAIL"
