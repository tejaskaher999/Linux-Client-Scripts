#!/bin/bash

# ============================================================
# 07. FTP CLIENT CONFIGURATION
# RHEL / ROCKY LINUX 10
# ============================================================

set -o pipefail

# ------------------------------------------------------------
# 1. Default Variables
# ------------------------------------------------------------

FTP_SERVER="192.168.78.128"
FTP_PORT="21"
FTP_USERNAME="anonymous"
FTP_MODE="anonymous"

LOCAL_DIR="$HOME/ftp-files"
REMOTE_DIR="/pub"

# Anonymous uploads use this directory on the FTP server.
ANONYMOUS_UPLOAD_DIR="/pub/upload"

FTP_TIMEOUT="5"

# ------------------------------------------------------------
# 2. Functions
# ------------------------------------------------------------

error() {
    echo -e "\033[0;31mERROR: $*\033[0m"
}

success() {
    echo -e "\033[0;32mSUCCESS: $*\033[0m"
}

warning() {
    echo -e "\033[1;33mWARNING: $*\033[0m"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Check that a filename contains only simple, safe characters.
valid_filename() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] &&
        [[ "$1" != "." && "$1" != ".." ]]
}

# Prepare curl authentication options.
set_ftp_auth() {
    if [[ "$FTP_MODE" == "anonymous" ]]; then
        CURL_AUTH=(--user "anonymous:anonymous@")
    else
        CURL_AUTH=(--user "$FTP_USERNAME")
    fi
}

# List a remote directory.
list_remote_directory() {
    local DIR="${1%/}"
    [[ -z "$DIR" ]] && DIR="/"

    curl --globoff --fail --show-error \
        --connect-timeout "$FTP_TIMEOUT" \
        --max-time 30 \
        "${CURL_AUTH[@]}" \
        --list-only \
        "ftp://${FTP_SERVER}:${FTP_PORT}${DIR}/"
}

# ------------------------------------------------------------
# 3. Check Root Privileges
# ------------------------------------------------------------

if [[ "$EUID" -eq 0 ]]; then
    echo "Running as root."
else
    echo "Running as user: $USER"
fi

# ------------------------------------------------------------
# 4. Display Configuration
# ------------------------------------------------------------

echo
echo "============================================================"
echo "               07. FTP CLIENT CONFIGURATION"
echo "============================================================"
echo "FTP server       : $FTP_SERVER"
echo "FTP port         : $FTP_PORT"
echo "FTP login mode   : $FTP_MODE"
echo "FTP username     : $FTP_USERNAME"
echo "Local directory  : $LOCAL_DIR"
echo "Remote directory : $REMOTE_DIR"
echo "Anonymous upload : $ANONYMOUS_UPLOAD_DIR"
echo "============================================================"
echo

# ------------------------------------------------------------
# 5. Modify Configuration
# ------------------------------------------------------------

read -r -p "Do you want to modify variables? (yes/no): " MODIFY

case "${MODIFY,,}" in
    yes|y)
        read -r -p "FTP server IP/hostname [$FTP_SERVER]: " INPUT
        FTP_SERVER="${INPUT:-$FTP_SERVER}"

        read -r -p "FTP port [$FTP_PORT]: " INPUT
        FTP_PORT="${INPUT:-$FTP_PORT}"

        echo
        echo "Select FTP login mode:"
        echo "1. Anonymous login"
        echo "2. Local user login"

        read -r -p "Enter choice [1]: " MODE_CHOICE
        MODE_CHOICE="${MODE_CHOICE:-1}"

        case "$MODE_CHOICE" in
            1)
                FTP_MODE="anonymous"
                FTP_USERNAME="anonymous"
                ;;
            2)
                FTP_MODE="local"
                read -r -p "FTP username: " FTP_USERNAME

                if [[ -z "$FTP_USERNAME" ]]; then
                    error "Username cannot be empty."
                    exit 1
                fi
                ;;
            *)
                error "Invalid login mode."
                exit 1
                ;;
        esac

        read -r -p "Local directory [$LOCAL_DIR]: " INPUT
        LOCAL_DIR="${INPUT:-$LOCAL_DIR}"

        read -r -p "Remote directory [$REMOTE_DIR]: " INPUT
        REMOTE_DIR="${INPUT:-$REMOTE_DIR}"
        ;;

    no|n|"")
        echo "Using default values..."
        ;;

    *)
        error "Invalid choice."
        exit 1
        ;;
