#!/bin/sh
set -eu

PIPE="${NANOVIZ_SHAIRPORT_METADATA_PIPE:-/tmp/shairport-sync-metadata}"

if [ ! -p "$PIPE" ]; then
    rm -f "$PIPE"
    mkfifo "$PIPE"
    chmod 0666 "$PIPE"
fi

log() { printf '[entrypoint %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# We rely on the HOST's dbus + avahi-daemon (bind-mounted via the compose
# file / Quadlet). Running our own here would race the host for the mDNS
# hostname and produce a "Host name conflict, retrying with HOST-N" loop.
if [ ! -S /var/run/dbus/system_bus_socket ]; then
    log "FATAL: /var/run/dbus/system_bus_socket missing — bind-mount the host's /var/run/dbus into the container"
    exit 1
fi

nqptp >&2 &
NQPTP_PID=$!
log "nqptp pid=$NQPTP_PID"

# -u: log to stderr instead of syslog. -vv: verbose (paired with diagnostics
# block in shairport-sync.conf). Drop -vv once we've captured the failure.
# -a NAME overrides the `general.name` in shairport-sync.conf with the user's
# chosen AirPlay display name. Set NANOVIZ_AIRPLAY_NAME in the Quadlet
# (Environment=NANOVIZ_AIRPLAY_NAME="My Speaker") or compose env to change
# what appears in the AirPlay picker; unset means the conf-file default.
if [ -n "${NANOVIZ_AIRPLAY_NAME:-}" ]; then
    log "AirPlay name override: $NANOVIZ_AIRPLAY_NAME"
    shairport-sync -u -vv -a "$NANOVIZ_AIRPLAY_NAME" >&2 &
else
    shairport-sync -u -vv >&2 &
fi
SHAIRPORT_PID=$!
log "shairport-sync pid=$SHAIRPORT_PID"

# Start nanoviz as a child (NOT exec'd) so this shell stays as PID 1 and
# the trap below can forward SIGTERM to shairport-sync on container stop.
# Without that forwarding, shairport-sync dies without deregistering from
# avahi-daemon, leaving a stale mDNS entry that causes "name collision,
# renaming to NAME #N" loops on the next container start.
nanoviz --host 0.0.0.0 --port 8787 "$@" &
NANOVIZ_PID=$!
log "nanoviz pid=$NANOVIZ_PID"

cleanup() {
    log "cleanup: stopping nanoviz=$NANOVIZ_PID shairport=$SHAIRPORT_PID nqptp=$NQPTP_PID"
    # SIGTERM shairport first so it gets a chance to call avahi_entry_group_free.
    kill -TERM "$SHAIRPORT_PID" 2>/dev/null || true
    wait "$SHAIRPORT_PID" 2>/dev/null || true
    kill -TERM "$NANOVIZ_PID" "$NQPTP_PID" 2>/dev/null || true
    wait "$NANOVIZ_PID" "$NQPTP_PID" 2>/dev/null || true
}
trap cleanup TERM INT

# Wait on nanoviz — its exit drives the container exit code. Tolerate
# non-zero exits and signal interrupts (set -e would otherwise abort here)
# so the cleanup below always runs and shairport gets a chance to
# deregister from avahi.
EXIT_CODE=0
wait "$NANOVIZ_PID" || EXIT_CODE=$?
cleanup
exit "$EXIT_CODE"
