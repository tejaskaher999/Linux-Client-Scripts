#!/bin/bash

# ==========================================================
# RHEL / ROCKY LINUX NTP CLIENT CONFIGURATION
# Uses Chrony to synchronize time with an NTP server
# ==========================================================

# ---------- Default variables ----------
NTP_PACKAGE="chrony"
NTP_SERVICE="chronyd"
NTP_CONFIG="/etc/chrony.conf"
NTP_PORT="123"
NTP_SERVER="192.168.78.128"

# ---------- Colors ----------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
info()    { echo -e "${CYAN}[INFO]${RESET} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${RESET} $1"; }

# ---------- 1. Check root privileges ----------
if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
    echo "Usage: sudo bash 13_ntp_client.sh"
    exit 1
fi

# ---------- 2. Display default configuration ----------
echo
echo "====================================================="
echo "          NTP CLIENT CONFIGURATION"
echo "====================================================="
echo "NTP_PACKAGE  = $NTP_PACKAGE"
echo "NTP_SERVICE  = $NTP_SERVICE"
echo "NTP_CONFIG   = $NTP_CONFIG"
echo "NTP_PORT     = $NTP_PORT"
echo "NTP_SERVER   = $NTP_SERVER"
echo "====================================================="

read -r -p "Do you want to modify any variables? (yes/no): " MODIFY

case "$MODIFY" in
    yes|YES|Yes|y|Y)
        read -r -p "NTP package [$NTP_PACKAGE]: " INPUT
        NTP_PACKAGE="${INPUT:-$NTP_PACKAGE}"

        read -r -p "NTP service [$NTP_SERVICE]: " INPUT
        NTP_SERVICE="${INPUT:-$NTP_SERVICE}"

        read -r -p "NTP configuration file [$NTP_CONFIG]: " INPUT
        NTP_CONFIG="${INPUT:-$NTP_CONFIG}"

        read -r -p "NTP server IP/hostname [$NTP_SERVER]: " INPUT
        NTP_SERVER="${INPUT:-$NTP_SERVER}"

        read -r -p "NTP server UDP port [$NTP_PORT]: " INPUT
        NTP_PORT="${INPUT:-$NTP_PORT}"
        ;;

    no|NO|No|n|N)
        info "Using default configuration."
        ;;

    *)
        error "Invalid choice. Exiting."
        exit 1
        ;;
esac

