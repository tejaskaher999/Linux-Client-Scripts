
#!/bin/bash

# =====================================================
# RHEL YUM/DNF CLIENT REPOSITORY CONFIGURATION SCRIPT
# =====================================================

# Variables that the system administrator can change
HTTP_PATH="/var/www/html/rhel"
PACKAGE_NAME=("AppStream" "BaseOS")
REPO_CONFIG_PATH="/etc/yum.repos.d/local.repo"

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: Please run this script as root."
    echo "Usage: sudo bash yum_client.sh"
    exit 1
fi

# Get repository server IP address
read -rp "Enter the Repository Server IP address: " USER_SERVER_IP

# Validate input
if [[ -z "$USER_SERVER_IP" ]]; then
    echo "Error: Repository Server IP cannot be empty."
    exit 1
fi

# Backup existing repository configuration
if [[ -f "$REPO_CONFIG_PATH" ]]; then
    cp -a "$REPO_CONFIG_PATH" \
        "${REPO_CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)"
    echo "Backup of existing local.repo created."
fi

# Create repository configuration file
cat > "$REPO_CONFIG_PATH" <<EOF
EOF

# Configure AppStream and BaseOS repositories
for i in "${PACKAGE_NAME[@]}"; do
    cat >> "$REPO_CONFIG_PATH" <<EOF
[$i]
name=RHEL $i Local Repository
baseurl=http://${USER_SERVER_IP}${HTTP_PATH}/${i}/
enabled=1
gpgcheck=0
metadata_expire=-1

EOF
done

echo "Repository configuration created:"
cat "$REPO_CONFIG_PATH"

# Refresh repository metadata
echo
echo "Cleaning DNF/YUM cache..."
dnf clean all

echo
echo "Refreshing repository metadata..."
if ! dnf makecache; then
    echo "Error: Failed to refresh repository metadata."
    echo "Check the server IP, HTTP access, and repository paths."
    exit 1
fi

# Display enabled repositories
echo
echo "Available repositories:"
dnf repolist

echo
echo "Repository setup completed successfully!"
echo "You can now install packages using:"
echo "dnf install <package_name>"

