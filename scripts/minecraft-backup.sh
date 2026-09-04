#!/usr/bin/env bash

set -Eeuo pipefail

# Do not allow group or other users to read newly created backups.
umask 0027

# ---------------------------------------------------------------------------
# Required configuration
# ---------------------------------------------------------------------------

: "${WORLD_DIR:?WORLD_DIR is not configured}"
: "${TEMP_DIR:?TEMP_DIR is not configured}"
: "${BACKUP_DIR:?BACKUP_DIR is not configured}"
: "${BACKUP_KEEP_COUNT:?BACKUP_KEEP_COUNT is not configured}"
: "${RCON_BIN:?RCON_BIN is not configured}"
: "${RCON_ADDRESS:?RCON_ADDRESS is not configured}"
: "${RCON_PASSWORD:?RCON_PASSWORD is not configured}"

MINECRAFT_SERVICE="minecraft-server.service"

TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"

ARCHIVE_NAME="backup-${TIMESTAMP}.tar.zst"
CHECKSUM_NAME="${ARCHIVE_NAME}.sha256"

TEMP_ARCHIVE="${TEMP_DIR}/${ARCHIVE_NAME}.partial"
TEMP_CHECKSUM="${TEMP_DIR}/${CHECKSUM_NAME}.partial"

FINAL_ARCHIVE="${BACKUP_DIR}/${ARCHIVE_NAME}"
FINAL_CHECKSUM="${BACKUP_DIR}/${CHECKSUM_NAME}"

SERVER_WAS_RUNNING=0
SERVER_STOP_REQUESTED=0
BACKUP_PUBLISHED=0

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fatal() {
    log "ERROR: $*"
    exit 1
}

# ---------------------------------------------------------------------------
# RCON
# ---------------------------------------------------------------------------

rcon() {
    "$RCON_BIN" \
        --config /usr/local/etc/rcon/rcon.yaml \
        -a "$RCON_ADDRESS" \
        -p "$RCON_PASSWORD" \
        "$@"
}

# ---------------------------------------------------------------------------
# systemd helpers
# ---------------------------------------------------------------------------

server_is_active() {
    sudo -n /usr/bin/systemctl is-active "$MINECRAFT_SERVICE" >/dev/null 2>&1
}

start_server() {
    log "Starting ${MINECRAFT_SERVICE}..."
    sudo -n /usr/bin/systemctl start "$MINECRAFT_SERVICE"
}

stop_server() {
    log "Stopping ${MINECRAFT_SERVICE}..."
    SERVER_STOP_REQUESTED=1
    sudo -n /usr/bin/systemctl stop "$MINECRAFT_SERVICE"
}

wait_for_server_stop() {
    local timeout_seconds=180
    local elapsed=0

    while server_is_active; do
        if (( elapsed >= timeout_seconds )); then
            fatal "Minecraft server did not stop within ${timeout_seconds} seconds."
        fi

        sleep 1
        ((elapsed += 1))
    done

    log "Minecraft server is fully stopped."
}

wait_for_server_start() {
    local timeout_seconds=180
    local elapsed=0

    while ! server_is_active; do
        if (( elapsed >= timeout_seconds )); then
            fatal "Minecraft server did not become active within ${timeout_seconds} seconds."
        fi

        if sudo -n /usr/bin/systemctl is-failed "$MINECRAFT_SERVICE" >/dev/null 2>&1; then
            fatal "Minecraft server entered the failed state while starting."
        fi

        sleep 1
        ((elapsed += 1))
    done

    log "Minecraft server is active."
}

# ---------------------------------------------------------------------------
# Cleanup and recovery
# ---------------------------------------------------------------------------