# ---------- 3. Validate configuration ----------
if [[ ! "$NTP_PACKAGE" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    error "Invalid package name."
    exit 1
fi

if [[ ! "$NTP_SERVICE" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
    error "Invalid service name."
    exit 1
fi

if [[ ! "$NTP_CONFIG" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
   [[ "$NTP_CONFIG" == *"/../"* ]] ||
   [[ "$NTP_CONFIG" == */.. ]]; then
    error "Invalid configuration file path."
    exit 1
fi

if [[ ! "$NTP_SERVER" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
    error "Invalid NTP server IP address or hostname."
    exit 1
fi

if ! [[ "$NTP_PORT" =~ ^[0-9]+$ ]] ||
   (( 10#$NTP_PORT < 1 || 10#$NTP_PORT > 65535 )); then
    error "Port must be between 1 and 65535."
    exit 1
fi

NTP_PORT=$((10#$NTP_PORT))

# ---------- 4. Confirm selected configuration ----------
echo
echo "====================================================="
echo "          SELECTED CLIENT CONFIGURATION"
echo "====================================================="
echo "Package          : $NTP_PACKAGE"
echo "Service          : $NTP_SERVICE"
echo "Configuration    : $NTP_CONFIG"
echo "NTP Server       : $NTP_SERVER"
echo "Server UDP Port  : $NTP_PORT"
echo "====================================================="

read -r -p "Continue with this configuration? (yes/no): " CONFIRM

case "$CONFIRM" in
    yes|YES|Yes|y|Y) ;;
    *)
        info "Operation cancelled. No changes made."
        exit 0
        ;;
esac

# ---------- 5. Install Chrony ----------
echo
info "Checking and installing NTP package..."

if ! rpm -q "$NTP_PACKAGE" >/dev/null 2>&1; then
    if ! dnf install -y "$NTP_PACKAGE"; then
        error "Package installation failed."
        exit 1
    fi
else
    info "$NTP_PACKAGE is already installed."
fi

if ! rpm -q "$NTP_PACKAGE" >/dev/null 2>&1; then
    error "NTP package is not installed."
    exit 1
fi

# ---------- 6. Check configuration file ----------
if [[ ! -f "$NTP_CONFIG" ]]; then
    error "Configuration file not found: $NTP_CONFIG"
    echo "Check the configured path and the installed package."
    exit 1
fi

# ---------- 7. Back up existing configuration ----------
BACKUP="${NTP_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

if ! cp -a "$NTP_CONFIG" "$BACKUP"; then
    error "Could not back up the existing configuration."
    exit 1
fi

success "Configuration backup created: $BACKUP"

# ---------- 8. Configure Chrony client ----------
echo
info "Configuring Chrony as an NTP client..."

# Remove existing server, pool, peer and local-server
# allow directives. Keep other settings intact.
if ! sed -i \
    -e '/^[[:space:]]*server[[:space:]]/d' \
    -e '/^[[:space:]]*pool[[:space:]]/d' \
    -e '/^[[:space:]]*peer[[:space:]]/d' \
    -e '/^[[:space:]]*allow[[:space:]]/d' \
    -e '/^[[:space:]]*makestep[[:space:]]/d' \
    "$NTP_CONFIG"; then
    error "Could not update configuration."
    cp -a "$BACKUP" "$NTP_CONFIG"
    exit 1
fi

# Add the selected NTP server.
{
    echo
    echo "# NTP client configuration managed by 13_ntp_client.sh"
    echo "server $NTP_SERVER port $NTP_PORT iburst"
    echo "makestep 1.0 3"
} >> "$NTP_CONFIG"

# If using a custom config path, tell systemd to launch
# chronyd with that configuration file.
if [[ "$NTP_CONFIG" != "/etc/chrony.conf" ]]; then
    DROPIN_DIR="/etc/systemd/system/${NTP_SERVICE}.service.d"
    DROPIN_FILE="$DROPIN_DIR/ntp-client.conf"

    mkdir -p "$DROPIN_DIR" || {
        error "Could not create systemd override directory."
        cp -a "$BACKUP" "$NTP_CONFIG"
        exit 1
    }

    if [[ -f "$DROPIN_FILE" ]]; then
        cp -a "$DROPIN_FILE" "${DROPIN_FILE}.bak.$(date +%Y%m%d%H%M%S)" || exit 1
    fi

    cat > "$DROPIN_FILE" <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/chronyd -n -F 2 -f $NTP_CONFIG
EOF

    systemctl daemon-reload || exit 1
fi

# ---------- 9. Validate configuration ----------
echo
info "Checking Chrony configuration..."

if ! chronyd -p -f "$NTP_CONFIG" >/dev/null 2>&1; then
    error "Chrony configuration validation failed."
    echo "Restoring previous configuration..."
    cp -a "$BACKUP" "$NTP_CONFIG"
    exit 1
fi

success "Chrony configuration is valid."

# ---------- 10. Enable and restart service ----------
echo
info "Enabling and restarting Chrony service..."

if ! systemctl enable "$NTP_SERVICE"; then
    error "Could not enable $NTP_SERVICE."
    exit 1
fi

if ! systemctl restart "$NTP_SERVICE"; then
    error "Could not restart $NTP_SERVICE."
    echo "Check: journalctl -u $NTP_SERVICE --no-pager -n 50"
    exit 1
fi

success "Chrony service started successfully."

# ---------- 11. Display service status ----------
echo
echo "====================================================="
echo "              CHRONY SERVICE STATUS"
echo "====================================================="
systemctl --no-pager --full status "$NTP_SERVICE" || true

# ---------- 12. Request an immediate update ----------
echo
info "Requesting an immediate time update..."

chronyc online >/dev/null 2>&1 || true
chronyc burst 4/4 || true
sleep 2

# ---------- 13. Verify NTP synchronization ----------
echo
echo "====================================================="
echo "              NTP CLIENT VERIFICATION"
echo "====================================================="

echo
echo "Configured NTP server:"
grep -E '^[[:space:]]*server[[:space:]]' "$NTP_CONFIG" || true

echo
echo "Chrony sources:"
chronyc sources -v || true

echo
echo "Chrony tracking:"
chronyc tracking || true

echo
echo "System clock synchronization:"
timedatectl status || true

echo
echo "====================================================="
echo "          NTP CLIENT SETUP COMPLETED"
echo "====================================================="
echo "NTP server      : $NTP_SERVER"
echo "NTP server port : UDP $NTP_PORT"
echo "Chrony service  : $NTP_SERVICE"
echo "Config file     : $NTP_CONFIG"
echo "Backup file     : $BACKUP"
echo
echo "Useful verification commands:"
echo "  systemctl status $NTP_SERVICE"
echo "  chronyc sources -v"
echo "  chronyc tracking"
echo "  timedatectl status"
echo
echo "Look for '*' in chronyc sources to identify the"
echo "currently selected synchronization source."
echo "====================================================="

