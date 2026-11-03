#!/bin/sh
# Runs one heavy command under the host-wide lock shared with the iOS and other agents
# (iOS #27): waits while another run holds it, writes a holder line naming this run, and
# sets CASSINI_HEAVY_LOCK_HELD=1 so iOS scripts called inside do not wait for it again.
# Usage: scripts/heavy.sh <command> [args...]
set -eu
[ $# -gt 0 ] || { echo "usage: $0 <command> [args...]" >&2; exit 2; }
lock="${CASSINI_HEAVY_LOCK:-$HOME/.cassini-heavy.lock}"
if [ "${CASSINI_HEAVY_LOCK_HELD:-}" = 1 ]; then exec "$@"; fi
echo "taking the host lock $lock (waits while another run holds it)" >&2
exec env CASSINI_HEAVY_LOCK_HELD=1 CASSINI_HEAVY_NOTE="cassini-mac ($(basename "$1") ${2:-}, pid $$, since $(date '+%Y-%m-%d %H:%M:%S'))" \
    /usr/bin/lockf -k -t $(( ${CASSINI_LOCK_MINUTES:-60} * 60 )) "$lock" \
    /bin/sh -c 'printf "%s\n" "$CASSINI_HEAVY_NOTE" > "$0"; status=0; "$@" || status=$?; : > "$0"; exit $status' "$lock" "$@"
