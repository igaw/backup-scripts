#!/usr/bin/env bash
set -euo pipefail

# Explanation: This script copies backup scripts to a remote host and sets up a systemd timer to run the backup script periodically.
# It connects as root to the remote host and installs the backup under the specified user (default: backup).
# It creates necessary directories, systemd service and timer units, enables and starts the timer.

# --- Argument parsing ---
usage() {
    echo "Usage: $0 [-u user] [-v] REMOTE_HOST"
    echo "  -u user      User to install under on remote host (default: backup)"
    echo "  -v           Verbose output"
    echo "  REMOTE_HOST  (required) Hostname or IP of the remote server"
    exit 1
}

VERBOSE=0
INSTALL_USER="backup"
while getopts ":u:v" opt; do
  case $opt in
    u) INSTALL_USER="$OPTARG" ;;
    v) VERBOSE=1 ;;
    *) usage ;;
  esac
done
shift $((OPTIND -1))

if [[ $# -ne 1 ]]; then
    usage
fi
REMOTE_HOST="$1"

# --- Configuration ---
BIN_DIR="/home/$INSTALL_USER/bin"
SCRIPT_NAME="sync-borg-and-nearlyone.sh"
SYSTEMD_DIR="/home/$INSTALL_USER/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_DIR/backup-sync.service"
TIMER_FILE="$SYSTEMD_DIR/backup-sync.timer"
LOG_FILE="/home/$INSTALL_USER/backup-sync.log"

# --- Show defaults and confirm ---
echo "Configuration:"
echo "  Remote host:     $REMOTE_HOST"
echo "  Install user:    $INSTALL_USER"
echo "  Script name:     $SCRIPT_NAME"
echo "  Bin dir:         $BIN_DIR"
echo "  Systemd dir:     $SYSTEMD_DIR"
echo "  Log file:        $LOG_FILE"
echo
read -p "Continue with these settings? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# --- Verbose logging function ---
vlog() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo "[VERBOSE] $*"
    fi
}

echo "🔧 Installing backup script and systemd timer for user: $INSTALL_USER on $REMOTE_HOST"

# --- Copy script to remote server ---
vlog "Copying $SCRIPT_NAME to $REMOTE_HOST:$BIN_DIR/"
ssh root@"$REMOTE_HOST" "mkdir -p '$BIN_DIR'"
scp "$(dirname "$0")/$SCRIPT_NAME" root@"$REMOTE_HOST":"$BIN_DIR/"
ssh root@"$REMOTE_HOST" "chown $INSTALL_USER:$INSTALL_USER '$BIN_DIR/$SCRIPT_NAME' && chmod 700 '$BIN_DIR/$SCRIPT_NAME'"

# --- Create systemd directories on remote ---
vlog "Creating systemd user dir $SYSTEMD_DIR on $REMOTE_HOST"
ssh root@"$REMOTE_HOST" "mkdir -p '$SYSTEMD_DIR' && chown -R $INSTALL_USER:$INSTALL_USER '/home/$INSTALL_USER/.config'"

# --- Copy systemd unit files (assume they exist locally) ---
for unit in backup-sync.service backup-sync.timer; do
    vlog "Copying $unit to $REMOTE_HOST:$SYSTEMD_DIR/"
    scp "$SYSTEMD_DIR/$unit" root@"$REMOTE_HOST":"$SYSTEMD_DIR/"
    ssh root@"$REMOTE_HOST" "chown $INSTALL_USER:$INSTALL_USER '$SYSTEMD_DIR/$unit'"
done

# --- Enable and start timer as the install user ---
vlog "Enabling and starting timer on $REMOTE_HOST as $INSTALL_USER"
ssh root@"$REMOTE_HOST" "sudo -u $INSTALL_USER bash -c '
    export XDG_RUNTIME_DIR="/run/user/$(id -u $INSTALL_USER)"
    systemctl --user daemon-reload
    systemctl --user enable --now backup-sync.timer
    systemctl --user list-timers --all | grep backup-sync || true
'"

echo "✅ Backup script and systemd units installed and timer enabled on $REMOTE_HOST."
echo "🪶 Logs will be written to: $LOG_FILE on $REMOTE_HOST."
