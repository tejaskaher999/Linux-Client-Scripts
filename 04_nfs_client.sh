#!/bin/bash

# ============================================================
# Script Name : 04_nfs_client.sh
# Purpose     : Configure an NFS client on Rocky Linux
# Features    :
#   1. Detect client network interface and IP automatically
#   2. Configure all variables through editable defaults/prompts
#   3. Validate server IP and directory paths
#   4. Install NFS utilities
#   5. Check server export visibility
#   6. Create local mount directory
#   7. Back up /etc/fstab before modifying it
#   8. Add a managed persistent NFS mount entry safely
#   9. Mount the NFS share and verify access
#  10. Display final status and useful commands
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# 1. DEFAULT CONFIGURATION
# Edit these defaults whenever required.
# You can also change them when the script prompts you.
# ------------------------------------------------------------

NFS_SERVER_IP="192.168.78.128"
REMOTE_SHARE_DIR="/srv/nfs"
LOCAL_MOUNT_DIR="/mnt/nfs"

MOUNT_OPTIONS="rw,hard,_netdev"
FSTAB_FILE="/etc/fstab"
DEMO_FILE="export.txt"

# Persistent mounting at boot: yes or no
PERSISTENT_MOUNT="yes"

# Automatically detected client network configuration
CLIENT_INTERFACE=""
CLIENT_IP=""

# ------------------------------------------------------------
# 2. HELPER FUNCTIONS
# ------------------------------------------------------------

print_line() {
    printf '%*s\n' 60 '' | tr ' ' '='
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

is_valid_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except ValueError:
    sys.exit(1)
PY
}

is_valid_absolute_path() {
    [[ "$1" == /* ]] &&
    [[ "$1" != "/" ]] &&
    [[ "$1" != *" "* ]] &&
    [[ "$1" != *","* ]] &&
    [[ "$1" != *"("* ]] &&
    [[ "$1" != *")"* ]] &&
    [[ "$1" != *"#"* ]]
}

# ------------------------------------------------------------
# 3. CHECK ROOT PRIVILEGES AND REQUIRED COMMANDS
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Run as root: sudo ./04_nfs_client.sh"
fi

for command in ip python3 systemctl dnf awk grep sed \
               mount umount mountpoint findmnt cp; do
    command -v "$command" >/dev/null 2>&1 ||
        error "Required command not found: $command"
done

# ------------------------------------------------------------
# 4. AUTOMATICALLY DETECT CLIENT INTERFACE AND IP
# ------------------------------------------------------------

echo
print_line
echo "             NFS CLIENT CONFIGURATION"
print_line
echo
echo "Detecting client network configuration..."

# Prefer the interface used to reach the NFS server.
CLIENT_INTERFACE="$(
    ip -o route get "$NFS_SERVER_IP" 2>/dev/null |
    awk '{
        for (i = 1; i <= NF; i++)
            if ($i == "dev") {
                print $(i+1)
                exit
            }
    }'
)"

if [[ -n "$CLIENT_INTERFACE" ]]; then
    CLIENT_IP="$(
        ip -o -4 addr show dev "$CLIENT_INTERFACE" scope global \
            2>/dev/null |
        awk 'NR == 1 {
            split($4, address, "/")
            print address[1]
            exit
        }'
    )"
fi

# Fallback: detect the first global IPv4 interface.
if [[ -z "$CLIENT_INTERFACE" || -z "$CLIENT_IP" ]]; then
    DETECTED_LINE="$(
        ip -o -4 addr show scope global 2>/dev/null |
        awk 'NR == 1 {
            print $2, $4
            exit
        }'
    )"

    if [[ -n "$DETECTED_LINE" ]]; then
        read -r CLIENT_INTERFACE DETECTED_CIDR <<< "$DETECTED_LINE"
        CLIENT_IP="${DETECTED_CIDR%/*}"
    fi
fi

echo
echo "Detected client configuration:"
print_line
echo "Client interface   : ${CLIENT_INTERFACE:-Not detected}"
echo "Client IP          : ${CLIENT_IP:-Not detected}"
echo "NFS server IP      : $NFS_SERVER_IP"
echo "Remote share       : $REMOTE_SHARE_DIR"
echo "Local mount point  : $LOCAL_MOUNT_DIR"
echo "Mount options      : $MOUNT_OPTIONS"
echo "Persistent mount   : $PERSISTENT_MOUNT"
echo "fstab file         : $FSTAB_FILE"
print_line

# ------------------------------------------------------------
# 5. EDIT CONFIGURATION
# Press ENTER to keep the displayed value.
# ------------------------------------------------------------

echo
echo "Press ENTER to keep each current value."
echo

read -r -p "NFS server IP [$NFS_SERVER_IP]: " INPUT
NFS_SERVER_IP="${INPUT:-$NFS_SERVER_IP}"

read -r -p "Remote share directory [$REMOTE_SHARE_DIR]: " INPUT
REMOTE_SHARE_DIR="${INPUT:-$REMOTE_SHARE_DIR}"

read -r -p "Local mount directory [$LOCAL_MOUNT_DIR]: " INPUT
LOCAL_MOUNT_DIR="${INPUT:-$LOCAL_MOUNT_DIR}"

read -r -p "Mount options [$MOUNT_OPTIONS]: " INPUT
MOUNT_OPTIONS="${INPUT:-$MOUNT_OPTIONS}"

read -r -p "Demo filename [$DEMO_FILE]: " INPUT
DEMO_FILE="${INPUT:-$DEMO_FILE}"

read -r -p "Persistent mount at boot? (yes/no) [$PERSISTENT_MOUNT]: " INPUT
PERSISTENT_MOUNT="${INPUT:-$PERSISTENT_MOUNT}"

# ------------------------------------------------------------
# 6. VALIDATE CONFIGURATION
# ------------------------------------------------------------

is_valid_ipv4 "$NFS_SERVER_IP" ||
    error "Invalid NFS server IPv4 address: $NFS_SERVER_IP"

[[ "$NFS_SERVER_IP" != "0.0.0.0" ]] ||
    error "The server IP cannot be 0.0.0.0."

is_valid_absolute_path "$REMOTE_SHARE_DIR" ||
    error "Invalid remote share path: $REMOTE_SHARE_DIR"

is_valid_absolute_path "$LOCAL_MOUNT_DIR" ||
    error "Invalid local mount path: $LOCAL_MOUNT_DIR"

[[ "$REMOTE_SHARE_DIR" != "$LOCAL_MOUNT_DIR" ]] ||
    error "Remote share and local mount paths must be different."

[[ "$MOUNT_OPTIONS" != *$'\n'* &&
   "$MOUNT_OPTIONS" != *$'\r'* &&
   "$MOUNT_OPTIONS" != *" "* &&
   "$MOUNT_OPTIONS" != *"#"* ]] ||
    error "Invalid mount options."

[[ "$MOUNT_OPTIONS" =~ ^[a-zA-Z0-9_.,=-]+$ ]] ||
    error "Mount options contain unsupported characters."

[[ "$DEMO_FILE" != */* &&
   -n "$DEMO_FILE" &&
   "$DEMO_FILE" != "." &&
   "$DEMO_FILE" != ".." &&
   "$DEMO_FILE" != *" "* &&
   "$DEMO_FILE" != *"#"* ]] ||
    error "Enter a valid demo filename."

case "$PERSISTENT_MOUNT" in
    yes|no) ;;
    *) error "Persistent mount must be yes or no." ;;
