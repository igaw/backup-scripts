#!/usr/bin/env bash
set -euo pipefail

# Global status variable to track script success
SCRIPT_STATUS=0
# Buffer for current run log
RUN_LOG=""
# Start time for this run
RUN_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

# Usage/help function
usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Options:
	--skip-encrypted-tar   Skip the encrypted tar backup step
	--test-mode            Run in test mode (no rotation, creates and deletes a test snapshot)
	-h, --help             Show this help message and exit

Environment/configuration is loaded from:
	[1m${XDG_CONFIG_HOME:-$HOME/.config}/backup-scripts/config[0m
EOF
}

############################################
#               CONFIGURATION              #
############################################
# Source config from XDG_CONFIG_HOME or fallback to ~/.config
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/backup-scripts/config"
if [[ -f "$CONFIG_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$CONFIG_FILE"
else
	echo "Config file $CONFIG_FILE not found."
	exit 1
fi

# Set BIN_DIR if not set in config
if [[ -z "${BIN_DIR:-}" ]]; then
	BIN_DIR="$(dirname "$0")"
fi

############################################
#                LOGGING                   #
############################################

log() {
	local t
	t=$(date '+%Y-%m-%d %H:%M:%S')
	local line="$t  $*"
	echo "$line"
	RUN_LOG+="$line\n"
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
		echo
		echo "Run started: $RUN_START_TIME"
		echo "Run ended:   $(date '+%Y-%m-%d %H:%M:%S')"
		echo
		echo "Log output for this run:"
		echo "----------------------------------------"
		# Print only the current run's log, interpreting \n as newlines
		printf "%b" "$RUN_LOG"
		echo "----------------------------------------"
	} | msmtp --from="${EMAIL_FROM}" "$EMAIL_TO"
}

fail_and_exit() {
	log "❌ ERROR: $*"
	SCRIPT_STATUS=1
	email_notify "$EMAIL_SUBJECT_FAIL" "$*"
	exit 1
}

############################################
#           SNAPSHOT MANAGEMENT            #
############################################

snapshot_has_locks() {
	local snap_path="$1"
	if [[ ! -d "$snap_path/repos" ]]; then
		log "⚠️  Snapshot repo directory missing: $snap_path/repos"
		return 1
	fi
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
	mapfile -t sorted < <(printf '%s\n' "${snapshots[@]}" | sort -n)

	# Delete older snapshots beyond LOCAL_KEEP
	local total=${#sorted[@]}
	local to_delete=$((total - LOCAL_KEEP))
	[[ $to_delete -le 0 ]] && return

	for ((i = 0; i < to_delete; i++)); do
		old_snap=${sorted[i]#* } # remove epoch prefix
		log "🧹 Removing old local snapshot: $old_snap"
		sudo btrfs subvolume delete "$old_snap" >/dev/null || true
	done
}

create_snapshot() {
	local snap_name snap_path

	if [[ ! -d "${SNAP_PARENT}" ]]; then
		mkdir -p "${SNAP_PARENT}"
	fi

	for attempt in $(seq 1 "$MAX_RETRIES"); do
		snap_name="backup-rsync-$(date +%Y%m%d-%H%M%S)"
		snap_path="$SNAP_PARENT/$snap_name"

		log "📸 [Attempt $attempt/$MAX_RETRIES] Creating Btrfs snapshot → $snap_path" >&2
		if ! btrfs subvolume snapshot -r "$SNAP_SOURCE" "$snap_path" >/dev/null 2>&1; then
			log "❌ ERROR: Not a btrfs subvolume or failed to create snapshot: $snap_path" >&2
			continue
		fi

		log "🔍 Checking snapshot for Borg locks..." >&2
		if snapshot_has_locks "$snap_path"; then
			log "🔒 Locks found — removing snapshot and retrying in $RETRY_DELAY seconds." >&2
			sudo btrfs subvolume delete "$snap_path" >/dev/null
			sleep "$RETRY_DELAY"
			continue
		fi

		echo "$snap_path"
		return 0
	done

	fail_and_exit "Could not create clean btrfs snapshot after $MAX_RETRIES attempts."
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

	# shellcheck disable=SC2029,SC2086
	ssh $SSH_OPTS "$REMOTE_HOST" "mkdir -p \"$remote_path\""

	if ! rsync -a --delete -e "ssh $SSH_OPTS" "$repo/" "$REMOTE_HOST:$remote_path/"; then
		log "⚠️ Rsync FAILED for $repo_name"
	else
		log "✔️ Repo synced: $repo_name"
	fi
}

sync_all_borg_repos() {
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

backup_encrypted_tar() {
	[[ -d "$ENCRYPTED_TAR_SRC" ]] || {
		log "⚠️ source directory missing — skipping."
		return
	}

	[[ -x "$AGE_BIN" ]] || fail_and_exit "age binary not found"
	[[ -f "$AGE_RECIPIENT_FILE" ]] || fail_and_exit "Missing age recipient file"

	local archive="$ENCRYPTED_TAR_ARCHIVE"
	local recipient
	recipient=$(cat "$AGE_RECIPIENT_FILE")

	log "🔐 Encrypting and archiving → $archive"
	tar cz "$ENCRYPTED_TAR_SRC" | "$AGE_BIN" -r "$recipient" -o "$archive"

	log "📤 Syncing encrypted tar backup..."
	rsync -av -e "ssh $SSH_OPTS" "$archive" "$ENCRYPTED_TAR_REMOTE_BASE/" ||
		log "⚠️ encrypted tar rsync failed"

	rm -f "$archive"
}

create_remote_snapshot() {
	local PREFIX="daily-"
	local KEEP=7
	local DATASET="pool/archive"

	log "📸 Creating remote ZFS snapshot on TrueNAS..."

	if python3 "$BIN_DIR/zfs-snap.py" \
		--host "$TN_HOST" \
		--token "$TN_TOKEN" \
		--dataset "$DATASET" \
		--prefix "$PREFIX" \
		--prune "$KEEP" \
		"${PREFIX}$(date +%Y-%m-%d_%H-%M-%S)"; then
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
	local skip_encrypted_tar=0
	local test_mode=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--skip-encrypted-tar)
			skip_encrypted_tar=1
			shift
			;;
		--test-mode)
			test_mode=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			shift
			;;
		esac
	done

	log "🚀 Backup started"

	# Declare snap_path as global for use in cleanup_snapshot
	global_snap_path=""

	if [[ $test_mode -eq 1 ]]; then
		cleanup_snapshot() {
			if [[ -n "$global_snap_path" && -d "$global_snap_path" ]]; then
				log "🧹 Cleaning up test snapshot: $global_snap_path"
				sudo btrfs subvolume delete "$global_snap_path" >/dev/null || true
			fi
		}
		trap cleanup_snapshot EXIT INT TERM
	fi

	if ! global_snap_path=$(create_snapshot); then
		fail_and_exit "Snapshot creation failed or did not produce a valid directory: $global_snap_path"
	fi

	if [[ $test_mode -eq 0 ]]; then
		rotate_local_snapshots
	fi

	sync_all_borg_repos "$global_snap_path"
	if [[ $skip_encrypted_tar -eq 0 ]]; then
		backup_encrypted_tar
	else
		log "🔕 Skipping encrypted tar backup step (--skip-encrypted-tar)"
	fi
	create_remote_snapshot

	if [[ $test_mode -eq 1 ]]; then
		cleanup_snapshot
		trap - EXIT INT TERM
	fi

	log "✅ Backup complete"
	SCRIPT_STATUS=0
	return 0
}

# Trap to always send an email on script exit
trap 'if [[ $SCRIPT_STATUS -eq 0 ]]; then email_notify "$EMAIL_SUBJECT_OK" "Backup completed successfully."; else email_notify "$EMAIL_SUBJECT_FAIL" "Backup failed. See logs for details."; fi' EXIT

run_backup "$@"
