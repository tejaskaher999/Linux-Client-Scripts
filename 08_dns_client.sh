#!/usr/bin/env bash

# ============================================================
# 08. ROCKY LINUX DNS CLIENT SETUP
# Interactive configuration + NetworkManager + DNS testing
# Supports IPv4 DNS server configuration
# ============================================================

set -Eeuo pipefail

# ---------- Default values ----------
DEFAULT_DOMAIN="tejas.com"
DEFAULT_DNS_SERVER="192.168.78.128"
DEFAULT_DNS_SERVER_HOST="docker"

DEFAULT_CLIENT_HOST="$(hostname -s)"
DEFAULT_INTERFACE="$(
    ip -o route show default 2>/dev/null |
    awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
)"

DEFAULT_CLIENT_IP="$(
    ip -o -4 addr show "$DEFAULT_INTERFACE" 2>/dev/null |
    awk 'NR == 1 {split($4,a,"/"); print a[1]}'
)"

DEFAULT_FORWARD_TEST="google.com"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/08_dns_client_${TIMESTAMP}.log"

# ---------- Logging ----------
mkdir -p /var/log
touch "$LOG_FILE"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

ask() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer

    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"

    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# ---------- Initial checks ----------
[[ $EUID -eq 0 ]] ||
    die "Run this script as root: sudo ./08_dns_client.sh"

command -v nmcli >/dev/null 2>&1 ||
    die "NetworkManager (nmcli) is required."

command -v ip >/dev/null 2>&1 ||
    die "The ip command is required."

[[ -n "$DEFAULT_INTERFACE" ]] ||
    die "Could not detect the default network interface."

[[ -n "$DEFAULT_CLIENT_IP" ]] ||
    die "Could not detect an IPv4 address on $DEFAULT_INTERFACE."

echo
echo "============================================================"
echo "          ROCKY LINUX DNS CLIENT CONFIGURATION"
echo "============================================================"
echo "Press Enter to accept a displayed default value."
echo

# ---------- Interactive configuration ----------
DNS_SERVER="$(ask 'DNS server IPv4 address' "$DEFAULT_DNS_SERVER")"
DNS_DOMAIN="$(ask 'DNS search domain' "$DEFAULT_DOMAIN")"
DNS_SERVER_HOST="$(ask 'DNS server hostname (short name)' "$DEFAULT_DNS_SERVER_HOST")"

CLIENT_HOST="$(ask 'This client hostname (short name)' "$DEFAULT_CLIENT_HOST")"
CLIENT_IP="$(ask 'This client current IPv4 address' "$DEFAULT_CLIENT_IP")"

INTERFACE="$(ask 'Network interface' "$DEFAULT_INTERFACE")"
FORWARD_TEST="$(ask 'Public hostname for forwarding test' "$DEFAULT_FORWARD_TEST")"

CONFIGURE_SYSTEM_RESOLVER="yes"

if ask_yes_no "Configure this machine to use the selected DNS server" "yes"; then
    CONFIGURE_SYSTEM_RESOLVER="yes"
else
    CONFIGURE_SYSTEM_RESOLVER="no"
fi

# Accept fully qualified names as input, but use short hostnames.
DNS_SERVER_HOST="${DNS_SERVER_HOST%%.*}"
CLIENT_HOST="${CLIENT_HOST%%.*}"

