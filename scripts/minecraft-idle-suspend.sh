#!/usr/bin/env bash
set -u

source /etc/minecraft-idle-suspend.conf

RCON_BIN=${RCON_BIN:-rcon}
idle=0

rcon_cmd() {
    "$RCON_BIN" -a "${RCON_HOST}:${RCON_PORT}" -p "$RCON_PASSWORD" "$@"
}

ssh_connections_active() {
    # Check for any users logged in on a pseudo-terminal,
    who | grep -q 'pts/'
}

players_online() {
    local output
    output=$(rcon_cmd list 2>/dev/null) || return 1

    printf '%s\n' "$output" |
        sed -nE 's/.*There are ([0-9]+) of a max of [0-9]+ players online.*/\1/p' |
        head -n1
}

while true; do
    players=$(players_online || true)

    # Never interpret an RCON failure as zero players.
    if [[ ! "$players" =~ ^[0-9]+$ ]]; then
        echo "Could not read player count; idle timer reset."
        idle=0
        sleep "$CHECK_SECONDS"
        continue
    fi

    echo "Players online: $players"

    if ((players > 0)); then
        idle=0
    else
        idle=$((idle + CHECK_SECONDS))
        echo "Empty for ${idle}/${IDLE_SECONDS} seconds"
    fi

    if ((idle >= IDLE_SECONDS)); then
        if systemctl is-active --quiet minecraft-backup.service; then
            echo "Backup is running; suspend postponed."
            sleep "$CHECK_SECONDS"
            continue
        fi

        if ssh_connections_active; then
            echo "SSH connection active; suspend postponed."
            sleep "$CHECK_SECONDS"
            continue
        fi

        echo "Flushing Minecraft world..."
        if ! rcon_cmd save-all flush; then
            echo "save-all flush failed; suspend cancelled."
            idle=0
            sleep "$CHECK_SECONDS"
            continue
        fi

        sleep 2

        # Re-check immediately before suspend.
        players=$(players_online || true)
        if [[ ! "$players" =~ ^[0-9]+$ ]] || ((players > 0)); then
            echo "Server is no longer confirmed empty; suspend cancelled."
            idle=0
            sleep "$CHECK_SECONDS"
            continue
        fi

        if systemctl is-active --quiet minecraft-backup.service; then
            echo "Backup started; suspend postponed."
            sleep "$CHECK_SECONDS"
            continue
        fi

        echo "No players, backup inactive, world flushed; suspending."
        systemctl suspend

        # Execution continues here after wake/resume.
        idle=0
        echo "System resumed; idle timer reset."
    fi

    sleep "$CHECK_SECONDS"
done