cleanup() {
    local exit_status=$?

    trap - EXIT INT TERM HUP

    if (( exit_status != 0 )); then
        log "Backup failed with exit status ${exit_status}."
    fi

    # Remove only this run's incomplete files. Older stale partial files are
    # cleaned at the beginning of the next backup.
    rm -f -- "$TEMP_ARCHIVE" "$TEMP_CHECKSUM" || true

    # If the server was originally running, make every reasonable effort to
    # bring it back, regardless of where the backup failed.
    if (( SERVER_WAS_RUNNING == 1 )); then
        if ! server_is_active; then
            log "Minecraft was running before the backup; attempting recovery start."

            if sudo -n /usr/bin/systemctl start "$MINECRAFT_SERVICE"; then
                log "Minecraft recovery start requested successfully."
            else
                log "ERROR: Failed to restart Minecraft during cleanup."
                exit 1
            fi
        fi
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

[[ -x "$RCON_BIN" ]] ||
    fatal "RCON executable is missing or not executable: ${RCON_BIN}"

[[ -d "$WORLD_DIR" ]] ||
    fatal "Minecraft world directory does not exist: ${WORLD_DIR}"

[[ -d "$TEMP_DIR" ]] ||
    fatal "Temporary backup directory does not exist: ${TEMP_DIR}"

[[ -d "$BACKUP_DIR" ]] ||
    fatal "Final backup directory does not exist: ${BACKUP_DIR}"

[[ -r "$WORLD_DIR" ]] ||
    fatal "Minecraft world directory is not readable: ${WORLD_DIR}"

[[ -w "$TEMP_DIR" ]] ||
    fatal "Temporary backup directory is not writable: ${TEMP_DIR}"

[[ -w "$BACKUP_DIR" ]] ||
    fatal "Final backup directory is not writable: ${BACKUP_DIR}"

[[ "$BACKUP_KEEP_COUNT" =~ ^[1-9][0-9]*$ ]] ||
    fatal "BACKUP_KEEP_COUNT must be a positive integer."

command -v tar >/dev/null ||
    fatal "tar is not installed."

command -v zstd >/dev/null ||
    fatal "zstd is not installed."

command -v sha256sum >/dev/null ||
    fatal "sha256sum is not installed."

command -v sync >/dev/null ||
    fatal "sync is not installed."

command -v stat >/dev/null ||
    fatal "stat is not installed."

# The final move must stay on one filesystem. Otherwise mv becomes a
# copy-and-delete operation and is not atomic during a power loss.
TEMP_DEVICE="$(stat -c '%d' "$TEMP_DIR")"
BACKUP_DEVICE="$(stat -c '%d' "$BACKUP_DIR")"

if [[ "$TEMP_DEVICE" != "$BACKUP_DEVICE" ]]; then
    fatal \
        "TEMP_DIR and BACKUP_DIR are on different filesystems. " \
        "Atomic publication is impossible. Put both directories on the same filesystem."
fi

if [[ -e "$FINAL_ARCHIVE" || -e "$FINAL_CHECKSUM" ]]; then
    fatal "A backup with timestamp ${TIMESTAMP} already exists."
fi

# ---------------------------------------------------------------------------
# Remove abandoned temporary files
# ---------------------------------------------------------------------------

log "Removing stale partial backup files."

find "$TEMP_DIR" \
    -maxdepth 1 \
    -type f \
    \( -name 'backup-*.tar.zst.partial' -o \
       -name 'backup-*.tar.zst.sha256.partial' \) \
    -delete

# ---------------------------------------------------------------------------
# Determine whether Minecraft needs to be restored afterward
# ---------------------------------------------------------------------------

if server_is_active; then
    SERVER_WAS_RUNNING=1
    log "Minecraft server is currently running."
else
    log "Minecraft server is already stopped."
fi

# ---------------------------------------------------------------------------
# Player warning
# ---------------------------------------------------------------------------

if (( SERVER_WAS_RUNNING == 1 )); then
    log "Checking online player count through RCON."

    # Do not silently assume zero players if RCON is broken. Unexpectedly
    # shutting down an occupied server is worse than skipping one backup.
    if ! LIST_OUTPUT="$(rcon "list" 2>&1)"; then
        fatal "Unable to query player count through RCON: ${LIST_OUTPUT}"
    fi

    ONLINE="$(
        printf '%s\n' "$LIST_OUTPUT" |
            sed -nE 's/.*There are ([0-9]+) of a max of [0-9]+ players online.*/\1/p' |
            head -n 1
    )"

    if [[ -z "$ONLINE" ]]; then
        # Support some server/RCON implementations that omit the maximum count.
        ONLINE="$(
            printf '%s\n' "$LIST_OUTPUT" |
                grep -oE 'There are [0-9]+' |
                awk '{print $3}' |
                head -n 1
        )"
    fi

    [[ "$ONLINE" =~ ^[0-9]+$ ]] ||
        fatal "Could not parse the player count from RCON output: ${LIST_OUTPUT}"

    log "Players online: ${ONLINE}"

    if (( ONLINE > 0 )); then
        rcon "say §6[Backup] Server backup begins in 10 minutes."
        sleep 300

        rcon "say §6[Backup] Server backup begins in 5 minutes."
        sleep 240

        rcon "say §6[Backup] Server backup begins in 1 minute."
        sleep 50

        rcon "say §c[Backup] Server shutting down in 10 seconds."
        sleep 10
    else
        log "No players are online; starting the backup immediately."
    fi

    # Explicitly request a complete world flush before systemd shutdown.
    log "Flushing Minecraft world data."
    rcon "save-all flush"

    # Give the server a moment to complete the flush command response.
    sleep 2

    stop_server
    wait_for_server_stop