esac

# ------------------------------------------------------------
# 6. Validate Configuration
# ------------------------------------------------------------

if [[ -z "$FTP_SERVER" ||
      ! "$FTP_SERVER" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
    error "Invalid FTP server address."
    exit 1
fi

if ! valid_port "$FTP_PORT"; then
    error "Invalid FTP port."
    exit 1
fi

if [[ "$FTP_MODE" != "anonymous" &&
      "$FTP_MODE" != "local" ]]; then
    error "Invalid FTP login mode."
    exit 1
fi

if [[ -z "$FTP_USERNAME" ||
      "$FTP_USERNAME" =~ [[:space:]] ||
      "$FTP_USERNAME" == *";"* ]]; then
    error "Invalid FTP username."
    exit 1
fi

if [[ "$LOCAL_DIR" != /* ||
      "$LOCAL_DIR" =~ [[:space:]] ||
      "$LOCAL_DIR" == *";"* ]]; then
    error "Local directory must be an absolute path without spaces or semicolons."
    exit 1
fi

if [[ "$REMOTE_DIR" != /* ||
      "$REMOTE_DIR" == *";"* ||
      "$REMOTE_DIR" == *$'\n'* ]]; then
    error "Remote directory must be an absolute path without semicolons or newlines."
    exit 1
fi

# Remove trailing slash, except for the root directory.
REMOTE_DIR="${REMOTE_DIR%/}"
[[ -z "$REMOTE_DIR" ]] && REMOTE_DIR="/"

# ------------------------------------------------------------
# 7. Confirm Configuration
# ------------------------------------------------------------

echo
echo "Selected FTP client configuration:"
echo "============================================================"
echo "FTP server       : $FTP_SERVER"
echo "FTP port         : $FTP_PORT"
echo "Login mode       : $FTP_MODE"
echo "FTP username     : $FTP_USERNAME"
echo "Local directory  : $LOCAL_DIR"
echo "Remote directory : $REMOTE_DIR"
if [[ "$FTP_MODE" == "anonymous" ]]; then
    echo "Upload directory : $ANONYMOUS_UPLOAD_DIR"
fi
echo "============================================================"
echo

read -r -p "Continue with FTP client setup? (yes/no): " CONFIRM

case "${CONFIRM,,}" in
    yes|y) ;;
    *)
        echo "Operation cancelled."
        exit 0
        ;;
esac

# ------------------------------------------------------------
# 8. Install FTP Client
# ------------------------------------------------------------

echo
echo "Installing FTP client tools..."

if [[ "$EUID" -eq 0 ]]; then
    if ! dnf install -y ftp curl; then
        error "Could not install FTP client packages."
        exit 1
    fi
else
    if ! command -v ftp >/dev/null 2>&1 ||
       ! command -v curl >/dev/null 2>&1; then
        error "FTP tools are missing."
        echo "Run: sudo dnf install -y ftp curl"
        exit 1
    fi
fi

if ! command -v curl >/dev/null 2>&1; then
    error "curl is not installed."
    exit 1
fi

if ! command -v ftp >/dev/null 2>&1; then
    error "ftp command is not installed."
    exit 1
fi

success "FTP client tools are available."

# ------------------------------------------------------------
# 9. Prepare Local Directory
# ------------------------------------------------------------

echo
echo "Preparing local FTP directory..."

if ! mkdir -p "$LOCAL_DIR"; then
    error "Could not create local directory: $LOCAL_DIR"
    exit 1
fi

success "Local directory is ready: $LOCAL_DIR"

# ------------------------------------------------------------
# 10. Test FTP Server Connectivity
# ------------------------------------------------------------

echo
echo "Testing TCP connectivity to $FTP_SERVER:$FTP_PORT..."

if timeout "$FTP_TIMEOUT" bash -c \
    ':</dev/tcp/"$1"/"$2"' _ "$FTP_SERVER" "$FTP_PORT" \
    2>/dev/null; then

    success "FTP server TCP port is reachable."
else
    error "FTP server is not reachable on port $FTP_PORT."
    echo "Check the server IP, vsftpd service and firewall."
    exit 1
fi

# ------------------------------------------------------------
# 11. Test FTP Login and Remote Directory
# ------------------------------------------------------------

set_ftp_auth

echo
echo "Testing FTP login and directory listing..."

if [[ "$FTP_MODE" == "local" ]]; then
    echo "Enter the password for FTP user: $FTP_USERNAME"
    echo "The password will be requested interactively."
fi

if list_remote_directory "$REMOTE_DIR"; then
    success "FTP login and remote directory listing succeeded."
else
    error "FTP login or directory listing failed."
    echo "Check the credentials, remote directory and permissions."
    exit 1
fi

# ------------------------------------------------------------
# 12. Display FTP Operations Menu
# ------------------------------------------------------------

echo
echo "============================================================"
echo "                  FTP CLIENT OPERATIONS"
echo "============================================================"
echo "1. List remote directory"
echo "2. Download a file"
echo "3. Upload a file"
echo "4. Open interactive FTP session"
echo "5. Test FTP connection again"
echo "6. Exit"
echo "============================================================"

while true; do

    echo
    read -r -p "Choose an operation [1-6]: " CHOICE

    case "$CHOICE" in

        # ----------------------------------------------------
        # OPTION 1: LIST REMOTE DIRECTORY
        # ----------------------------------------------------

        1)
            echo
            echo "Listing remote directory: $REMOTE_DIR"

            if list_remote_directory "$REMOTE_DIR"; then
                success "Remote directory listed successfully."
            else
                error "Could not list the remote directory."
            fi
            ;;

        # ----------------------------------------------------
        # OPTION 2: DOWNLOAD A FILE
        # ----------------------------------------------------

        2)
            echo
            read -r -p "Enter remote filename to download: " REMOTE_FILE

            if ! valid_filename "$REMOTE_FILE"; then
                error "Use a filename containing only letters, numbers, dots, underscores or hyphens."
                continue
            fi

            echo
            echo "Downloading: $REMOTE_FILE"
            echo "From: $REMOTE_DIR"
            echo "To  : $LOCAL_DIR/$REMOTE_FILE"

            if curl --globoff --fail --show-error \
                --connect-timeout "$FTP_TIMEOUT" \
                --max-time 300 \
                "${CURL_AUTH[@]}" \
                --output "$LOCAL_DIR/$REMOTE_FILE" \
                "ftp://${FTP_SERVER}:${FTP_PORT}${REMOTE_DIR%/}/${REMOTE_FILE}"; then

                success "File downloaded to $LOCAL_DIR/$REMOTE_FILE"
            else
                error "File download failed."
                rm -f -- "$LOCAL_DIR/$REMOTE_FILE"
                echo "Check the filename and read permissions."
            fi
            ;;

        # ----------------------------------------------------
        # OPTION 3: UPLOAD A FILE
        # ----------------------------------------------------

        3)
            echo
            read -r -p "Enter local filename to upload: " LOCAL_FILE

            if ! valid_filename "$LOCAL_FILE"; then
                error "Use a filename containing only letters, numbers, dots, underscores or hyphens."
                continue
            fi

            if [[ ! -f "$LOCAL_DIR/$LOCAL_FILE" ]]; then
                error "File not found: $LOCAL_DIR/$LOCAL_FILE"
                echo "Create or copy the file into $LOCAL_DIR first."
                continue
            fi

            if [[ "$FTP_MODE" == "anonymous" ]]; then
                UPLOAD_DIR="$ANONYMOUS_UPLOAD_DIR"
            else
                UPLOAD_DIR="$REMOTE_DIR"
            fi

            echo
            echo "Uploading file : $LOCAL_DIR/$LOCAL_FILE"
            echo "FTP server     : $FTP_SERVER:$FTP_PORT"
            echo "Destination    : $UPLOAD_DIR/$LOCAL_FILE"

            if [[ "$FTP_MODE" == "local" ]]; then
                echo "Enter the FTP user's password when prompted."
            else
                echo "Using anonymous FTP authentication."
                echo "The server must permit anonymous uploads to $UPLOAD_DIR."
            fi

            if curl --globoff --fail --show-error \
                --connect-timeout "$FTP_TIMEOUT" \
                --max-time 300 \
                "${CURL_AUTH[@]}" \
                --upload-file "$LOCAL_DIR/$LOCAL_FILE" \
                "ftp://${FTP_SERVER}:${FTP_PORT}${UPLOAD_DIR%/}/${LOCAL_FILE}"; then

                success "File uploaded successfully."
                echo "Remote file: $UPLOAD_DIR/$LOCAL_FILE"
            else
                error "File upload failed."
                echo "Check the destination directory and FTP permissions."
                if [[ "$FTP_MODE" == "anonymous" ]]; then
                    echo "Verify anonymous upload settings and SELinux permissions on the server."
                else
                    echo "Verify write_enable and the local user's directory permissions."
                fi
            fi
            ;;

        # ----------------------------------------------------
        # OPTION 4: INTERACTIVE FTP SESSION
        # ----------------------------------------------------

        4)
            echo
            echo "Starting interactive FTP session..."
            echo "Connect to: $FTP_SERVER:$FTP_PORT"
            echo
            echo "At the ftp> prompt, enter:"
            if [[ "$FTP_MODE" == "anonymous" ]]; then
                echo "  user anonymous anonymous@"
            else
                echo "  user $FTP_USERNAME"
                echo "  Then enter the password when prompted."
            fi
            echo
            echo "Useful FTP commands: pwd, ls, cd, get, put, bye"
            echo

            # No here-document: this is a genuinely interactive session.
            ftp -inv "$FTP_SERVER" "$FTP_PORT"

            echo
            echo "Interactive FTP session ended."
            ;;

        # ----------------------------------------------------
        # OPTION 5: TEST CONNECTION AGAIN
        # ----------------------------------------------------

        5)
            echo
            echo "Rechecking FTP connectivity..."

            if timeout "$FTP_TIMEOUT" bash -c \
                ':</dev/tcp/"$1"/"$2"' _ "$FTP_SERVER" "$FTP_PORT" \
                2>/dev/null; then

                success "FTP server is reachable."
            else
                error "FTP server is unreachable."
                continue
            fi

            echo "Testing FTP login and directory listing..."

            if list_remote_directory "$REMOTE_DIR"; then
                success "FTP login and listing succeeded."
            else
                error "FTP login or directory listing failed."
            fi
            ;;

        # ----------------------------------------------------
        # OPTION 6: EXIT
        # ----------------------------------------------------

        6)
            echo
            echo "Exiting FTP client."
            break
            ;;

        *)
            error "Invalid choice. Enter a number from 1 to 6."
            ;;
    esac

done

# ------------------------------------------------------------
# 13. Final Information
# ------------------------------------------------------------

echo
echo "============================================================"
echo "             FTP CLIENT CONFIGURATION COMPLETED"
echo "============================================================"
echo "FTP server       : $FTP_SERVER"
echo "FTP port         : $FTP_PORT"
echo "Login mode       : $FTP_MODE"
echo "Local directory  : $LOCAL_DIR"
echo "Remote directory : $REMOTE_DIR"

if [[ "$FTP_MODE" == "anonymous" ]]; then
    echo "Upload directory : $ANONYMOUS_UPLOAD_DIR"
fi

echo
echo "Useful commands:"
echo "  FTP connection : ftp $FTP_SERVER $FTP_PORT"
echo "  Local files    : ls -la $LOCAL_DIR"
echo
echo "IMPORTANT:"
echo "Standard FTP does not encrypt credentials or file contents."
echo "Use SFTP or FTPS for sensitive information."
echo "============================================================"

