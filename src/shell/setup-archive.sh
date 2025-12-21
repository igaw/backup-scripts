#!/usr/bin/env bash
set -euo pipefail

# Source project-wide configuration
PROJECT_CONF="$(dirname "$0")/../../project.conf"
if [[ -f "$PROJECT_CONF" ]]; then
	# shellcheck source=/dev/null
	source "$PROJECT_CONF"
else
	echo "Project config $PROJECT_CONF not found."
	exit 1
fi

# Source mail configuration for msmtp
MAIL_CONF="$(dirname "$0")/../../mail.conf"
if [[ -f "$MAIL_CONF" ]]; then
	# shellcheck source=/dev/null
	source "$MAIL_CONF"
else
	echo "Mail config $MAIL_CONF not found. Using defaults for msmtp."
fi

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
shift $((OPTIND - 1))

if [[ $# -ne 1 ]]; then
	usage
fi
REMOTE_HOST="$1"

# --- Configuration ---
# Use XDG_CONFIG_HOME or fallback to ~/.config
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/home/$INSTALL_USER/.config}"
SCRIPT_PATH="${SCRIPT_PATH:-src/shell/archive.sh}"

# Set defaults, allow override from project.conf
BIN_DIR="${BIN_DIR:-/home/$INSTALL_USER/.local/bin}"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SYSTEMD_DIR="${SYSTEMD_DIR:-$XDG_CONFIG_HOME/systemd/user}"
LOG_FILE="${LOG_FILE:-/home/$INSTALL_USER/archive.log}"

# --- Show defaults and confirm ---
echo "Configuration:"
echo "  Remote host:     $REMOTE_HOST"
echo "  Install user:    $INSTALL_USER"
echo "  Script:          $SCRIPT_PATH"
echo "  Bin dir:         $BIN_DIR"
echo "  Systemd dir:     $SYSTEMD_DIR"
echo "  Log file:        $LOG_FILE"
echo
read -r -p "Continue with these settings? [y/N]: " confirm
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

echo "🔧 Installing archive script and systemd timer for user: $INSTALL_USER on $REMOTE_HOST"

# --- Always use remote /home/$INSTALL_USER for all remote paths ---
REMOTE_HOME="/home/$INSTALL_USER"
REMOTE_BIN_DIR="$REMOTE_HOME/.local/bin"
REMOTE_CONFIG_DIR="$REMOTE_HOME/.config/archive"
REMOTE_SYSTEMD_DIR="$REMOTE_HOME/.config/systemd/user"

vlog "Copying $SCRIPT_NAME from $SCRIPT_PATH to $REMOTE_HOST:$REMOTE_BIN_DIR/"
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "mkdir -p \"$REMOTE_BIN_DIR\""
scp "$SCRIPT_PATH" root@"$REMOTE_HOST":"$REMOTE_BIN_DIR/"
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "chown $INSTALL_USER:$INSTALL_USER \"$REMOTE_BIN_DIR/$SCRIPT_NAME\" && chmod 700 \"$REMOTE_BIN_DIR/$SCRIPT_NAME\""

# --- Also copy zfs-snap.py to remote bin dir ---
ZFS_SNAP_SRC="$(dirname "$0")/../../src/python/zfs-snap.py"
vlog "Copying zfs-snap.py to $REMOTE_HOST:$REMOTE_BIN_DIR/"
scp "$ZFS_SNAP_SRC" root@"$REMOTE_HOST":"$REMOTE_BIN_DIR/"
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "chown $INSTALL_USER:$INSTALL_USER \"$REMOTE_BIN_DIR/zfs-snap.py\" && chmod 700 \"$REMOTE_BIN_DIR/zfs-snap.py\""

# --- Copy config to remote XDG_CONFIG_HOME ---
vlog "Copying project.conf to $REMOTE_HOST:$REMOTE_CONFIG_DIR/config"
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "mkdir -p \"$REMOTE_CONFIG_DIR\""
scp "$(dirname "$0")/../../archive.conf" root@"$REMOTE_HOST":"$REMOTE_CONFIG_DIR/config"
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "chown $INSTALL_USER:$INSTALL_USER \"$REMOTE_CONFIG_DIR/config\""

# --- Install .msmtprc for backup user ---
MSMTP_LOCAL="$(mktemp)"
cat >"$MSMTP_LOCAL" <<EOF
defaults
auth            on
tls             on
logfile         ~/.msmtp_default.log

account         ${MSMTP_ACCOUNT}
host            ${MSMTP_HOST}
from            ${MSMTP_FROM}
user            ${MSMTP_USER}
port            ${MSMTP_PORT}
password        ${MSMTP_PASSWORD}
EOF
vlog "Copying .msmtprc to $REMOTE_HOST:$REMOTE_HOME/.msmtprc"
scp "$MSMTP_LOCAL" root@"$REMOTE_HOST":"$REMOTE_HOME/.msmtprc"
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "chown $INSTALL_USER:$INSTALL_USER \"$REMOTE_HOME/.msmtprc\" && chmod 600 \"$REMOTE_HOME/.msmtprc\""
rm -f "$MSMTP_LOCAL"

# --- Create systemd directories on remote ---
vlog "Creating systemd user dir $REMOTE_SYSTEMD_DIR on $REMOTE_HOST"
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "mkdir -p \"$REMOTE_SYSTEMD_DIR\" && chown -R $INSTALL_USER:$INSTALL_USER '$REMOTE_HOME/.config'"

# --- Copy systemd unit files (assume they exist locally) ---

# --- Create systemd service and timer files in a temporary directory ---
LOCAL_SYSTEMD_DIR="$(mktemp -d)"
SERVICE_FILE="$LOCAL_SYSTEMD_DIR/archive.service"
TIMER_FILE="$LOCAL_SYSTEMD_DIR/archive.timer"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Run Archive Scripts
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/$SCRIPT_NAME
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=no
PrivateTmp=yes
ProtectSystem=full
ProtectHome=no
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
EOF

cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Daily Archive Scripts Execution

[Timer]
OnCalendar=03:00
RandomizedDelaySec=900
Persistent=true
AccuracySec=5min

[Install]
WantedBy=timers.target
EOF

# Use remote systemd dir based on INSTALL_USER
for unit in archive.service archive.timer; do
	local_file="$LOCAL_SYSTEMD_DIR/$unit"
	vlog "Copying $unit to $REMOTE_HOST:$REMOTE_SYSTEMD_DIR/"
	scp "$local_file" root@"$REMOTE_HOST":"$REMOTE_SYSTEMD_DIR/"
	# shellcheck disable=SC2029
	ssh root@"$REMOTE_HOST" "chown $INSTALL_USER:$INSTALL_USER \"$REMOTE_SYSTEMD_DIR/$unit\""
done

# Clean up temporary directory
rm -rf "$LOCAL_SYSTEMD_DIR"

# --- Enable and start timer as the install user ---
vlog "Enabling and starting timer on $REMOTE_HOST as $INSTALL_USER"
# Get remote UID for INSTALL_USER
# shellcheck disable=SC2029
REMOTE_UID=$(ssh root@"$REMOTE_HOST" "id -u $INSTALL_USER")
# shellcheck disable=SC2029
ssh root@"$REMOTE_HOST" "sudo -u $INSTALL_USER bash -c '
# shellcheck disable=SC2046,SC2086
	export XDG_RUNTIME_DIR=\"/run/user/$REMOTE_UID\"
	systemctl --user daemon-reload
	systemctl --user enable --now archive.timer
	systemctl --user list-timers --all | grep archive || true
'"

echo "✅ Archive script and systemd units installed and timer enabled on $REMOTE_HOST."
echo "🪶 Logs will be written to: $LOG_FILE on $REMOTE_HOST."

# --- Add sudoers file for backup user to allow passwordless btrfs subvolume commands ---
SUDOERS_TMP="$(mktemp)"
cat >"$SUDOERS_TMP" <<EOF
$INSTALL_USER ALL=(ALL) NOPASSWD: /usr/bin/btrfs subvolume delete /home/$INSTALL_USER/backup/archive-snapshots/*
$INSTALL_USER ALL=(ALL) NOPASSWD: /usr/bin/btrfs subvolume show /home/$INSTALL_USER/backup/archive-snapshots/*
$INSTALL_USER ALL=(ALL) NOPASSWD: /usr/bin/btrfs subvolume create /home/$INSTALL_USER/backup/archive-snapshots
EOF
echo "Installing sudoers file for $INSTALL_USER on $REMOTE_HOST..."
scp "$SUDOERS_TMP" root@"$REMOTE_HOST":/etc/sudoers.d/archive-snapshots
ssh root@"$REMOTE_HOST" "chmod 0440 /etc/sudoers.d/archive-snapshots"
rm -f "$SUDOERS_TMP"
