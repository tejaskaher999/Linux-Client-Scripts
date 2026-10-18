#!/bin/bash

# ==========================================================
# Script Name : 09_smtp_client.sh
# Purpose     : Interactive SMTP Client and Mutt Setup
# OS          : Rocky Linux / RHEL
# ==========================================================

set -o pipefail

# ----------------------------------------------------------
# Colors and helper functions
# ----------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

ask() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "${prompt} [${default}]: " answer
    REPLY="${answer:-$default}"
}

# ----------------------------------------------------------
# 1. Root check
# ----------------------------------------------------------

if [ "$EUID" -ne 0 ]; then
    error "Run as root: sudo bash 09_smtp_client.sh"
    exit 1
fi

# ----------------------------------------------------------
# 2. Ask for machine-specific configuration FIRST
#    No packages or configuration are changed before this.
# ----------------------------------------------------------

echo
echo "=========================================================="
echo "       SMTP CLIENT - INTERACTIVE CONFIGURATION"
echo "=========================================================="
echo "Enter the values for this machine."
echo "Press Enter to accept a suggested default."
echo

DEFAULT_HOSTNAME="$(hostname -s 2>/dev/null || echo client1)"
DEFAULT_DOMAIN="tejas.com"
DEFAULT_SMTP_SERVER="192.168.78.128"
DEFAULT_SMTP_PORT="25"
DEFAULT_RECIPIENT="root@docker.tejas.com"
DEFAULT_SENDER="root@tejas.com"

ask "1. Client hostname (short name)" "$DEFAULT_HOSTNAME"
CLIENT_HOSTNAME="$REPLY"

ask "2. Mail domain" "$DEFAULT_DOMAIN"
DOMAIN="$REPLY"

ask "3. SMTP server IP address or hostname" "$DEFAULT_SMTP_SERVER"
SMTP_SERVER="$REPLY"

ask "4. SMTP server port" "$DEFAULT_SMTP_PORT"
SMTP_PORT="$REPLY"

ask "5. Default recipient email address" "$DEFAULT_RECIPIENT"
DEFAULT_RECIPIENT="$REPLY"

ask "6. Sender email address for this setup" "$DEFAULT_SENDER"
SENDER_EMAIL="$REPLY"

ask "7. Configure Postfix to receive mail on this client too? (yes/no)" "yes"
ENABLE_INBOUND="$REPLY"

echo
echo "=========================================================="
echo "             CONFIGURATION SUMMARY"
echo "=========================================================="
echo "Client hostname : ${CLIENT_HOSTNAME}"
echo "Client FQDN     : ${CLIENT_HOSTNAME}.${DOMAIN}"
echo "Mail domain     : ${DOMAIN}"
echo "SMTP server     : ${SMTP_SERVER}"
echo "SMTP port       : ${SMTP_PORT}"
echo "Sender address  : ${SENDER_EMAIL}"
echo "Default recipient: ${DEFAULT_RECIPIENT}"
echo "Receive mail on client: ${ENABLE_INBOUND}"
echo "=========================================================="
echo

read -r -p "Continue with these settings? (y/N): " CONFIRM

case "$CONFIRM" in
    y|Y|yes|YES)
        ;;
    *)
        warn "Cancelled. No changes were made."
        exit 0
        ;;
esac

# ----------------------------------------------------------
# 3. Validate the entered values
# ----------------------------------------------------------

if [[ ! "$SMTP_PORT" =~ ^[0-9]+$ ]] ||
   [ "$SMTP_PORT" -lt 1 ] ||
   [ "$SMTP_PORT" -gt 65535 ]; then
    error "Invalid SMTP port: ${SMTP_PORT}"
    exit 1
fi