esac

# ------------------------------------------------------------
# 7. SHOW FINAL CONFIGURATION AND ASK FOR CONFIRMATION
# ------------------------------------------------------------

echo
echo "Final NFS client configuration:"
print_line
echo "Client interface   : ${CLIENT_INTERFACE:-Not detected}"
echo "Client IP          : ${CLIENT_IP:-Not detected}"
echo "NFS server IP      : $NFS_SERVER_IP"
echo "Remote share       : $REMOTE_SHARE_DIR"
echo "Local mount point  : $LOCAL_MOUNT_DIR"
echo "Mount options      : $MOUNT_OPTIONS"
echo "Demo filename      : $DEMO_FILE"
echo "Persistent mount   : $PERSISTENT_MOUNT"
echo "fstab file         : $FSTAB_FILE"
print_line

echo
echo "IMPORTANT:"
echo "- The NFS server must export the selected remote directory."
echo "- The client IP must be allowed by the server export."
echo "- Existing /etc/fstab entries will be preserved."
echo "- Existing local data in the mount directory may be hidden"
echo "  while the NFS share is mounted."
echo

read -r -p "Continue with NFS client setup? (y/N): " CONFIRM

case "$CONFIRM" in
    y|Y|yes|YES|Yes) ;;
    *)
        echo "Setup cancelled. No NFS client configuration changes made."
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 8. INSTALL NFS UTILITIES
# ------------------------------------------------------------

echo
echo "Installing NFS utilities..."
dnf install -y nfs-utils

command -v mount.nfs >/dev/null 2>&1 ||
    error "NFS mount helper is unavailable after installation."

# ------------------------------------------------------------
# 9. CHECK NETWORK CONNECTIVITY
# ------------------------------------------------------------

echo
echo "Checking network route to NFS server..."

if ! ip route get "$NFS_SERVER_IP" >/dev/null 2>&1; then
    error "No route to NFS server $NFS_SERVER_IP."
