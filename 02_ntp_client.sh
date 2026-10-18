#!/bin/bash

# =====================================================
# NTP CLIENT CONFIGURATION SCRIPT
# Operating System: Rocky Linux / RHEL
# Service: Chrony
# =====================================================

set -o pipefail

NTP_PACKAGE="chrony"
NTP_SERVICE="chronyd"
NTP_CONFIG="/etc/chrony.conf"
NTP_PORT="123"
NTP_SERVER="192.168.78.128"

BACKUP_FILE=""
CONFIG_CHANGED=0
CUSTOM_CONFIG=0
SYSTEMD_OVERRIDE="/etc/systemd/system/${NTP_SERVICE}.service.d/ntp-client.conf"

# -----------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------

print_line() {
    echo "====================================================="
}

error_exit() {
    echo "[ERROR] $1"
    exit 1
}

is_yes() {
    [[ "$1" =~ ^([yY]|[yY][eE][sS])$ ]]
}

valid_service_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_.@-]+$ ]]
}

show_configuration() {
    print_line
    echo "          $1"
    print_line
    echo "NTP_PACKAGE  = $NTP_PACKAGE"
    echo "NTP_SERVICE  = $NTP_SERVICE"
    echo "NTP_CONFIG   = $NTP_CONFIG"
    echo "NTP_PORT     = $NTP_PORT"
    echo "NTP_SERVER   = $NTP_SERVER"
    print_line
}

# Return success only when:
# 1. Chrony has selected the configured server.
# 2. Chrony reports normal leap status.
# 3. timedatectl reports synchronized system clock.

check_synchronization() {
    local sources tracking sync_status

    sources=$(chronyc -n sources 2>/dev/null)
    tracking=$(chronyc tracking 2>/dev/null)
    sync_status=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)

    if echo "$sources" | awk '$1 == "^*" { found=1 } END { exit !found }' \
        && echo "$tracking" | grep -qE 'Leap status[[:space:]]*:[[:space:]]*Normal' \
        && [[ "$sync_status" == "yes" ]]; then
        return 0
    fi

    return 1
}

show_sync_status() {
    echo
    echo "Chrony sources:"
    chronyc sources -v 2>&1

    echo
    echo "Chrony tracking:"
    chronyc tracking 2>&1

    echo
    echo "System clock synchronization:"
    timedatectl status 2>&1
}

