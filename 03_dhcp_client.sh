
#!/bin/bash

# ============================================================
# Script Name : 04_dhcp_client.sh
# Purpose     : Automatically configure a Rocky Linux DHCP
#               client using NetworkManager.
#
# Features:
#   1. Detect network interface and active connection.
#   2. Allow interface and connection settings to be changed.
#   3. Back up the existing connection configuration.
#   4. Configure IPv4 to obtain settings automatically using DHCP.
#   5. Request an IP address from an ISC DHCP or Kea server.
#   6. Wait for a DHCP lease and verify assigned settings.
#   7. Display IP, gateway, DNS, domain and DHCP lease details.
#
# No terminal screen clearing is performed.
# ============================================================

set -Eeuo pipefail

# -------------------- DEFAULT VARIABLES ----------------------

DHCP_INTERFACE=""
DHCP_CONNECTION=""
DHCP_TIMEOUT=60
DHCP_SERVER="192.168.78.128"

BACKUP_DIR="/root/dhcp-client-backups"
BACKUP_FILE=""
NETWORK_CHANGED=0

# -------------------- FUNCTIONS ------------------------------

print_line() {
    echo "============================================================"
}

error_exit() {
    echo
    echo "[ERROR] $1"
    exit 1
}

is_yes() {
    [[ "$1" =~ ^([yY]|[yY][eE][sS])$ ]]
}

show_settings() {
    echo
    print_line
    echo "             DHCP CLIENT CONFIGURATION"
    print_line
    echo "Interface        : $DHCP_INTERFACE"
    echo "Connection       : $DHCP_CONNECTION"
    echo "DHCP Server      : $DHCP_SERVER"
    echo "DHCP Timeout     : $DHCP_TIMEOUT seconds"
    echo "Network Manager  : NetworkManager"
    print_line
}

# Find the active NetworkManager connection for an interface.
find_connection() {
    local device="$1"
    local connection

    connection="$(
        nmcli -g GENERAL.CONNECTION device show "$device" \
            2>/dev/null || true
    )"

    if [[ -n "$connection" && "$connection" != "--" ]]; then
        printf '%s\n' "$connection"
        return 0
    fi

    return 1
}

# -------------------- ROOT CHECK -----------------------------

if [[ "$EUID" -ne 0 ]]; then
    error_exit "Run this script as root."
fi

# -------------------- REQUIRED COMMANDS ----------------------

for cmd in ip nmcli systemctl date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "Required command '$cmd' is missing."
    fi
done

if ! systemctl is-active --quiet NetworkManager; then
    error_exit "NetworkManager is not running. Check systemctl status NetworkManager."
fi

# -------------------- DETECT INTERFACE -----------------------

echo
print_line
echo "          AUTOMATIC DHCP CLIENT CONFIGURATION"
print_line

echo
echo "[INFO] Detecting network interface..."

DHCP_INTERFACE="$(
    ip -4 route show default |
        awk 'NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }'
)"

# Fallback: find the first non-loopback interface with IPv4.
if [[ -z "$DHCP_INTERFACE" ]]; then
    DHCP_INTERFACE="$(
        ip -o -4 addr show scope global |
            awk '$2 !~ /^(docker|br-|veth)/ {
                print $2
                exit
            }'
    )"
fi

if [[ -z "$DHCP_INTERFACE" ]]; then
    DHCP_INTERFACE="$(
        nmcli -t -f DEVICE,TYPE device status |
            awk -F: '$2 == "ethernet" {
                print $1
                exit
            }'
    )"
fi

if [[ -z "$DHCP_INTERFACE" ]]; then
    error_exit "No suitable network interface was detected."
fi

DHCP_CONNECTION="$(find_connection "$DHCP_INTERFACE" || true)"

if [[ -z "$DHCP_CONNECTION" ]]; then
    echo "[INFO] No active connection profile found."
    echo "[INFO] Searching for an available profile..."

    DHCP_CONNECTION="$(
        nmcli -t -f NAME,DEVICE connection show |
            awk -F: -v dev="$DHCP_INTERFACE" '$2 == dev {
                print $1
                exit
            }'
    )"
fi

if [[ -z "$DHCP_CONNECTION" ]]; then
    error_exit "No NetworkManager connection profile exists for $DHCP_INTERFACE. Create a profile first."
fi

# -------------------- DISPLAY CURRENT SETTINGS ---------------

echo
echo "Detected network details:"
echo "------------------------------------------------------------"
echo "Interface       : $DHCP_INTERFACE"
echo "Connection      : $DHCP_CONNECTION"
echo "Current IPv4    : $(ip -o -4 addr show dev "$DHCP_INTERFACE" scope global | awk '{print $4}' | paste -sd ', ' -)"
echo "Current Gateway : $(ip -4 route show default dev "$DHCP_INTERFACE" | awk '{print $3}' | paste -sd ', ' -)"
echo "------------------------------------------------------------"

# -------------------- EDIT VARIABLES ------------------------