fi

echo "A network route to $NFS_SERVER_IP exists."

# ------------------------------------------------------------
# 10. CHECK SERVER EXPORTS
# ------------------------------------------------------------

echo
echo "Checking NFS server exports..."

if ! command -v showmount >/dev/null 2>&1; then
    error "showmount is unavailable. Check nfs-utils installation."
fi

if ! EXPORT_OUTPUT="$(showmount -e "$NFS_SERVER_IP" 2>&1)"; then
    echo "$EXPORT_OUTPUT"
    error "Cannot query server exports. Check server NFS/RPC services, firewall, and network connectivity."
fi

echo "$EXPORT_OUTPUT"

if ! printf '%s\n' "$EXPORT_OUTPUT" |
    awk -v share="$REMOTE_SHARE_DIR" '
        $1 == share { found = 1 }
        END { exit !found }
    '; then
    error "The server does not list $REMOTE_SHARE_DIR in showmount output. Check /etc/exports on the server."
fi

echo "Requested share is listed by the NFS server."

# ------------------------------------------------------------
# 11. CREATE LOCAL MOUNT DIRECTORY
# ------------------------------------------------------------

echo
echo "Preparing local mount directory..."

if [[ -e "$LOCAL_MOUNT_DIR" && ! -d "$LOCAL_MOUNT_DIR" ]]; then
    error "$LOCAL_MOUNT_DIR exists but is not a directory."
fi

mkdir -p "$LOCAL_MOUNT_DIR"

echo "Local mount directory ready: $LOCAL_MOUNT_DIR"

# ------------------------------------------------------------
# 12. CHECK WHETHER THE SHARE IS ALREADY MOUNTED
# ------------------------------------------------------------

echo
echo "Checking existing mount..."

if mountpoint -q "$LOCAL_MOUNT_DIR"; then
    CURRENT_SOURCE="$(
        findmnt -n -o SOURCE --target "$LOCAL_MOUNT_DIR" || true
    )"
    CURRENT_FSTYPE="$(
        findmnt -n -o FSTYPE --target "$LOCAL_MOUNT_DIR" || true
    )"

    if [[ "$CURRENT_SOURCE" == "$NFS_SERVER_IP:$REMOTE_SHARE_DIR" &&
          "$CURRENT_FSTYPE" == nfs* ]]; then
        echo "The requested NFS share is already mounted."
        ALREADY_MOUNTED=yes
    else
        echo "Current source: ${CURRENT_SOURCE:-Unknown}"
        echo "Current type  : ${CURRENT_FSTYPE:-Unknown}"
        error "Mount point is already occupied by another filesystem. Choose a different local mount directory."
    fi
else
    ALREADY_MOUNTED=no
fi

# ------------------------------------------------------------
# 13. BACK UP /etc/fstab IF PERSISTENCE IS ENABLED
# ------------------------------------------------------------

if [[ "$PERSISTENT_MOUNT" == "yes" ]]; then
    echo
    echo "Preparing persistent mount configuration..."

    [[ -f "$FSTAB_FILE" ]] ||
        error "$FSTAB_FILE does not exist."

    BACKUP_FILE="${FSTAB_FILE}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FSTAB_FILE" "$BACKUP_FILE"
    echo "Backup created: $BACKUP_FILE"

    # Replace only this script's managed block.
    # All unrelated fstab entries are preserved.
    python3 - "$FSTAB_FILE" "$NFS_SERVER_IP" \
        "$REMOTE_SHARE_DIR" "$LOCAL_MOUNT_DIR" \
        "$MOUNT_OPTIONS" <<'PY'
import os
import sys
import tempfile

fstab, server, remote, local, options = sys.argv[1:]

begin = "# BEGIN managed by 04_nfs_client.sh"
end = "# END managed by 04_nfs_client.sh"

with open(fstab, "r", encoding="utf-8") as file:
    original = file.read()

result = []
inside = False

for line in original.splitlines():
    if line.strip() == begin:
        inside = True
        continue
    if line.strip() == end:
        inside = False
        continue
    if not inside:
        result.append(line)

# Refuse to silently override a pre-existing unmanaged entry
# targeting the same mount point.
for line in result:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue

    fields = stripped.split()
    if len(fields) >= 2 and fields[1] == local:
        raise SystemExit(
            f"ERROR: An unmanaged fstab entry already uses {local}:\n"
            f"{line}\n"
            "Review /etc/fstab manually before continuing."
        )

while result and not result[-1].strip():
    result.pop()

result.extend([
    begin,
    f"{server}:{remote}\t{local}\tnfs\t{options}\t0 0",
    end,
])

new_content = "\n".join(result) + "\n"
directory = os.path.dirname(fstab) or "."

