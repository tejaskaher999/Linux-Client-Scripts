#!/bin/bash

# ==========================================================
# MariaDB Client Management Script
# Compatible with Rocky Linux / RHEL-based systems
# Connects to a remote MariaDB server
# ==========================================================

# ---------- Colors ----------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

# ---------- Default Configuration ----------
DEFAULT_SERVER="192.168.78.128"
DEFAULT_PORT="3306"
DEFAULT_USER="dbclient"
DEFAULT_DATABASE=""

SERVER="$DEFAULT_SERVER"
PORT="$DEFAULT_PORT"
DB_USER="$DEFAULT_USER"
DB_NAME="$DEFAULT_DATABASE"
DB_PASS=""

# ---------- Helper Functions ----------
success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
info()    { echo -e "${CYAN}[INFO]${RESET} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${RESET} $1"; }

pause_screen() {
    echo
    read -r -p "Press Enter to continue..."
}

confirm_action() {
    local answer
    read -r -p "$1 (yes/no): " answer
    [[ "$answer" == "yes" ]]
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Run this script as root."
        echo "Example: sudo bash $0"
        exit 1
    fi
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# ---------- Install Client ----------
install_client() {
    if ! command -v mariadb >/dev/null 2>&1; then
        info "Installing MariaDB client tools..."
        if ! dnf install -y mariadb; then
            error "MariaDB client installation failed."
            exit 1
        fi
    fi

    if ! command -v mariadb-dump >/dev/null 2>&1; then
        warning "mariadb-dump is unavailable. Backup and restore may not work."
    fi

    success "MariaDB client tools are ready."
}

# ---------- Connection Functions ----------
db() {
    MYSQL_PWD="$DB_PASS" mariadb \
        --protocol=TCP \
        --connect-timeout=5 \
        -h "$SERVER" \
        -P "$PORT" \
        -u "$DB_USER" "$@"
}

db_dump() {
    MYSQL_PWD="$DB_PASS" mariadb-dump \
        --protocol=TCP \
        --connect-timeout=5 \
        -h "$SERVER" \
        -P "$PORT" \
        -u "$DB_USER" "$@"
}

test_connection() {
    echo
    info "Testing MariaDB connection..."

    if db -N -B -e "SELECT VERSION();" 2>/dev/null; then
        success "Connected to MariaDB at $SERVER:$PORT."
        echo
        db -e "SELECT USER() AS Connected_As, CURRENT_USER() AS Authenticated_As, VERSION() AS MariaDB_Version;"
        return 0
    else
        error "Connection failed."
        echo
        echo "Check the following:"
        echo "1. MariaDB server is running."
        echo "2. Server IP and port are correct."
        echo "3. Firewall allows TCP port $PORT."
        echo "4. The MariaDB user permits connections from this client."
        echo "5. Username and password are correct."
        return 1
    fi
}

configure_connection() {
    local new_server new_port new_user new_database

    echo
    echo "========== Connection Configuration =========="

    read -r -p "Server IP [$SERVER]: " new_server
    SERVER="${new_server:-$SERVER}"

    if [[ ! "$SERVER" =~ ^[A-Za-z0-9.-]+$ ]]; then
        error "Invalid server address."
        return 1
    fi

    read -r -p "Server port [$PORT]: " new_port
    PORT="${new_port:-$PORT}"

    if [[ ! "$PORT" =~ ^[0-9]+$ ]] ||
       (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
        error "Invalid port number."
        return 1
    fi

    read -r -p "Database username [$DB_USER]: " new_user
    DB_USER="${new_user:-$DB_USER}"

    if ! valid_name "$DB_USER"; then
        error "Invalid username."
        return 1
    fi

    read -r -p "Default database (blank for none) [$DB_NAME]: " new_database
    DB_NAME="${new_database:-$DB_NAME}"

    if [[ -n "$DB_NAME" ]] && ! valid_name "$DB_NAME"; then
        error "Invalid database name."
        return 1
    fi

    echo
    read -r -s -p "Password for '$DB_USER': " DB_PASS
    echo

    if [[ -z "$DB_PASS" ]]; then
        warning "An empty password was entered."
    fi

    if test_connection; then
        success "Connection configuration saved for this script session."
        return 0
    else
        warning "Connection test failed. You can update the settings and retry."
        return 1
    fi
}

require_connection() {
    if [[ -z "$DB_PASS" ]]; then
        error "Configure the connection first."
        return 1
    fi

    return 0
}

require_database() {
    require_connection || return 1

    if [[ -z "$DB_NAME" ]]; then
        read -r -p "Enter database name: " DB_NAME
    fi

    if ! valid_name "$DB_NAME"; then
        error "Invalid database name."
        return 1
    fi

    if ! db -N -B -e \
        "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME';" \
        2>/dev/null | grep -Fxq "$DB_NAME"; then
        error "Database '$DB_NAME' does not exist or access was denied."
        return 1
    fi

    return 0
}

require_table() {
    require_database || return 1

    read -r -p "Enter table name: " TABLE_NAME

    if ! valid_name "$TABLE_NAME"; then
        error "Invalid table name."
        return 1
    fi

    if ! db -N -B -e \
        "SELECT TABLE_NAME FROM information_schema.TABLES
         WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_NAME='$TABLE_NAME';" \
        2>/dev/null | grep -Fxq "$TABLE_NAME"; then
        error "Table '$TABLE_NAME' does not exist or access was denied."
        return 1
    fi

    return 0
}

# ---------- Database Operations ----------
show_databases() {
    require_connection || return
    db -e "SHOW DATABASES;"
}

select_database() {
    require_connection || return

    local name
    read -r -p "Database name: " name

    if ! valid_name "$name"; then
        error "Invalid database name."
        return
    fi

    if db -e "USE \`$name\`; SELECT DATABASE() AS Selected_Database;" \
        2>/dev/null; then
        DB_NAME="$name"
        success "Default database set to '$DB_NAME'."
    else
        error "Could not select database. Check its existence and permissions."
    fi
}

show_tables() {
    require_database || return
    db -e "SHOW TABLES FROM \`$DB_NAME\`;"
}

show_table_structure() {
    require_table || return
    db -e "SHOW COLUMNS FROM \`$DB_NAME\`.\`$TABLE_NAME\`;"
}

show_records() {
    require_table || return
    db -e "SELECT * FROM \`$DB_NAME\`.\`$TABLE_NAME\`;"
}

search_records() {
    require_table || return

    local column value
    read -r -p "Column name to search: " column

    if ! valid_name "$column"; then
        error "Invalid column name."
        return
    fi

    read -r -p "Value to search for: " value

    # Escape SQL single quotes in the search value.
    value="${value//\'/\'\'}"

    db -e "SELECT * FROM \`$DB_NAME\`.\`$TABLE_NAME\`
           WHERE \`$column\`='$value';"
}

run_select_query() {
    require_connection || return

    local query
    echo "Enter a SELECT query. End it with a semicolon."
    read -r -p "SQL> " query

    if [[ ! "$query" =~ ^[[:space:]]*SELECT[[:space:]] ]]; then
        error "Only SELECT statements are allowed in this menu option."
        return
    fi

    db ${DB_NAME:+ "$DB_NAME"} -e "$query"
}

# ---------- Interactive SQL Shell ----------
interactive_shell() {
    require_connection || return

    echo
    info "Opening MariaDB interactive shell."
    echo "Type exit; or quit; to return to the menu."
    echo

    MYSQL_PWD="$DB_PASS" mariadb \
        --protocol=TCP \
        --connect-timeout=5 \
        -h "$SERVER" \
        -P "$PORT" \
        -u "$DB_USER" ${DB_NAME:+"$DB_NAME"}
}

# ---------- Backup and Restore ----------
backup_database() {
    require_database || return

    if ! command -v mariadb-dump >/dev/null 2>&1; then
        error "mariadb-dump is not installed."
        return
    fi

    local file
    read -r -p "Backup path [/root/${DB_NAME}_backup.sql]: " file
    file="${file:-/root/${DB_NAME}_backup.sql}"

    if [[ -e "$file" ]]; then
        warning "The backup file already exists."
        if ! confirm_action "Overwrite '$file'"; then
            info "Backup cancelled."
            return
        fi
    fi

    if db_dump "$DB_NAME" > "$file"; then
        chmod 600 "$file"
        success "Backup created: $file"
        ls -lh "$file"
    else
        rm -f "$file"
        error "Backup failed. Check database permissions and disk space."
    fi
}

restore_database() {
    require_connection || return

    if [[ -z "$DB_NAME" ]]; then
        read -r -p "Target database name: " DB_NAME
    fi

    if ! valid_name "$DB_NAME"; then
        error "Invalid database name."
        return
    fi

    local file
    read -r -p "SQL backup file path: " file

    if [[ ! -f "$file" || ! -r "$file" ]]; then
        error "Backup file does not exist or cannot be read."
        return
    fi

    warning "Only restore SQL files you trust."
    warning "The connected user needs suitable privileges on '$DB_NAME'."

    if confirm_action "Restore '$file' into '$DB_NAME'"; then
        if db "$DB_NAME" < "$file"; then
            success "Restore completed."
        else
            error "Restore failed. Check the SQL file and user permissions."
        fi
    else
        info "Restore cancelled."
    fi
}

# ---------- Server Status ----------
server_status() {
    require_connection || return

    echo
    echo "========== Remote MariaDB Information =========="

    db -e "SELECT
        @@hostname AS Server_Hostname,
        @@port AS MariaDB_Port,
        VERSION() AS Version,
        CURRENT_USER() AS Authenticated_User,
        USER() AS Client_Connection;"

    echo
    echo "Client-side TCP connection check:"

    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 3 "$SERVER" "$PORT"; then
            success "TCP port $PORT is reachable."
        else
            error "TCP port $PORT is not reachable."
        fi
    else
        info "Install nmap-ncat if you want to use the nc port test."
    fi
}

# ---------- Main Menu ----------
show_menu() {
    echo
    echo "=================================================="
    echo "          MariaDB Client Management"
    echo "=================================================="
    echo " Server   : $SERVER:$PORT"
    echo " User     : $DB_USER"
    echo " Database : ${DB_NAME:-Not selected}"
    echo "=================================================="
    echo " 1. Configure / reconnect to server"
    echo " 2. Test connection"
    echo " 3. Display databases"
    echo " 4. Select / verify database"
    echo " 5. Display tables"
    echo " 6. Display table structure"
    echo " 7. Display table records"
    echo " 8. Search records"
    echo " 9. Run a SELECT query"
    echo "10. Open interactive SQL shell"
    echo "--------------------------------------------------"
    echo "11. Back up database to client"
    echo "12. Restore database from client file"
    echo "13. Remote server status"
    echo " 0. Exit"
    echo "=================================================="
}

main() {
    check_root
    install_client

    echo
    echo "MariaDB Client Setup"
    echo "Default server: $DEFAULT_SERVER:$DEFAULT_PORT"
    echo
    configure_connection || true

    while true; do
        show_menu
        read -r -p "Enter your choice: " choice
        echo

        case "$choice" in
            1)  configure_connection || true ;;
            2)  test_connection ;;
            3)  show_databases ;;
            4)  select_database ;;
            5)  show_tables ;;
            6)  show_table_structure ;;
            7)  show_records ;;
            8)  search_records ;;
            9)  run_select_query ;;
            10) interactive_shell ;;
            11) backup_database ;;
            12) restore_database ;;
            13) server_status ;;
            0)
                unset DB_PASS
                echo "Exiting MariaDB Client Management."
                exit 0
                ;;
            *)
                error "Invalid choice. Enter a number from 0 to 13."
                ;;
        esac

        echo
        pause_screen
    done
}

main

