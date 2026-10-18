
#!/bin/bash

# ============================================================
# Script Name : 05_samba_client.sh
# Purpose     : Configure Samba client on Rocky Linux
# Server      : 192.168.78.128
# Share       : data
# ============================================================

set -Eeuo pipefail

# ---------------- DEFAULT CONFIGURATION ----------------

SERVER_IP="192.168.78.128"
SHARE_NAME="data"
SAMBA_USERNAME="tejas"
MOUNT_POINT="/mnt/samba"
PERSISTENT_MOUNT="yes"
FSTAB_FILE="/etc/fstab"
CREDENTIALS_FILE="/etc/samba/credentials_data"

BEGIN_MARKER="# BEGIN managed by 05_samba_client.sh"
END_MARKER="# END managed by 05_samba_client.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------- HELPER FUNCTIONS ----------------

error()   { echo -e "${RED}ERROR: $*${NC}" >&2; }
success() { echo -e "${GREEN}$*${NC}"; }
warning() { echo -e "${YELLOW}$*${NC}"; }
info()    { echo -e "${BLUE}$*${NC}"; }

prompt_value() {
    local variable_name="$1"
    local prompt_text="$2"
    local current_value="$3"
    local entered_value=""

    read -r -p "$prompt_text [$current_value]: " entered_value

    if [[ -n "$entered_value" ]]; then
        printf -v "$variable_name" '%s' "$entered_value"
    fi
}

valid_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except ipaddress.AddressValueError:
    sys.exit(1)
PY
}

# ---------------- ROOT CHECK ----------------

if [[ "$EUID" -ne 0 ]]; then
    error "Run this script as root."
    echo "Example: sudo ./05_samba_client.sh"
    exit 1
fi

# Do not clear the screen.
echo
echo "============================================================"
echo "             SAMBA CLIENT CONFIGURATION"
echo "============================================================"
echo
echo "Detecting client network configuration..."

CLIENT_INTERFACE="$(ip route show default 2>/dev/null |
    awk 'NR==1 {print $5}')"

CLIENT_IP="Unknown"

if [[ -n "$CLIENT_INTERFACE" ]]; then
    DETECTED_IP="$(ip -o -4 addr show dev "$CLIENT_INTERFACE" scope global 2>/dev/null |
        awk 'NR==1 {split($4,a,"/"); print a[1]}')"

    [[ -n "$DETECTED_IP" ]] && CLIENT_IP="$DETECTED_IP"
fi

echo
echo "Detected client configuration:"
echo "============================================================"
echo "Client interface : ${CLIENT_INTERFACE:-Unknown}"
echo "Client IP        : $CLIENT_IP"
echo "Samba server IP  : $SERVER_IP"
echo "Share name       : $SHARE_NAME"
echo "Samba username   : $SAMBA_USERNAME"
echo "Mount directory  : $MOUNT_POINT"
echo "Persistent mount : $PERSISTENT_MOUNT"
echo "============================================================"
echo

# ---------------- CONFIGURATION PROMPTS ----------------

echo "Press Enter to keep the default values."
echo

prompt_value SERVER_IP "Samba server IPv4 address" "$SERVER_IP"
prompt_value SHARE_NAME "Samba share name" "$SHARE_NAME"
prompt_value SAMBA_USERNAME "Samba username" "$SAMBA_USERNAME"
prompt_value MOUNT_POINT "Client mount directory" "$MOUNT_POINT"
prompt_value CREDENTIALS_FILE "Credentials file path" "$CREDENTIALS_FILE"

while true; do
    read -r -p "Mount automatically at boot? (Y/n) [$PERSISTENT_MOUNT]: " answer

    case "${answer,,}" in
        ""|y|yes)
            PERSISTENT_MOUNT="yes"
            break
            ;;
        n|no)
            PERSISTENT_MOUNT="no"
            break
            ;;
        *)
            echo "Please enter Y or N."
            ;;
    esac
done

# ---------------- VALIDATION ----------------

