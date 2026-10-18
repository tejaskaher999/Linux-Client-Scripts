#!/bin/bash

# ============================================================
# 06. SSH CLIENT CONFIGURATION
# Rocky Linux 10
# ============================================================

set -o pipefail

KEY_FILE="$HOME/.ssh/id_ed25519"
PUBLIC_KEY="${KEY_FILE}.pub"

SERVER_IP="192.168.78.128"
REMOTE_USER="root"
SSH_PORT="22"

# ============================================================
# Functions
# ============================================================

error() {
    echo "ERROR: $*"
}

success() {
    echo "SUCCESS: $*"
}

warning() {
    echo "WARNING: $*"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# ============================================================
# Check privileges and SSH tools
# ============================================================

echo "============================================================"
echo "              06. SSH CLIENT CONFIGURATION"
echo "============================================================"
echo

if [[ "$EUID" -eq 0 ]]; then
    echo "Running as root."
    echo "SSH keys will be managed under $HOME/.ssh."
else
    echo "Running as user: $USER"
    echo "SSH keys will be managed under $HOME/.ssh."
fi

echo
echo "This script configures and tests SSH client access."
echo "It does not modify the remote SSH server configuration."
echo

if ! command -v ssh >/dev/null 2>&1 ||
   ! command -v ssh-keygen >/dev/null 2>&1 ||
   ! command -v ssh-copy-id >/dev/null 2>&1 ||
   ! command -v scp >/dev/null 2>&1; then

    if [[ "$EUID" -ne 0 ]]; then
        error "Install SSH client tools as root:"
        echo "sudo dnf install -y openssh-clients"
        exit 1
    fi

    echo "Installing SSH client packages..."

    if ! dnf install -y openssh-clients; then
        error "Could not install openssh-clients."
        exit 1
    fi
fi

success "SSH client tools are available."

# ============================================================
# Get remote server details
# ============================================================

echo
echo "Enter the SSH server details."
echo "Press Enter to use the default values."
echo

read -r -p "SSH server IP/hostname [$SERVER_IP]: " INPUT
SERVER_IP="${INPUT:-$SERVER_IP}"

read -r -p "Remote username [$REMOTE_USER]: " INPUT
REMOTE_USER="${INPUT:-$REMOTE_USER}"

read -r -p "SSH port [$SSH_PORT]: " INPUT
SSH_PORT="${INPUT:-$SSH_PORT}"

if [[ ! "$SERVER_IP" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
    error "Invalid server IP address or hostname."
    exit 1
fi

if [[ ! "$REMOTE_USER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    error "Invalid remote username."
    exit 1
fi

if ! valid_port "$SSH_PORT"; then
    error "Invalid SSH port. Use a port from 1 to 65535."
    exit 1
fi

REMOTE_TARGET="${REMOTE_USER}@${SERVER_IP}"

echo
echo "============================================================"
echo "SSH CLIENT DETAILS"
echo "============================================================"
echo "Server       : $SERVER_IP"
echo "Username     : $REMOTE_USER"
echo "Port         : $SSH_PORT"
echo "Target       : $REMOTE_TARGET"
echo "Private key  : $KEY_FILE"
echo "Public key   : $PUBLIC_KEY"
echo "============================================================"

# ============================================================
# Test network connectivity
# ============================================================

echo
echo "Testing network connectivity..."

if command -v ping >/dev/null 2>&1; then
    if ping -c 2 -W 2 "$SERVER_IP" >/dev/null 2>&1; then
        success "Server responded to ping."
    else
        warning "Ping failed. ICMP may be blocked."
        echo "Continuing with the SSH port test."
    fi
else
    warning "ping command is unavailable."
fi

# ============================================================
# Test SSH TCP port
# ============================================================

echo
echo "Testing TCP port $SSH_PORT..."

if timeout 5 bash -c \
    ':</dev/tcp/"$1"/"$2"' _ "$SERVER_IP" "$SSH_PORT" \
    2>/dev/null; then

    success "SSH port $SSH_PORT is reachable."

else
    warning "Could not connect to $SERVER_IP:$SSH_PORT."
    echo "Check the server IP, SSH service, firewall and port."

    read -r -p "Continue anyway? (y/N): " CONTINUE

    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ============================================================
# Test SSH login
# ============================================================

echo
echo "Testing SSH connection..."
echo "You may need to accept the server host key"
echo "or enter the remote account password."
echo

if ssh \
    -o ConnectTimeout=8 \
    -o NumberOfPasswordPrompts=1 \
    -p "$SSH_PORT" \
    "$REMOTE_TARGET" \
    "echo 'SSH connection successful'; hostname; whoami"; then

    success "SSH login test completed."
else
    warning "SSH login test failed or was cancelled."
    echo "Check the username, credentials, port and server settings."
fi

# ============================================================
# Optional passwordless authentication
# ============================================================

echo
read -r -p \
"Configure passwordless SSH using an Ed25519 key? (yes/no): " \
KEY_CHOICE

if [[ "$KEY_CHOICE" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then

    echo
    echo "Preparing SSH key authentication..."

    if ! mkdir -p "$HOME/.ssh"; then
        error "Could not create $HOME/.ssh."
        exit 1
    fi

    chmod 700 "$HOME/.ssh"

    # --------------------------------------------------------
    # Generate a key only if one does not already exist
    # --------------------------------------------------------

    if [[ ! -f "$KEY_FILE" ]]; then

        echo "Generating an Ed25519 SSH key..."
        echo "You may set a passphrase or press Enter for none."

        if ! ssh-keygen -t ed25519 -f "$KEY_FILE"; then
            error "SSH key generation failed."
            exit 1
        fi

    elif [[ ! -f "$PUBLIC_KEY" ]]; then

        echo "Public key is missing. Recreating it from the private key..."

        if ! ssh-keygen -y -f "$KEY_FILE" > "$PUBLIC_KEY"; then
            error "Could not recreate the public key."
            exit 1
        fi

    else
        echo "An SSH key already exists."
        echo "Keeping the existing key."
    fi

    chmod 600 "$KEY_FILE"
    chmod 644 "$PUBLIC_KEY"

    # --------------------------------------------------------
    # Install the public key on the remote server
    #
    # FIX:
    # Disable SSH agent identities and use password-based
    # authentication only during key installation.
    # This avoids MaxAuthTries / Too many authentication failures.
    # --------------------------------------------------------

    echo
    echo "Copying the public key to the remote server..."
    echo "Enter the remote account password if requested."
    echo

    if ssh-copy-id \
        -i "$PUBLIC_KEY" \
        -o IdentityAgent=none \
        -o IdentitiesOnly=yes \
        -o "IdentityFile=$KEY_FILE" \
        -o PreferredAuthentications=password,keyboard-interactive \
        -o PubkeyAuthentication=no \
        -o NumberOfPasswordPrompts=1 \
        -p "$SSH_PORT" \
        "$REMOTE_TARGET"; then

        success "Public key installation completed."

        # ----------------------------------------------------
        # Verify public-key authentication only
        # ----------------------------------------------------

        echo
        echo "Testing passwordless authentication..."

        if ssh \
            -i "$KEY_FILE" \
            -o IdentityAgent=none \
            -o IdentitiesOnly=yes \
            -o PreferredAuthentications=publickey \
            -o PubkeyAuthentication=yes \
            -o BatchMode=yes \
            -o ConnectTimeout=8 \
            -p "$SSH_PORT" \
            "$REMOTE_TARGET" \
            "echo 'Passwordless SSH works'; hostname; whoami"; then

            success "Passwordless SSH authentication works."

        else
            error "Passwordless SSH test failed."
            echo "Check the remote authorized_keys file and permissions."
            echo "Also check PubkeyAuthentication and server-side SSH logs."
        fi

    else
        error "Could not install the public key."
        echo "Check the remote username, password and SSH server settings."
        echo "The server may restrict password or keyboard-interactive login."
    fi

else
    echo "Skipping passwordless authentication setup."
fi

# ============================================================
# Optional SCP file transfer
# ============================================================

echo
read -r -p "Do you want to test SCP file transfer? (yes/no): " SCP_CHOICE

if [[ "$SCP_CHOICE" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then

    TEST_FILE="$(mktemp "${TMPDIR:-/tmp}/ssh-client-test.XXXXXX")" || {
        error "Could not create a temporary test file."
        exit 1
    }

    printf 'SCP test from %s at %s\n' \
        "$(hostname)" "$(date)" > "$TEST_FILE"

    echo
    echo "Uploading a temporary test file to the remote home directory..."

    if scp \
        -o ConnectTimeout=8 \
        -P "$SSH_PORT" \
        "$TEST_FILE" \
        "${REMOTE_TARGET}:ssh-client-test.txt"; then

        success "File uploaded successfully."
        echo "Remote file: ~/ssh-client-test.txt"
        echo "Remove it from the server when no longer needed."

    else
        warning "SCP upload failed."
    fi

    rm -f "$TEST_FILE"
fi

# ============================================================
# Final output
# ============================================================

echo
echo "============================================================"
echo "           SSH CLIENT CONFIGURATION FINISHED"
echo "============================================================"
echo
echo "Server       : $SERVER_IP"
echo "Remote user  : $REMOTE_USER"
echo "SSH port     : $SSH_PORT"
echo
echo "Useful commands:"
echo
echo "Connect to server:"
echo "  ssh -p $SSH_PORT $REMOTE_TARGET"
echo
echo "Copy local file to server:"
echo "  scp -P $SSH_PORT file.txt $REMOTE_TARGET:~/"
echo
echo "Download file from server:"
echo "  scp -P $SSH_PORT $REMOTE_TARGET:~/file.txt ."
echo
echo "Open SFTP session:"
echo "  sftp -P $SSH_PORT $REMOTE_TARGET"
echo
echo "View public key:"
echo "  cat $PUBLIC_KEY"
echo
echo "============================================================"

