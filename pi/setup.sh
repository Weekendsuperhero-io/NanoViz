#!/usr/bin/env bash
# NanoViz — Raspberry Pi container setup (podman only).
#
# Usage:
#   sudo ./pi/setup.sh                      # full install + deploy
#   curl -fsSL https://raw.githubusercontent.com/Weekendsuperhero-io/nanoviz/main/pi/setup.sh | sudo bash
#
# Flags:
#   --name=NAME           instance name (default "nanoviz"). Controls the
#                         systemd unit (NAME.service), container name, Quadlet
#                         filename (NAME.container), polkit rule, and the
#                         default config dir (~/.config/NAME). Use a distinct
#                         name to run multiple independent instances on one host.
#   --no-systemd          skip writing/enabling the systemd service
#   --no-deploy           host prep only (don't pull/start the container)
#   --force-compose       overwrite the staged compose.yaml if it exists
#   --config-dir=DIR      override the default config dir
#   --image-tag=TAG       container image tag (default: "dev" on non-main git
#                         branches, "latest" otherwise)
#   --airplay-name=NAME   AirPlay display name advertised on mDNS (the name
#                         that appears in the iPhone/Mac AirPlay picker).
#                         Default leaves the image's built-in value. Spaces
#                         are allowed; quote the value when calling.

set -euo pipefail

# ---------- defaults ----------
ENABLE_SYSTEMD=1
DEPLOY=1
FORCE_COMPOSE=0
CONFIG_DIR=""           # resolved after preflight; "" means "pick default"
IMAGE_TAG=""
INSTANCE_NAME="nanoviz"
AIRPLAY_NAME=""
COMPOSE_URL="https://raw.githubusercontent.com/Weekendsuperhero-io/nanoviz/main/containers/compose.yaml"
QUADLET_URL="https://raw.githubusercontent.com/Weekendsuperhero-io/nanoviz/main/containers/nanoviz.container"

TARGET_USER="${SUDO_USER:-${USER:-}}"
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
fi