wait_for_synchronization() {
    local max_wait="$1"
    local elapsed=0
    local last_message=0

    echo
    echo "[INFO] Waiting for the system clock to synchronize..."
    echo "[INFO] Maximum wait time: ${max_wait} seconds."
    echo

    while (( elapsed < max_wait )); do
        if check_synchronization; then
            echo
            echo "[SUCCESS] System clock synchronization confirmed!"
            return 0
        fi

        if (( elapsed >= last_message )); then
            echo "[INFO] Still waiting... (${elapsed}/${max_wait} seconds)"
            last_message=$((last_message + 10))
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

# -----------------------------------------------------
# ROOT CHECK
# -----------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    error_exit "Run this script as root or with sudo."
fi

# -----------------------------------------------------
# DISPLAY DEFAULT CONFIGURATION
# -----------------------------------------------------

show_configuration "NTP CLIENT CONFIGURATION"

read -r -p "Do you want to modify any variables? (yes/no): " MODIFY

if is_yes "$MODIFY"; then
    read -r -p "NTP package [$NTP_PACKAGE]: " INPUT
    NTP_PACKAGE=${INPUT:-$NTP_PACKAGE}

    read -r -p "NTP service [$NTP_SERVICE]: " INPUT
    NTP_SERVICE=${INPUT:-$NTP_SERVICE}

    read -r -p "NTP configuration file [$NTP_CONFIG]: " INPUT
    NTP_CONFIG=${INPUT:-$NTP_CONFIG}

    read -r -p "NTP server IP/hostname [$NTP_SERVER]: " INPUT
    NTP_SERVER=${INPUT:-$NTP_SERVER}

    read -r -p "NTP server UDP port [$NTP_PORT]: " INPUT
    NTP_PORT=${INPUT:-$NTP_PORT}
else
    echo "[INFO] Using default configuration."
fi

# -----------------------------------------------------
# VALIDATE VARIABLES
# -----------------------------------------------------

[[ "$NTP_PACKAGE" =~ ^[a-zA-Z0-9_.+-]+$ ]] \
    || error_exit "Invalid package name."

valid_service_name "$NTP_SERVICE" \
    || error_exit "Invalid service name."

[[ "$NTP_CONFIG" == /* && "$NTP_CONFIG" != *".."* ]] \
    || error_exit "Configuration path must be an absolute path without '..'."

[[ "$NTP_SERVER" =~ ^[a-zA-Z0-9._:-]+$ ]] \
    || error_exit "Invalid NTP server address."

[[ "$NTP_PORT" =~ ^[0-9]+$ ]] \
    && (( NTP_PORT >= 1 && NTP_PORT <= 65535 )) \
    || error_exit "Port must be between 1 and 65535."

SYSTEMD_OVERRIDE="/etc/systemd/system/${NTP_SERVICE}.service.d/ntp-client.conf"

show_configuration "SELECTED CLIENT CONFIGURATION"

read -r -p "Continue with this configuration? (yes/no): " CONFIRM

if ! is_yes "$CONFIRM"; then
    echo "[INFO] Operation cancelled. No configuration changes made."
    exit 0
fi

# -----------------------------------------------------
# INSTALL CHRONY
# -----------------------------------------------------

echo
echo "[INFO] Checking and installing NTP package..."

if ! rpm -q "$NTP_PACKAGE" >/dev/null 2>&1; then
    if ! dnf install -y "$NTP_PACKAGE"; then
        error_exit "Failed to install $NTP_PACKAGE."
    fi
else
    echo "[INFO] $NTP_PACKAGE is already installed."
fi

# -----------------------------------------------------
# BACKUP EXISTING CONFIGURATION
# -----------------------------------------------------

if [[ -e "$NTP_CONFIG" ]]; then
    BACKUP_FILE="${NTP_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    cp -a "$NTP_CONFIG" "$BACKUP_FILE" \
        || error_exit "Failed to back up $NTP_CONFIG."

    echo "[SUCCESS] Configuration backup created: $BACKUP_FILE"
else
    mkdir -p "$(dirname "$NTP_CONFIG")" \
        || error_exit "Unable to create configuration directory."

    touch "$NTP_CONFIG" \
        || error_exit "Unable to create $NTP_CONFIG."

    BACKUP_FILE="Not applicable (new configuration file)"
    echo "[INFO] Created new configuration file: $NTP_CONFIG"
fi

# -----------------------------------------------------
# CONFIGURE CHRONY CLIENT
# -----------------------------------------------------

echo
echo "[INFO] Configuring Chrony as an NTP client..."

TEMP_CONFIG=$(mktemp) \
    || error_exit "Unable to create temporary configuration."

# Remove old server/pool/peer entries and server-side
# allow directives, then add the selected NTP server.
if ! grep -Ev '^[[:space:]]*(server|pool|peer|allow|makestep)([[:space:]]|$)' \
    "$NTP_CONFIG" > "$TEMP_CONFIG"; then
    rm -f "$TEMP_CONFIG"
    error_exit "Unable to prepare Chrony configuration."
fi

{
    echo
    echo "# NTP client configuration managed by 02_ntp_client.sh"
    echo "server $NTP_SERVER port $NTP_PORT iburst"
    echo "makestep 1.0 3"
} >> "$TEMP_CONFIG"

if ! cat "$TEMP_CONFIG" > "$NTP_CONFIG"; then
    rm -f "$TEMP_CONFIG"
    error_exit "Unable to write Chrony configuration."
fi

rm -f "$TEMP_CONFIG"
CONFIG_CHANGED=1

# -----------------------------------------------------
# SUPPORT A CUSTOM CONFIGURATION PATH
# -----------------------------------------------------

if [[ "$NTP_CONFIG" != "/etc/chrony.conf" ]]; then
    CUSTOM_CONFIG=1

    echo "[INFO] Creating systemd override for custom config..."

    mkdir -p "$(dirname "$SYSTEMD_OVERRIDE")" \
        || error_exit "Unable to create systemd override directory."

    cat > "$SYSTEMD_OVERRIDE" <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/chronyd -n -F 2 -f $NTP_CONFIG
EOF

    systemctl daemon-reload \
        || error_exit "Failed to reload systemd."
fi

# -----------------------------------------------------
# VALIDATE CONFIGURATION
# -----------------------------------------------------

echo
echo "[INFO] Checking Chrony configuration..."

if ! chronyd -p -f "$NTP_CONFIG" >/dev/null 2>&1; then
    echo "[ERROR] Invalid Chrony configuration."

    if [[ "$BACKUP_FILE" != "Not applicable (new configuration file)" \
        && -f "$BACKUP_FILE" ]]; then
        cp -a "$BACKUP_FILE" "$NTP_CONFIG"
        echo "[INFO] Previous configuration restored."
    fi

    error_exit "Configuration validation failed."
fi

echo "[SUCCESS] Chrony configuration is valid."

# -----------------------------------------------------
# ENABLE AND RESTART CHRONY
# -----------------------------------------------------

echo
echo "[INFO] Enabling and restarting Chrony service..."

if ! systemctl enable "$NTP_SERVICE"; then
    error_exit "Failed to enable $NTP_SERVICE."
fi

if ! systemctl restart "$NTP_SERVICE"; then
    systemctl status "$NTP_SERVICE" --no-pager -l
    error_exit "Failed to restart $NTP_SERVICE."
fi

if ! systemctl is-active --quiet "$NTP_SERVICE"; then
    systemctl status "$NTP_SERVICE" --no-pager -l
    error_exit "$NTP_SERVICE is not running."
fi

echo "[SUCCESS] Chrony service started successfully."

# -----------------------------------------------------
# SHOW SERVICE STATUS
# -----------------------------------------------------

echo
print_line
echo "              CHRONY SERVICE STATUS"
print_line

systemctl status "$NTP_SERVICE" --no-pager -l

# -----------------------------------------------------
# REQUEST AN IMMEDIATE UPDATE
# -----------------------------------------------------

echo
echo "[INFO] Bringing Chrony online and requesting updates..."

chronyc online 2>&1 || true
chronyc burst 4/4 2>&1 || true

# First wait: allow normal synchronization to complete.
if ! wait_for_synchronization 60; then
    echo
    echo "[WARNING] Synchronization not confirmed after 60 seconds."
    echo "[INFO] Retrying the online and burst commands..."

    chronyc online 2>&1 || true
    chronyc burst 4/4 2>&1 || true

    # Second wait: do not restart the service again here,
    # because another restart can reset synchronization progress.
    if ! wait_for_synchronization 30; then
        SYNC_OK=0
    else
        SYNC_OK=1
    fi
else
    SYNC_OK=1
fi

# -----------------------------------------------------
# FINAL VERIFICATION
# -----------------------------------------------------

echo
print_line
echo "              NTP CLIENT VERIFICATION"
print_line

echo
echo "Configured NTP server:"
grep -E '^[[:space:]]*server[[:space:]]+' "$NTP_CONFIG" || true

show_sync_status

echo
print_line

if [[ "$SYNC_OK" -eq 1 ]] && check_synchronization; then
    echo "        NTP CLIENT SETUP SUCCESSFUL"
    print_line
    echo "[SUCCESS] Chrony service is running."
    echo "[SUCCESS] NTP source is selected."
    echo "[SUCCESS] System clock synchronized: yes"
    echo "[SUCCESS] Leap status: Normal"
    echo
    echo "NTP server      : $NTP_SERVER"
    echo "NTP server port : UDP $NTP_PORT"
    echo "Chrony service  : $NTP_SERVICE"
    echo "Config file     : $NTP_CONFIG"
    echo "Backup file     : $BACKUP_FILE"
    echo
    echo "Useful commands:"
    echo "  chronyc sources -v"
    echo "  chronyc tracking"
    echo "  timedatectl status"
    print_line
    exit 0
else
    echo "        NTP CLIENT CONFIGURED - SYNC PENDING"
    print_line
    echo "[WARNING] The client configuration was applied, but"
    echo "[WARNING] system clock synchronization is NOT confirmed."
    echo
    echo "Current synchronization status:"
    timedatectl show -p NTPSynchronized --value 2>/dev/null \
        | awk '{print "System clock synchronized: " $0}'
    echo
    echo "Troubleshooting steps:"
    echo "  1. Check the server: chronyc sources -v"
    echo "  2. Check synchronization: chronyc tracking"
    echo "  3. Test network connectivity to $NTP_SERVER."
    echo "  4. On the NTP server, check: systemctl status chronyd"
    echo "  5. On the server, verify UDP port $NTP_PORT is allowed."
    echo "  6. Check server synchronization: chronyc tracking"
    echo
    echo "Wait and check again using:"
    echo "  watch -n 2 'chronyc sources -v'"
    echo "  timedatectl status"
    echo
    echo "Do not consider the client synchronized until"
    echo "timedatectl reports: System clock synchronized: yes"
    print_line
    exit 1
fi

