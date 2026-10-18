#!/bin/bash

# ============================================================
# Script Name : 11_iSCSI_client.sh
# Purpose     : Configure an iSCSI Initiator Client
# OS          : Rocky Linux / RHEL
# Features    : Auto-detection, discovery, login, disk checks,
#               optional filesystem, mounting and /etc/fstab
# ============================================================

set -Eeuo pipefail

# -------------------- Default Variables ---------------------

DEFAULT_SERVER_IP="192.168.78.128"
DEFAULT_PORT="3260"
DEFAULT_TARGET_IQN="iqn.2024-04.com.skynet:target1"
DEFAULT_MOUNT_POINT="/media/iscsi"

INITIATOR_FILE="/etc/iscsi/initiatorname.iscsi"
ISCSI_CONF="/etc/iscsi/iscsid.conf"
FSTAB_FILE="/etc/fstab"

# -------------------- Helper Functions ----------------------

info() {
    echo -e "\n[INFO] $*"
}

success() {
    echo -e "\n[SUCCESS] $*"
}

warning() {
    echo -e "\n[WARNING] $*"
}

error() {
    echo -e "\n[ERROR] $*" >&2
    exit 1
}

ask() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
}

confirm_yes() {
    local prompt="$1"
    local answer

    read -r -p "$prompt (y/N): " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

valid_ipv4() {
    local ip="$1"
    local octet
    local -a parts

    IFS='.' read -r -a parts <<< "$ip"
    [[ ${#parts[@]} -eq 4 ]] || return 1

    for octet in "${parts[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done

    return 0
}

valid_iqn() {
    [[ "$1" =~ ^iqn\.[A-Za-z0-9:.-]+$ ]]
}

# List disk device names, one per line.
list_disks() {
    lsblk -dn -o NAME,TYPE |
        awk '$2 == "disk" {print $1}' |
        sort
}

# -------------------- Root Check ---------------------------

[[ $EUID -eq 0 ]] || error "Run this script as root."

# -------------------- Operating System Check ---------------

if [[ -r /etc/os-release ]]; then
    . /etc/os-release

    case "${ID:-}" in
        rocky|rhel|almalinux|ol)
            ;;
        *)
            warning "This script is intended for Rocky Linux / RHEL."
            confirm_yes "Continue anyway?" ||
                error "Cancelled by user."
            ;;
    esac
fi

# -------------------- Initial Information ------------------

echo
echo "============================================================"
echo "          iSCSI INITIATOR - CLIENT CONFIGURATION"
echo "============================================================"

echo "Client hostname : $(hostname -f 2>/dev/null || hostname)"
echo
echo "Client IP addresses:"

if command -v ip >/dev/null 2>&1; then
    ip -brief address show
fi

echo
echo "Current block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

# -------------------- Detect Initiator IQN -----------------

CURRENT_IQN=""

if [[ -f "$INITIATOR_FILE" ]]; then
    CURRENT_IQN="$(
        sed -n 's/^[[:space:]]*InitiatorName[[:space:]]*=[[:space:]]*//p' \
            "$INITIATOR_FILE" | head -n 1
    )"
fi

if [[ -z "$CURRENT_IQN" ]]; then
    SHORT_HOST="$(hostname -s | tr '[:upper:]' '[:lower:]')"
    CURRENT_IQN="iqn.2026-10.com.tejas:${SHORT_HOST}"
    warning "No configured initiator IQN was found."
    echo "Suggested IQN: $CURRENT_IQN"
fi

echo
echo "Detected initiator IQN: $CURRENT_IQN"

# -------------------- Existing Sessions --------------------

echo
echo "Existing iSCSI sessions:"

if command -v iscsiadm >/dev/null 2>&1; then
    iscsiadm -m session 2>/dev/null || echo "No active sessions."
else
    echo "iscsiadm is not installed yet."
fi

# -------------------- Configuration Inputs -----------------

echo
echo "============================================================"
echo "             iSCSI CLIENT CONFIGURATION"
echo "============================================================"

SERVER_IP="$(ask "iSCSI server IPv4 address" "$DEFAULT_SERVER_IP")"

while ! valid_ipv4 "$SERVER_IP"; do
    warning "Invalid IPv4 address."
    SERVER_IP="$(ask "iSCSI server IPv4 address" "$DEFAULT_SERVER_IP")"
done

PORT="$(ask "iSCSI TCP port" "$DEFAULT_PORT")"

while ! [[ "$PORT" =~ ^[0-9]+$ ]] ||
      (( 10#$PORT < 1 || 10#$PORT > 65535 )); do
    warning "Enter a port from 1 to 65535."
    PORT="$(ask "iSCSI TCP port" "$DEFAULT_PORT")"
done

PORT=$((10#$PORT))

TARGET_IQN="$(ask "iSCSI target IQN" "$DEFAULT_TARGET_IQN")"

while ! valid_iqn "$TARGET_IQN"; do
    warning "Invalid target IQN format."
    TARGET_IQN="$(ask "iSCSI target IQN" "$DEFAULT_TARGET_IQN")"
done

INITIATOR_IQN="$(ask "Client initiator IQN" "$CURRENT_IQN")"

while ! valid_iqn "$INITIATOR_IQN"; do
    warning "Invalid initiator IQN format."
    INITIATOR_IQN="$(ask "Client initiator IQN" "$CURRENT_IQN")"
done

MOUNT_POINT="$(ask "Mount point for iSCSI storage" "$DEFAULT_MOUNT_POINT")"

if [[ "$MOUNT_POINT" != /* ||
      "$MOUNT_POINT" == "/" ||
      "$MOUNT_POINT" == *" "* ]]; then
    error "Mount point must be an absolute path other than / and contain no spaces."
fi

# -------------------- Configuration Summary ---------------

echo
echo "============================================================"
echo "                 CONFIGURATION SUMMARY"
echo "============================================================"
echo "iSCSI server IP : $SERVER_IP"
echo "TCP port        : $PORT"
echo "Target IQN      : $TARGET_IQN"
echo "Initiator IQN   : $INITIATOR_IQN"
echo "Mount point     : $MOUNT_POINT"
echo "Initiator file  : $INITIATOR_FILE"
echo "============================================================"

echo
echo "IMPORTANT:"
echo "- The server's target ACL must allow this initiator IQN."
echo "- Do not format an existing disk containing important data."
echo "- Do not mount a shared writable filesystem on multiple clients."

confirm_yes "Continue with this configuration?" ||
    error "Cancelled by user."

# -------------------- Install Packages ---------------------

info "Installing iSCSI initiator utilities"

dnf install -y iscsi-initiator-utils util-linux

command -v iscsiadm >/dev/null 2>&1 ||
    error "iscsiadm is not available after package installation."

# -------------------- Configure Initiator IQN --------------

info "Configuring initiator IQN"

mkdir -p /etc/iscsi

if [[ -f "$INITIATOR_FILE" ]]; then
    cp -p "$INITIATOR_FILE" \
        "${INITIATOR_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
fi

if [[ ! -f "$INITIATOR_FILE" ]] ||
   ! grep -q '^[[:space:]]*InitiatorName[[:space:]]*=' "$INITIATOR_FILE"; then
    printf 'InitiatorName=%s\n' "$INITIATOR_IQN" > "$INITIATOR_FILE"
else
    sed -i \
        "s|^[[:space:]]*InitiatorName[[:space:]]*=.*|InitiatorName=${INITIATOR_IQN}|" \
        "$INITIATOR_FILE"
fi

success "Initiator IQN configured: $INITIATOR_IQN"

# -------------------- Start Services -----------------------

info "Enabling and starting iSCSI services"

systemctl enable --now iscsid

# The iscsi service handles configured node/session startup.
systemctl enable iscsi

# -------------------- Check Network ------------------------

info "Checking connectivity to ${SERVER_IP}:${PORT}"

if command -v nc >/dev/null 2>&1; then
    if nc -z -w 5 "$SERVER_IP" "$PORT"; then
        success "TCP port $PORT is reachable."
    else
        warning "TCP connection failed. Discovery will still be attempted."
        echo "Check the server IP, target service and server firewall."
    fi
else
    warning "nc is unavailable; skipping the preliminary port check."
fi

# -------------------- Discover Target ----------------------

info "Discovering iSCSI targets"

DISCOVERY_OUTPUT=""

if ! DISCOVERY_OUTPUT="$(
    iscsiadm -m discovery -t st -p "${SERVER_IP}:${PORT}" 2>&1
)"; then
    echo "$DISCOVERY_OUTPUT"
    error "Target discovery failed. Check the server, network and target service."
fi

echo "$DISCOVERY_OUTPUT"

if ! grep -Fq "$TARGET_IQN" <<< "$DISCOVERY_OUTPUT"; then
    warning "The configured target IQN was not found in this discovery output."
    echo "Targets reported by the server:"
    echo "$DISCOVERY_OUTPUT"

    error "Verify TARGET_IQN and the server's iSCSI configuration."
fi

success "Target discovered: $TARGET_IQN"

# -------------------- Capture Disks Before Login ------------

BEFORE_DISKS="$(list_disks)"

# -------------------- Configure Node Startup ---------------

info "Configuring the discovered target node"

if ! iscsiadm -m node \
    -T "$TARGET_IQN" \
    -p "${SERVER_IP}:${PORT}" \
    --op update -n node.startup -v automatic; then
    error "Could not configure automatic startup for the target node."
fi

# -------------------- Login --------------------------------

info "Logging in to the iSCSI target"

if iscsiadm -m session 2>/dev/null |
    grep -Fq "$TARGET_IQN"; then
    success "A session for this target already exists."
else
    if ! iscsiadm -m node \
        -T "$TARGET_IQN" \
        -p "${SERVER_IP}:${PORT}" \
        --login; then
        error "Login failed. Check the initiator ACL on the server."
    fi
    success "Successfully logged in to the target."
fi

udevadm settle
sleep 2

# -------------------- Verify Session ------------------------

echo
echo "============================================================"
echo "                 ACTIVE iSCSI SESSIONS"
echo "============================================================"

if ! iscsiadm -m session; then
    error "No active iSCSI session found."
fi

# -------------------- Identify Attached Disks ---------------

AFTER_DISKS="$(list_disks)"

echo
echo "============================================================"
echo "                BLOCK DEVICE INFORMATION"
echo "============================================================"

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS

echo
echo "Disks detected before login:"
if [[ -n "$BEFORE_DISKS" ]]; then
    echo "$BEFORE_DISKS"
else
    echo "No disk devices detected."
fi

echo
echo "Disks detected after login:"
if [[ -n "$AFTER_DISKS" ]]; then
    echo "$AFTER_DISKS"
else
    echo "No disk devices detected."
fi

echo
echo "New disk candidates:"
NEW_DISKS="$(
    comm -13 \
        <(printf '%s\n' "$BEFORE_DISKS" | sed '/^$/d' | sort -u) \
        <(printf '%s\n' "$AFTER_DISKS" | sed '/^$/d' | sort -u)
)"

if [[ -n "$NEW_DISKS" ]]; then
    while IFS= read -r disk; do
        [[ -n "$disk" ]] && echo "/dev/$disk"
    done <<< "$NEW_DISKS"
else
    echo "No newly detected disk. The LUN may already have been attached."
fi

# -------------------- Optional Storage Setup ----------------

echo
echo "============================================================"
echo "             OPTIONAL STORAGE CONFIGURATION"
echo "============================================================"
echo "The iSCSI login is complete."
echo "You can stop here if you only want to connect the LUN."
echo
echo "1. Do not format or mount anything"
echo "2. Select a disk and configure its filesystem/mount"

read -r -p "Choose option [1-2]: " STORAGE_OPTION

case "$STORAGE_OPTION" in
    1)
        info "Skipping filesystem and mount configuration."
        ;;

    2)
        echo
        echo "Available disk devices:"
        lsblk -dn -o NAME,SIZE,TYPE,MODEL

        echo
        read -r -p "Enter the whole disk path, e.g. /dev/sdb: " LUN_DEVICE

        [[ "$LUN_DEVICE" == /dev/* ]] ||
            error "Enter an absolute device path such as /dev/sdb."

        [[ -b "$LUN_DEVICE" ]] ||
            error "$LUN_DEVICE is not a block device."

        DEVICE_TYPE="$(lsblk -dnro TYPE "$LUN_DEVICE")"

        [[ "$DEVICE_TYPE" == "disk" ]] ||
            error "Select a whole disk, not a partition or logical volume."

        # Confirm this device is associated with an iSCSI session.
        DEVICE_REAL="$(readlink -f "$LUN_DEVICE")"
        DEVICE_NAME="$(basename "$DEVICE_REAL")"

        if [[ ! -e "/sys/class/iscsi_session" ]]; then
            warning "Could not find the expected iSCSI sysfs directory."
            echo "Inspect lsblk and /dev/disk/by-path before proceeding."
            confirm_yes "Are you certain this is the intended iSCSI LUN?" ||
                error "Cancelled."
        fi

        echo
        echo "Selected device details:"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$LUN_DEVICE"

        echo
        echo "Existing signatures, if any:"
        wipefs -n "$LUN_DEVICE" || true

        EXISTING_FS="$(lsblk -dnro FSTYPE "$LUN_DEVICE" | head -n 1)"
        EXISTING_MOUNT="$(lsblk -dnro MOUNTPOINT "$LUN_DEVICE" | head -n 1)"

        if [[ -n "$EXISTING_MOUNT" ]]; then
            error "$LUN_DEVICE is already mounted at $EXISTING_MOUNT."
        fi

        if [[ -n "$EXISTING_FS" ]]; then
            echo
            success "Existing filesystem detected: $EXISTING_FS"
            echo "The script will not format this disk."
            FS_TYPE="$EXISTING_FS"
        else
            echo
            warning "No filesystem was detected on the selected whole disk."
            echo "Formatting will destroy existing data on this device."
            echo "Only proceed if this is a new, dedicated iSCSI LUN."

            confirm_yes "Format $LUN_DEVICE as a new filesystem?" ||
                error "Formatting cancelled."

            echo "Choose filesystem:"
            echo "1. XFS"
            echo "2. ext4"

            read -r -p "Filesystem [1-2]: " FS_OPTION

            case "$FS_OPTION" in
                1) FS_TYPE="xfs" ;;
                2) FS_TYPE="ext4" ;;
                *) error "Invalid filesystem choice." ;;
            esac

            read -r -p "Type FORMAT to confirm formatting $LUN_DEVICE: " FORMAT_CONFIRM
            [[ "$FORMAT_CONFIRM" == "FORMAT" ]] ||
                error "Formatting cancelled."

            if [[ "$FS_TYPE" == "xfs" ]]; then
                command -v mkfs.xfs >/dev/null 2>&1 ||
                    dnf install -y xfsprogs
                mkfs.xfs "$LUN_DEVICE"
            else
                command -v mkfs.ext4 >/dev/null 2>&1 ||
                    dnf install -y e2fsprogs
                mkfs.ext4 "$LUN_DEVICE"
            fi

            success "Filesystem created: $FS_TYPE"
        fi

        # Obtain filesystem UUID.
        udevadm settle

        UUID="$(blkid -s UUID -o value "$LUN_DEVICE" || true)"

        [[ -n "$UUID" ]] ||
            error "No filesystem UUID found on $LUN_DEVICE."

        echo
        echo "Filesystem UUID: $UUID"

        # Create mount point and back up fstab.
        mkdir -p "$MOUNT_POINT"

        if mountpoint -q "$MOUNT_POINT"; then
            error "$MOUNT_POINT is already a mount point."
        fi

        FSTAB_BACKUP="${FSTAB_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp -p "$FSTAB_FILE" "$FSTAB_BACKUP"
        success "Backup created: $FSTAB_BACKUP"

        # Do not add a duplicate UUID entry.
        if grep -Eq "^[[:space:]]*UUID=${UUID}[[:space:]]" "$FSTAB_FILE"; then
            info "An fstab entry for this UUID already exists."
        else
            echo
            echo "Choose whether to mount automatically at boot."
            if confirm_yes "Add a permanent /etc/fstab entry?"; then
                read -r -p "Filesystem mount options [defaults,_netdev]: " MOUNT_OPTIONS
                MOUNT_OPTIONS="${MOUNT_OPTIONS:-defaults,_netdev}"

                if [[ "$MOUNT_OPTIONS" == *" "* ||
                      "$MOUNT_OPTIONS" == *"," ||
                      "$MOUNT_OPTIONS" == *$'\n'* ]]; then
                    error "Enter mount options without spaces or commas, e.g. defaults,_netdev"
                fi

                printf 'UUID=%s %s %s %s 0 0\n' \
                    "$UUID" "$MOUNT_POINT" "$FS_TYPE" "$MOUNT_OPTIONS" \
                    >> "$FSTAB_FILE"

                success "Added persistent mount entry."
            fi
        fi

        # Mount the selected filesystem now.
        info "Mounting iSCSI filesystem"

        if ! mount "$MOUNT_POINT"; then
            # If no fstab entry exists, mount explicitly by device.
            if ! grep -Eq "^[[:space:]]*UUID=${UUID}[[:space:]]" "$FSTAB_FILE"; then
                mount -t "$FS_TYPE" "$LUN_DEVICE" "$MOUNT_POINT"
            else
                error "Mount failed. Check /etc/fstab and filesystem details."
            fi
        fi

        success "Storage mounted at $MOUNT_POINT"

        echo
        echo "Mounted filesystem:"
        findmnt "$MOUNT_POINT"
        df -h "$MOUNT_POINT"
        ;;

    *)
        error "Invalid option. Choose 1 or 2."
        ;;
esac

# -------------------- Final Summary ------------------------

echo
echo "============================================================"
echo "       iSCSI INITIATOR CLIENT CONFIGURATION COMPLETE"
echo "============================================================"
echo "Server IP      : $SERVER_IP"
echo "TCP port       : $PORT"
echo "Target IQN     : $TARGET_IQN"
echo "Initiator IQN  : $INITIATOR_IQN"
echo
echo "Useful commands:"
echo "  iscsiadm -m discovery -t st -p ${SERVER_IP}:${PORT}"
echo "  iscsiadm -m session"
echo "  iscsiadm -m node"
echo "  lsblk -f"
echo "  blkid"
echo "  findmnt"
echo "  systemctl status iscsid"
echo "  systemctl status iscsi"
echo "============================================================"

success "iSCSI client script finished."