echo
echo "Press ENTER to keep the current value."
read -r -p "Modify any variables? (y/N): " EDIT

if is_yes "$EDIT"; then

    read -r -p "Network interface [$DHCP_INTERFACE]: " INPUT
    DHCP_INTERFACE="${INPUT:-$DHCP_INTERFACE}"

    # Detect the connection for the newly selected interface.
    DETECTED_CONNECTION="$(find_connection "$DHCP_INTERFACE" || true)"

    if [[ -z "$DETECTED_CONNECTION" ]]; then
        DETECTED_CONNECTION="$(
            nmcli -t -f NAME,DEVICE connection show |
                awk -F: -v dev="$DHCP_INTERFACE" '$2 == dev {
                    print $1
                    exit
                }'
        )"
    fi

    if [[ -n "$DETECTED_CONNECTION" ]]; then
        DHCP_CONNECTION="$DETECTED_CONNECTION"
    fi

    read -r -p "NetworkManager connection [$DHCP_CONNECTION]: " INPUT
    DHCP_CONNECTION="${INPUT:-$DHCP_CONNECTION}"

    read -r -p "Expected DHCP server IP/hostname [$DHCP_SERVER]: " INPUT
    DHCP_SERVER="${INPUT:-$DHCP_SERVER}"

    read -r -p "DHCP lease timeout in seconds [$DHCP_TIMEOUT]: " INPUT
    DHCP_TIMEOUT="${INPUT:-$DHCP_TIMEOUT}"

fi

# -------------------- VALIDATE INPUT -------------------------

if ! ip link show dev "$DHCP_INTERFACE" >/dev/null 2>&1; then
    error_exit "Interface '$DHCP_INTERFACE' does not exist."
fi

if ! nmcli -t -f NAME connection show |
    grep -Fxq -- "$DHCP_CONNECTION"; then
    error_exit "Connection profile '$DHCP_CONNECTION' does not exist."
fi

if [[ ! "$DHCP_TIMEOUT" =~ ^[0-9]+$ ]] ||
    (( DHCP_TIMEOUT < 10 || DHCP_TIMEOUT > 600 )); then
    error_exit "Timeout must be between 10 and 600 seconds."
fi

if [[ ! "$DHCP_SERVER" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
    error_exit "Invalid DHCP server address."
fi

show_settings

echo
echo "IMPORTANT:"
echo "- This script changes the selected profile to IPv4 DHCP mode."
echo "- Existing static IPv4 addresses, gateway and DNS settings"
echo "  in that profile will be cleared."
echo "- IPv6 settings are not intentionally changed."
echo "- The DHCP server must be reachable on this network."
echo

read -r -p "Continue with DHCP client configuration? (y/N): " CONFIRM

if ! is_yes "$CONFIRM"; then
    echo "[INFO] Cancelled. No changes made."
    exit 0
fi

# -------------------- BACKUP CONNECTION SETTINGS -------------

echo
echo "[INFO] Backing up current connection settings..."

mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/${DHCP_CONNECTION//[^a-zA-Z0-9_.-]/_}_$(date +%Y%m%d-%H%M%S).txt"

if ! nmcli connection show "$DHCP_CONNECTION" > "$BACKUP_FILE"; then
    error_exit "Unable to back up connection settings."
fi

chmod 600 "$BACKUP_FILE"

echo "[SUCCESS] Connection settings saved to:"
echo "$BACKUP_FILE"
echo "[INFO] This is a reference backup, not an importable profile."

# -------------------- CONFIGURE DHCP -------------------------

echo
echo "[INFO] Configuring IPv4 to use DHCP..."

# Record old settings for possible rollback.
OLD_METHOD="$(nmcli -g ipv4.method connection show "$DHCP_CONNECTION")"
OLD_ADDRESSES="$(nmcli -g ipv4.addresses connection show "$DHCP_CONNECTION")"
OLD_GATEWAY="$(nmcli -g ipv4.gateway connection show "$DHCP_CONNECTION")"
OLD_DNS="$(nmcli -g ipv4.dns connection show "$DHCP_CONNECTION")"
OLD_DNS_SEARCH="$(nmcli -g ipv4.dns-search connection show "$DHCP_CONNECTION")"
OLD_IGNORE_AUTO_DNS="$(nmcli -g ipv4.ignore-auto-dns connection show "$DHCP_CONNECTION")"
OLD_AUTOCONNECT="$(nmcli -g connection.autoconnect connection show "$DHCP_CONNECTION")"

NETWORK_CHANGED=1

if ! nmcli connection modify "$DHCP_CONNECTION" \
    ipv4.method auto \
    ipv4.addresses "" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.dns-search "" \
    ipv4.ignore-auto-dns no \
    connection.autoconnect yes; then

    echo "[ERROR] Could not modify the connection profile."
    NETWORK_CHANGED=0
    exit 1
fi

echo "[SUCCESS] Connection configured for automatic IPv4."
echo "[INFO] Reconnecting to request a DHCP lease..."

# -------------------- REQUEST DHCP LEASE ---------------------

if ! nmcli --wait "$DHCP_TIMEOUT" connection up \
    "$DHCP_CONNECTION" ifname "$DHCP_INTERFACE"; then

    echo
    echo "[WARNING] The connection did not come up successfully."
    echo "[INFO] Attempting to restore previous IPv4 settings..."

    nmcli connection modify "$DHCP_CONNECTION" \
        ipv4.method "$OLD_METHOD" \
        ipv4.addresses "$OLD_ADDRESSES" \
        ipv4.gateway "$OLD_GATEWAY" \
        ipv4.dns "$OLD_DNS" \
        ipv4.dns-search "$OLD_DNS_SEARCH" \
        ipv4.ignore-auto-dns "$OLD_IGNORE_AUTO_DNS" \
        connection.autoconnect "$OLD_AUTOCONNECT" || true

    echo "[INFO] Previous settings have been restored in the profile."
    echo "[INFO] Reconnecting with the previous profile settings..."

    nmcli --wait 30 connection up \
        "$DHCP_CONNECTION" ifname "$DHCP_INTERFACE" || true

    error_exit "Could not activate the DHCP connection. Check the DHCP server and network."
fi

# -------------------- WAIT FOR IPv4 ADDRESS ------------------

echo
echo "[INFO] Waiting for an IPv4 address..."

ELAPSED=0
CLIENT_IP=""

while (( ELAPSED < DHCP_TIMEOUT )); do
    CLIENT_IP="$(
        ip -o -4 addr show dev "$DHCP_INTERFACE" scope global |
            awk 'NR == 1 {print $4}'
    )"

    if [[ -n "$CLIENT_IP" ]]; then
        break
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [[ -z "$CLIENT_IP" ]]; then
    echo
    echo "[WARNING] No global IPv4 address was assigned."
    echo "[INFO] Checking NetworkManager device status..."
    nmcli device show "$DHCP_INTERFACE" || true
    error_exit "No DHCP IPv4 lease was detected. Check the server, VLAN, firewall and DHCP pool."
fi

# -------------------- FINAL VERIFICATION ---------------------

CLIENT_IP="${CLIENT_IP%%/*}"

CLIENT_GATEWAY="$(
    ip -4 route show default dev "$DHCP_INTERFACE" |
        awk 'NR == 1 {print $3}'
)"

CLIENT_DNS="$(
    nmcli -g IP4.DNS device show "$DHCP_INTERFACE" 2>/dev/null |
        paste -sd ', ' -
)"

