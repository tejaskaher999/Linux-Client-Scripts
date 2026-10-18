#!/bin/bash

# ============================================================
# INTERACTIVE SMTP CLIENT SETUP
# Supported OS: RHEL / Rocky Linux
# Services/Tools: Postfix SMTP Server, Mutt, Netcat, dig
# Purpose: Test SMTP connectivity and send test emails
# ============================================================

# -------------------- DEFAULT VARIABLES ---------------------

DEFAULT_SMTP_SERVER="docker.tejas.com"
DEFAULT_SMTP_SERVER_IP="192.168.78.128"
DEFAULT_SMTP_PORT="25"
DEFAULT_DOMAIN="tejas.com"
DEFAULT_RECIPIENT="root@skynet.com"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------- FUNCTIONS ------------------------------

print_line() {
    echo "============================================================"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

ask_value() {
    local prompt="$1"
    local default="$2"
    local result

    read -r -p "$prompt [$default]: " result
    echo "${result:-$default}"
}

is_valid_ipv4() {
    local ip="$1"
    local a b c d extra

    IFS='.' read -r a b c d extra <<< "$ip"

    [[ -n "$ip" && -z "$extra" ]] || return 1

    local octet
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done

    return 0
}

is_valid_hostname() {
    local host="$1"

    [[ ${#host} -le 253 ]] || return 1
    [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
    [[ "$host" != *..* ]] || return 1

    return 0
}

is_valid_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# -------------------- ROOT CHECK -----------------------------

if [[ $EUID -ne 0 ]]; then
    error "Run this script as root."
    echo "Example: sudo bash 09_smtp_client.sh"
    exit 1
fi

# -------------------- OS CHECK -------------------------------

if [[ ! -f /etc/os-release ]]; then
    error "Cannot identify the operating system."
    exit 1
fi

source /etc/os-release

if [[ "$ID" != "rocky" && "$ID" != "rhel" &&
      " ${ID_LIKE:-} " != *" rhel "* ]]; then
    error "This script supports RHEL / Rocky Linux."
    exit 1
fi

# -------------------- DETECT CLIENT INFORMATION --------------

CLIENT_HOSTNAME=$(hostname -s)

CLIENT_IP=$(
    ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{
        for (i=1; i<=NF; i++)
            if ($i=="src") {
                print $(i+1)
                exit
            }
    }'
)

if [[ -z "$CLIENT_IP" ]]; then
    CLIENT_IP=$(
        ip -o -4 addr show scope global |
        awk 'NR==1 {
            split($4,a,"/")
            print a[1]
        }'
    )
fi

CLIENT_IP=${CLIENT_IP:-127.0.0.1}

# -------------------- HEADER ---------------------------------

print_line
echo "             INTERACTIVE SMTP CLIENT SETUP"
echo "             RHEL / ROCKY LINUX"
print_line
echo "Press Enter to accept the displayed defaults."
echo

echo -e "${BLUE}Current Client Information${NC}"
hostnamectl
echo
ip -br addr
echo

# -------------------- USER CONFIGURATION ---------------------

SMTP_SERVER=$(ask_value \
    "SMTP server hostname or IPv4 address" \
    "$DEFAULT_SMTP_SERVER")

SMTP_SERVER_IP=$(ask_value \
    "SMTP server IPv4 address (for connectivity tests)" \
    "$DEFAULT_SMTP_SERVER_IP")

SMTP_PORT=$(ask_value \
    "SMTP server port" "$DEFAULT_SMTP_PORT")

SMTP_DOMAIN=$(ask_value \
    "Client email domain" "$DEFAULT_DOMAIN")

DEFAULT_SENDER="$(id -un)@${SMTP_DOMAIN}"

SENDER_EMAIL=$(ask_value \
    "Sender email address" "$DEFAULT_SENDER")

RECIPIENT=$(ask_value \
    "Recipient email address" "$DEFAULT_RECIPIENT")

echo
print_line
echo "             CONFIGURATION SUMMARY"
print_line
echo "Client hostname    : $CLIENT_HOSTNAME"
echo "Client IP          : $CLIENT_IP"
echo "SMTP server        : $SMTP_SERVER"
echo "SMTP server IP     : $SMTP_SERVER_IP"
echo "SMTP port          : $SMTP_PORT"
echo "Sender email       : $SENDER_EMAIL"
echo "Recipient email    : $RECIPIENT"
print_line
echo

read -r -p "Continue with this configuration? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warning "Setup cancelled. No configuration changes made."
    exit 0
fi

# -------------------- VALIDATION -----------------------------

if ! is_valid_hostname "$SMTP_SERVER" &&
   ! is_valid_ipv4 "$SMTP_SERVER"; then
    error "Invalid SMTP server hostname or IPv4 address."
    exit 1
fi

if ! is_valid_ipv4 "$SMTP_SERVER_IP"; then
    error "Invalid SMTP server IPv4 address."
    exit 1
fi

if [[ ! "$SMTP_PORT" =~ ^[0-9]+$ ]] ||
   (( 10#$SMTP_PORT < 1 || 10#$SMTP_PORT > 65535 )); then
    error "Invalid TCP port: $SMTP_PORT"
    exit 1
fi

if [[ "$SMTP_PORT" != "25" ]]; then
    warning "Your server script is designed for standard SMTP port 25."
    error "Use port 25 unless the server has been configured for another port."
    exit 1
fi

if ! is_valid_email "$SENDER_EMAIL"; then
    error "Invalid sender email address."
    exit 1
fi

if ! is_valid_email "$RECIPIENT"; then
    error "Invalid recipient email address."
    exit 1
fi

# -------------------- INSTALL PACKAGES -----------------------

echo
echo "[1/5] Installing SMTP client tools..."

if ! dnf install -y mutt nmap-ncat bind-utils; then
    error "Package installation failed. Check repository access."
    exit 1
fi

command -v mutt >/dev/null 2>&1 || {
    error "Mutt is not installed."
    exit 1
}

command -v nc >/dev/null 2>&1 || {
    error "Netcat is not installed."
    exit 1
}

command -v dig >/dev/null 2>&1 || {
    error "dig is not installed."
    exit 1
}

success "Mutt, Netcat, and DNS utilities are available."

# -------------------- CREATE WORK DIRECTORY ------------------

WORK_DIR="/root/smtp-client"

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

# -------------------- DNS VERIFICATION -----------------------

echo
echo "[2/5] Checking SMTP server name resolution..."

if is_valid_ipv4 "$SMTP_SERVER"; then
    info "SMTP server was entered as an IP address; DNS lookup skipped."
else
    if getent ahostsv4 "$SMTP_SERVER" >/dev/null 2>&1; then
        success "SMTP server hostname resolves successfully."
        getent ahostsv4 "$SMTP_SERVER" | head -n 3
    else
        warning "Hostname resolution failed for $SMTP_SERVER."
        warning "The script will still test the supplied server IP."
        warning "Check DNS or use the server IP as SMTP server."
    fi
fi

echo
echo "DNS lookup for SMTP server IP:"
dig +short -x "$SMTP_SERVER_IP" || true

# -------------------- TCP CONNECTIVITY -----------------------

echo
echo "[3/5] Testing SMTP server connectivity..."

if nc -z -w 5 "$SMTP_SERVER_IP" "$SMTP_PORT"; then
    success "TCP connection to $SMTP_SERVER_IP:$SMTP_PORT succeeded."
else
    error "Cannot connect to $SMTP_SERVER_IP:$SMTP_PORT."
    warning "Check that Postfix is running and listening on port 25."
    warning "Check server firewall, client network, and server IP."
    echo
    echo "Run these commands on the SMTP server:"
    echo "  systemctl status postfix"
    echo "  ss -ltnp | grep ':25'"
    echo "  firewall-cmd --list-all"
    exit 1
fi

# -------------------- SMTP GREETING TEST ---------------------

echo
echo "Checking SMTP server greeting..."

SMTP_GREETING=$(
    timeout 8 bash -c \
        'exec 3<>/dev/tcp/"$1"/"$2"; IFS= read -r -t 5 line <&3; printf "%s\n" "$line"; exec 3<&-; exec 3>&-' \
        _ "$SMTP_SERVER_IP" "$SMTP_PORT" 2>/dev/null
)

if [[ "$SMTP_GREETING" == 220* ]]; then
    success "SMTP greeting received:"
    echo "$SMTP_GREETING"
else
    warning "Could not read a standard SMTP greeting."
    warning "Use the menu to retry the connection test."
fi

# -------------------- SMTP CLIENT MENU -----------------------

send_test_email() {
    local SUBJECT BODY_FILE

    echo
    print_line
    echo "                 SEND TEST EMAIL"
    print_line

    read -r -p "Email subject [SMTP Client Test]: " SUBJECT
    SUBJECT=${SUBJECT:-SMTP Client Test}

    BODY_FILE=$(mktemp "$WORK_DIR/email-body.XXXXXX") || {
        error "Could not create email body file."
        return 1
    }

    cat > "$BODY_FILE" <<EOF
Hello,

This is a test email sent from a Rocky Linux SMTP client.

Client hostname : $CLIENT_HOSTNAME
Client IP       : $CLIENT_IP
SMTP server     : $SMTP_SERVER
SMTP server IP  : $SMTP_SERVER_IP
SMTP port       : $SMTP_PORT
Date            : $(date)

If you received this email, the SMTP client successfully submitted
the message to the configured SMTP server.

Regards,
Rocky Linux SMTP Client
EOF

    chmod 600 "$BODY_FILE"

    echo
    echo "Sending email..."
    echo "From       : $SENDER_EMAIL"
    echo "To         : $RECIPIENT"
    echo "SMTP server: $SMTP_SERVER_IP:$SMTP_PORT"
    echo

    if mutt \
        -e "set smtp_url=smtp://${SMTP_SERVER_IP}:${SMTP_PORT}" \
        -e "set from=${SENDER_EMAIL}" \
        -s "$SUBJECT" -- "$RECIPIENT" < "$BODY_FILE"; then

        success "Mutt submitted the email without reporting an error."
        warning "This does not guarantee final delivery."
        echo "Check the SMTP server logs and recipient mailbox."
    else
        error "Mutt could not submit the email."
        warning "Check the SMTP greeting, server logs, and Postfix restrictions."
        echo
        echo "Server-side commands:"
        echo "  journalctl -u postfix -n 50 --no-pager"
        echo "  postqueue -p"
    fi

    rm -f "$BODY_FILE"
}

while true; do
    echo
    print_line
    echo "                 SMTP CLIENT MENU"
    print_line
    echo "1. Test SMTP TCP connection"
    echo "2. Check SMTP server greeting"
    echo "3. Send a test email"
    echo "4. Show troubleshooting commands"
    echo "5. Exit"
    print_line

    read -r -p "Choose an option [1-5]: " CHOICE

    case "$CHOICE" in
        1)
            if nc -z -w 5 "$SMTP_SERVER_IP" "$SMTP_PORT"; then
                success "SMTP port $SMTP_PORT is reachable."
            else
                error "SMTP port $SMTP_PORT is not reachable."
            fi
            ;;

        2)
            SMTP_GREETING=$(
                timeout 8 bash -c \
                    'exec 3<>/dev/tcp/"$1"/"$2"; IFS= read -r -t 5 line <&3; printf "%s\n" "$line"; exec 3<&-; exec 3>&-' \
                    _ "$SMTP_SERVER_IP" "$SMTP_PORT" 2>/dev/null
            )

            if [[ "$SMTP_GREETING" == 220* ]]; then
                success "SMTP server greeting received."
                echo "$SMTP_GREETING"
            else
                error "No valid SMTP greeting received."
            fi
            ;;

        3)
            send_test_email
            ;;

        4)
            echo
            echo "Run on the SMTP server ($SMTP_SERVER_IP):"
            echo "  systemctl status postfix"
            echo "  postfix check"
            echo "  postconf -n"
            echo "  ss -ltnp | grep ':25'"
            echo "  firewall-cmd --list-all"
            echo "  journalctl -u postfix -n 50 --no-pager"
            echo "  postqueue -p"
            echo
            echo "Run on this client:"
            echo "  dig $SMTP_SERVER"
            echo "  nc -vz $SMTP_SERVER_IP $SMTP_PORT"
            echo "  getent hosts $SMTP_SERVER"
            ;;

        5)
            success "SMTP client testing completed."
            break
            ;;

        *)
            warning "Invalid option. Choose 1 to 5."
            ;;
    esac
done

# -------------------- COMPLETION -----------------------------

echo
print_line
success "SMTP CLIENT SETUP COMPLETED"
print_line
echo "Client hostname : $CLIENT_HOSTNAME"
echo "Client IP       : $CLIENT_IP"
echo "SMTP server     : $SMTP_SERVER_IP"
echo "SMTP port       : $SMTP_PORT"
echo "Sender          : $SENDER_EMAIL"
echo "Recipient       : $RECIPIENT"
echo "Working folder  : $WORK_DIR"
print_line