if ! valid_ipv4 "$SERVER_IP"; then
    error "Invalid server IPv4 address."
    exit 1
fi

if [[ ! "$SHARE_NAME" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    error "Invalid share name."
    exit 1
fi

if [[ ! "$SAMBA_USERNAME" =~ ^[a-zA-Z0-9_.@-]+$ ]]; then
    error "Invalid Samba username."
    exit 1
fi

if [[ "$MOUNT_POINT" != /* ||
      "$MOUNT_POINT" == "/" ||
      "$MOUNT_POINT" =~ [[:space:]] ||
      "$MOUNT_POINT" == *","* ]]; then
    error "Mount point must be absolute and contain no spaces or commas."
    exit 1
fi

if [[ "$CREDENTIALS_FILE" != /* ||
      "$CREDENTIALS_FILE" =~ [[:space:]] ||
      "$CREDENTIALS_FILE" == *","* ||
      "$CREDENTIALS_FILE" == "/" ]]; then
    error "Credentials path must be absolute and contain no spaces or commas."
    exit 1
fi

if [[ "$CREDENTIALS_FILE" == "$FSTAB_FILE" ||
      "$CREDENTIALS_FILE" == "$MOUNT_POINT" ]]; then
    error "Credentials path conflicts with another configuration path."
    exit 1
fi

# ---------------- FINAL SUMMARY ----------------

echo
echo "Final Samba client configuration:"
echo "============================================================"
echo "Client interface : ${CLIENT_INTERFACE:-Unknown}"
echo "Client IP        : $CLIENT_IP"
echo "Samba server IP  : $SERVER_IP"
echo "Share name       : $SHARE_NAME"
echo "Samba username   : $SAMBA_USERNAME"
echo "Mount directory  : $MOUNT_POINT"
echo "Persistent mount : $PERSISTENT_MOUNT"
echo "fstab file       : $FSTAB_FILE"
echo "Credentials file : $CREDENTIALS_FILE"
echo "============================================================"
echo
echo "The password will be hidden while entering it."
echo "The credentials file will be readable only by root."
echo

read -r -p "Continue with Samba client setup? (y/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warning "Setup cancelled."
    exit 0
fi

# ---------------- INSTALL PACKAGES ----------------

echo
info "Installing Samba client packages..."

dnf install -y cifs-utils samba-client

for cmd in ip awk python3 smbclient mount mountpoint findmnt; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command not found: $cmd"
        exit 1
    fi
done

if ! command -v mount.cifs >/dev/null 2>&1; then
    error "mount.cifs is unavailable. Check cifs-utils."
    exit 1
fi

success "Required packages are ready."

# ---------------- READ PASSWORD ----------------

echo
echo "Enter the Samba password for: $SAMBA_USERNAME"

read -r -s -p "Samba password: " SAMBA_PASSWORD
echo

read -r -s -p "Confirm Samba password: " SAMBA_PASSWORD_CONFIRM
echo

if [[ -z "$SAMBA_PASSWORD" ]]; then
    unset SAMBA_PASSWORD SAMBA_PASSWORD_CONFIRM
    error "Password cannot be empty."
    exit 1
fi

if [[ "$SAMBA_PASSWORD" != "$SAMBA_PASSWORD_CONFIRM" ]]; then
    unset SAMBA_PASSWORD SAMBA_PASSWORD_CONFIRM
    error "Passwords do not match."
    exit 1
fi

unset SAMBA_PASSWORD_CONFIRM

# ---------------- CREATE CREDENTIALS FILE ----------------

echo
info "Creating secure credentials file..."

mkdir -p "$(dirname "$CREDENTIALS_FILE")"

umask 077
install -m 600 -o root -g root /dev/null "$CREDENTIALS_FILE"

# Keep the format simple and omit the domain field.
# This avoids forcing a potentially incorrect workgroup/domain.
{
    printf 'username=%s\n' "$SAMBA_USERNAME"
    printf 'password=%s\n' "$SAMBA_PASSWORD"
} > "$CREDENTIALS_FILE"

chown root:root "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"

unset SAMBA_PASSWORD

success "Credentials file created with permissions 600."

# ---------------- TEST SMB AUTHENTICATION ----------------

SHARE_SOURCE="//$SERVER_IP/$SHARE_NAME"

echo
info "Testing Samba authentication using smbclient..."

if ! smbclient "$SHARE_SOURCE" \
    -A "$CREDENTIALS_FILE" -c 'ls'; then
    error "smbclient authentication failed."
    echo "Check the Samba username, password, share name and server permissions."
    exit 1
fi

success "smbclient authentication succeeded."

# ---------------- PREPARE MOUNT POINT ----------------

echo
info "Preparing mount directory..."

mkdir -p "$MOUNT_POINT"

ALREADY_MOUNTED="no"
SELECTED_VERSION=""

if mountpoint -q "$MOUNT_POINT"; then
    CURRENT_SOURCE="$(findmnt -n -o SOURCE --target "$MOUNT_POINT" || true)"

    if [[ "$CURRENT_SOURCE" != "$SHARE_SOURCE" ]]; then
        error "Mount directory is already used by another source."
        echo "Current source : $CURRENT_SOURCE"
        echo "Expected source: $SHARE_SOURCE"
        echo "Choose another mount directory or inspect the existing mount."
        exit 1
    fi

    ALREADY_MOUNTED="yes"

    CURRENT_OPTIONS="$(findmnt -n -o OPTIONS --target "$MOUNT_POINT" || true)"
    SELECTED_VERSION="$(printf '%s\n' "$CURRENT_OPTIONS" |
        tr ',' '\n' | grep -E '^vers=' | head -n 1 || true)"

    success "The requested share is already mounted."
fi

# ---------------- MOUNT SHARE ----------------

if [[ "$ALREADY_MOUNTED" == "no" ]]; then

    echo
    info "Attempting CIFS mount..."

    MOUNT_SUCCEEDED="no"

    # Test modern SMB dialects. Protocol changes do not fix
    # incorrect credentials, but help rule out dialect issues.
    for VERSION in "3.1.1" "3.0" "2.1" "default"; do

        if [[ "$VERSION" == "default" ]]; then
            CURRENT_MOUNT_OPTIONS="credentials=$CREDENTIALS_FILE,rw"
            VERSION_LABEL="system default"
        else
            CURRENT_MOUNT_OPTIONS="credentials=$CREDENTIALS_FILE,rw,vers=$VERSION"
            VERSION_LABEL="SMB $VERSION"
        fi

        echo
        echo "Trying mount with protocol: $VERSION_LABEL"

        if mount -t cifs "$SHARE_SOURCE" "$MOUNT_POINT" \
            -o "$CURRENT_MOUNT_OPTIONS"; then

            MOUNT_SUCCEEDED="yes"

            if [[ "$VERSION" == "default" ]]; then
                SELECTED_VERSION=""
            else
                SELECTED_VERSION="vers=$VERSION"
            fi

            success "Mount succeeded using $VERSION_LABEL."
            break
        fi

        warning "Mount failed using $VERSION_LABEL."
    done

    if [[ "$MOUNT_SUCCEEDED" != "yes" ]]; then
        error "All CIFS mount attempts failed."
        echo
        echo "smbclient succeeded, but the kernel CIFS mount failed."
        echo "Recent kernel messages:"
        dmesg | tail -n 25 || true
        echo
        echo "Check the Samba account and server-side logs."
        echo "Credentials file: $CREDENTIALS_FILE"
        echo "No new fstab entry has been written by this run."
        exit 1
    fi
fi

# ---------------- CONFIGURE PERSISTENT MOUNT ----------------

if [[ "$PERSISTENT_MOUNT" == "yes" ]]; then

    echo
    info "Configuring persistent mount in $FSTAB_FILE..."

    if [[ ! -f "$FSTAB_FILE" ]]; then
        error "$FSTAB_FILE does not exist."
        exit 1
    fi

    FSTAB_BACKUP="${FSTAB_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp -a "$FSTAB_FILE" "$FSTAB_BACKUP"
    echo "Backup created: $FSTAB_BACKUP"

    FSTAB_OPTIONS="credentials=$CREDENTIALS_FILE,rw,_netdev"

    if [[ -n "$SELECTED_VERSION" ]]; then
        FSTAB_OPTIONS="$FSTAB_OPTIONS,$SELECTED_VERSION"
    fi

    if ! python3 - \
        "$FSTAB_FILE" \
        "$MOUNT_POINT" \
        "$SHARE_SOURCE" \
        "$FSTAB_OPTIONS" \
        "$BEGIN_MARKER" \
        "$END_MARKER" <<'PY'
import sys
from pathlib import Path

(
    fstab_path,
    mount_point,
    share_source,
    mount_options,
    begin_marker,
    end_marker,
) = sys.argv[1:]

path = Path(fstab_path)
lines = path.read_text().splitlines()

# Remove this script's previous managed block.
output = []
inside_block = False

for line in lines:
    stripped = line.strip()

    if stripped == begin_marker:
        if inside_block:
            raise SystemExit("ERROR: Nested managed fstab block.")
        inside_block = True
        continue

    if stripped == end_marker:
        if not inside_block:
            raise SystemExit("ERROR: End marker without start marker.")
        inside_block = False
        continue

    if not inside_block:
        output.append(line)

if inside_block:
    raise SystemExit("ERROR: Managed fstab block has no end marker.")

# Avoid duplicating or overwriting manually managed mount entries.
for line in output:
    stripped = line.strip()

    if not stripped or stripped.startswith("#"):
        continue

    fields = stripped.split()

    if len(fields) >= 2 and fields[1] == mount_point:
        raise SystemExit(
            "ERROR: An unmanaged fstab entry already uses mount point "
            + mount_point
            + ". Review that entry manually."
        )

entry = (
    f"{share_source} {mount_point} cifs "
    f"{mount_options} 0 0"
)

if output and output[-1].strip():
    output.append("")

output.extend([begin_marker, entry, end_marker])

path.write_text("\n".join(output) + "\n")
PY
    then
        error "Could not safely update fstab."
        echo "The share is mounted for this session, but boot configuration needs review."
        echo "Backup: $FSTAB_BACKUP"
        exit 1
    fi

    systemctl daemon-reload
    success "Persistent mount entry saved."
else
    info "Persistent mounting is disabled. fstab was not changed."
fi

# ---------------- FINAL VERIFICATION ----------------

echo
info "Verifying Samba mount..."

if ! mountpoint -q "$MOUNT_POINT"; then
    error "Mount verification failed."
    exit 1
fi

echo
success "============================================================"
success "       SAMBA CLIENT CONFIGURATION COMPLETED"
success "============================================================"

echo
echo "Mount details:"
echo "------------------------------------------------------------"
findmnt --target "$MOUNT_POINT"
echo "------------------------------------------------------------"

echo
echo "Share contents:"
ls -la "$MOUNT_POINT"

echo
echo "Useful commands:"
echo "  Check mount   : findmnt --target $MOUNT_POINT"
echo "  Check disk    : df -h $MOUNT_POINT"
echo "  List files    : ls -la $MOUNT_POINT"
echo "  Unmount share : umount $MOUNT_POINT"
echo "  Test access   : smbclient $SHARE_SOURCE -A $CREDENTIALS_FILE -c 'ls'"

if [[ "$PERSISTENT_MOUNT" == "yes" ]]; then
    echo "  Boot mount    : Enabled through $FSTAB_FILE"
else
    echo "  Boot mount    : Disabled"
fi

echo
warning "Keep $CREDENTIALS_FILE private. Do not display its contents."
success "Samba client setup finished successfully."

