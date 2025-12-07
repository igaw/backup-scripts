#!/usr/bin/env bash
set -euo pipefail 

# Explenation what this script does:
# it copies backup scripts to a remote host and setups a systemd timer to run the backup script periodically.

# technical details:
# the script assumes it connects as root to the remote host and installs the backup under the user backup
# it creates the necessary directories if they do not exist
# it creates a systemd service and timer unit under the user backup to run the backup script periodically
# it enables and starts the timer unit 

# TODO add argument parser , add  verbose option
# TODO non optional argument is the remote host name
# TODO add verbose logging

# --- Configuration ---
# TODO show the defaults before running the scripts and ask if they are correct before continuing.
# TODO add default user to install
BIN_DIR="$HOME/bin"
SCRIPT_NAME="sync-borg-and-nearlyone.sh"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_DIR/backup-sync.service"
TIMER_FILE="$SYSTEMD_DIR/backup-sync.timer"
LOG_FILE="$HOME/backup-sync.log"


echo "🔧 Installing backup script and systemd timer for user: $(whoami)"

# --- Create directories ---
mkdir -p "$BIN_DIR" "$SYSTEMD_DIR"

# --- Install the main backup script ---
#  TODO  copy script with name SCRIPT_NAME to remote server


echo "✅ Backup script and systemd units installed."

# --- Check for user systemd bus ---
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    echo "⚠️  User systemd bus not found. Please run this script in a login shell."
    echo "    Example:"
    echo "        sudo -u backup -i bash /home/backup/setup-archive-tasks-v3.sh"
    echo "    Then run manually:"
    echo "        systemctl --user daemon-reload"
    echo "        systemctl --user enable --now backup-sync.timer"
    exit 0
fi

# --- Reload user systemd and enable timer ---
systemctl --user daemon-reload
systemctl --user enable --now backup-sync.timer

echo "✅ User systemd timer enabled."
echo "🪶 Logs will be written to: $LOG_FILE"
systemctl --user list-timers --all | grep backup-sync || true