# ---------- arg parsing ----------
for arg in "$@"; do
    case "$arg" in
        --no-systemd)         ENABLE_SYSTEMD=0 ;;
        --no-deploy)          DEPLOY=0 ;;
        --force-compose)      FORCE_COMPOSE=1 ;;
        --config-dir=*)       CONFIG_DIR="${arg#*=}" ;;
        --image-tag=*)        IMAGE_TAG="${arg#*=}" ;;
        --name=*)
            INSTANCE_NAME="${arg#*=}"
            if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo "ERROR: --name must match [a-zA-Z0-9_-]+ (got: $INSTANCE_NAME)" >&2
                exit 2
            fi
            ;;
        --airplay-name=*)
            AIRPLAY_NAME="${arg#*=}"
            # mDNS rejects control characters and very long names. Spaces are
            # fine. Strip leading/trailing whitespace; reject anything obvious.
            AIRPLAY_NAME="${AIRPLAY_NAME#"${AIRPLAY_NAME%%[![:space:]]*}"}"
            AIRPLAY_NAME="${AIRPLAY_NAME%"${AIRPLAY_NAME##*[![:space:]]}"}"
            if [[ -z "$AIRPLAY_NAME" || ${#AIRPLAY_NAME} -gt 63 || "$AIRPLAY_NAME" == *$'\n'* ]]; then
                echo "ERROR: --airplay-name must be 1-63 printable chars, no newlines." >&2
                exit 2
            fi
            ;;
        -h|--help)
            sed -n '2,23p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

# ---------- helpers ----------
banner() { printf '\n[%s/9] %s\n' "$1" "$2"; }
log()    { printf '  %s\n' "$*"; }
warn()   { printf '  WARN: %s\n' "$*" >&2; }
die()    { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Pick the container image tag. Explicit --image-tag wins. Otherwise, if the
# script is running from a git checkout, default to "dev" on non-main branches
# so feature-branch installs pull the CI :dev tag instead of :latest (= main).
detect_image_tag() {
    [[ -n "$IMAGE_TAG" ]] && { echo "$IMAGE_TAG"; return; }
    if [[ -n "$SCRIPT_DIR" ]] && git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        local branch
        branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo)"
        if [[ -n "$branch" && "$branch" != "main" && "$branch" != "HEAD" ]]; then
            echo "dev"
            return
        fi
    fi
    echo "latest"
}

# ---------- preflight ----------
[[ "$(uname -s)" == "Linux" ]] || die "This script targets Linux (Raspberry Pi OS / Debian)."
command -v apt-get >/dev/null   || die "apt-get not found. This script targets Debian-based hosts."
command -v systemctl >/dev/null || die "systemctl not found. systemd is required."

if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null; then
        log "Re-executing under sudo..."
        exec sudo -E bash "$0" "$@"
    fi
    die "Must run as root (or via sudo)."
fi

TARGET_HOME=""
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    warn "No non-root \$SUDO_USER detected; group memberships will be skipped."
    TARGET_USER=""
else
    # We were re-exec'd under sudo, so $HOME is root's. Look up the real user's
    # home directly so config defaults land in their home, not /root.
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        warn "Could not resolve home directory for $TARGET_USER; falling back to /etc."
        TARGET_HOME=""
    fi
fi

# Resolve CONFIG_DIR default: invoking user's XDG config when possible,
# system-wide /etc otherwise. Explicit --config-dir= always wins. The
# instance name is part of the path so multiple --name= installs don't share
# config and device files.
if [[ -z "$CONFIG_DIR" ]]; then
    if [[ -n "$TARGET_HOME" ]]; then
        CONFIG_DIR="$TARGET_HOME/.config/$INSTANCE_NAME"
    else
        CONFIG_DIR="/etc/$INSTANCE_NAME"
    fi
fi
log "Instance name: $INSTANCE_NAME"
log "Config dir:    $CONFIG_DIR"

# Warn (but don't migrate) if an old /etc install would be left orphaned.
if [[ "$CONFIG_DIR" != "/etc/$INSTANCE_NAME" && -f "/etc/$INSTANCE_NAME/config/config.toml" ]]; then
    warn "/etc/$INSTANCE_NAME/config/config.toml exists. New default is $CONFIG_DIR;"
    warn "re-run with --config-dir=/etc/$INSTANCE_NAME to keep using the old layout."
fi

IMAGE_TAG="$(detect_image_tag)"
log "Using container image tag: $IMAGE_TAG"

# ---------- 1. install OS packages ----------
banner 1 "Install OS packages"
NEED_INSTALL=()
for pkg in podman podman-compose alsa-utils ca-certificates curl; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        NEED_INSTALL+=("$pkg")
    fi
done
if (( ${#NEED_INSTALL[@]} )); then
    log "Installing: ${NEED_INSTALL[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${NEED_INSTALL[@]}"
else
    log "All packages already installed."
fi

# Decide which compose invocation to use. Prefer the v5+ plugin (`podman compose`)
# and fall back to the legacy standalone `podman-compose` binary.
if podman compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(podman compose)
elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(podman-compose)
else
    die "Neither 'podman compose' nor 'podman-compose' is available after install."
fi
log "Using compose: ${COMPOSE_CMD[*]}"

# ---------- 2. group memberships ----------
banner 2 "Group memberships"
if [[ -n "$TARGET_USER" ]]; then
    current_groups="$(id -nG "$TARGET_USER" 2>/dev/null || echo "")"
    # audio  — ALSA device access for native runs
    # render — some Pi GPU/audio paths use it
    # systemd-journal — read system journal without sudo (`journalctl -fu nanoviz`)
    for grp in audio render systemd-journal; do
        if getent group "$grp" >/dev/null; then
            if [[ " $current_groups " == *" $grp "* ]]; then
                log "$TARGET_USER already in '$grp'."
            else
                usermod -aG "$grp" "$TARGET_USER"
                log "Added $TARGET_USER to '$grp'."
            fi
        else
            log "Group '$grp' not present on this host; skipping."
        fi
    done
    log "Note: new group memberships take effect after next login."
else
    log "Skipped (no target user)."
fi

# ---------- 3. snd-aloop kernel module ----------
banner 3 "Configure snd-aloop kernel module"
mkdir -p /etc/modules-load.d /etc/modprobe.d
echo "snd-aloop" > /etc/modules-load.d/snd-aloop.conf
cat > /etc/modprobe.d/snd-aloop.conf <<'EOF'
options snd-aloop id=Loopback index=2 pcm_substreams=8
EOF

needs_reload=0
if lsmod | grep -q '^snd_aloop'; then
    current_id=""
    if [[ -r /sys/module/snd_aloop/parameters/id ]]; then
        current_id="$(tr -d '\0\n ' </sys/module/snd_aloop/parameters/id)"
    fi
    if [[ "$current_id" != "Loopback" ]]; then
        log "snd-aloop loaded with id='$current_id'; reloading with 'Loopback'."
        needs_reload=1
    else
        log "snd-aloop already loaded with id=Loopback."
    fi
else
    log "snd-aloop not loaded; loading now."
    needs_reload=1
fi

if (( needs_reload )); then
    modprobe -r snd-aloop 2>/dev/null || true
    if ! modprobe snd-aloop; then
        warn "modprobe snd-aloop failed. The kernel module package may be missing."
    fi
fi

if grep -q Loopback /proc/asound/cards 2>/dev/null; then
    log "Verified: 'Loopback' present in /proc/asound/cards."
else
    warn "'Loopback' card not present in /proc/asound/cards. Audio capture will fail until this is resolved."
fi

# ---------- 4. stage compose + config ----------
banner 4 "Stage compose file + config dir"
mkdir -p "$CONFIG_DIR/config"
chmod 0755 "$CONFIG_DIR" "$CONFIG_DIR/config"

# When the config lives under the invoking user's home, hand ownership back
# to them so they can edit config.toml without sudo.
if [[ -n "$TARGET_HOME" && "$CONFIG_DIR" == "$TARGET_HOME"/* ]]; then
    chown -R "$TARGET_USER:" "$CONFIG_DIR"
    log "Chowned $CONFIG_DIR to $TARGET_USER."
fi

compose_dest="$CONFIG_DIR/compose.yaml"
local_compose=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../containers/compose.yaml" ]]; then
    local_compose="$SCRIPT_DIR/../containers/compose.yaml"
fi

if [[ -f "$compose_dest" && $FORCE_COMPOSE -eq 0 ]]; then
    log "$compose_dest exists; preserving (use --force-compose to overwrite)."
elif [[ -n "$local_compose" ]]; then
    cp "$local_compose" "$compose_dest"
    log "Copied compose.yaml from local clone."
else
    if curl -fsSL "$COMPOSE_URL" -o "$compose_dest"; then
        log "Fetched compose.yaml from $COMPOSE_URL."
    else
        die "Failed to fetch $COMPOSE_URL"
    fi
fi

# Rewrite the image: tag in the staged compose. The in-repo file always pins
# :latest; the installer swaps it for whatever detect_image_tag picked.
if [[ -f "$compose_dest" && "$IMAGE_TAG" != "latest" ]]; then
    sed -i "s|\(image: ghcr.io/weekendsuperhero-io/nanoviz:\)latest|\1${IMAGE_TAG}|" \
        "$compose_dest"
fi

# ---------- 5. pull image ----------
banner 5 "Pull container image"
if (( DEPLOY )); then
    ( cd "$CONFIG_DIR" && "${COMPOSE_CMD[@]}" pull )
else
    log "Skipped (--no-deploy)."
fi

# ---------- 6. install Quadlet ----------
banner 6 "Install Podman Quadlet"
if (( DEPLOY )) && (( ENABLE_SYSTEMD )); then
    # Quadlets require podman >= 4.4 (the systemd generator that translates
    # .container files into .service units).
    podman_version="$(podman version --format '{{.Client.Version}}' 2>/dev/null || echo 0)"
    podman_major="${podman_version%%.*}"
    podman_minor_full="${podman_version#*.}"
    podman_minor="${podman_minor_full%%.*}"
    if [[ ! "$podman_major" =~ ^[0-9]+$ ]] || [[ ! "$podman_minor" =~ ^[0-9]+$ ]] \
       || (( podman_major < 4 )) \
       || (( podman_major == 4 && podman_minor < 4 )); then
        die "Podman $podman_version is too old for Quadlets (need >= 4.4). Re-run with --no-systemd to use compose, or upgrade podman."
    fi
    log "Podman $podman_version supports Quadlets."

    # Source for the Quadlet template: prefer local clone, else fetch from main.
    local_quadlet=""
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/../containers/nanoviz.container" ]]; then
        local_quadlet="$SCRIPT_DIR/../containers/nanoviz.container"
    fi

    quadlet_dir="/etc/containers/systemd"
    quadlet_dest="$quadlet_dir/${INSTANCE_NAME}.container"
    mkdir -p "$quadlet_dir"

    if [[ -n "$local_quadlet" ]]; then
        quadlet_src="$local_quadlet"
        log "Installing Quadlet from local clone."
    else
        quadlet_src="$(mktemp)"
        if ! curl -fsSL "$QUADLET_URL" -o "$quadlet_src"; then
            rm -f "$quadlet_src"
            die "Failed to fetch $QUADLET_URL"
        fi
        log "Fetched Quadlet from $QUADLET_URL."
    fi

    # Substitute the volume mount (template default: /etc/nanoviz/config),
    # the image tag (template default: :latest), and the container name
    # (template default: ContainerName=nanoviz) so multiple --name=
    # instances don't collide on the host.
    sed_args=()
    if [[ "$CONFIG_DIR" != "/etc/nanoviz" ]]; then
        sed_args+=(-e "s|^Volume=/etc/nanoviz/config:|Volume=${CONFIG_DIR}/config:|")
    fi
    if [[ "$IMAGE_TAG" != "latest" ]]; then
        sed_args+=(-e "s|^\(Image=ghcr.io/weekendsuperhero-io/nanoviz:\)latest|\1${IMAGE_TAG}|")
    fi
    if [[ "$INSTANCE_NAME" != "nanoviz" ]]; then
        sed_args+=(-e "s|^ContainerName=nanoviz$|ContainerName=${INSTANCE_NAME}|")
    fi
    if [[ -n "$AIRPLAY_NAME" ]]; then
        # Uncomment the placeholder and set the value. Escape sed metacharacters
        # in the name so spaces / regex chars survive cleanly.
        escaped_airplay_name="$(printf '%s' "$AIRPLAY_NAME" | sed 's/[\\&|]/\\&/g')"
        sed_args+=(-e "s|^#Environment=NANOVIZ_AIRPLAY_NAME=.*|Environment=NANOVIZ_AIRPLAY_NAME=${escaped_airplay_name}|")
    fi
    if (( ${#sed_args[@]} )); then
        sed "${sed_args[@]}" "$quadlet_src" > "$quadlet_dest"
        log "Rewrote Quadlet (name=$INSTANCE_NAME, config-dir=$CONFIG_DIR, image tag=$IMAGE_TAG${AIRPLAY_NAME:+, airplay-name=$AIRPLAY_NAME})."
    else
        cp "$quadlet_src" "$quadlet_dest"
    fi
    chmod 0644 "$quadlet_dest"

    # Clean up the temp file if we used one.
    [[ -z "$local_quadlet" ]] && rm -f "$quadlet_src"

    # The Quadlet generator runs at daemon-reload and turns .container files
    # into transient .service units in /run/systemd/generator/. The generator
    # honors [Install] WantedBy= itself by writing the wants symlinks, so we
    # must NOT call `systemctl enable` (which fails on generated units with
    # "Unit ... is transient or generated.").
    systemctl daemon-reload

    service_unit="${INSTANCE_NAME}.service"
    if systemctl is-active --quiet "$service_unit"; then
        systemctl restart "$service_unit"
        log "$service_unit restarted via Quadlet."
    else
        systemctl start "$service_unit"
        log "$service_unit started via Quadlet (auto-wired to default.target by the generator)."
    fi
else
    log "Skipped ($([[ $DEPLOY -eq 0 ]] && echo --no-deploy || echo --no-systemd))."
fi

# ---------- 7. polkit rule (no-sudo systemctl) ----------
banner 7 "polkit rule for no-sudo service control"
if (( ENABLE_SYSTEMD )); then
    polkit_rules_dir="/etc/polkit-1/rules.d"
    polkit_rule_file="$polkit_rules_dir/50-${INSTANCE_NAME}.rules"
    if [[ -d "$polkit_rules_dir" ]]; then
        cat >"$polkit_rule_file" <<POLKIT
// Allow members of the 'audio' group to start/stop/restart/enable/disable
// ${INSTANCE_NAME}.service without a password prompt or sudo.
// Installed by nanoviz's pi/setup.sh.
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "${INSTANCE_NAME}.service" &&
        subject.isInGroup("audio")) {
        return polkit.Result.YES;
    }
});
POLKIT
        chmod 0644 "$polkit_rule_file"
        log "Installed $polkit_rule_file (audio-group → manage ${INSTANCE_NAME}.service)."
    else
        warn "$polkit_rules_dir not present; skipping. Install 'polkitd' for no-sudo systemctl."
    fi
else
    log "Skipped (--no-systemd: no service to manage)."
fi

# ---------- 8. start (when not using systemd) ----------
banner 8 "Start container"
if (( DEPLOY )) && (( ! ENABLE_SYSTEMD )); then
    ( cd "$CONFIG_DIR" && "${COMPOSE_CMD[@]}" up -d )
    log "Container started via compose."
elif (( ! DEPLOY )); then
    log "Skipped (--no-deploy)."
else
    log "Started by Quadlet-generated ${INSTANCE_NAME}.service."
fi

# ---------- 9. final report ----------
banner 9 "Done"
host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
host_ip="${host_ip:-<pi-ip>}"

cat <<EOF

NanoViz is set up.

  Instance:      $INSTANCE_NAME
  AirPlay name:  ${AIRPLAY_NAME:-<image default ("nanoviz")>}
  Web UI:        http://${host_ip}:8787
  Config dir:    $CONFIG_DIR/config
  Devices file:  $CONFIG_DIR/config/nl_devices.toml  (host path; container sees /root/.config/nanoviz/nl_devices.toml)
  Compose file:  $compose_dest
  Quadlet:       /etc/containers/systemd/${INSTANCE_NAME}.container

Useful commands (no sudo needed once you've logged out and back in):
  journalctl -fu ${INSTANCE_NAME}                   # live logs
  systemctl status ${INSTANCE_NAME}                 # service state
  systemctl restart ${INSTANCE_NAME}                # restart
  sudo podman compose -f $CONFIG_DIR/compose.yaml pull   # update image (still needs sudo for podman)

To enable verbose shairport metadata logging:
  edit /etc/containers/systemd/${INSTANCE_NAME}.container
  uncomment the NANOVIZ_LOG_METADATA line, then
  sudo systemctl daemon-reload && systemctl restart ${INSTANCE_NAME}
  journalctl -fu ${INSTANCE_NAME} | grep META

If you were just added to new groups, log out and log back in for them to apply.
EOF
