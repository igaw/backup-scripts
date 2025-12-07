#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
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
cat > "$BIN_DIR/$SCRIPT_NAME" <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

############################################
#               CONFIGURATION              #
############################################

SRC_DIR="/home/backup/repos"
SNAP_PARENT="/home/backup/backup-snapshots"   # Btrfs subvolume parent
REMOTE_HOST="backup@truenas.lan"
REMOTE_BASE="/data/repos"
SSH_OPTS="-p 5522 -i ~/.ssh/id_backup-nearlyone_ed25519"

RETRY_DELAY=120
MAX_RETRIES=10
LOCAL_KEEP=3

# nearlyone encrypted backup
NEARLYONE_SRC="$HOME/nearlyone"
AGE_BIN="$(command -v age || true)"
AGE_RECIPIENT_FILE="$HOME/.ssh/id_backup-nearlyone_ed25519.pub"
NEARLYONE_REMOTE_BASE="backup@truenas.lan:/data"

# Logging
LOGFILE="/var/log/backup-sync.log"

# Email notifications (set EMAIL_TO to enable)
EMAIL_TO="wagi@monom.org"
EMAIL_FROM="backup@backup.lan"
EMAIL_SUBJECT_OK="Backup completed successfully"
EMAIL_SUBJECT_FAIL="Backup FAILED"
EMAIL_CMD="mail -s"   # Example: "mail -s". Works with mailutils/mailx.

# ZFS settings
ZFS_DATASET="pool/repos"
ZFS_KEEP=30

############################################
#                LOGGING                   #
############################################

log() {
    local t
    t=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$t  $*" | tee -a "$LOGFILE"
}

email_notify() {
    local subject="$1"
    local body="$2"

    [[ -z "${EMAIL_TO}" ]] && return 0

    if [[ "$EMAIL_CMD" == "mail -s" ]]; then
        echo "$body" | mail -s "$subject" -r "$EMAIL_FROM" "$EMAIL_TO"
    else
        # Custom command
        echo "$body" | $EMAIL_CMD "$subject" "$EMAIL_TO"
    fi
}

fail_and_exit() {
    log "❌ ERROR: $*"
    email_notify "$EMAIL_SUBJECT_FAIL" "$*"
    exit 1
}

############################################
#           SNAPSHOT MANAGEMENT            #
############################################

snapshot_has_locks() {
    local snap_path="$1"
    find "$snap_path/repos" -type f -name 'lock*' | grep -q . || return 1
}

rotate_local_snapshots() {
    ls -1dt "$SNAP_PARENT"/backup-rsync-* 2>/dev/null \
        | tail -n +$((LOCAL_KEEP + 1)) \
        | while read -r old_snap; do
            log "🧹 Removing old local snapshot: $old_snap"
            btrfs subvolume delete "$old_snap" >/dev/null || true
        done
}

create_snapshot() {
    local snap_name snap_path

    for attempt in $(seq 1 "$MAX_RETRIES"); do
        snap_name="backup-rsync-$(date +%Y%m%d-%H%M%S)"
        snap_path="$SNAP_PARENT/$snap_name"

        log "📸 [Attempt $attempt/$MAX_RETRIES] Creating Btrfs snapshot → $snap_path"
        btrfs subvolume snapshot -r /home/backup "$snap_path" >/dev/null

        log "🔍 Checking snapshot for Borg locks..."
        if snapshot_has_locks "$snap_path"; then
            log "🔒 Locks found — removing snapshot and retrying in $RETRY_DELAY seconds."
            btrfs subvolume delete "$snap_path" >/dev/null
            sleep "$RETRY_DELAY"
            continue
        fi

        echo "$snap_path"
        return 0
    done

    fail_and_exit "Could not create clean Btrfs snapshot after $MAX_RETRIES attempts."
}

############################################
#               REMOTE SYNC                #
############################################