CLIENT_DOMAIN="$(
    nmcli -g IP4.DOMAIN device show "$DHCP_INTERFACE" 2>/dev/null |
        paste -sd ', ' -
)"

echo
print_line
echo "              DHCP CLIENT VERIFICATION"
print_line

echo "Interface       : $DHCP_INTERFACE"
echo "Connection      : $DHCP_CONNECTION"
echo "Client IPv4     : $CLIENT_IP"
echo "Gateway         : ${CLIENT_GATEWAY:-Not provided}"
echo "DNS Server(s)   : ${CLIENT_DNS:-Not provided}"
echo "Domain          : ${CLIENT_DOMAIN:-Not provided}"
echo "Expected Server : $DHCP_SERVER"
echo "Backup File     : $BACKUP_FILE"

echo
echo "NetworkManager connection:"
nmcli connection show --active

echo
echo "DHCP-related options:"
nmcli -f DHCP4.OPTION device show "$DHCP_INTERFACE" 2>/dev/null || true

echo
echo "IPv4 routes:"
ip -4 route show

echo
echo "Connectivity checks:"

if [[ -n "$CLIENT_GATEWAY" ]]; then
    if ping -c 2 -W 2 "$CLIENT_GATEWAY"; then
        echo "[SUCCESS] Gateway is reachable."
    else
        echo "[WARNING] Gateway did not respond to ping."
        echo "[INFO] Some gateways block ICMP; this alone does not prove failure."
    fi
else
    echo "[WARNING] No default gateway was received."
fi

echo
print_line
echo "              DHCP CLIENT CONFIGURED"
print_line
echo "[SUCCESS] NetworkManager connection is active."
echo "[SUCCESS] An IPv4 address is assigned to the client."
echo
echo "To inspect the lease and network settings:"
echo "  nmcli device show $DHCP_INTERFACE"
echo "  nmcli -f DHCP4.OPTION device show $DHCP_INTERFACE"
echo "  ip -4 route"
echo
echo "To renew by reconnecting:"
echo "  nmcli connection down \"$DHCP_CONNECTION\""
echo "  nmcli connection up \"$DHCP_CONNECTION\""
echo
echo "NOTE: The expected DHCP server is $DHCP_SERVER."
echo "The client lease must be checked to confirm which server"
echo "provided it; an assigned address alone does not prove that."
print_line