fi

# ---------------------------------------------------------------------------
# Build backup
# ---------------------------------------------------------------------------

log "Creating compressed archive: ${TEMP_ARCHIVE}"

tar \
    --create \
    --file="$TEMP_ARCHIVE" \
    --use-compress-program='zstd -5 --threads=0' \
    --directory="$(dirname "$WORLD_DIR")" \
    --exclude="$(basename "$WORLD_DIR")/vss-lod" \
    "$(basename "$WORLD_DIR")"

[[ -s "$TEMP_ARCHIVE" ]] ||
    fatal "Created archive is empty."

# Flush the completed temporary archive before verification/publication.
sync -f "$TEMP_ARCHIVE"

# ---------------------------------------------------------------------------
# Verify backup
# ---------------------------------------------------------------------------

log "Testing zstd archive integrity."
zstd --test "$TEMP_ARCHIVE"

log "Checking that the archive contains the world directory."
tar \
    --list \
    --file="$TEMP_ARCHIVE" \
    --use-compress-program=zstd \
    >/dev/null

log "Creating SHA-256 checksum."

(
    cd "$TEMP_DIR"
    sha256sum "$(basename "$TEMP_ARCHIVE")" |
        sed "s/$(basename "$TEMP_ARCHIVE")/${ARCHIVE_NAME}/" \
        > "$(basename "$TEMP_CHECKSUM")"
)

sync -f "$TEMP_CHECKSUM"

# ---------------------------------------------------------------------------
# Atomically publish completed backup
# ---------------------------------------------------------------------------

log "Publishing completed archive atomically."

mv -- "$TEMP_ARCHIVE" "$FINAL_ARCHIVE"
mv -- "$TEMP_CHECKSUM" "$FINAL_CHECKSUM"

BACKUP_PUBLISHED=1

# Flush both published files and the directory entries. This reduces the chance
# of losing a completed rename during an immediate power failure.
sync -f "$FINAL_ARCHIVE"
sync -f "$FINAL_CHECKSUM"
sync -f "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# Verify published checksum
# ---------------------------------------------------------------------------

log "Verifying published checksum."

(
    cd "$BACKUP_DIR"
    sha256sum --check "$CHECKSUM_NAME"
)

# ---------------------------------------------------------------------------
# Update latest symlinks
# ---------------------------------------------------------------------------

log "Updating latest backup links."

ln -sfn "$ARCHIVE_NAME" "${BACKUP_DIR}/latest.new"
mv -Tf "${BACKUP_DIR}/latest.new" "${BACKUP_DIR}/latest"

ln -sfn "$CHECKSUM_NAME" "${BACKUP_DIR}/latest.sha256.new"
mv -Tf \
    "${BACKUP_DIR}/latest.sha256.new" \
    "${BACKUP_DIR}/latest.sha256"

sync -f "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# Restart Minecraft before deleting older backups
# ---------------------------------------------------------------------------

if (( SERVER_WAS_RUNNING == 1 )); then
    start_server
    wait_for_server_start
fi

# Mark the server as successfully restored so cleanup does not need to recover
# it again.
SERVER_STOP_REQUESTED=0

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

log "Applying backup retention policy: keep newest ${BACKUP_KEEP_COUNT}."

shopt -s nullglob

BACKUPS=("${BACKUP_DIR}"/backup-*.tar.zst)

if (( ${#BACKUPS[@]} > BACKUP_KEEP_COUNT )); then
    DELETE_COUNT=$(( ${#BACKUPS[@]} - BACKUP_KEEP_COUNT ))

    # The timestamp format sorts chronologically, and Bash glob expansion is
    # lexicographically sorted.
    for (( i = 0; i < DELETE_COUNT; i++ )); do
        OLD_ARCHIVE="${BACKUPS[$i]}"
        OLD_CHECKSUM="${OLD_ARCHIVE}.sha256"

        log "Removing old backup: $(basename "$OLD_ARCHIVE")"

        rm -f -- "$OLD_ARCHIVE" "$OLD_CHECKSUM"
    done

    sync -f "$BACKUP_DIR"
fi

log "Backup completed successfully: ${FINAL_ARCHIVE}"