if [[ ! "$CLIENT_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    error "Invalid client hostname."
    exit 1
fi

if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then
    error "Invalid domain."
    exit 1
fi

if [[ "$SENDER_EMAIL" != *@* ]] ||
   [[ "$DEFAULT_RECIPIENT" != *@* ]]; then
    error "Sender and recipient must be valid email-address formats."
    exit 1
fi

if [[ "$ENABLE_INBOUND" != "yes" &&
      "$ENABLE_INBOUND" != "YES" &&
      "$ENABLE_INBOUND" != "y" &&
      "$ENABLE_INBOUND" != "Y" &&
      "$ENABLE_INBOUND" != "no" &&
      "$ENABLE_INBOUND" != "NO" &&
      "$ENABLE_INBOUND" != "n" &&
      "$ENABLE_INBOUND" != "N" ]]; then
    error "Enter yes or no for the inbound mail question."
    exit 1
fi

# ----------------------------------------------------------
# 4. Install required packages
# ----------------------------------------------------------

echo
info "Installing required packages..."

if ! dnf install -y postfix mutt bind-utils nmap-ncat; then
    error "Package installation failed."
    exit 1
fi

# ----------------------------------------------------------
# 5. Configure Postfix on the client
# ----------------------------------------------------------

info "Configuring Postfix..."

postconf -e "myhostname = ${CLIENT_HOSTNAME}.${DOMAIN}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e 'myorigin = $mydomain'
postconf -e "relayhost = [${SMTP_SERVER}]:${SMTP_PORT}"

if [[ "$ENABLE_INBOUND" == "yes" ||
      "$ENABLE_INBOUND" == "YES" ||
      "$ENABLE_INBOUND" == "y" ||
      "$ENABLE_INBOUND" == "Y" ]]; then

    postconf -e 'inet_interfaces = all'
    postconf -e 'mydestination = $myhostname, localhost.$mydomain, localhost'

else
    # Local-only Postfix submission; Mutt sends directly to SMTP_SERVER.
    postconf -e 'inet_interfaces = loopback-only'
    postconf -e 'mydestination = $myhostname, localhost.$mydomain, localhost'
fi

if ! systemctl enable --now postfix; then
    error "Could not start Postfix."
    exit 1
fi

if ! systemctl restart postfix; then
    error "Postfix restart failed."
    exit 1
fi

info "Postfix is active."

# ----------------------------------------------------------
# 6. Configure firewall
# ----------------------------------------------------------

if systemctl is-active --quiet firewalld; then

    if [[ "$ENABLE_INBOUND" == "yes" ||
          "$ENABLE_INBOUND" == "YES" ||
          "$ENABLE_INBOUND" == "y" ||
          "$ENABLE_INBOUND" == "Y" ]]; then

        if firewall-cmd --get-services |
            tr ' ' '\n' | grep -qx smtp; then
            firewall-cmd --permanent --add-service=smtp
            firewall-cmd --reload
            info "SMTP inbound firewall rule enabled."
        else
            warn "SMTP service is unavailable in firewalld."
        fi
    else
        info "Inbound SMTP firewall rule not changed."
    fi
else
    warn "firewalld is not active; skipping firewall changes."
fi

# ----------------------------------------------------------
# 7. Configure Mutt for the selected Linux users
# ----------------------------------------------------------

configure_mutt() {
    local username="$1"
    local userhome="$2"
    local sender="$3"
    local groupname
    local mainconfig="${userhome}/.muttrc"
    local smtpconfig="${userhome}/.muttrc.smtp-client"

    groupname="$(id -gn "$username")"

    touch "$mainconfig"

    cat > "$smtpconfig" <<EOF
# Managed by 09_smtp_client.sh
# SMTP server configuration

set smtp_url = "smtp://${SMTP_SERVER}:${SMTP_PORT}"
set from = "${sender}"
set realname = "${username} (${CLIENT_HOSTNAME})"
set use_from = yes
set envelope_from = yes
EOF

    if ! grep -Fqx 'source ~/.muttrc.smtp-client' "$mainconfig"; then
        echo 'source ~/.muttrc.smtp-client' >> "$mainconfig"
    fi

    chown "$username:$groupname" "$mainconfig" "$smtpconfig"
    chmod 600 "$mainconfig" "$smtpconfig"

    info "Mutt configured for ${username}."
}

# Configure root.
configure_mutt root /root "$SENDER_EMAIL"

# If invoked with sudo, also configure the original invoking user.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    if id "$SUDO_USER" >/dev/null 2>&1; then
        USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

        if [ -d "$USER_HOME" ]; then
            configure_mutt "$SUDO_USER" "$USER_HOME" "$SENDER_EMAIL"
        fi
    fi
fi

# ----------------------------------------------------------
# 8. Check DNS resolution
# ----------------------------------------------------------

echo
info "Checking SMTP server name resolution..."

if getent hosts "$SMTP_SERVER"; then
    info "SMTP server name resolves successfully."
else
    warn "DNS did not resolve ${SMTP_SERVER}."
    warn "If you entered an IP address, this warning can be ignored."
fi

# ----------------------------------------------------------
# 9. SMTP client menu
# ----------------------------------------------------------

while true; do

    echo
    echo "=========================================================="
    echo "                  SMTP CLIENT MENU"
    echo "=========================================================="
    echo "Client      : ${CLIENT_HOSTNAME}.${DOMAIN}"
    echo "SMTP Server : ${SMTP_SERVER}:${SMTP_PORT}"
    echo "Sender      : ${SENDER_EMAIL}"
    echo "Recipient   : ${DEFAULT_RECIPIENT}"
    echo "----------------------------------------------------------"
    echo "1. Test connection to SMTP server"
    echo "2. Send test email"
    echo "3. Compose and send email using Mutt"
    echo "4. Read local root mailbox"
    echo "5. Show SMTP and Mutt configuration"
    echo "6. Show Postfix logs"
    echo "7. Exit"
    echo "=========================================================="

    read -r -p "Enter your choice [1-7]: " choice

    case "$choice" in

        1)
            echo
            info "Testing SMTP connection..."

            if timeout 5 bash -c \
                "echo > /dev/tcp/${SMTP_SERVER}/${SMTP_PORT}" 2>/dev/null; then
                info "SMTP connection succeeded."
                echo "Server greeting:"
                timeout 5 nc -w 3 "$SMTP_SERVER" "$SMTP_PORT" < /dev/null
            else
                error "SMTP connection failed."
                echo "Check the SMTP server, port, firewall and Postfix."
            fi
            ;;

        2)
            echo
            read -r -p "Recipient [${DEFAULT_RECIPIENT}]: " recipient
            recipient="${recipient:-$DEFAULT_RECIPIENT}"

            read -r -p "Subject [Test from ${CLIENT_HOSTNAME}]: " subject
            subject="${subject:-Test from ${CLIENT_HOSTNAME}}"

            echo
            info "Sending test email to ${recipient}..."

            if printf 'Hello!\n\nThis test email was sent from %s using Mutt and SMTP server %s:%s.\n' \
                "${CLIENT_HOSTNAME}.${DOMAIN}" "$SMTP_SERVER" "$SMTP_PORT" |
                mutt -s "$subject" -- "$recipient"; then
                info "Mutt finished the send operation."
                echo "Check the SMTP server logs to confirm delivery."
            else
                error "Mutt could not send the email."
            fi
            ;;

        3)
            echo
            read -r -p "Recipient [${DEFAULT_RECIPIENT}]: " recipient
            recipient="${recipient:-$DEFAULT_RECIPIENT}"

            echo
            echo "Opening Mutt compose window..."
            echo "Recipient: ${recipient}"
            echo "Enter your message, then use Mutt's send command."

            mutt -s "Email from ${CLIENT_HOSTNAME}" -- "$recipient"
            ;;

        4)
            echo
            if [ -f /var/spool/mail/root ]; then
                mutt -f /var/spool/mail/root
            else
                warn "The local root mailbox does not exist yet."
            fi
            ;;

        5)
            echo
            echo "----- Postfix configuration -----"
            postconf myhostname mydomain myorigin inet_interfaces \
                mydestination relayhost

            echo
            echo "----- Mutt SMTP configuration -----"
            cat /root/.muttrc.smtp-client

            echo
            echo "----- SMTP listener -----"
            ss -lntp | grep ':25' || \
                echo "No service is listening on port 25."
            ;;

        6)
            echo
            journalctl -u postfix -n 40 --no-pager
            ;;

        7)
            info "SMTP client configuration complete."
            exit 0
            ;;

        *)
            warn "Invalid choice. Please enter a number from 1 to 7."
            ;;
    esac

done

