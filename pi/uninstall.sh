#!/usr/bin/env bash
# nanoviz — Raspberry Pi teardown (reverses pi/setup.sh).
#
# Usage:
#   sudo ./pi/uninstall.sh                  # remove service + Quadlet + polkit rule
#   sudo ./pi/uninstall.sh --name=foo       # uninstall a non-default instance
#   sudo ./pi/uninstall.sh --remove-image   # also `podman rmi` the nanoviz image
#   sudo ./pi/uninstall.sh --remove-aloop   # also remove snd-aloop module config
#   sudo ./pi/uninstall.sh --purge          # also delete the config dir (loses
#                                           # nl_devices.toml pairing tokens)
#
# Always preserved unless --purge:
#   ~/.config/<name>/        (compose.yaml, config/config.toml, config/nl_devices.toml)
#
# Always removed:
#   /etc/containers/systemd/<name>.container
#   /etc/polkit-1/rules.d/50-<name>.rules
#   the running <name>.service + container

set -euo pipefail

# ---------- defaults ----------
INSTANCE_NAME="nanoviz"
REMOVE_IMAGE=0
REMOVE_ALOOP=0
PURGE=0
CONFIG_DIR=""

TARGET_USER="${SUDO_USER:-${USER:-}}"

# ---------- arg parsing ----------
for arg in "$@"; do
    case "$arg" in
        --name=*)             INSTANCE_NAME="${arg#*=}" ;;
        --config-dir=*)       CONFIG_DIR="${arg#*=}" ;;
        --remove-image)       REMOVE_IMAGE=1 ;;
        --remove-aloop)       REMOVE_ALOOP=1 ;;
        --purge)              PURGE=1 ;;
        -h|--help)
            sed -n '2,19p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: --name must match [a-zA-Z0-9_-]+ (got: $INSTANCE_NAME)" >&2
    exit 2
fi

# ---------- helpers ----------
banner() { printf '\n[%s/6] %s\n' "$1" "$2"; }
log()    { printf '  %s\n' "$*"; }
warn()   { printf '  WARN: %s\n' "$*" >&2; }

# ---------- preflight ----------
if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null; then
        log "Re-executing under sudo..."
        exec sudo -E bash "$0" "$@"
    fi
    echo "ERROR: must run as root (or via sudo)." >&2
    exit 1
fi

# Resolve a sensible default for CONFIG_DIR mirroring setup.sh, so --purge
# knows where to look. Skip the lookup unless we're actually purging.
if (( PURGE )) && [[ -z "$CONFIG_DIR" ]]; then
    if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
        target_home="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
        if [[ -n "$target_home" && -d "$target_home" ]]; then
            CONFIG_DIR="$target_home/.config/$INSTANCE_NAME"
        fi
    fi
    if [[ -z "$CONFIG_DIR" ]]; then
        CONFIG_DIR="/etc/$INSTANCE_NAME"
    fi
fi

service_unit="${INSTANCE_NAME}.service"
quadlet_file="/etc/containers/systemd/${INSTANCE_NAME}.container"
polkit_rule="/etc/polkit-1/rules.d/50-${INSTANCE_NAME}.rules"

log "Instance:     $INSTANCE_NAME"
log "Service:      $service_unit"
log "Quadlet:      $quadlet_file"
log "Polkit rule:  $polkit_rule"
(( PURGE )) && log "Will purge:   $CONFIG_DIR"

# ---------- 1. stop the systemd service ----------
banner 1 "Stop systemd service"
if systemctl list-unit-files --type=service --all 2>/dev/null | grep -q "^${service_unit}" \
   || systemctl is-active --quiet "$service_unit" 2>/dev/null \
   || systemctl status "$service_unit" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$service_unit"; then
        systemctl stop "$service_unit" || warn "systemctl stop $service_unit returned non-zero"
        log "Stopped $service_unit."
    else
        log "$service_unit not active."
    fi
else
    log "$service_unit not present."
fi

# ---------- 2. remove Quadlet drop-in + reload generator ----------
banner 2 "Remove Quadlet drop-in"
if [[ -f "$quadlet_file" ]]; then
    rm -f "$quadlet_file"
    log "Removed $quadlet_file."
else
    log "Already absent: $quadlet_file."
fi
systemctl daemon-reload
log "systemctl daemon-reload done (generator will no longer materialize the unit)."

# ---------- 3. remove the container if still around ----------
banner 3 "Remove container"
if command -v podman >/dev/null 2>&1; then
    if podman container exists "$INSTANCE_NAME" 2>/dev/null; then
        podman rm -f "$INSTANCE_NAME" >/dev/null
        log "Removed container '$INSTANCE_NAME'."
    else
        log "No container named '$INSTANCE_NAME'."
    fi
else
    log "podman not installed; skipping container removal."
fi

# ---------- 4. remove polkit rule ----------
banner 4 "Remove polkit rule"
if [[ -f "$polkit_rule" ]]; then
    rm -f "$polkit_rule"
    log "Removed $polkit_rule."
else
    log "Already absent: $polkit_rule."
fi

# ---------- 5. optional: snd-aloop module config ----------
banner 5 "snd-aloop module config"
if (( REMOVE_ALOOP )); then
    rm -f /etc/modules-load.d/snd-aloop.conf /etc/modprobe.d/snd-aloop.conf
    log "Removed /etc/modules-load.d/snd-aloop.conf and /etc/modprobe.d/snd-aloop.conf."
    if lsmod | grep -q '^snd_aloop'; then
        if modprobe -r snd-aloop 2>/dev/null; then
            log "Unloaded snd-aloop."
        else
            warn "snd-aloop is in use; unload deferred until next reboot."
        fi
    fi
else
    log "Kept (pass --remove-aloop to remove). Loopback ALSA card will still load at boot."
fi

# ---------- 6. optional: image + config purge ----------
banner 6 "Image and config"
if (( REMOVE_IMAGE )); then
    if command -v podman >/dev/null 2>&1; then
        # Match any tag of the nanoviz image; ignore failures (e.g. image absent).
        for img in $(podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
                       | grep -E 'nanoviz:(latest|dev|[A-Za-z0-9._-]+)$' || true); do
            podman rmi -f "$img" >/dev/null 2>&1 && log "Removed image $img." \
                || warn "Could not remove $img (in use?)."
        done
    else
        log "podman not installed; skipping image removal."
    fi
else
    log "Image kept (pass --remove-image to remove)."
fi

if (( PURGE )); then
    if [[ -n "$CONFIG_DIR" && -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        log "Purged $CONFIG_DIR."
    else
        log "Config dir $CONFIG_DIR not present."
    fi
else
    log "Config kept at default location (pass --purge to remove)."
fi

# Recommend an avahi-daemon restart so any stale mDNS registration from the
# now-removed service doesn't linger and collide with future installs.
echo
echo "Suggested follow-up:"
echo "  sudo systemctl restart avahi-daemon   # clear any leaked mDNS registration"
echo "Done. To reinstall: sudo ./pi/setup.sh ${INSTANCE_NAME:+--name=$INSTANCE_NAME}"
