# Minecraft Server Management System

This repository contains scripts and systemd services to manage a Minecraft server, specifically for:
- Automatic backups with retention policy.
- Automatic system suspension when the server is idle.

*Note:- For my personal server I am using a esp32 module to start the server from suspend using Wake-on-LAN. If you are running on a vps then the idle-suspend services might not be necessary.*

## Prerequisites

- **Java**: The `minecraft-server.service` is configured to run `/usr/bin/java`.
- **RCON CLI Tool**: The backup and idle-suspend scripts rely on an RCON command-line tool. The `minecraft-backup.sh` script specifically looks for a config at `/usr/local/etc/rcon/rcon.yaml`.
- **User/Group**: Services expect a `minecraft` user and group.
- **Dependencies**: `tar`, `zstd`, `sha256sum`, `sync`, `stat`.

## Installation

1. **Set up the User**:
   ```bash
   sudo groupadd minecraft
   sudo useradd -r -g minecraft -m -d /srv/minecraft minecraft
   ```

2. **Prepare Directories**:
   ```bash
   sudo mkdir -p /srv/minecraft
   # Ensure your server jar and world files are in /srv/minecraft
   sudo chown -R minecraft:minecraft /srv/minecraft
   ```
  *Note: If you keep the world anywhere else just change it in env files also*

3. **Install Scripts**:
   ```bash
   sudo cp scripts/minecraft-backup.sh /usr/local/bin/
   sudo cp scripts/minecraft-idle-suspend.sh /usr/local/sbin/
   sudo chmod +x /usr/local/bin/minecraft-backup.sh /usr/local/sbin/minecraft-idle-suspend.sh
   ```

4. **Install Services**:
   ```bash
   sudo cp services/*.service /etc/systemd/system/
   sudo cp services/*.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   ```

## Configuration

### 1. RCON Configuration
Create `/usr/local/etc/rcon/rcon.yaml` (or the equivalent config for your RCON tool).

### 2. Backup Configuration (`/etc/minecraft-backup.conf`)
Create `/etc/minecraft-backup.conf` with the following variables:
```bash
WORLD_DIR="/srv/minecraft/world"
TEMP_DIR="/srv/minecraft/backup/temp"
BACKUP_DIR="/srv/minecraft/backup"
BACKUP_KEEP_COUNT=5
RCON_BIN="/path/to/your/rcon-cli"
RCON_ADDRESS="127.0.0.1:25575"
RCON_PASSWORD="your-rcon-password"
```
*Note: `TEMP_DIR` and `BACKUP_DIR` must be on the same filesystem for atomic operations.*

### 3. Idle Suspend Configuration (`/etc/minecraft-idle-suspend.conf`)
Create `/etc/minecraft-idle-suspend.conf` with the following variables:
```bash
RCON_HOST="127.0.0.1"
RCON_PORT=25575
RCON_PASSWORD="your-rcon-password"
CHECK_SECONDS=60
IDLE_SECONDS=3600
```

## Running the Services

```bash
# Start and enable the main server
sudo systemctl enable --now minecraft-server.service

# Start and enable backup services
sudo systemctl enable --now minecraft-backup.timer

# Start and enable idle suspension
sudo systemctl enable --now minecraft-idle-suspend.service
```

