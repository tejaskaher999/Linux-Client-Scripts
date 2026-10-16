
#!/bin/bash

# =====================================================
# RHEL / ROCKY LINUX YUM-DNF CLIENT CONFIGURATION
# =====================================================

# Variables that the system administrator can change
HTTP_PATH="/rhel"
PACKAGE_NAME=("AppStream" "BaseOS")
REPO_CONFIG_PATH="/etc/yum.repos.d/local.repo"

# -----------------------------------------------------
# 1. Check root privileges
# -----------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Error: Please run this script as root."
    echo "Usage: sudo bash yum_client.sh"
    exit 1
fi

# -----------------------------------------------------
# 2. Get repository server IP address
# -----------------------------------------------------
read -rp "Enter the Repository Server IP address: " USER_SERVER_IP

if [[ -z "$USER_SERVER_IP" ]]; then
    echo "Error: Repository Server IP cannot be empty."
    exit 1
fi

# Basic IPv4 validation
if [[ ! "$USER_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: Please enter a valid IPv4 address."
    exit 1
fi

# -----------------------------------------------------
# 3. Check required commands
# -----------------------------------------------------
for cmd in curl dnf; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' is not installed."
        exit 1
    fi
done

# -----------------------------------------------------
# 4. Test repository server and metadata URLs
# -----------------------------------------------------
echo
echo "Testing repository server: $USER_SERVER_IP"
echo

for i in "${PACKAGE_NAME[@]}"; do
    REPO_URL="http://${USER_SERVER_IP}${HTTP_PATH}/${i}/repodata/repomd.xml"

    echo "Checking $i repository..."
    HTTP_STATUS=$(curl -sS -o /dev/null \
        --connect-timeout 5 --max-time 10 \
        -w "%{http_code}" "$REPO_URL")
    CURL_STATUS=$?

    if [[ $CURL_STATUS -ne 0 || "$HTTP_STATUS" != "200" ]]; then
        echo "Error: Cannot access $i repository metadata."
        echo "URL: $REPO_URL"
        echo "HTTP status: ${HTTP_STATUS:-connection failed}"
        echo "Check the server IP, Apache configuration, firewall,"
        echo "repository path, and repodata/repomd.xml file."
        exit 1
    fi

    echo "$i repository is accessible."
done

# -----------------------------------------------------
# 5. Back up existing repository configuration
# -----------------------------------------------------
if [[ -f "$REPO_CONFIG_PATH" ]]; then
    BACKUP_PATH="${REPO_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"

    if cp -a "$REPO_CONFIG_PATH" "$BACKUP_PATH"; then
        echo
        echo "Existing configuration backed up to:"
        echo "$BACKUP_PATH"
    else
        echo "Error: Could not back up existing configuration."
        exit 1
    fi
fi

# -----------------------------------------------------
# 6. Create local repository configuration
# -----------------------------------------------------
if ! cat > "$REPO_CONFIG_PATH" <<EOF
[AppStream]
name=RHEL AppStream Local Repository
baseurl=http://${USER_SERVER_IP}${HTTP_PATH}/AppStream/
enabled=1
gpgcheck=0
metadata_expire=-1

[BaseOS]
name=RHEL BaseOS Local Repository
baseurl=http://${USER_SERVER_IP}${HTTP_PATH}/BaseOS/
enabled=1
gpgcheck=0
metadata_expire=-1
EOF
then
    echo "Error: Failed to create repository configuration."
    exit 1
fi

echo
echo "Repository configuration created:"
cat "$REPO_CONFIG_PATH"

# -----------------------------------------------------
# 7. Clean DNF cache
# -----------------------------------------------------
echo
echo "Cleaning DNF cache..."
if ! dnf clean all; then
    echo "Warning: DNF cache cleanup reported an error."
fi

# -----------------------------------------------------
# 8. Refresh only the local repositories
# -----------------------------------------------------
echo
echo "Refreshing local repository metadata..."

if ! dnf --disablerepo='*' \
    --enablerepo=AppStream,BaseOS makecache; then
    echo
    echo "Error: Failed to refresh local repository metadata."
    echo "Check the repository URLs and metadata on the server."
    exit 1
fi

# -----------------------------------------------------
# 9. Display configured local repositories
# -----------------------------------------------------
echo
echo "Local repositories:"
dnf --disablerepo='*' \
    --enablerepo=AppStream,BaseOS repolist

# -----------------------------------------------------
# 10. Display usage instructions
# -----------------------------------------------------
echo
echo "=============================================="
echo " Local YUM/DNF client setup completed!"
echo "=============================================="
echo
echo "Install a package from local repositories:"
echo "dnf --disablerepo='*' --enablerepo=AppStream,BaseOS install <package_name>"
echo
echo "Example:"
echo "dnf --disablerepo='*' --enablerepo=AppStream,BaseOS install tree"

