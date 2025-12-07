#!/usr/bin/env bash
set -euo pipefail

############################################
#               CONFIGURATION              #
############################################
TN_HOST="truenas.lan"
TN_TOKEN=""

SRC_DIR="/home/backup/repos"
SNAP_PARENT="/home/backup/backup-snapshots"   # Btrfs subvolume parent
REMOTE_HOST="backup@$TN_HOST"
REMOTE_BASE="/data/repos"
SSH_OPTS="-p 5522 -i ~/.ssh/id_backup-nearlyone_ed25519"

RETRY_DELAY=120
MAX_RETRIES=10
LOCAL_KEEP=10

# nearlyone encrypted backup
NEARLYONE_SRC="$HOME/nearlyone"
AGE_BIN="$(command -v age || true)"
AGE_RECIPIENT_FILE="$HOME/.ssh/id_backup-nearlyone_ed25519.pub"
NEARLYONE_REMOTE_BASE="backup@truenas.lan:/data"

# Logging
LOGFILE="$HOME/backup-sync.log"

# Email notifications (set EMAIL_TO to enable)
EMAIL_TO="wagi@monom.org"
EMAIL_FROM="backup@backup.lan"
EMAIL_SUBJECT_OK="Backup completed successfully"
EMAIL_SUBJECT_FAIL="Backup FAILED"

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

    # Compose the email
    {
        echo "From: ${EMAIL_FROM}"
        echo "To: ${EMAIL_TO}"
        echo "Subject: ${subject}"
        echo
        echo "$body"
    } | msmtp --from="${EMAIL_FROM}" "$EMAIL_TO"
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
    # Build an array of snapshots with creation timestamps
    local snapshots=()
    for snap in "$SNAP_PARENT"/backup-rsync-*; do
        [[ -d "$snap" ]] || continue
        local ctime
        ctime=$(sudo btrfs subvolume show "$snap" | awk -F': ' '/Creation time/ {print $2}')
        # Convert to sortable format (epoch)
        ctime_epoch=$(date -d "$ctime" +%s)
        snapshots+=("$ctime_epoch $snap")
    done

    # Sort by creation time (oldest first)
    IFS=$'\n' sorted=($(sort -n <<<"${snapshots[*]}"))
    unset IFS

    # Delete older snapshots beyond LOCAL_KEEP
    local total=${#sorted[@]}
    local to_delete=$((total - LOCAL_KEEP))
    [[ $to_delete -le 0 ]] && return

    for ((i=0; i<to_delete; i++)); do
        old_snap=${sorted[i]#* }   # remove epoch prefix
        log "🧹 Removing old local snapshot: $old_snap"
        sudo btrfs subvolume delete "$old_snap" >/dev/null || true
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
            sudo btrfs subvolume delete "$snap_path" >/dev/null
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
    #mapfile -t repos < <(find "$snap_path/repos" -mindepth 2 -maxdepth 2 -type d | sort)

    mapfile -t repos < <(find "$snap_path/repos" -mindepth 1 -maxdepth 1 -type d | sort)

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

create_remote_snapshot() {
    local PREFIX="daily-"
    local KEEP=7
    local DATASET="pool/archive"

    log "📸 Creating remote ZFS snapshot on TrueNAS..."

    if python3 /home/backup/bin/zfs-snap.py \
        --host "$TN_HOST" \
	--token "$TN_TOKEN" \
        --dataset "$DATASET" \
        --prefix "$PREFIX" \
        --prune "$KEEP" \
        "${PREFIX}$(date +%Y-%m-%d_%H-%M-%S)"
    then
        log "✔️ Remote ZFS snapshot created and pruned successfully."
    else
        log "⚠️ Remote snapshot failed."
        # The backup continues, but you can uncomment this if you want:
        # fail_and_exit "Failed to create remote ZFS snapshot"
    fi
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
    create_remote_snapshot

    log "✅ Backup complete"
    email_notify "$EMAIL_SUBJECT_OK" "Backup completed successfully."

    return 0
}
    
#email_notify "$EMAIL_SUBJECT_OK" "Backup completed successfully."

run_backup
