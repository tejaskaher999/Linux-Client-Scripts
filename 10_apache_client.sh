#!/bin/bash

# ============================================================
# Script Name : 10_apache_client.sh
# Purpose     : Configure client /etc/hosts and test Apache sites
# OS          : Rocky Linux / RHEL
# ============================================================

set -o pipefail

# -------------------- DEFAULT VARIABLES ---------------------

DEFAULT_SERVER_IP="192.168.78.128"
DEFAULT_HTTP_PORT="80"
DEFAULT_WEBSITES="server.skynet.com,www.skynet.com"
DEFAULT_TEST_PATH="/"

# -------------------- COLORS --------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# -------------------- FUNCTIONS -----------------------------

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
    REPLY="${result:-$default}"
}

valid_hostname() {
    local name="$1"
    local label
    local IFS='.'

    [[ ${#name} -le 253 &&
       "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ &&
       "$name" != *..* ]] || return 1

    read -r -a labels <<< "$name"

    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 &&
           "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] ||
            return 1
    done

    return 0
}

valid_ipv4() {
    local ip="$1"
    local octet
    local -a octets

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

    IFS='.' read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done

    return 0
}

# -------------------- ROOT CHECK -----------------------------

if [[ "$EUID" -ne 0 ]]; then
    error "Run this script as root."
    echo "Example: sudo bash 10_apache_client.sh"
    exit 1
fi

# -------------------- OS CHECK -------------------------------

if [[ ! -f /etc/os-release ]]; then
    error "Cannot identify the operating system."
    exit 1
fi

source /etc/os-release

if [[ "$ID" != "rocky" && "$ID" != "rhel" &&
      "${ID_LIKE:-}" != *rhel* ]]; then
    warning "This script is intended for RHEL / Rocky Linux."
    read -r -p "Continue anyway? (y/n): " OS_CONFIRM

    if [[ ! "$OS_CONFIRM" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# -------------------- HEADER ---------------------------------

echo
print_line
echo "          APACHE WEB SERVER - CLIENT CONFIGURATION"
print_line
echo "This script manages client-side hostname entries and tests"
echo "websites hosted on a remote Apache server."
echo
echo "Current client hostname: $(hostname -f 2>/dev/null || hostname)"
echo "Current client IP addresses:"
ip -br -4 addr
echo

# -------------------- INTERACTIVE VARIABLES ------------------

echo
print_line
echo "               CONFIGURATION VARIABLES"
print_line

ask_value "Apache server IPv4 address" "$DEFAULT_SERVER_IP"
SERVER_IP="$REPLY"

ask_value "Apache HTTP port" "$DEFAULT_HTTP_PORT"
HTTP_PORT="$REPLY"

ask_value "Website hostnames, comma-separated" "$DEFAULT_WEBSITES"
WEBSITES_INPUT="$REPLY"

ask_value "Website test path" "$DEFAULT_TEST_PATH"
TEST_PATH="$REPLY"

if [[ "$TEST_PATH" != /* ]]; then
    TEST_PATH="/$TEST_PATH"
fi

# -------------------- VALIDATE VARIABLES ---------------------

if ! valid_ipv4 "$SERVER_IP"; then
    error "Invalid IPv4 address: $SERVER_IP"
    exit 1
fi

if [[ ! "$HTTP_PORT" =~ ^[0-9]+$ ]] ||
   (( 10#$HTTP_PORT < 1 || 10#$HTTP_PORT > 65535 )); then
    error "Invalid TCP port: $HTTP_PORT"
    exit 1
fi

# Validate the path to avoid malformed request URLs.
if [[ "$TEST_PATH" =~ [[:space:][:cntrl:]] ]]; then
    error "The test path must not contain spaces or control characters."
    exit 1
fi

# Convert comma-separated hostnames into an array.
IFS=',' read -r -a WEBSITES <<< "$WEBSITES_INPUT"

# Trim surrounding spaces and remove duplicate names.
CLEAN_WEBSITES=()

for site in "${WEBSITES[@]}"; do
    site="${site#"${site%%[![:space:]]*}"}"
    site="${site%"${site##*[![:space:]]}"}"

    [[ -z "$site" ]] && continue

    if ! valid_hostname "$site"; then
        error "Invalid website hostname: $site"
        exit 1
    fi

    duplicate="no"

    for existing in "${CLEAN_WEBSITES[@]}"; do
        if [[ "${existing,,}" == "${site,,}" ]]; then
            duplicate="yes"
            break
        fi
    done

    if [[ "$duplicate" == "no" ]]; then
        CLEAN_WEBSITES+=("$site")
    fi
done

if [[ ${#CLEAN_WEBSITES[@]} -eq 0 ]]; then
    error "Enter at least one website hostname."
    exit 1
fi

# -------------------- CONFIGURATION SUMMARY ------------------

echo
print_line
echo "                 CONFIGURATION SUMMARY"
print_line
echo "Apache server IP : $SERVER_IP"
echo "HTTP port        : $HTTP_PORT"
echo "Test path        : $TEST_PATH"
echo "Client hosts file: /etc/hosts"
echo
echo "Websites to check:"

for site in "${CLEAN_WEBSITES[@]}"; do
    echo "  - $site"
done

print_line
echo
echo "The script can back up and update /etc/hosts."
echo "It will preserve unrelated host entries."
echo

read -r -p "Continue with these settings? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warning "Cancelled. No changes made."
    exit 0
fi

# -------------------- CHECK REQUIRED COMMANDS -----------------

echo
info "Checking required commands..."

for cmd in awk grep sed getent curl nc mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Required command '$cmd' was not found."
        echo "Install curl and nmap-ncat if required:"
        echo "  dnf install -y curl nmap-ncat"
        exit 1
    fi
done

# -------------------- HOSTS FILE UPDATE OPTION ---------------

echo
print_line
echo "                 CLIENT HOSTS FILE"
print_line
echo "1. Add/update website entries in /etc/hosts"
echo "2. Skip hosts file changes and only test websites"
echo

read -r -p "Choose option [1-2]: " HOSTS_OPTION

case "$HOSTS_OPTION" in
    1)
        HOSTS_FILE="/etc/hosts"

        if [[ ! -f "$HOSTS_FILE" ]]; then
            error "/etc/hosts does not exist."
            exit 1
        fi

        # Create a backup before editing.
        HOSTS_BACKUP="/etc/hosts.backup.$(date +%Y%m%d_%H%M%S)"

        if ! cp -a "$HOSTS_FILE" "$HOSTS_BACKUP"; then
            error "Could not back up /etc/hosts."
            exit 1
        fi

        info "Backup created: $HOSTS_BACKUP"

        # Build a comma-separated list for awk.
        TARGET_HOSTS=""
        for site in "${CLEAN_WEBSITES[@]}"; do
            TARGET_HOSTS+="${TARGET_HOSTS:+,}${site}"
        done

        HOSTS_TEMP="$(mktemp)" || {
            error "Could not create a temporary file."
            exit 1
        }

        # Remove only the selected hostnames from old entries.
        # Preserve other hostnames, comments and unrelated records.
        if ! awk \
            -v ip="$SERVER_IP" \
            -v target_list="$TARGET_HOSTS" \
            '
            BEGIN {
                count = split(target_list, list, ",")
                for (i = 1; i <= count; i++) {
                    target[tolower(list[i])] = 1
                }
            }

            {
                original = $0
                line = $0
                comment = ""

                hashpos = index(line, "#")
                if (hashpos > 0) {
                    comment = substr(line, hashpos)
                    line = substr(line, 1, hashpos - 1)
                }

                gsub(/^[ \t]+|[ \t]+$/, "", line)

                if (line == "") {
                    print original
                    next
                }

                n = split(line, fields, /[ \t]+/)
                changed = 0
                output = fields[1]

                for (i = 2; i <= n; i++) {
                    if (tolower(fields[i]) in target) {
                        changed = 1
                    } else {
                        output = output " " fields[i]
                    }
                }

                if (!changed) {
                    print original
                    next
                }

                # If other aliases remain, preserve them.
                if (n > 1 && output != fields[1]) {
                    print output (comment != "" ? " " comment : "")
                } else if (comment != "") {
                    print comment
                }
            }

            END {
                printf "%s", ""
            }
            ' "$HOSTS_FILE" > "$HOSTS_TEMP"; then

            rm -f "$HOSTS_TEMP"
            error "Failed to prepare the updated hosts file."
            exit 1
        fi

        # Add the configured websites together on one line.
        printf '%s' "$SERVER_IP" >> "$HOSTS_TEMP"

        for site in "${CLEAN_WEBSITES[@]}"; do
            printf ' %s' "$site" >> "$HOSTS_TEMP"
        done

        printf '\n' >> "$HOSTS_TEMP"

        if ! cat "$HOSTS_TEMP" > "$HOSTS_FILE"; then
            rm -f "$HOSTS_TEMP"
            error "Could not update /etc/hosts."
            warning "Backup: $HOSTS_BACKUP"
            exit 1
        fi

        rm -f "$HOSTS_TEMP"

        success "Client /etc/hosts updated successfully."
        echo "Backup: $HOSTS_BACKUP"
        ;;

    2)
        info "Skipping /etc/hosts modifications."
        ;;

    *)
        error "Invalid choice."
        exit 1
        ;;
esac

# -------------------- DISPLAY HOSTS ENTRIES ------------------

echo
print_line
echo "             HOSTNAME RESOLUTION CHECK"
print_line

for site in "${CLEAN_WEBSITES[@]}"; do
    echo
    echo "Website: $site"

    RESOLVED_IPS="$(getent ahostsv4 "$site" 2>/dev/null |
        awk '!seen[$1]++ {print $1}')"

    if [[ -n "$RESOLVED_IPS" ]]; then
        echo "Resolved IPv4 address(es):"
        echo "$RESOLVED_IPS"

        if grep -Fxq "$SERVER_IP" <<< "$RESOLVED_IPS"; then
            success "$site resolves to $SERVER_IP."
        else
            warning "$site resolves, but not to the configured server IP."
            echo "The website test below will explicitly target $SERVER_IP."
        fi
    else
        warning "Hostname did not resolve through the system resolver."
    fi
done

# -------------------- TEST TCP CONNECTIVITY -------------------

echo
print_line
echo "                 HTTP PORT CHECK"
print_line
echo "Testing $SERVER_IP on TCP port $HTTP_PORT..."

if timeout 5 nc -z -w 3 "$SERVER_IP" "$HTTP_PORT"; then
    success "TCP port $HTTP_PORT is reachable on $SERVER_IP."
else
    error "Cannot connect to $SERVER_IP:$HTTP_PORT."
    warning "Check Apache, firewalld, network routing and server IP."
fi

# -------------------- TEST EACH WEBSITE -----------------------

echo
print_line
echo "                  WEBSITE TEST RESULTS"
print_line

TEMP_BODY="$(mktemp)" || {
    error "Could not create a temporary response file."
    exit 1
}

trap 'rm -f "$TEMP_BODY"' EXIT

for site in "${CLEAN_WEBSITES[@]}"; do
    echo
    print_line
    echo "Website hostname : $site"
    echo "Target server IP : $SERVER_IP"
    echo "Test URL         : http://${site}:${HTTP_PORT}${TEST_PATH}"
    print_line

    # --resolve makes curl connect to the specified IP while
    # sending the correct Host header for Apache virtual hosting.
    HTTP_STATUS="$(
        curl --noproxy '*' \
            --connect-timeout 5 \
            --max-time 15 \
            --silent --show-error \
            --resolve "${site}:${HTTP_PORT}:${SERVER_IP}" \
            --output "$TEMP_BODY" \
            --write-out '%{http_code}' \
            "http://${site}:${HTTP_PORT}${TEST_PATH}" 2>/dev/null
    )"
    CURL_STATUS=$?

    if [[ $CURL_STATUS -eq 0 && "$HTTP_STATUS" =~ ^[0-9]{3}$ ]]; then
        if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ||
              "$HTTP_STATUS" =~ ^3[0-9][0-9]$ ]]; then
            success "HTTP response: $HTTP_STATUS"
        else
            warning "Server responded with HTTP status: $HTTP_STATUS"
        fi

        echo
        echo "Response body preview (first 10 lines):"
        sed -n '1,10p' "$TEMP_BODY"

    else
        error "Website request failed."
        echo "curl exit code: $CURL_STATUS"
        echo "Check that Apache is running and the website is configured."
    fi
done

rm -f "$TEMP_BODY"
trap - EXIT

# -------------------- FINAL SUMMARY ---------------------------

echo
print_line
echo "             APACHE CLIENT TEST COMPLETED"
print_line

echo "Server IP        : $SERVER_IP"
echo "HTTP port        : $HTTP_PORT"
echo "Hosts file       : /etc/hosts"
echo "Websites checked : ${#CLEAN_WEBSITES[@]}"

echo
echo "Configured website entries:"
for site in "${CLEAN_WEBSITES[@]}"; do
    echo "$SERVER_IP $site"
done

echo
echo "Useful commands:"
echo "  getent hosts <website-hostname>"
echo "  curl http://<website-hostname>/"
echo "  curl http://$SERVER_IP/ -H 'Host: <website-hostname>'"
echo "  nc -zv $SERVER_IP $HTTP_PORT"

echo
echo "If a website fails, check on the Apache server:"
echo "  httpd -t"
echo "  httpd -S"
echo "  systemctl status httpd"
echo "  firewall-cmd --list-all"
echo "  journalctl -u httpd -n 30 --no-pager"

print_line