# ---------- Input validation ----------
valid_ipv4() {
    local ip="$1"
    local a b c d extra

    IFS=. read -r a b c d extra <<< "$ip"

    [[ -z "${extra:-}" ]] || return 1

    [[ "$a" =~ ^[0-9]+$ &&
       "$b" =~ ^[0-9]+$ &&
       "$c" =~ ^[0-9]+$ &&
       "$d" =~ ^[0-9]+$ ]] || return 1

    (( 10#$a <= 255 &&
       10#$b <= 255 &&
       10#$c <= 255 &&
       10#$d <= 255 ))
}

valid_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] &&
        (( ${#1} <= 63 ))
}

valid_domain() {
    local domain="$1"
    local label

    [[ -n "$domain" && ${#domain} -le 253 ]] || return 1
    [[ "$domain" != .* && "$domain" != *. ]] || return 1
    [[ "$domain" == *.* ]] || return 1

    [[ "$domain" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1

    IFS=. read -r -a labels <<< "$domain"

    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] ||
            return 1
    done
}

valid_dns_name() {
    [[ "$1" =~ ^[a-zA-Z0-9.-]+$ ]] &&
        [[ "$1" != .* && "$1" != *. ]]
}

valid_ipv4 "$DNS_SERVER" ||
    die "Invalid DNS server IPv4 address: $DNS_SERVER"

valid_ipv4 "$CLIENT_IP" ||
    die "Invalid client IPv4 address: $CLIENT_IP"

valid_domain "$DNS_DOMAIN" ||
    die "Invalid DNS domain: $DNS_DOMAIN"

valid_hostname "$DNS_SERVER_HOST" ||
    die "Invalid DNS server hostname."

valid_hostname "$CLIENT_HOST" ||
    die "Invalid client hostname."

valid_dns_name "$FORWARD_TEST" ||
    die "Invalid public hostname for the forwarding test."

[[ "$DNS_SERVER" != "$CLIENT_IP" ]] ||
    die "The DNS server IP and client IP must be different."

ip link show "$INTERFACE" >/dev/null 2>&1 ||
    die "Network interface does not exist: $INTERFACE"

CONNECTION_NAME="$(
    nmcli -g GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null || true
)"

[[ -n "$CONNECTION_NAME" && "$CONNECTION_NAME" != "--" ]] ||
    die "No active NetworkManager connection found for $INTERFACE."

DNS_SERVER_FQDN="${DNS_SERVER_HOST}.${DNS_DOMAIN}"
CLIENT_FQDN="${CLIENT_HOST}.${DNS_DOMAIN}"

# ---------- Configuration summary ----------
echo
echo "---------------- Configuration summary ----------------"
echo "DNS server       : $DNS_SERVER_FQDN ($DNS_SERVER)"
echo "DNS domain       : $DNS_DOMAIN"
echo "Client hostname  : $CLIENT_FQDN"
echo "Client IPv4      : $CLIENT_IP"
echo "Interface        : $INTERFACE"
echo "Connection       : $CONNECTION_NAME"
echo "Forward test     : $FORWARD_TEST"
echo "Configure DNS    : $CONFIGURE_SYSTEM_RESOLVER"
echo "Log file         : $LOG_FILE"
echo "--------------------------------------------------------"
echo

ask_yes_no "Continue with this configuration" "yes" ||
    die "Setup cancelled by user."

log "Starting DNS client configuration."

# ---------- Install DNS utilities ----------
if ! command -v dig >/dev/null 2>&1; then
    log "Installing DNS utilities."

    dnf install -y bind-utils ||
        die "Could not install bind-utils. Check DNF repositories and network access."
fi

command -v dig >/dev/null 2>&1 ||
    die "dig is unavailable after installing bind-utils."

# ---------- Verify network connectivity ----------
log "Checking reachability of DNS server $DNS_SERVER."

if ! timeout 5 bash -c \
    ':</dev/tcp/"$1"/53' _ "$DNS_SERVER" 2>/dev/null; then
    log "WARNING: TCP port 53 test failed or timed out."
    log "DNS normally uses UDP as well; continuing with direct DNS queries."
fi

# ---------- Test DNS server before changing resolver ----------
log "Testing DNS server response directly."

if ! dig +time=3 +tries=1 +short @"$DNS_SERVER" "$DNS_SERVER_FQDN" A |
    grep -Fxq "$DNS_SERVER"; then
    log "WARNING: Expected server record was not returned."
    log "Expected: $DNS_SERVER_FQDN -> $DNS_SERVER"
    log "Check that the DNS server is running and its forward zone contains the correct record."
fi

# Test the client record in the server's DNS zone.
CLIENT_DNS_ANSWER="$(
    dig +time=3 +tries=1 +short @"$DNS_SERVER" "$CLIENT_FQDN" A |
    head -n 1 || true
)"

if [[ "$CLIENT_DNS_ANSWER" == "$CLIENT_IP" ]]; then
    log "PASS: $CLIENT_FQDN resolves to $CLIENT_IP."
else
    log "WARNING: Client DNS record does not match the configured client IP."
    log "Client IP entered here : $CLIENT_IP"
    log "DNS answer from server : ${CLIENT_DNS_ANSWER:-no answer}"
    log "Update the client A record in the DNS server's forward zone if necessary."
fi

# ---------- Configure NetworkManager ----------
if [[ "$CONFIGURE_SYSTEM_RESOLVER" == "yes" ]]; then

    log "Configuring NetworkManager to use $DNS_SERVER."

    # Save current settings in the log before modifying them.
    {
        echo "----- Previous NetworkManager DNS settings -----"
        nmcli -f ipv4.dns,ipv4.dns-search,ipv4.ignore-auto-dns,ipv4.dns-priority \
            connection show "$CONNECTION_NAME"
        echo "-------------------------------------------------"
    } | tee -a "$LOG_FILE"

    # Change DNS settings only; do not change the client IP or gateway.
    nmcli connection modify "$CONNECTION_NAME" \
        ipv4.dns "$DNS_SERVER" \
        ipv4.dns-search "$DNS_DOMAIN" \
        ipv4.ignore-auto-dns yes \
        ipv4.dns-priority -50 ||
        die "Failed to configure NetworkManager DNS settings."

    if ! nmcli device reapply "$INTERFACE"; then
        log "Device reapply failed; activating the connection."
        nmcli connection up "$CONNECTION_NAME" ||
            die "Could not reactivate the NetworkManager connection."
    fi

    log "NetworkManager DNS configuration applied."

    echo
    echo "Current resolver configuration:"
    cat /etc/resolv.conf | tee -a "$LOG_FILE"

    # Verify the configured DNS server is in resolv.conf.
    if grep -Eq \
        "^[[:space:]]*nameserver[[:space:]]+${DNS_SERVER//./\\.}([[:space:]]*)$" \
        /etc/resolv.conf; then
        log "PASS: $DNS_SERVER is present in /etc/resolv.conf."
    else
        log "WARNING: $DNS_SERVER is not visible in /etc/resolv.conf."
        log "Check NetworkManager settings and /etc/resolv.conf."
    fi

else
    log "System resolver changes skipped by user."
fi

# ---------- Test local DNS records ----------
log "Testing local DNS records through the configured DNS server."

echo
echo "============================================================"
echo "                 DNS LOOKUP TESTS"
echo "============================================================"

test_dns_record() {
    local name="$1"
    local expected_ip="$2"
    local answer

    answer="$(
        dig +time=3 +tries=1 +short @"$DNS_SERVER" "$name" A |
        head -n 1 || true
    )"

    if [[ -n "$answer" ]]; then
        echo "Name     : $name"
        echo "Expected : $expected_ip"
        echo "Received : $answer"

        if [[ "$answer" == "$expected_ip" ]]; then
            success "DNS record matches."
        else
            warning "DNS returned a different IP address."
        fi
    else
        echo "Name     : $name"
        error "No A record returned."
    fi

    echo
}

success() {
    echo -e "\033[0;32mSUCCESS: $*\033[0m"
}

warning() {
    echo -e "\033[1;33mWARNING: $*\033[0m"
}

test_dns_record "$DNS_SERVER_FQDN" "$DNS_SERVER"
test_dns_record "$CLIENT_FQDN" "$CLIENT_IP"

# ---------- Test reverse DNS ----------
echo "Testing reverse DNS..."

PTR_ANSWER="$(
    dig +time=3 +tries=1 +short @"$DNS_SERVER" -x "$CLIENT_IP" |
    head -n 1 || true
)"

if [[ -n "$PTR_ANSWER" ]]; then
    echo "Reverse lookup: $CLIENT_IP -> $PTR_ANSWER"
    success "Reverse DNS returned a record."
else
    warning "No reverse DNS record returned for $CLIENT_IP."
    echo "Check the reverse zone on the DNS server."
fi

echo

# ---------- Test public DNS forwarding ----------
log "Testing public DNS forwarding for $FORWARD_TEST."

PUBLIC_ANSWER="$(
    dig +time=4 +tries=1 +short @"$DNS_SERVER" "$FORWARD_TEST" A |
    head -n 1 || true
)"

if [[ -n "$PUBLIC_ANSWER" ]]; then
    log "PASS: Public DNS lookup succeeded: $FORWARD_TEST -> $PUBLIC_ANSWER"
else
    log "WARNING: Public DNS forwarding failed for $FORWARD_TEST."
    log "Check internet connectivity, DNS forwarders, and the server firewall."
fi

# ---------- Test system resolver ----------
if [[ "$CONFIGURE_SYSTEM_RESOLVER" == "yes" ]]; then

    echo
    log "Testing hostname resolution through the system resolver."

    if getent ahostsv4 "$CLIENT_FQDN" >/dev/null 2>&1; then
        log "PASS: System resolver resolves $CLIENT_FQDN."
    else
        log "WARNING: System resolver could not resolve $CLIENT_FQDN."
        log "Check the local DNS server and its forward zone."
    fi

    if getent ahostsv4 "$FORWARD_TEST" >/dev/null 2>&1; then
        log "PASS: System resolver resolves $FORWARD_TEST."
    else
        log "WARNING: System resolver could not resolve $FORWARD_TEST."
    fi

    # Short names use the configured search domain.
    if getent ahostsv4 "$CLIENT_HOST" >/dev/null 2>&1; then
        log "PASS: Short hostname lookup works for $CLIENT_HOST."
    else
        log "WARNING: Short hostname lookup failed for $CLIENT_HOST."
        log "Try the fully qualified name: $CLIENT_FQDN"
    fi
fi

# ---------- Final summary ----------
echo
echo "============================================================"
echo "           DNS CLIENT CONFIGURATION FINISHED"
echo "============================================================"
echo "DNS server       : $DNS_SERVER_FQDN ($DNS_SERVER)"
echo "DNS domain       : $DNS_DOMAIN"
echo "Client hostname  : $CLIENT_FQDN"
echo "Client IP        : $CLIENT_IP"
echo "Interface        : $INTERFACE"
echo "Connection       : $CONNECTION_NAME"
echo "System DNS setup : $CONFIGURE_SYSTEM_RESOLVER"
echo
echo "Useful commands:"
echo "  dig @$DNS_SERVER $CLIENT_FQDN"
echo "  dig @$DNS_SERVER $DNS_SERVER_FQDN"
echo "  dig @$DNS_SERVER -x $CLIENT_IP"
echo "  dig @$DNS_SERVER $FORWARD_TEST"
echo "  getent ahostsv4 $CLIENT_FQDN"
echo "  cat /etc/resolv.conf"
echo "  nmcli device show $INTERFACE"
echo
echo "Log file: $LOG_FILE"
echo
echo "NOTE: DNS lookups can fail if the server's forward/reverse"
echo "zones do not contain records matching the actual client IP."
echo "============================================================"

