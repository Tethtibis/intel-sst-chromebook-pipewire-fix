#!/bin/sh
# ==============================================================================
# Intel Bay Trail / Braswell (Cherry Trail) SST DSP + Realtek RT5645/RT5650
# PipeWire Quantum Collapse & Capture Clock-Hijack Remediation Utility
#
# Author:  Bill Fullen (@Tethtibis)
# License: MIT
# Target:  Debian 12/13, Ubuntu 22.04/24.04+, Fedora, Arch (PipeWire + WirePlumber)
# ==============================================================================

set -eu

PW_CONF_DIR="/etc/pipewire/pipewire.conf.d"
PW_CONF_FILE="${PW_CONF_DIR}/99-cht-sst-audio-fix.conf"

WP_CONF_DIR="/etc/wireplumber/wireplumber.conf.d"
WP_CONF_FILE="${WP_CONF_DIR}/99-cht-sst-audio-fix.conf"

usage() {
    cat << 'EOF'
Usage: sudo ./apply_sst_pipewire_fix.sh [--status | --apply | --rollback]

Options:
  --status    Inspect ALSA SST PCM hardware parameters, PipeWire clock floor,
              and active WirePlumber drop-in status.
  --apply     Deploy PipeWire clock quantum floor (min-quantum 1024) and
              WirePlumber ALSA SST period/priority/suspend hardening drop-ins.
  --rollback  Remove the remediation drop-ins and restore stock PipeWire defaults.
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERROR] Root privileges required. Run with sudo." >&2
        exit 1
    fi
}

restart_user_audio() {
    target_user="${SUDO_USER:-}"
    if [ -n "${target_user}" ] && [ "${target_user}" != "root" ]; then
        target_uid="$(id -u "${target_user}")"
        if [ -d "/run/user/${target_uid}" ]; then
            echo "[INFO] Restarting PipeWire & WirePlumber for user '${target_user}' (UID ${target_uid})..."
            sudo -u "${target_user}" XDG_RUNTIME_DIR="/run/user/${target_uid}" \
                systemctl --user restart pipewire wireplumber pipewire-pulse 2>/dev/null || true
        fi
    else
        echo "[INFO] Restart your user session PipeWire services via:"
        echo "       systemctl --user restart pipewire wireplumber pipewire-pulse"
    fi
}

show_status() {
    echo "=== [1] ALSA Sound Cards ==="
    if [ -f /proc/asound/cards ]; then
        cat /proc/asound/cards
    else
        echo "No /proc/asound/cards found."
    fi

    echo ""
    echo "=== [2] Active SST / Realtek Codec PCM Status ==="
    for f in /proc/asound/card*/pcm*/sub0/status /proc/asound/card*/pcm*/sub0/hw_params; do
        if [ -f "$f" ]; then
            echo "--> $f"
            cat "$f"
        fi
    done

    echo ""
    echo "=== [3] Installed Drop-in Files ==="
    for cfg in "${PW_CONF_FILE}" "${WP_CONF_FILE}"; do
        if [ -f "${cfg}" ]; then
            echo "[PRESENT] ${cfg}"
        else
            echo "[MISSING] ${cfg}"
        fi
    done

    echo ""
    echo "=== [4] Recent Kernel SST DSP Messages ==="
    dmesg 2>/dev/null | grep -iE "intel_sst_acpi|rt5645|rt5650|cht-bsw" | tail -n 15 || true
}

apply_fix() {
    require_root
    mkdir -p "${PW_CONF_DIR}" "${WP_CONF_DIR}"

    echo "[INFO] Writing PipeWire clock floor configuration to ${PW_CONF_FILE}..."
    cat << 'EOF' > "${PW_CONF_FILE}"
# Intel Bay Trail / Braswell (Cherry Trail) SST DSP + Realtek RT5640/RT5645/RT5650
# Prevent dynamic quantum collapse below the 1008-frame (21ms @ 48kHz) hardware SST DSP period.
context.properties = {
    default.clock.rate          = 48000
    default.clock.allowed-rates = [ 48000 ]
    default.clock.quantum       = 2048
    default.clock.min-quantum   = 1024
    default.clock.max-quantum   = 4096
}
EOF
    chmod 0644 "${PW_CONF_FILE}"

    echo "[INFO] Writing WirePlumber ALSA SST hardening rules to ${WP_CONF_FILE}..."
    cat << 'EOF' > "${WP_CONF_FILE}"
# Intel Bay Trail / Braswell (Cherry Trail) SST DSP + Realtek RT5640/RT5645/RT5650
# 1. Align ALSA period-size (1008 frames) and expand capture/playback ring buffers (16 periods).
# 2. Elevate playback driver priority (2500) above capture (1500) so opening microphone/meter
#    streams (pavucontrol, VoIP, RustDesk, Steam Link) cannot hijack the master graph clock.
# 3. Disable 5-second idle suspend to prevent 'intel_sst_acpi: sst: Busy wait failed' mailbox hangs.

monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.platform-cht-bsw-.*"
      }
      {
        node.name = "~alsa_output.platform-bytcr-.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.period-size            = 1008
        api.alsa.period-num             = 16
        api.alsa.headroom               = 2048
        priority.driver                 = 2500
        priority.session                = 2500
        session.suspend-timeout-seconds = 0
        node.pause-on-idle              = false
      }
    }
  }
  {
    matches = [
      {
        node.name = "~alsa_input.platform-cht-bsw-.*"
      }
      {
        node.name = "~alsa_input.platform-bytcr-.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.period-size            = 1008
        api.alsa.period-num             = 16
        api.alsa.headroom               = 2048
        priority.driver                 = 1500
        priority.session                = 1500
        session.suspend-timeout-seconds = 0
        node.pause-on-idle              = false
      }
    }
  }
]
EOF
    chmod 0644 "${WP_CONF_FILE}"

    restart_user_audio
    echo "[SUCCESS] Intel SST PipeWire/WirePlumber remediation applied."
}

rollback_fix() {
    require_root
    echo "[INFO] Removing remediation drop-in files..."
    rm -f "${PW_CONF_FILE}" "${WP_CONF_FILE}"
    restart_user_audio
    echo "[SUCCESS] Rolled back to stock PipeWire/WirePlumber configuration."
}

case "${1:-}" in
    --status)
        show_status
        ;;
    --apply)
        apply_fix
        ;;
    --rollback)
        rollback_fix
        ;;
    *)
        usage
        exit 1
        ;;
esac