fd, temp_path = tempfile.mkstemp(prefix=".fstab.", dir=directory)

try:
    with os.fdopen(fd, "w", encoding="utf-8") as file:
        file.write(new_content)

    os.chmod(temp_path, os.stat(fstab).st_mode & 0o777)
    os.chown(temp_path, os.stat(fstab).st_uid, os.stat(fstab).st_gid)
    os.replace(temp_path, fstab)

except Exception:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
    raise
PY

    echo "Persistent NFS entry configured in $FSTAB_FILE."
else
    echo
    echo "Persistent mounting disabled; /etc/fstab will not be changed."
fi

# ------------------------------------------------------------
# 14. MOUNT NFS SHARE
# ------------------------------------------------------------

echo
echo "Mounting NFS share..."

if [[ "$ALREADY_MOUNTED" == "no" ]]; then
    if ! mount -t nfs -o "$MOUNT_OPTIONS" \
        "$NFS_SERVER_IP:$REMOTE_SHARE_DIR" "$LOCAL_MOUNT_DIR"; then
        echo
        echo "ERROR: NFS mount failed."
        echo "Check:"
        echo "  1. Server IP and exported directory"
        echo "  2. Server /etc/exports and exportfs -v"
        echo "  3. Server firewall and NFS services"
        echo "  4. Client network and server access rules"
        echo "  5. SELinux/audit logs if access is denied"
        exit 1
    fi
else
    echo "Using the existing NFS mount."
fi

mountpoint -q "$LOCAL_MOUNT_DIR" ||
    error "Mount verification failed."

ACTUAL_SOURCE="$(
    findmnt -n -o SOURCE --target "$LOCAL_MOUNT_DIR" || true
)"
ACTUAL_FSTYPE="$(
    findmnt -n -o FSTYPE --target "$LOCAL_MOUNT_DIR" || true
)"

[[ "$ACTUAL_FSTYPE" == nfs* ]] ||
    error "The mount point is not reporting an NFS filesystem."

echo "NFS mount successful."
echo "Mounted source: $ACTUAL_SOURCE"

# ------------------------------------------------------------
# 15. VERIFY ACCESS TO THE DEMO FILE
# ------------------------------------------------------------

echo
echo "Verifying shared directory access..."

if [[ -r "$LOCAL_MOUNT_DIR/$DEMO_FILE" ]]; then
    echo "Demo file found: $LOCAL_MOUNT_DIR/$DEMO_FILE"
    echo
    echo "Demo file contents:"
    cat "$LOCAL_MOUNT_DIR/$DEMO_FILE"
else
    echo "WARNING: Demo file is missing or unreadable:"
    echo "  $LOCAL_MOUNT_DIR/$DEMO_FILE"
    echo "The share is mounted, but verify the filename and permissions."
fi

# ------------------------------------------------------------
# 16. FINAL STATUS
# ------------------------------------------------------------

echo
print_line
echo "             NFS CLIENT CONFIGURED"
print_line

echo
echo "NFS Server IP:"
echo "  $NFS_SERVER_IP"

echo
echo "Client Interface:"
echo "  ${CLIENT_INTERFACE:-Not detected}"

echo
echo "Client IP:"
echo "  ${CLIENT_IP:-Not detected}"

echo
echo "Remote Shared Directory:"
echo "  $REMOTE_SHARE_DIR"

echo
echo "Local Mount Directory:"
echo "  $LOCAL_MOUNT_DIR"

echo
echo "Filesystem Status:"
findmnt --target "$LOCAL_MOUNT_DIR"

echo
echo "Persistent Mount:"
echo "  $PERSISTENT_MOUNT"

if [[ "$PERSISTENT_MOUNT" == "yes" ]]; then
    echo "fstab entry:"
    sed -n '/# BEGIN managed by 04_nfs_client.sh/,/# END managed by 04_nfs_client.sh/p' "$FSTAB_FILE"
fi

echo
echo "Useful client commands:"
echo "  showmount -e $NFS_SERVER_IP"
echo "  mount | grep nfs"
echo "  findmnt $LOCAL_MOUNT_DIR"
echo "  df -h $LOCAL_MOUNT_DIR"
echo "  ls -la $LOCAL_MOUNT_DIR"
echo "  cat $LOCAL_MOUNT_DIR/$DEMO_FILE"

echo
echo "Unmount command:"
echo "  umount $LOCAL_MOUNT_DIR"

echo
echo "NOTES:"
echo "- Run server-side configuration on the NFS server."
echo "- Files are stored on the server, not copied to the client."
echo "- root_squash and filesystem permissions affect write access."
echo "- Do not unmount while applications are using the share."
echo "- If boot mounting fails, check network availability and /etc/fstab."
print_line

