
#!/bin/bash

# ============================================================
# Apache Web Server - Client Configuration and Testing
# Compatible with Rocky Linux / RHEL
# ============================================================

set -o pipefail

HOSTS_FILE="/etc/hosts"
DEFAULT_SERVER_IP="192.168.78.128"
DEFAULT_HTTP_PORT="80"
DEFAULT_WEBSITES="server.skynet.com,www.skynet.com"
DEFAULT_TEST_PATH="/"

# -------------------- DISPLAY -------------------------------

show_header() {
    echo
    echo "============================================================"
    echo "       APACHE WEB SERVER - CLIENT CONFIGURATION"
    echo "============================================================"
}

info() {
    echo "[INFO] $*"
}

success() {
    echo "[SUCCESS] $*"
}

warning() {
    echo "[WARNING] $*"
}

error() {
    echo "[ERROR] $*" >&2
}

# -------------------- ROOT CHECK ----------------------------

if [[ $EUID -ne 0 ]]; then
    error "Run this script as root."
    echo "Example: sudo ./10_apache_client.sh"
    exit 1
fi

# -------------------- INPUT VALIDATION ----------------------

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


valid_hostname() {
    local name="$1"
    local label

    [[ ${#name} -le 253 ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$name" != .* && "$name" != *. ]] || return 1
    [[ "$name" != *..* ]] || return 1

    IFS='.' read -r -a labels <<< "$name"

    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done

    return 0
}


# -------------------- SYSTEM INFORMATION --------------------

show_header

echo "Client hostname: $(hostname -f 2>/dev/null || hostname)"
echo
echo "Client IP addresses:"

if command -v ip >/dev/null 2>&1; then
    ip -brief address show
else
    warning "'ip' command not found."
fi

# -------------------- CONFIGURATION -------------------------

echo
echo "============================================================"
echo "               CONFIGURATION VARIABLES"
echo "============================================================"

read -r -p "Apache server IPv4 address [$DEFAULT_SERVER_IP]: " SERVER_IP
SERVER_IP="${SERVER_IP:-$DEFAULT_SERVER_IP}"

while ! valid_ipv4 "$SERVER_IP"; do
    error "Invalid IPv4 address."
    read -r -p "Enter Apache server IPv4 address: " SERVER_IP
done

read -r -p "Apache HTTP port [$DEFAULT_HTTP_PORT]: " HTTP_PORT
HTTP_PORT="${HTTP_PORT:-$DEFAULT_HTTP_PORT}"

while ! [[ "$HTTP_PORT" =~ ^[0-9]+$ ]] ||
      (( 10#$HTTP_PORT < 1 || 10#$HTTP_PORT > 65535 )); do
    error "Port must be between 1 and 65535."
    read -r -p "Enter HTTP port: " HTTP_PORT
done

HTTP_PORT=$((10#$HTTP_PORT))

read -r -p "Website hostnames, comma-separated [$DEFAULT_WEBSITES]: " WEBSITES
WEBSITES="${WEBSITES:-$DEFAULT_WEBSITES}"

read -r -p "Website test path [$DEFAULT_TEST_PATH]: " TEST_PATH
TEST_PATH="${TEST_PATH:-$DEFAULT_TEST_PATH}"

[[ "$TEST_PATH" == /* ]] || TEST_PATH="/$TEST_PATH"

# Avoid malformed URLs and command-line confusion.
if [[ "$TEST_PATH" == *" "* || "$TEST_PATH" == *"#"* ]]; then
    error "Test path must not contain spaces or a fragment (#)."
    exit 1
fi

# Parse, normalize and deduplicate hostnames.
WEBSITES="${WEBSITES//;/,}"
IFS=',' read -r -a INPUT_HOSTS <<< "$WEBSITES"

declare -a SITES=()
declare -A SEEN_HOSTS=()

for site in "${INPUT_HOSTS[@]}"; do
    site="$(echo "$site" | tr '[:upper:]' '[:lower:]' | xargs)"

    [[ -z "$site" ]] && continue

    if ! valid_hostname "$site"; then
        error "Invalid hostname: $site"
        exit 1
    fi

    if [[ -z "${SEEN_HOSTS[$site]+x}" ]]; then
        SITES+=("$site")
        SEEN_HOSTS["$site"]=1
    fi
done

if [[ ${#SITES[@]} -eq 0 ]]; then
    error "Enter at least one website hostname."
    exit 1
fi

# -------------------- SUMMARY -------------------------------

echo
echo "============================================================"
echo "                 CONFIGURATION SUMMARY"
echo "============================================================"
echo "Apache server IP : $SERVER_IP"
echo "HTTP port        : $HTTP_PORT"
echo "Test path        : $TEST_PATH"
echo "Client hosts file: $HOSTS_FILE"
echo
echo "Websites to check:"

for site in "${SITES[@]}"; do
    echo "  - $site"
done

echo "============================================================"

read -r -p "Continue with these settings? (y/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    info "Cancelled. No changes made."
    exit 0
fi

# -------------------- REQUIRED COMMANDS ---------------------

echo
info "Checking required commands..."

MISSING=()

for cmd in awk grep sed getent curl nc cp mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "Missing commands: ${MISSING[*]}"
    echo "Install the required tools using:"
    echo "  dnf install -y curl nmap-ncat"
    echo "Then run this script again."
    exit 1
fi

# -------------------- HOSTS FILE MENU -----------------------

echo
echo "============================================================"
echo "                 CLIENT HOSTS FILE"
echo "============================================================"
echo "1. Add/update website entries in /etc/hosts"
echo "2. Skip hosts file changes and only test websites"

read -r -p "Choose option [1-2]: " HOSTS_OPTION

case "$HOSTS_OPTION" in
    1)
        if [[ ! -f "$HOSTS_FILE" ]]; then
            error "$HOSTS_FILE does not exist."
            exit 1
        fi

        BACKUP="${HOSTS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

        if ! cp -p "$HOSTS_FILE" "$BACKUP"; then
            error "Could not back up $HOSTS_FILE."
            exit 1
        fi

        success "Backup created: $BACKUP"

        TMP_FILE="$(mktemp)" || exit 1

        # Remove only the configured website aliases from old entries.
        # Preserve unrelated hostnames and comments.
        TARGETS="$(IFS=,; echo "${SITES[*]}")"

        if ! awk -v targets="$TARGETS" '
        BEGIN {
            count = split(targets, t, ",")
            for (i = 1; i <= count; i++)
                wanted[tolower(t[i])] = 1
        }
        {
            original = $0
            body = $0
            comment = ""

            hash = index(body, "#")
            if (hash > 0) {
                comment = substr(body, hash)
                body = substr(body, 1, hash - 1)
            }

            trimmed = body
            gsub(/^[ \t]+|[ \t]+$/, "", trimmed)

            if (trimmed == "") {
                print original
                next
            }

            n = split(trimmed, fields, /[ \t]+/)
            ip = fields[1]
            output = ip
            matched = 0
            aliases = 0

            for (i = 2; i <= n; i++) {
                name = tolower(fields[i])

                if (name in wanted) {
                    matched = 1
                } else {
                    output = output " " fields[i]
                    aliases++
                }
            }

            if (!matched) {
                print original
            } else if (aliases > 0) {
                print output (comment != "" ? " " comment : "")
            } else if (comment != "") {
                print comment
            }
        }' "$HOSTS_FILE" > "$TMP_FILE"; then
            rm -f "$TMP_FILE"
            error "Failed while processing $HOSTS_FILE."
            exit 1
        fi

        # Add all configured websites on one hosts-file line.
        {
            echo
            printf '%s' "$SERVER_IP"
            for site in "${SITES[@]}"; do
                printf ' %s' "$site"
            done
            echo
        } >> "$TMP_FILE"

        if ! cat "$TMP_FILE" > "$HOSTS_FILE"; then
            cp -p "$BACKUP" "$HOSTS_FILE"
            rm -f "$TMP_FILE"
            error "Could not update $HOSTS_FILE. Backup restored."
            exit 1
        fi

        rm -f "$TMP_FILE"
        success "Updated $HOSTS_FILE"
        echo
        echo "Added entry:"
        printf '%s' "$SERVER_IP"
        for site in "${SITES[@]}"; do
            printf ' %s' "$site"
        done
        echo
        ;;

    2)
        info "Skipping /etc/hosts modifications."
        echo "Hostname resolution may fail if DNS or /etc/hosts"
        echo "does not already contain these website names."
        ;;

    *)
        error "Invalid option. Choose 1 or 2."
        exit 1
        ;;
esac

# -------------------- HOSTNAME RESOLUTION -------------------

echo
echo "============================================================"
echo "             HOSTNAME RESOLUTION CHECK"
echo "============================================================"

RESOLUTION_FAILURES=0

for site in "${SITES[@]}"; do
    echo
    echo "Website: $site"

    if getent ahostsv4 "$site" 2>/dev/null |
        awk -v expected="$SERVER_IP" '$1 == expected { found=1 } END { exit !found }'; then
        success "$site resolves to $SERVER_IP."
    else
        warning "$site does not resolve to $SERVER_IP through the system resolver."
        ((RESOLUTION_FAILURES++))
    fi
done

# -------------------- SERVER PORT CHECK ---------------------

echo
echo "============================================================"
echo "                 HTTP PORT CHECK"
echo "============================================================"
echo "Testing $SERVER_IP on TCP port $HTTP_PORT..."

if nc -z -w 5 "$SERVER_IP" "$HTTP_PORT" >/dev/null 2>&1; then
    success "TCP port $HTTP_PORT is reachable on $SERVER_IP."
    PORT_REACHABLE=1
else
    error "TCP port $HTTP_PORT is not reachable on $SERVER_IP."
    warning "Check Apache status, firewall rules, IP address and port."
    PORT_REACHABLE=0
fi

# -------------------- WEBSITE TESTS -------------------------

echo
echo "============================================================"
echo "                  WEBSITE TEST RESULTS"
echo "============================================================"

HTTP_FAILURES=0
HTTP_SUCCESSES=0

for site in "${SITES[@]}"; do
    URL="http://${site}:${HTTP_PORT}${TEST_PATH}"

    echo
    echo "============================================================"
    echo "Website hostname : $site"
    echo "Target server IP : $SERVER_IP"
    echo "Test URL         : $URL"
    echo "============================================================"

    # --resolve sends the request to the specified server IP while
    # preserving the hostname in the HTTP Host header.
    # This allows virtual-host testing even if DNS is not configured.
    RESULT="$(curl --noproxy '*' \
        --resolve "${site}:${HTTP_PORT}:${SERVER_IP}" \
        --connect-timeout 5 \
        --max-time 15 \
        --silent --show-error \
        --output - \
        --write-out $'\n__HTTP_STATUS__:%{http_code}\n' \
        "$URL" 2>&1)"

    CURL_RC=$?

    if [[ $CURL_RC -ne 0 ]]; then
        error "HTTP request failed for $site (curl exit code $CURL_RC)."
        echo "$RESULT" | tail -n 5
        ((HTTP_FAILURES++))
        continue
    fi

    HTTP_STATUS="$(printf '%s\n' "$RESULT" |
        sed -n 's/^__HTTP_STATUS__:\([0-9][0-9][0-9]\)$/\1/p' |
        tail -n 1)"

    BODY="$(printf '%s\n' "$RESULT" |
        sed '/^__HTTP_STATUS__:[0-9][0-9][0-9]$/d')"

    if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
        success "HTTP response: $HTTP_STATUS"
        ((HTTP_SUCCESSES++))
    elif [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]]; then
        warning "HTTP response: $HTTP_STATUS"
        ((HTTP_FAILURES++))
    else
        warning "Could not determine HTTP status."
        ((HTTP_FAILURES++))
    fi

    echo
    echo "Response body preview (first 10 lines):"
    printf '%s\n' "$BODY" | head -n 10
done

# -------------------- FINAL SUMMARY ------------------------

echo
echo "============================================================"
echo "             APACHE CLIENT TEST COMPLETED"
echo "============================================================"
echo "Server IP            : $SERVER_IP"
echo "HTTP port            : $HTTP_PORT"
echo "Hosts file           : $HOSTS_FILE"
echo "Websites checked     : ${#SITES[@]}"
echo "HTTP successes       : $HTTP_SUCCESSES"
echo "HTTP failures        : $HTTP_FAILURES"
echo "Resolution warnings  : $RESOLUTION_FAILURES"
echo "TCP port reachable   : $PORT_REACHABLE"
echo

echo "Website hostnames:"
for site in "${SITES[@]}"; do
    echo "  $site -> $SERVER_IP (HTTP test target)"
done

echo
echo "Useful commands:"
echo "  getent hosts <website-hostname>"
echo "  curl http://<website-hostname>:${HTTP_PORT}${TEST_PATH}"
echo "  curl --resolve <website-hostname>:${HTTP_PORT}:${SERVER_IP} \\"
echo "       http://<website-hostname>:${HTTP_PORT}${TEST_PATH}"
echo "  nc -zv $SERVER_IP $HTTP_PORT"

echo
echo "If a website fails, check on the Apache SERVER:"
echo "  httpd -t"
echo "  httpd -S"
echo "  systemctl status httpd"
echo "  firewall-cmd --list-all"
echo "  journalctl -u httpd -n 30 --no-pager"

if (( RESOLUTION_FAILURES > 0 )); then
    echo
    warning "Some names did not resolve through the system resolver."
    echo "Choose option 1 next time to update /etc/hosts, or configure DNS."
    echo "HTTP tests can still succeed because curl --resolve bypasses DNS."
fi

echo "============================================================"

# A failed HTTP request or unreachable server should produce a
# non-zero exit status, useful for automation and Jenkins.
if (( HTTP_FAILURES > 0 || PORT_REACHABLE == 0 )); then
    exit 1
fi

exit 0

