#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKUP_ROOT:=/backups}"
: "${TZ:=Europe/Amsterdam}"

export TZ

DETAIL_LOG="${DETAIL_LOG:-$BACKUP_ROOT/backup-latest.log}"
RUN_LOG="${RUN_LOG:-$BACKUP_ROOT/backup-runs.log}"

mkdir -p "$BACKUP_ROOT"

# Bewaar originele stdout/stderr, zodat we aan het eind 1 summary-regel kunnen tonen.
exec 3>&1
exec 4>&2

# Detail-log wordt per run overschreven.
: > "$DETAIL_LOG"
exec > "$DETAIL_LOG" 2>&1

START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
ERROR_MESSAGE=""

on_error() {
    local exit_code=$?
    ERROR_MESSAGE="line $LINENO: command failed: $BASH_COMMAND"
    return "$exit_code"
}

on_exit() {
    local exit_code=$?
    local end_ts
    local result_line

    end_ts="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ "$exit_code" -eq 0 ]]; then
        result_line="[$end_ts] result=success started=\"$START_TS\""
    else
        if [[ -z "$ERROR_MESSAGE" ]]; then
            ERROR_MESSAGE="exit_code=$exit_code"
        fi

        result_line="[$end_ts] result=failed started=\"$START_TS\" error=\"$ERROR_MESSAGE\""
    fi

    # Eén regel per run in de compacte history-log.
    echo "$result_line" >> "$RUN_LOG"

    # Ook één regel naar stdout, handig voor cron/docker logs.
    echo "$result_line" >&3

    exit "$exit_code"
}

trap on_error ERR
trap on_exit EXIT

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${DAILY_RETENTION_DAYS:=14}"

# Supports:
# - GITHUB_OWNER=my-user-or-org
# - GITHUB_OWNERS=my-user,my-org,another-org
: "${GITHUB_OWNERS:=${GITHUB_OWNER:-}}"
: "${GITHUB_OWNERS:?GITHUB_OWNERS or GITHUB_OWNER is required}"

ENABLE_DAILY="${ENABLE_DAILY:-false}"
ENABLE_WEEKLY="${ENABLE_WEEKLY:-false}"
ENABLE_MONTHLY="${ENABLE_MONTHLY:-false}"

TODAY="$(date +%F)"
MONTH="$(date +%Y-%m)"
ISO_WEEK="$(date +%G-W%V)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

bool_enabled() {
    case "${1,,}" in
        true|1|yes|y|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "ERROR: required command not found: $1"
        exit 1
    fi
}

make_clean_url() {
    local repo_url="$1"

    if [[ "$repo_url" != *.git ]]; then
        repo_url="${repo_url}.git"
    fi

    echo "$repo_url"
}

make_authenticated_url() {
    local repo_url="$1"

    repo_url="$(make_clean_url "$repo_url")"
    echo "${repo_url/https:\/\//https:\/\/x-access-token:${GITHUB_TOKEN}@}"
}

backup_owner() {
    local owner="$1"

    local owner_root="$BACKUP_ROOT/$owner"
    local current_root="$owner_root/current"

    mkdir -p "$current_root"

    log "Backing up GitHub owner: $owner"
    log "Current target: $current_root"

    gh repo list "$owner" --limit 1000 --json nameWithOwner,url \
      --jq '.[] | [.nameWithOwner, .url] | @tsv' |
    while IFS=$'\t' read -r name repo_url; do
        if [[ -z "$name" || -z "$repo_url" ]]; then
            continue
        fi

        local repo_name
        local target
        local clean_url
        local clone_url

        repo_name="$(basename "$name")"
        target="$current_root/$repo_name.git"

        clean_url="$(make_clean_url "$repo_url")"
        clone_url="$(make_authenticated_url "$repo_url")"

        if [[ -d "$target" ]]; then
            log "Updating $name"
            git -C "$target" remote set-url origin "$clone_url"
            git -C "$target" remote update --prune
            git -C "$target" remote set-url origin "$clean_url"
        else
            log "Cloning $name"
            git clone --mirror "$clone_url" "$target"
            git -C "$target" remote set-url origin "$clean_url"
        fi

        log "Checking $name"
        git -C "$target" fsck --full >/dev/null
        log "OK: $name"
    done
}

create_snapshot() {
    local current_root="$1"
    local snapshot_path="$2"
    local snapshot_name="$3"

    if [[ ! -d "$current_root" ]]; then
        log "Skipping $snapshot_name snapshot; current folder does not exist: $current_root"
        return 0
    fi

    if [[ -d "$snapshot_path" ]]; then
        log "$snapshot_name snapshot already exists: $snapshot_path"
        return 0
    fi

    log "Creating $snapshot_name snapshot: $snapshot_path"
    mkdir -p "$snapshot_path"

    # Use rsync with hardlinks where possible.
    # This creates a point-in-time copy while avoiding duplicate file storage.
    if rsync -a --delete --link-dest="$current_root" "$current_root/" "$snapshot_path/"; then
        log "$snapshot_name snapshot created: $snapshot_path"
    else
        log "Hardlink snapshot failed, retrying as normal copy..."
        rm -rf "$snapshot_path"
        mkdir -p "$snapshot_path"
        rsync -a --delete "$current_root/" "$snapshot_path/"
        log "$snapshot_name snapshot created as normal copy: $snapshot_path"
    fi
}

cleanup_daily_snapshots() {
    local daily_root="$1"

    if ! [[ "$DAILY_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        log "WARNING: DAILY_RETENTION_DAYS is not numeric: $DAILY_RETENTION_DAYS"
        return 0
    fi

    if [[ ! -d "$daily_root" ]]; then
        return 0
    fi

    log "Cleaning daily snapshots older than $DAILY_RETENTION_DAYS days in $daily_root"

    find "$daily_root" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -mtime +"$DAILY_RETENTION_DAYS" \
        -print \
        -exec rm -rf {} +
}

handle_owner_snapshots() {
    local owner="$1"

    local owner_root="$BACKUP_ROOT/$owner"
    local current_root="$owner_root/current"

    if bool_enabled "$ENABLE_DAILY"; then
        mkdir -p "$owner_root/daily"
        create_snapshot "$current_root" "$owner_root/daily/$TODAY" "daily"
        cleanup_daily_snapshots "$owner_root/daily"
    fi

    if bool_enabled "$ENABLE_WEEKLY"; then
        mkdir -p "$owner_root/weekly"
        create_snapshot "$current_root" "$owner_root/weekly/$ISO_WEEK" "weekly"
    fi

    if bool_enabled "$ENABLE_MONTHLY"; then
        mkdir -p "$owner_root/monthly"
        create_snapshot "$current_root" "$owner_root/monthly/$MONTH" "monthly"
    fi
}

main() {
    require_command git
    require_command gh
    require_command rsync
    require_command find
    require_command basename
    require_command xargs

    mkdir -p "$BACKUP_ROOT"

    log "Starting GitHub backup"
    log "Backup root inside container: $BACKUP_ROOT"
    log "Detail log: $DETAIL_LOG"
    log "Run log: $RUN_LOG"

    IFS=',' read -ra OWNERS <<< "$GITHUB_OWNERS"

    for raw_owner in "${OWNERS[@]}"; do
        local owner
        owner="$(echo "$raw_owner" | xargs)"

        if [[ -z "$owner" ]]; then
            continue
        fi

        backup_owner "$owner"
        handle_owner_snapshots "$owner"
    done

    log "Backup complete"
}

main "$@"