sync_repo() {
    local repo="$1"
    local snap_path="$2"

    local repo_name remote_path
    repo_name=$(realpath --relative-to="$snap_path/repos" "$repo")
    remote_path="$REMOTE_BASE/$repo_name"

    log "➡️ Syncing $repo_name → $remote_path"

    ssh $SSH_OPTS "$REMOTE_HOST" "mkdir -p '$remote_path'"

    if ! rsync -a --delete -e "ssh $SSH_OPTS" "$repo/" "$REMOTE_HOST:$remote_path/"; then
        log "⚠️ Rsync FAILED for $repo_name"
    else
        log "✔️ Repo synced: $repo_name"
    fi
}

sync_all_repos() {
    local snap_path="$1"
    mapfile -t repos < <(find "$snap_path/repos" -mindepth 2 -maxdepth 2 -type d | sort)

    for repo in "${repos[@]}"; do
        sync_repo "$repo" "$snap_path"
    done
}

############################################
#         NEARLYONE ENCRYPTED BACKUP       #
############################################

backup_nearlyone() {
    [[ -d "$NEARLYONE_SRC" ]] || {
        log "⚠️ nearlyone directory missing — skipping."
        return
    }

    [[ -x "$AGE_BIN" ]] || fail_and_exit "age binary not found"
    [[ -f "$AGE_RECIPIENT_FILE" ]] || fail_and_exit "Missing age recipient file"

    local archive="$HOME/nearlyone.tar.age"
    local recipient
    recipient=$(cat "$AGE_RECIPIENT_FILE")

    log "🔐 Encrypting nearlyone → $archive"
    tar cz "$NEARLYONE_SRC" | "$AGE_BIN" -r "$recipient" -o "$archive"

    log "📤 Syncing nearlyone backup..."
    rsync -av -e "ssh $SSH_OPTS" "$archive" "$NEARLYONE_REMOTE_BASE/" \
        || log "⚠️ nearlyone rsync failed"

    rm -f "$archive"
}

############################################
#         REMOTE ZFS SNAPSHOT FEATURES     #
############################################

take_remote_zfs_snapshot() {
    local snapname="backup-$(date +%Y-%m-%d_%H-%M-%S)"
    log "📡 Creating remote ZFS snapshot: ${ZFS_DATASET}@$snapname"

    ssh $SSH_OPTS "$REMOTE_HOST" \
        "sudo zfs snapshot -r ${ZFS_DATASET}@$snapname" \
        || log "⚠️ Remote ZFS snapshot failed"
}

prune_remote_zfs_snapshots() {
    log "🧹 Pruning remote ZFS snapshots, keeping last $ZFS_KEEP"

    ssh $SSH_OPTS "$REMOTE_HOST" "
        sudo zfs list -t snapshot -o name -s creation |
        grep '${ZFS_DATASET}@backup-' |
        head -n -${ZFS_KEEP} |
        xargs -r sudo zfs destroy
    " || log "⚠️ Remote ZFS prune failed"
}

############################################
#                 MAIN                     #
############################################

run_backup() {
    log "🚀 Backup started"

    mkdir -p "$SNAP_PARENT"

    local snap_path
    snap_path=$(create_snapshot)

    rotate_local_snapshots
    sync_all_repos "$snap_path"
    backup_nearlyone

    take_remote_zfs_snapshot
    prune_remote_zfs_snapshots

    log "✅ Backup complete"
    email_notify "$EMAIL_SUBJECT_OK" "Backup completed successfully."

    return 0
}

run_backup
EOF

chmod 700 "$BIN_DIR/$SCRIPT_NAME"

# --- Create systemd service ---
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Run Borg + Nearlyone backup sync
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN_DIR/$SCRIPT_NAME
Nice=10
IOSchedulingClass=idle
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=no
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
EOF

# --- Create systemd timer ---
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Daily Borg + Nearlyone backup

[Timer]
OnCalendar=03:00
RandomizedDelaySec=900
Persistent=true
AccuracySec=5min

[Install]
WantedBy=timers.target
EOF

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

