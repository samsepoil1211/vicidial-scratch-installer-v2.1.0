#!/usr/bin/env bash
#===============================================================================
#
#  install-vicidial.sh — Production VICIdial Standalone Server Installer
#
#  Unified, idempotent, resumable installer for VICIdial on
#  AlmaLinux / Rocky Linux 8 & 9 (x86_64).
#
#  Replaces: main-installer.sh, alma-rocky9-ast16/18.sh, alma-rocky-centos8-*
#  from https://github.com/samsepoil1211/Vicidial-scratch-install
#
#  Author : Debjit Pal (Sam) — Systems & VoIP Infrastructure Engineer
#           Beltalk Technologies Pvt. Ltd.
#  License: AGPLv2 (same as VICIdial)
#
#  Usage (interactive):
#      bash install-vicidial.sh
#
#  Usage (fully unattended):
#      bash install-vicidial.sh --yes --hostname dialer1.example.com \
#           --timezone America/New_York --asterisk 16 --php 7.4
#
#  Re-running the script resumes from the last completed step.
#  See --help for all options.
#
#===============================================================================

set -Eeuo pipefail

#-------------------------------------------------------------------------------
# Constants / defaults (overridable via flags or saved config)
#-------------------------------------------------------------------------------
INSTALLER_VERSION="2.0.0"
STATE_DIR="/var/lib/vicidial-installer"
CONF_FILE="${STATE_DIR}/install.conf"
LOG_FILE="/var/log/vicidial-install.log"
SRC_DIR="/usr/src"
SCRIPTS_DIR="/usr/src/vicidial-install-scripts"
REPO_URL="${REPO_URL:-https://github.com/samsepoil1211/Vicidial-scratch-install.git}"

# --- user-tunable defaults -----------------------------------------------------
VD_HOSTNAME=""                       # --hostname
VD_TIMEZONE="America/New_York"       # --timezone
AST_SERIES="16"                      # --asterisk 16|18
AST_VER_16="16.30.1-vici"
AST_VER_18="18.21.0-vici"
PHP_STREAM="7.4"                     # --php 7.4|8.2
MARIADB_STREAM="10.5"
DB_NAME="asterisk"
DB_CRON_USER="cron"
DB_CRON_PASS=""                      # generated unless --legacy-creds
DB_CUSTOM_USER="custom"
DB_CUSTOM_PASS=""
VD_ADMIN_PASS=""                     # new password for web admin '6666'
LEGACY_CREDS="no"                    # --legacy-creds  -> cron/1234 custom/custom1234
ALLOW_DB_REMOTE=""                   # --db-remote-subnet 10.0.0.%  (cluster use)
WITH_WEBPHONE="yes"                  # --no-webphone
WITH_DYNPORTAL="yes"                 # --no-dynportal
WITH_COCKPIT="no"                    # --with-cockpit
WITH_G729="no"                       # --with-g729
WITH_SNGREP="yes"                    # --no-sngrep
TMPFS_RECORDINGS="yes"               # --no-tmpfs  (2G tmpfs on monitor dir)
TMPFS_SIZE="2G"
SSL_DOMAIN=""                        # --domain dialer.example.com
SSL_EMAIL=""                         # --email you@example.com
CARRIER_IPS=""                       # --carrier-ips "1.2.3.4,5.6.7.8"
PERMIT_ROOT_SSH="no"                 # --permit-root-ssh
ASSUME_YES="no"                      # --yes
AUTO_RESUME="no"                     # --auto-resume (systemd unit after reboot)
SKIP_OS_UPDATE="no"                  # --skip-update (not recommended)

SERVER_IP=""
OS_ID="" ; OS_VER="" ; EL="" ; PRETTY_NAME=""

#-------------------------------------------------------------------------------
# Logging / UI helpers
#-------------------------------------------------------------------------------
C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_CYN=$'\e[36m'; C_RST=$'\e[0m'

log()   { printf '%s %s\n' "[$(date '+%F %T')]" "$*" >> "$LOG_FILE"; }
info()  { printf '%s[INFO]%s  %s\n' "$C_CYN" "$C_RST" "$*"; log "INFO  $*"; }
ok()    { printf '%s[ OK ]%s  %s\n' "$C_GRN" "$C_RST" "$*"; log "OK    $*"; }
warn()  { printf '%s[WARN]%s  %s\n' "$C_YLW" "$C_RST" "$*"; log "WARN  $*"; }
fail()  { printf '%s[FAIL]%s  %s\n' "$C_RED" "$C_RST" "$*"; log "FAIL  $*"; exit 1; }

on_error() {
    local lineno=$1 cmd=$2
    printf '%s[FAIL]%s Installer aborted at line %s: %s\n' "$C_RED" "$C_RST" "$lineno" "$cmd"
    printf '       Full log: %s\n' "$LOG_FILE"
    printf '       Fix the issue and re-run this script — it resumes automatically.\n'
    log "ERROR line $lineno: $cmd"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

confirm() {
    [[ "$ASSUME_YES" == "yes" ]] && return 0
    local reply
    read -r -p "$1 [y/N]: " reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

#-------------------------------------------------------------------------------
# Step framework — every step runs once; re-runs resume where they stopped
#-------------------------------------------------------------------------------
step_done()  { [[ -f "${STATE_DIR}/step.$1.done" ]]; }
mark_done()  { touch "${STATE_DIR}/step.$1.done"; ok "Step complete: $1"; }
run_step() {
    local name=$1; shift
    if step_done "$name"; then
        info "Skipping (already done): $name"
        return 0
    fi
    info "===== STEP: $name ====="
    "$@"
    mark_done "$name"
}

retry() {  # retry <tries> <sleep> <cmd...>
    local tries=$1 pause=$2 n=1; shift 2
    until "$@"; do
        (( n >= tries )) && return 1
        warn "Command failed (attempt $n/$tries), retrying in ${pause}s: $*"
        sleep "$pause"; n=$((n+1))
    done
}

pkg() {  # dnf install with retry, tolerant logging
    retry 3 10 dnf -y install "$@" >>"$LOG_FILE" 2>&1 \
        || fail "Package install failed: $* (see $LOG_FILE)"
}

pkg_soft() {  # dnf install with retry, but WARNS and continues instead of
              # aborting the script if some package names don't exist on
              # this EL release. Use for lists with known distro-specific gaps.
    retry 3 10 dnf -y install "$@" >>"$LOG_FILE" 2>&1 \
        || warn "Some packages unavailable/failed: $* (continuing — see $LOG_FILE)"
}

fetch() {  # fetch <url> <dest-file>
    retry 4 5 curl -fL --connect-timeout 20 -o "$2" "$1" >>"$LOG_FILE" 2>&1
}

gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true; }

#-------------------------------------------------------------------------------
# Argument parsing
#-------------------------------------------------------------------------------
usage() {
cat <<'EOF'
install-vicidial.sh — production VICIdial standalone installer (Alma/Rocky 8|9)

General:
  --yes                   Non-interactive; accept all confirmations
  --hostname NAME         Server hostname (FQDN recommended)
  --timezone TZ           System+PHP timezone (default America/New_York)
  --auto-resume           Install a systemd unit to auto-continue after reboot

Versions:
  --asterisk 16|18        Asterisk series: 16 -> 16.30.0-vici (default),
                                           18 -> 18.21.0-vici
  --php 7.4|8.2           PHP remi stream (default 7.4)

Credentials:
  --legacy-creds          Use classic cron/1234 + custom/custom1234 DB creds
                          (default: strong random passwords, saved to report)
  --admin-pass PASS       Set web admin user 6666 password (default: random)
  --db-remote-subnet S    Also grant DB access from subnet, e.g. '10.0.0.%'
                          (cluster installs; default: localhost only)

Components:
  --no-webphone           Skip CyburPhone WebRTC phone
  --no-dynportal          Skip dynamic firewall portal (dialer.one)
  --with-cockpit          Install Cockpit web console (port 9090)
  --with-g729             Install binary g729 codec (3rd-party .so)
  --no-sngrep             Skip sngrep SIP capture tool
  --no-tmpfs              Do not mount tmpfs on /var/spool/asterisk/monitor

SSL / network:
  --domain FQDN           Issue Let's Encrypt cert + enable WebRTC (wss:8089)
  --email ADDR            Email for Let's Encrypt registration
  --carrier-ips LIST      Comma-separated carrier IPs allowed to SIP (5060)
                          (if omitted, 5060/udp opens publicly with a warning)
  --permit-root-ssh       Set PermitRootLogin yes (default: leave sshd alone)

Misc:
  --skip-update           Skip 'dnf update' (not recommended)
  --reset                 Clear saved state and start over
  --help                  This help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes)              ASSUME_YES="yes";;
            --hostname)         VD_HOSTNAME="$2"; shift;;
            --timezone)         VD_TIMEZONE="$2"; shift;;
            --asterisk)         AST_SERIES="$2"; shift;;
            --php)              PHP_STREAM="$2"; shift;;
            --legacy-creds)     LEGACY_CREDS="yes";;
            --admin-pass)       VD_ADMIN_PASS="$2"; shift;;
            --db-remote-subnet) ALLOW_DB_REMOTE="$2"; shift;;
            --no-webphone)      WITH_WEBPHONE="no";;
            --no-dynportal)     WITH_DYNPORTAL="no";;
            --with-cockpit)     WITH_COCKPIT="yes";;
            --with-g729)        WITH_G729="yes";;
            --no-sngrep)        WITH_SNGREP="no";;
            --no-tmpfs)         TMPFS_RECORDINGS="no";;
            --domain)           SSL_DOMAIN="$2"; shift;;
            --email)            SSL_EMAIL="$2"; shift;;
            --carrier-ips)      CARRIER_IPS="$2"; shift;;
            --permit-root-ssh)  PERMIT_ROOT_SSH="yes";;
            --auto-resume)      AUTO_RESUME="yes";;
            --skip-update)      SKIP_OS_UPDATE="yes";;
            --reset)            rm -rf "$STATE_DIR"; echo "State cleared. Re-run the installer to start fresh."; exit 0;;
            --help|-h)          usage; exit 0;;
            *) fail "Unknown option: $1 (see --help)";;
        esac
        shift
    done
    [[ "$AST_SERIES" == "16" || "$AST_SERIES" == "18" ]] || fail "--asterisk must be 16 or 18"
    [[ "$PHP_STREAM" == "7.4" || "$PHP_STREAM" == "8.2" ]] || fail "--php must be 7.4 or 8.2"
}

save_config() {
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    cat > "$CONF_FILE" <<EOF
VD_HOSTNAME='$VD_HOSTNAME'
VD_TIMEZONE='$VD_TIMEZONE'
AST_SERIES='$AST_SERIES'
PHP_STREAM='$PHP_STREAM'
DB_CRON_PASS='$DB_CRON_PASS'
DB_CUSTOM_PASS='$DB_CUSTOM_PASS'
VD_ADMIN_PASS='$VD_ADMIN_PASS'
LEGACY_CREDS='$LEGACY_CREDS'
ALLOW_DB_REMOTE='$ALLOW_DB_REMOTE'
WITH_WEBPHONE='$WITH_WEBPHONE'
WITH_DYNPORTAL='$WITH_DYNPORTAL'
WITH_COCKPIT='$WITH_COCKPIT'
WITH_G729='$WITH_G729'
WITH_SNGREP='$WITH_SNGREP'
TMPFS_RECORDINGS='$TMPFS_RECORDINGS'
SSL_DOMAIN='$SSL_DOMAIN'
SSL_EMAIL='$SSL_EMAIL'
CARRIER_IPS='$CARRIER_IPS'
PERMIT_ROOT_SSH='$PERMIT_ROOT_SSH'
AUTO_RESUME='$AUTO_RESUME'
SKIP_OS_UPDATE='$SKIP_OS_UPDATE'
SERVER_IP='$SERVER_IP'
EOF
    chmod 600 "$CONF_FILE"
}

# shellcheck disable=SC1090
load_config() { [[ -f "$CONF_FILE" ]] && source "$CONF_FILE" || true; }

#-------------------------------------------------------------------------------
# STEP 00 — preflight
#-------------------------------------------------------------------------------
ast_version() { [[ "$AST_SERIES" == "16" ]] && echo "$AST_VER_16" || echo "$AST_VER_18"; }

detect_ip() {
    SERVER_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}')
    [[ -n "$SERVER_IP" ]] || fail "Could not determine primary IPv4 address"
}

# detect_os: sets PRETTY_NAME/OS_ID/OS_VER/EL. Called unconditionally at the
# top of main() — NOT inside a skippable step — so these vars are always
# populated in memory, even on a resumed run where step_preflight is skipped.
# (EL/SERVER_IP are also persisted in install.conf as a second safety net.)
detect_os() {
    [[ -f /etc/os-release ]] || fail "Cannot detect OS (/etc/os-release missing)"
    source /etc/os-release
    OS_ID="$ID"; OS_VER="${VERSION_ID%%.*}"
    case "$OS_ID" in
        almalinux|rocky|centos|rhel) : ;;
        *) fail "Unsupported OS '$PRETTY_NAME'. Supported: AlmaLinux/Rocky 8 or 9." ;;
    esac
    [[ "$OS_VER" == "8" || "$OS_VER" == "9" ]] || fail "Unsupported EL version $VERSION_ID (need 8 or 9)"
    EL="$OS_VER"
}

step_preflight() {
    [[ $EUID -eq 0 ]] || fail "Run as root."
    [[ "$(uname -m)" == "x86_64" ]] || fail "Only x86_64 is supported."

    info "Detected: $PRETTY_NAME (EL$EL)"

    # Resources
    local mem_mb disk_gb cpus
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    cpus=$(nproc)
    info "Resources: ${cpus} vCPU, ${mem_mb} MB RAM, ${disk_gb} GB free on /"
    (( mem_mb >= 3500 ))  || { warn "Less than 4 GB RAM — fine for lab, NOT for production dialing."; confirm "Continue anyway?" || exit 1; }
    (( disk_gb >= 20 ))   || fail "Need at least 20 GB free disk on /"

    # Connectivity
    retry 3 5 curl -fsI --connect-timeout 10 https://download.vicidial.com >/dev/null 2>&1 \
        || fail "Cannot reach download.vicidial.com — check DNS/network."
    retry 3 5 curl -fsI --connect-timeout 10 https://github.com >/dev/null 2>&1 \
        || fail "Cannot reach github.com"

    detect_ip
    info "Primary IP: $SERVER_IP"

    # Existing install guard
    if [[ -f /etc/astguiclient.conf && ! -f "${STATE_DIR}/step.preflight.done" ]]; then
        warn "/etc/astguiclient.conf already exists — this looks like a VICIdial server."
        confirm "Continue and OVERWRITE existing VICIdial configuration?" || exit 1
    fi
}

#-------------------------------------------------------------------------------
# STEP 01 — interactive config (only what's missing), then freeze config
#-------------------------------------------------------------------------------
step_configure() {
    if [[ -z "$VD_HOSTNAME" ]]; then
        if [[ "$ASSUME_YES" == "yes" ]]; then
            VD_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
        else
            read -r -p "Hostname for this server [$(hostname)]: " VD_HOSTNAME
            VD_HOSTNAME="${VD_HOSTNAME:-$(hostname)}"
        fi
    fi

    if [[ "$LEGACY_CREDS" == "yes" ]]; then
        DB_CRON_PASS="1234"; DB_CUSTOM_PASS="custom1234"
        warn "Legacy DB credentials selected (cron/1234). Acceptable only on firewalled fleets."
    else
        [[ -z "$DB_CRON_PASS"   ]] && DB_CRON_PASS=$(gen_pass)
        [[ -z "$DB_CUSTOM_PASS" ]] && DB_CUSTOM_PASS=$(gen_pass)
    fi
    [[ -z "$VD_ADMIN_PASS" ]] && VD_ADMIN_PASS=$(gen_pass | head -c 12 || true)

    save_config

    echo
    echo "=============================================================="
    echo "  VICIdial Production Installer v${INSTALLER_VERSION}"
    echo "=============================================================="
    echo "  OS              : $PRETTY_NAME"
    echo "  Hostname        : $VD_HOSTNAME"
    echo "  Server IP       : $SERVER_IP"
    echo "  Timezone        : $VD_TIMEZONE"
    echo "  Asterisk        : $(ast_version)"
    echo "  PHP             : $PHP_STREAM (remi)"
    echo "  MariaDB         : $MARIADB_STREAM"
    echo "  DB creds        : $([[ $LEGACY_CREDS == yes ]] && echo 'LEGACY (cron/1234)' || echo 'random (see report)')"
    echo "  WebPhone        : $WITH_WEBPHONE   DynPortal: $WITH_DYNPORTAL   Cockpit: $WITH_COCKPIT"
    echo "  SSL domain      : ${SSL_DOMAIN:-<none>}"
    echo "  tmpfs recordings: $TMPFS_RECORDINGS ($TMPFS_SIZE)"
    echo "  Log file        : $LOG_FILE"
    echo "=============================================================="
    confirm "Proceed with installation?" || exit 0
}

#-------------------------------------------------------------------------------
# STEP 02 — base system: locale, tz, hostname, SELinux, repos, update, kernel
#-------------------------------------------------------------------------------
step_system_prep() {
    pkg glibc-langpack-en
    localectl set-locale en_US.UTF-8 || true
    timedatectl set-timezone "$VD_TIMEZONE" || warn "Could not set timezone $VD_TIMEZONE"
    pkg chrony && systemctl enable --now chronyd >>"$LOG_FILE" 2>&1 || true
    hostnamectl set-hostname "$VD_HOSTNAME"
    grep -q " $VD_HOSTNAME" /etc/hosts || echo "$SERVER_IP $VD_HOSTNAME ${VD_HOSTNAME%%.*}" >> /etc/hosts

    # SELinux permissive now, disabled after reboot (VICIdial requirement)
    if [[ -f /etc/selinux/config ]]; then
        sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        setenforce 0 2>/dev/null || true
    fi

    # Repos — version-correct only
    pkg epel-release
    pkg "https://rpms.remirepo.net/enterprise/remi-release-${EL}.rpm" || true
    pkg dnf-plugins-core yum-utils
    if [[ "$EL" == "9" ]]; then
        dnf config-manager --set-enabled crb        >>"$LOG_FILE" 2>&1 || true
    else
        dnf config-manager --set-enabled powertools >>"$LOG_FILE" 2>&1 || true
    fi
    dnf module reset  php mariadb -y                    >>"$LOG_FILE" 2>&1 || true
    dnf module enable "php:remi-${PHP_STREAM}" -y       >>"$LOG_FILE" 2>&1
    dnf module enable "mariadb:${MARIADB_STREAM}" -y    >>"$LOG_FILE" 2>&1 || true

    if [[ "$SKIP_OS_UPDATE" != "yes" ]]; then
        info "Running full system update (this can take a while)..."
        retry 2 15 dnf -y update --exclude='kernel-debug*' >>"$LOG_FILE" 2>&1 \
            || fail "dnf update failed"
    fi
    pkg git tar curl wget rsync

    # kernel-devel/headers MUST match the running kernel for DAHDI
    pkg kernel-devel kernel-headers
}

# After system_prep: if running kernel != newest installed kernel, we must reboot
# before building DAHDI. The step framework resumes automatically on re-run.
reboot_checkpoint() {
    local newest running
    running=$(uname -r)
    newest=$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)
    if [[ -n "$newest" && "$running" != "$newest" ]]; then
        warn "Kernel updated: running=$running, installed=$newest"
        warn "A reboot is required before building DAHDI kernel modules."
        if [[ "$AUTO_RESUME" == "yes" ]]; then
            install_resume_unit
            info "Rebooting now; installation will resume automatically."
            sleep 3; reboot
        else
            echo
            echo "  >>> Please REBOOT now, then re-run this script."
            echo "  >>> It will resume exactly where it left off."
            echo
            exit 0
        fi
    fi
    # kernel-devel for the (now current) kernel
    dnf -y install "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" >>"$LOG_FILE" 2>&1 \
        || warn "Exact kernel-devel-$(uname -r) not found; generic kernel-devel will be used."
}

install_resume_unit() {
    local self; self=$(readlink -f "$0")
    cat > /etc/systemd/system/vicidial-installer-resume.service <<EOF
[Unit]
Description=Resume VICIdial installation after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $self --yes --auto-resume
ExecStartPost=/usr/bin/systemctl disable vicidial-installer-resume.service
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable vicidial-installer-resume.service >>"$LOG_FILE" 2>&1
}

#-------------------------------------------------------------------------------
# STEP 03 — packages
#-------------------------------------------------------------------------------
step_packages() {
    pkg "@Development Tools"

    # PHP + Apache
    pkg php php-cli php-devel php-gd php-curl php-mysqlnd php-ldap php-zip \
        php-fileinfo php-opcache php-mbstring php-imap php-odbc php-pear \
        php-xml php-process httpd mod_ssl
    # php-mcrypt exists only on 7.4
    [[ "$PHP_STREAM" == "7.4" ]] && dnf -y install php-mcrypt >>"$LOG_FILE" 2>&1 || true

    # Build deps + system tools
    pkg wget unzip make patch gcc gcc-c++ subversion gd-devel readline-devel \
        newt newt-devel libxml2 libxml2-devel kernel-devel sqlite-devel \
        libuuid-devel libedit-devel speex speex-devel sox sendmail \
        curl libcurl-devel ImageMagick perl-libwww-perl \
        elfutils-libelf-devel openssl-devel libsrtp libsrtp-devel \
        jansson-devel \
        nano screen htop iftop bind-utils pv python3-pip initscripts \
        chkconfig mariadb-devel cronie crontabs

    # mytop/atop are EPEL extras — non-fatal
    dnf -y install mytop atop >>"$LOG_FILE" 2>&1 || true

    # lame: EPEL first, source build as fallback
    if ! dnf -y install lame lame-devel >>"$LOG_FILE" 2>&1; then
        info "Building lame 3.100 from source..."
        cd "$SRC_DIR"
        fetch "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" lame-3.100.tar.gz \
            || fail "Cannot download lame"
        tar -zxf lame-3.100.tar.gz && cd lame-3.100
        ./configure >>"$LOG_FILE" 2>&1 && make -j"$(nproc)" >>"$LOG_FILE" 2>&1 && make install >>"$LOG_FILE" 2>&1
        ldconfig
    fi

    if [[ "$WITH_SNGREP" == "yes" ]]; then
        dnf -y copr enable irontec/sngrep >>"$LOG_FILE" 2>&1 || true
        dnf -y install sngrep >>"$LOG_FILE" 2>&1 || warn "sngrep not installed (copr unavailable)"
    fi

    pip3 install --quiet mysql-connector-python >>"$LOG_FILE" 2>&1 || true

    # Clone/refresh helper repo (extensions.conf, confbridge conf, cpanfile)
    if [[ -d "$SCRIPTS_DIR/.git" ]]; then
        git -C "$SCRIPTS_DIR" pull --ff-only >>"$LOG_FILE" 2>&1 || true
    else
        rm -rf "$SCRIPTS_DIR"
        retry 3 10 git clone --depth 1 "$REPO_URL" "$SCRIPTS_DIR" >>"$LOG_FILE" 2>&1 \
            || fail "Cannot clone $REPO_URL"
    fi
}

#-------------------------------------------------------------------------------
# STEP 04 — MariaDB install + tuned config
#-------------------------------------------------------------------------------
step_database() {
    pkg mariadb-server mariadb

    local mem_mb kb
    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if   (( mem_mb >= 15000 )); then kb="2048M"
    elif (( mem_mb >= 7500  )); then kb="1024M"
    else                             kb="512M"; fi

    [[ -f /etc/my.cnf && ! -f /etc/my.cnf.original ]] && cp /etc/my.cnf /etc/my.cnf.original
    cat > /etc/my.cnf <<MYSQLCONF
#
# MariaDB configuration for VICIdial — generated by install-vicidial.sh
#
[client]
port   = 3306
socket = /var/lib/mysql/mysql.sock

[mysqld]
datadir = /var/lib/mysql
socket  = /var/lib/mysql/mysql.sock
user    = mysql
bind-address = 127.0.0.1

ft_min_word_len     = 3
max_connections     = 800
max_allowed_packet  = 32M
skip-external-locking
sql_mode = "NO_ENGINE_SUBSTITUTION"

log-error = /var/log/mysqld/mysqld.log
long_query_time     = 1
#slow_query_log     = 1
#slow_query_log_file = /var/log/mysqld/slow-queries.log

# query cache helps VICIdial's repetitive reads (MariaDB still supports it)
query_cache_type = 1
query_cache_size = 64M

tmp_table_size      = 128M
max_heap_table_size = 128M
table_open_cache    = 2048

join_buffer_size        = 1M
key_buffer_size         = ${kb}
sort_buffer_size        = 6M
read_buffer_size        = 4M
read_rnd_buffer_size    = 16M
myisam_sort_buffer_size = 64M
thread_cache_size       = 16

innodb_buffer_pool_size = 256M

# If using replication, uncomment:
#log-bin = mysql-bin
#server-id = 1

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash
MYSQLCONF

    # Remote DB access only when explicitly requested (cluster)
    if [[ -n "$ALLOW_DB_REMOTE" ]]; then
        sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/my.cnf
        warn "MariaDB will listen on 0.0.0.0 (cluster mode) — firewall accordingly."
    fi

    mkdir -p /var/log/mysqld
    touch /var/log/mysqld/mysqld.log /var/log/mysqld/slow-queries.log
    chown -R mysql:mysql /var/log/mysqld

    systemctl enable mariadb httpd >>"$LOG_FILE" 2>&1
    systemctl restart mariadb || fail "MariaDB failed to start — check /var/log/mysqld/mysqld.log"
    systemctl restart httpd   || fail "Apache failed to start"

    # Harden: remove anon users/test db (fresh install: root auths via unix_socket)
    mysql -u root <<'HARDEN' 2>>"$LOG_FILE" || true
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
HARDEN
}

#-------------------------------------------------------------------------------
# STEP 05 — PHP config
#-------------------------------------------------------------------------------
step_php() {
    local ini="/etc/php.d/99-vicidial.ini"
    cat > "$ini" <<EOF
; VICIdial PHP overrides — generated by install-vicidial.sh
error_reporting = E_ALL & ~E_NOTICE & ~E_DEPRECATED
memory_limit = 448M
short_open_tag = On
max_execution_time = 3330
max_input_time = 3360
post_max_size = 448M
upload_max_filesize = 442M
default_socket_timeout = 3360
date.timezone = ${VD_TIMEZONE}
max_input_vars = 50000
EOF
    systemctl restart httpd
}

#-------------------------------------------------------------------------------
# STEP 06 — Perl modules
#-------------------------------------------------------------------------------
step_perl() {
    # NOTE: perl-IO-Scalar and perl-Term-ReadKey do not exist as RPMs on EL9
    # (confirmed via dnf "No match for argument") — they're installed via
    # cpm/cpanfile below instead. Using pkg_soft here too: if any *other*
    # package name ever goes missing on a future EL point release, we warn
    # and let cpm fill the gap rather than hard-aborting the whole install.
    pkg_soft perl-CPAN perl-YAML perl-CPAN-DistnameInfo perl-libwww-perl perl-DBI \
        perl-DBD-MySQL perl-GD perl-Env perl-Digest-MD5 perl-Digest-SHA \
        perl-Time-HiRes perl-Net-Server perl-Switch perl-Mail-Sendmail \
        perl-Unicode-Map perl-Jcode perl-Spreadsheet-WriteExcel \
        perl-OLE-Storage_Lite perl-Proc-ProcessTable \
        perl-Spreadsheet-ParseExcel perl-Curses perl-Getopt-Long-Descriptive \
        perl-Term-ANSIColor perl-Data-Dumper \
        perl-Term-ReadLine-Gnu perl-SelfLoader perl-open.noarch

    # cpm + cpanfile from the scripts repo
    cd "$SCRIPTS_DIR"
    retry 3 10 bash -c 'curl -fsSL https://raw.githubusercontent.com/skaji/cpm/main/cpm | perl - install -g App::cpm' \
        >>"$LOG_FILE" 2>&1 || fail "cpm bootstrap failed"
    retry 2 10 /usr/local/bin/cpm install -g >>"$LOG_FILE" 2>&1 \
        || warn "cpm reported failures — check $LOG_FILE; continuing"

    # asterisk-perl
    cd "$SRC_DIR"
    fetch "http://download.vicidial.com/required-apps/asterisk-perl-0.08.tar.gz" asterisk-perl-0.08.tar.gz \
        || fail "Cannot download asterisk-perl"
    tar xzf asterisk-perl-0.08.tar.gz
    cd asterisk-perl-0.08
    perl Makefile.PL >>"$LOG_FILE" 2>&1
    make all     >>"$LOG_FILE" 2>&1
    make install >>"$LOG_FILE" 2>&1
}

#-------------------------------------------------------------------------------
# STEP 07 — DAHDI (kernel-module build; requires matching kernel-devel)
#-------------------------------------------------------------------------------
step_dahdi() {
    local ddir="$SRC_DIR/dahdi-build"
    rm -rf "$ddir"; mkdir -p "$ddir"; cd "$ddir"

    # Primary: Sam's known-good EL9-kernel-patched DAHDI; fallback: official 3.4.0
    if fetch "https://cybur-dial.com/dahdi-9.5-fix.zip" dahdi.zip && unzip -q dahdi.zip; then
        info "Using patched DAHDI (dahdi-9.5-fix)"
    else
        warn "Patched DAHDI unavailable — falling back to official dahdi-linux-complete-3.4.0"
        fetch "https://downloads.asterisk.org/pub/telephony/dahdi-linux-complete/dahdi-linux-complete-3.4.0+3.4.0.tar.gz" dahdi.tgz \
            || fail "Cannot download DAHDI from any source"
        tar -zxf dahdi.tgz --strip-components=1
    fi

    # --- EL9 5.14.0-6xx+ kernel compatibility fixes for dahdi-9.5-fix.zip ---
    # Verified by an actual build on a live AlmaLinux 9.7/9.8 VM (kernel
    # 5.14.0-687.58.1.el9_8), iterating until `make` exited 0. Two distinct
    # problem classes:
    #
    # (1) Several legacy PCI/USB card drivers use a pre-5.x from_timer() call
    #     with a wrong/nonexistent struct member (wctc4xxp, wcte12xp) or are
    #     for hardware nobody runs on a cloud VM at all (wct4xxp, wctdm24xxp,
    #     wcaxx, wctdm, wcb4xxp, wct1xxp, wcte11xp, wcfxo, xpp/Astribank,
    #     opvxa1200, wcte13xp, wcte43x). These are excluded via Kbuild's own
    #     obj-$(DAHDI_BUILD_ALL)$(CONFIG_DAHDI_<NAME>) gates — commenting
    #     the line out is equivalent to never enabling that CONFIG symbol.
    #     wctc4xxp/wcte12xp additionally have no valid fallback inside their
    #     own source, so their directories are removed outright (deleting the
    #     dir without also disabling the Kbuild line leaves a dangling
    #     "No such file or directory" reference, confirmed by testing).
    #
    # (2) Core DAHDI itself (dahdi-sysfs.c, dahdi-sysfs-chan.c — NOT optional,
    #     always built) implements struct bus_type.match() callbacks against
    #     the pre-6.x signature "int (*)(struct device *, struct device_driver *)".
    #     EL9's current kernel backports the upstream change to
    #     "int (*)(struct device *, const struct device_driver *)", so these
    #     two functions need `const` added to compile. This is a 2-line fix
    #     to vendor source, not a drop/skip — there is no way to exclude core
    #     code and still have a working DAHDI.
    info "Applying EL9 kernel-compatibility fixes to DAHDI source (verified against this kernel's build)..."

    if [[ -d linux/drivers/dahdi/wctc4xxp ]]; then
        rm -rf linux/drivers/dahdi/wctc4xxp
    fi
    if [[ -d linux/drivers/dahdi/wcte12xp ]]; then
        rm -rf linux/drivers/dahdi/wcte12xp
    fi

    local kbuild="linux/drivers/dahdi/Kbuild"
    if [[ -f "$kbuild" ]]; then
        sed -i -E \
            -e '/CONFIG_DAHDI_WCTC4XXP/s/^/# excluded (EL9 incompat): /' \
            -e '/CONFIG_DAHDI_WCTE12XP/s/^/# excluded (EL9 incompat): /' \
            -e '/CONFIG_DAHDI_WCTE13XP/s/^/# excluded (EL9 incompat): /' \
            -e '/CONFIG_DAHDI_WCTE43X/s/^/# excluded (EL9 incompat): /' \
            -e '/CONFIG_DAHDI_WCT4XXP/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_WCTDM24XXP/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_WCAXX/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_WCTDM\)/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_WCB4XXP/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_WCT1XXP/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_WCTE11XP/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_WCFXO/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_XPP/s/^/# excluded (no cloud HW): /' \
            -e '/CONFIG_DAHDI_OPVXA1200/s/^/# excluded (no cloud HW): /' \
            "$kbuild" 2>>"$LOG_FILE" || warn "Kbuild edit had issues — see $LOG_FILE"
    else
        warn "linux/drivers/dahdi/Kbuild not found — card-driver exclusions skipped (official DAHDI fallback source may differ)"
    fi

    local sysfs1="linux/drivers/dahdi/dahdi-sysfs.c"
    local sysfs2="linux/drivers/dahdi/dahdi-sysfs-chan.c"
    [[ -f "$sysfs1" ]] && sed -i \
        's/static int span_match(struct device \*dev, struct device_driver \*driver)/static int span_match(struct device *dev, const struct device_driver *driver)/' \
        "$sysfs1"
    [[ -f "$sysfs2" ]] && sed -i \
        's/static int chan_match(struct device \*dev, struct device_driver \*driver)/static int chan_match(struct device *dev, const struct device_driver *driver)/' \
        "$sysfs2"

    make clean DAHDI_BUILD_ALL=m HOTPLUG_FIRMWARE=yes >>"$LOG_FILE" 2>&1 || true
    make -j"$(nproc)" DAHDI_BUILD_ALL=m HOTPLUG_FIRMWARE=yes >>"$LOG_FILE" 2>&1 \
        || fail "DAHDI build failed even after applying known EL9 fixes (not a kernel-devel mismatch — headers matched). See $LOG_FILE"
    make install        >>"$LOG_FILE" 2>&1
    make install-config >>"$LOG_FILE" 2>&1 || true
    if [[ -d tools ]]; then
        ( cd tools && make clean >>"$LOG_FILE" 2>&1 || true
          make >>"$LOG_FILE" 2>&1 && make install >>"$LOG_FILE" 2>&1 \
          && make install-config >>"$LOG_FILE" 2>&1 || true )
    fi

    [[ -f /etc/dahdi/system.conf ]] || cp /etc/dahdi/system.conf.sample /etc/dahdi/system.conf 2>/dev/null || true
    modprobe dahdi        || fail "modprobe dahdi failed"
    modprobe dahdi_dummy  2>/dev/null || true
    /usr/sbin/dahdi_cfg -v >>"$LOG_FILE" 2>&1 || true
    echo -e "dahdi\ndahdi_dummy" > /etc/modules-load.d/dahdi.conf
    ok "DAHDI modules loaded"
}

#-------------------------------------------------------------------------------
# STEP 08 — Asterisk
#-------------------------------------------------------------------------------
step_asterisk() {
    local ver tarball adir
    ver=$(ast_version)
    tarball="asterisk-${ver}.tar.gz"
    adir="$SRC_DIR/asterisk/asterisk-${ver}"

    mkdir -p "$SRC_DIR/asterisk"; cd "$SRC_DIR/asterisk"

    # VICIdial periodically bumps the -vici patch tag (e.g. 16.30.0 -> 16.30.1)
    # without notice, which 404s a hardcoded filename. If the exact configured
    # version isn't there, list the real directory and try the newest -vici
    # build matching the same major.minor series before giving up.
    if [[ ! -f "$tarball" ]] && ! fetch "https://download.vicidial.com/required-apps/${tarball}" "$tarball"; then
        warn "Asterisk $ver not found at the expected path — checking for a newer -vici patch build..."
        local major_minor="${ver%.*}"   # e.g. "16.30" from "16.30.0-vici"
        major_minor="${major_minor%-vici}"
        local found
        found=$(curl -fsL --connect-timeout 15 "https://download.vicidial.com/required-apps/" 2>>"$LOG_FILE" \
            | grep -oE "asterisk-${major_minor}\.[0-9]+-vici\.tar\.gz" | sort -V | tail -1)
        if [[ -n "$found" ]]; then
            warn "Found ${found} instead — using it (update AST_VER_${AST_SERIES} in the script to silence this check next time)."
            tarball="$found"
            ver="${found#asterisk-}"; ver="${ver%.tar.gz}"
            adir="$SRC_DIR/asterisk/asterisk-${ver}"
            fetch "https://download.vicidial.com/required-apps/${tarball}" "$tarball" \
                || fail "Found ${tarball} in listing but download still failed"
        else
            fail "Cannot download Asterisk $ver, and no matching ${major_minor}.x -vici build found either"
        fi
    fi
    tar -xzf "$tarball"
    cd "$adir" || fail "Asterisk source dir missing after extract"

    local jobs=$(( $(nproc) + $(nproc) / 2 ))
    info "Configuring Asterisk $ver ..."
    # NOTE: --with-jansson-bundled makes `make` fetch jansson's source live
    # from raw.githubusercontent.com during ./configure — a real install hit
    # a hard failure here when that specific endpoint was unreachable from
    # the VPS, even though the rest of the network (download.vicidial.com,
    # github.com clone, etc.) was fine. jansson-devel is a standard, always-
    # available EL8/9 RPM (installed in step_packages), so we link the system
    # copy instead and drop the live-download dependency entirely.
    # IMPORTANT: the correct flag is "--with-jansson=PATH", NOT a bare
    # "--with-jansson" — the bare form is not a recognized option at all
    # (confirmed via `./configure --help`) and silently falls through to the
    # same bundled/download behavior, masking the real fix. /usr is the
    # correct PATH since jansson-devel installs to the standard system
    # prefix (/usr/include/jansson.h, /usr/lib64/pkgconfig/jansson.pc),
    # confirmed by a live ./configure run completing successfully with it.
    # pjproject has no equivalent EL RPM, so it stays bundled (also a live
    # download from the same raw.githubusercontent.com host; a live test
    # showed this one succeeds reliably even when jansson's endpoint didn't,
    # so no fallback needed here, but step_asterisk's overall `fail` still
    # catches it if that ever changes).
    ./configure --libdir=/usr/lib64 --with-gsm=internal --enable-opus --enable-srtp \
        --with-ssl --enable-asteriskssl --with-pjproject-bundled --with-jansson=/usr \
        >>"$LOG_FILE" 2>&1 || fail "Asterisk ./configure failed — see $LOG_FILE"

    make menuselect/menuselect menuselect-tree menuselect.makeopts >>"$LOG_FILE" 2>&1
    menuselect/menuselect --enable app_meetme          menuselect.makeopts
    menuselect/menuselect --enable res_http_websocket  menuselect.makeopts
    menuselect/menuselect --enable res_srtp            menuselect.makeopts
    menuselect/menuselect --enable chan_sip            menuselect.makeopts 2>/dev/null || true

    info "Compiling Asterisk with -j${jobs} (grab a coffee)..."
    make -j"$jobs" all >>"$LOG_FILE" 2>&1 || fail "Asterisk build failed — see $LOG_FILE"
    make install       >>"$LOG_FILE" 2>&1
    make samples       >>"$LOG_FILE" 2>&1

    # chan_sip must load (VICIdial standard), problem timing modules must not
    sed -i 's|^noload = chan_sip.so|;noload = chan_sip.so|'   /etc/asterisk/modules.conf || true
    sed -i 's|^noload => chan_sip.so|;noload => chan_sip.so|' /etc/asterisk/modules.conf || true
    for m in res_timing_timerfd res_timing_kqueue res_timing_pthread; do
        grep -q "noload => ${m}.so" /etc/asterisk/modules.conf \
            || echo "noload => ${m}.so" >> /etc/asterisk/modules.conf
    done
    ldconfig
    ok "Asterisk $ver installed"
}

#-------------------------------------------------------------------------------
# STEP 09 — VICIdial (astguiclient) checkout + database + install.pl
#-------------------------------------------------------------------------------
step_vicidial_src() {
    mkdir -p "$SRC_DIR/astguiclient"
    cd "$SRC_DIR/astguiclient"
    if [[ ! -d trunk/.svn ]]; then
        retry 5 20 svn checkout svn://svn.eflo.net/agc_2-X/trunk trunk >>"$LOG_FILE" 2>&1 \
            || fail "SVN checkout of VICIdial trunk failed (svn.eflo.net unreachable?)"
    else
        svn update trunk >>"$LOG_FILE" 2>&1 || warn "svn update failed; using existing checkout"
    fi
}

step_vicidial_db() {
    local remote_grants=""
    if [[ -n "$ALLOW_DB_REMOTE" ]]; then
        remote_grants="
CREATE USER IF NOT EXISTS '${DB_CRON_USER}'@'${ALLOW_DB_REMOTE}' IDENTIFIED BY '${DB_CRON_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES,CREATE TEMPORARY TABLES ON ${DB_NAME}.* TO '${DB_CRON_USER}'@'${ALLOW_DB_REMOTE}';
GRANT RELOAD ON *.* TO '${DB_CRON_USER}'@'${ALLOW_DB_REMOTE}';
CREATE USER IF NOT EXISTS '${DB_CUSTOM_USER}'@'${ALLOW_DB_REMOTE}' IDENTIFIED BY '${DB_CUSTOM_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES,CREATE TEMPORARY TABLES ON ${DB_NAME}.* TO '${DB_CUSTOM_USER}'@'${ALLOW_DB_REMOTE}';"
    fi

    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_CRON_USER}'@'localhost' IDENTIFIED BY '${DB_CRON_PASS}';
ALTER USER '${DB_CRON_USER}'@'localhost' IDENTIFIED BY '${DB_CRON_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES,CREATE TEMPORARY TABLES ON ${DB_NAME}.* TO '${DB_CRON_USER}'@'localhost';
GRANT RELOAD ON *.* TO '${DB_CRON_USER}'@'localhost';
CREATE USER IF NOT EXISTS '${DB_CUSTOM_USER}'@'localhost' IDENTIFIED BY '${DB_CUSTOM_PASS}';
ALTER USER '${DB_CUSTOM_USER}'@'localhost' IDENTIFIED BY '${DB_CUSTOM_PASS}';
GRANT SELECT,CREATE,ALTER,INSERT,UPDATE,DELETE,LOCK TABLES,CREATE TEMPORARY TABLES ON ${DB_NAME}.* TO '${DB_CUSTOM_USER}'@'localhost';
${remote_grants}
FLUSH PRIVILEGES;
SQL

    # Load schema + first-server data only once
    if ! mysql -u root -e "SELECT 1 FROM ${DB_NAME}.servers LIMIT 1" >/dev/null 2>&1; then
        info "Loading VICIdial schema (this takes a few minutes)..."
        mysql -u root "${DB_NAME}" < "$SRC_DIR/astguiclient/trunk/extras/MySQL_AST_CREATE_tables.sql"
        mysql -u root "${DB_NAME}" < "$SRC_DIR/astguiclient/trunk/extras/first_server_install.sql"
    else
        warn "VICIdial schema already present — not reloading."
    fi
    mysql -u root -e "UPDATE ${DB_NAME}.servers SET asterisk_version='$(ast_version)';"
}

step_vicidial_conf() {
    cat > /etc/astguiclient.conf <<ASTGUI
# astguiclient.conf — generated by install-vicidial.sh v${INSTALLER_VERSION}

PATHhome => /usr/share/astguiclient
PATHlogs => /var/log/astguiclient
PATHagi => /var/lib/asterisk/agi-bin
PATHweb => /var/www/html
PATHsounds => /var/lib/asterisk/sounds
PATHmonitor => /var/spool/asterisk/monitor
PATHDONEmonitor => /var/spool/asterisk/monitorDONE

# The IP address of this machine
VARserver_ip => ${SERVER_IP}

# Database connection information
VARDB_server => localhost
VARDB_database => ${DB_NAME}
VARDB_user => ${DB_CRON_USER}
VARDB_pass => ${DB_CRON_PASS}
VARDB_custom_user => ${DB_CUSTOM_USER}
VARDB_custom_pass => ${DB_CUSTOM_PASS}
VARDB_port => 3306

# Alpha-Numeric list of the astGUIclient processes to be kept running
#  1-AST_update 2-AST_send_listen 3-AST_VDauto_dial 4-AST_VDremote_agents
#  5-AST_VDadapt 6-FastAGI_log 8-ip_relay 9-Timeclock E-Email C-...
VARactive_keepalives => 12345689EC

# Asterisk version VICIDIAL is installed for
VARasterisk_version => ${AST_SERIES}.X

# FTP recording archive connection information (local defaults; change if archiving off-box)
VARFTP_host => 127.0.0.1
VARFTP_user => cron
VARFTP_pass => CHANGE_ME
VARFTP_port => 21
VARFTP_dir => RECORDINGS
VARHTTP_path => http://${SERVER_IP}

# REPORT server connection information
VARREPORT_host => 127.0.0.1
VARREPORT_user => cron
VARREPORT_pass => CHANGE_ME
VARREPORT_port => 21
VARREPORT_dir => REPORTS

# FastAGI logging server
VARfastagi_log_min_servers => 3
VARfastagi_log_max_servers => 16
VARfastagi_log_min_spare_servers => 2
VARfastagi_log_max_spare_servers => 8
VARfastagi_log_max_requests => 1000
VARfastagi_log_checkfordead => 30
VARfastagi_log_checkforwait => 60

# Expected DB Schema version for this install
ExpectedDBSchema => 1720
ASTGUI
    # NOTE: VICIdial's own web UI (dbconnect_mysqli.php, running as the apache
    # user) reads this file directly to get its DB credentials — this is
    # standard, expected VICIdial behavior, not a workaround. 600/root-only
    # blocks Apache from reading it at all, which manifests as PHP silently
    # getting empty $VARDB_* values and mysqli_connect() falling back to an
    # anonymous/blank-password connection (confirmed by a live install).
    # 640 + group apache is the correct, minimum-necessary permission: root
    # can read/write, the apache group can read, nobody else can.
    chown root:apache /etc/astguiclient.conf
    chmod 640 /etc/astguiclient.conf

    cd "$SRC_DIR/astguiclient/trunk"
    info "Running VICIdial install.pl ..."
    perl install.pl --no-prompt --copy_sample_conf_files=Y >>"$LOG_FILE" 2>&1 \
        || fail "install.pl failed — see $LOG_FILE"

    # Secure AMI: bind to loopback only
    sed -i 's/0\.0\.0\.0/127.0.0.1/g' /etc/asterisk/manager.conf

    # confcron AMI user for confbridge tooling.
    # IMPORTANT: unlike every other astguiclient script (AST_update.pl,
    # AST_VDauto_dial.pl, etc.), which all read their AMI secret dynamically
    # from the `servers.ASTmgrSECRET` DB column, AST_conf_update_screen.pl's
    # confcron login ALSO reads $ASTmgrSECRET from that exact same column —
    # there is no separate DB field for it. install.pl already populates
    # ASTmgrSECRET to match cron/updatecron/listencron/sendcron/sipcron
    # (all "1234" by VICIdial convention, confirmed against a live install's
    # manager.conf + `servers` table). Giving confcron its own random secret
    # here breaks AST_conf_update_screen.pl silently (empty $ASTmgrSECRET at
    # runtime -> AMI login fails every run, confirmed in testing) since
    # nothing in VICIdial's own code looks for a second, confcron-specific
    # secret anywhere. So: match the existing ASTmgrSECRET value instead of
    # generating a new one, unless --legacy-creds is off, in which case we
    # still have to use whatever install.pl actually put in the DB for
    # ASTmgrSECRET (it is NOT one of our random DB_CRON_PASS/DB_CUSTOM_PASS
    # values — it's installed to the fixed default below by install.pl
    # regardless of --legacy-creds).
    local confcron_secret
    confcron_secret=$(mysql -u root -N -e \
        "SELECT ASTmgrSECRET FROM ${DB_NAME}.servers WHERE server_ip='${SERVER_IP}' LIMIT 1;" 2>>"$LOG_FILE")
    [[ -z "$confcron_secret" ]] && confcron_secret="1234"   # install.pl's own default if the query somehow comes back empty
    if ! grep -q '^\[confcron\]' /etc/asterisk/manager.conf; then
        cat >> /etc/asterisk/manager.conf <<EOF

[confcron]
secret = ${confcron_secret}
read = command,reporting
write = command,reporting
eventfilter=Event: Meetme
eventfilter=Event: Confbridge
EOF
    else
        sed -i "/^\[confcron\]/,/^\[/ s/^secret = .*/secret = ${confcron_secret}/" /etc/asterisk/manager.conf
    fi
    echo "CONFCRON_SECRET='${confcron_secret}'" >> "$CONF_FILE"

    # ConfBridge dialplan + conf from scripts repo
    if [[ -f "$SCRIPTS_DIR/extensions.conf" ]]; then
        cp -f "$SCRIPTS_DIR/extensions.conf" /etc/asterisk/extensions.conf
    fi
    if [[ -f "$SCRIPTS_DIR/confbridge-vicidial.conf" ]]; then
        cp -f "$SCRIPTS_DIR/confbridge-vicidial.conf" /etc/asterisk/
        grep -q 'confbridge-vicidial.conf' /etc/asterisk/confbridge.conf 2>/dev/null \
            || echo -e "\n#include confbridge-vicidial.conf" >> /etc/asterisk/confbridge.conf
    fi

    # ConfBridge rooms 9600000-9600299 for THIS server IP (idempotent)
    local sql="INSERT IGNORE INTO vicidial_confbridges VALUES "
    local i
    for i in $(seq 9600000 9600299); do sql+="(${i},'${SERVER_IP}','','0',NULL),"; done
    mysql -u root -e "USE ${DB_NAME}; ${sql%,};"

    info "Populating area codes..."
    /usr/share/astguiclient/ADMIN_area_code_populate.pl >>"$LOG_FILE" 2>&1 || true

    info "Rewriting default IP 10.10.10.15 -> ${SERVER_IP} ..."
    /usr/share/astguiclient/ADMIN_update_server_ip.pl \
        --old-server_ip=10.10.10.15 --server_ip="${SERVER_IP}" --auto >>"$LOG_FILE" 2>&1 || true

    # Second pass of install.pl per upstream procedure
    perl install.pl --no-prompt >>"$LOG_FILE" 2>&1 || true

    # Set admin 6666 password + sane system settings
    mysql -u root -e "USE ${DB_NAME};
        UPDATE vicidial_users SET pass='${VD_ADMIN_PASS}' WHERE user='6666';
        UPDATE system_settings SET active_voicemail_server='${SERVER_IP}', sounds_web_server='http://${SERVER_IP}';" \
        || warn "Could not set admin password automatically"
}

#-------------------------------------------------------------------------------
# STEP 10 — ip_relay build
#-------------------------------------------------------------------------------
step_ip_relay() {
    cd "$SRC_DIR/astguiclient/trunk/extras/ip_relay/"
    unzip -o ip_relay_1.1.112705.zip >>"$LOG_FILE" 2>&1
    cd ip_relay_1.1/src/unix/
    make >>"$LOG_FILE" 2>&1 || { warn "ip_relay build failed (non-fatal)"; return 0; }
    install -m 755 ip_relay /usr/bin/ip_relay
    install -m 755 ip_relay /usr/local/bin/ip_relay
}

#-------------------------------------------------------------------------------
# STEP 11 — Sounds / MOH
#-------------------------------------------------------------------------------
step_sounds() {
    cd "$SRC_DIR"
    local f base="http://downloads.asterisk.org/pub/telephony/sounds"
    for f in asterisk-core-sounds-en-ulaw-current asterisk-core-sounds-en-wav-current \
             asterisk-core-sounds-en-gsm-current asterisk-extra-sounds-en-ulaw-current \
             asterisk-extra-sounds-en-wav-current asterisk-extra-sounds-en-gsm-current \
             asterisk-moh-opsound-gsm-current asterisk-moh-opsound-ulaw-current \
             asterisk-moh-opsound-wav-current; do
        [[ -f "$f.tar.gz" ]] || fetch "$base/$f.tar.gz" "$f.tar.gz" || fail "Cannot download $f"
    done

    mkdir -p /var/lib/asterisk/sounds /var/lib/asterisk/mohmp3 /var/lib/asterisk/quiet-mp3
    cd /var/lib/asterisk/sounds
    for f in core-sounds-en-gsm core-sounds-en-ulaw core-sounds-en-wav \
             extra-sounds-en-gsm extra-sounds-en-ulaw extra-sounds-en-wav; do
        tar -zxf "$SRC_DIR/asterisk-$f-current.tar.gz"
    done
    [[ -e /var/lib/asterisk/default ]] || ln -s /var/lib/asterisk/mohmp3 /var/lib/asterisk/default
    cd /var/lib/asterisk/mohmp3
    for f in moh-opsound-gsm moh-opsound-ulaw moh-opsound-wav; do
        tar -zxf "$SRC_DIR/asterisk-$f-current.tar.gz"
    done
    rm -f /var/lib/asterisk/{mohmp3,moh,sounds}/{CHANGES,LICENSE,CREDITS}* 2>/dev/null || true

    # quiet-mp3 (25% volume) versions used by VICIdial agent screen
    cd /var/lib/asterisk/quiet-mp3
    local s
    for s in macroform-cold_day macroform-robot_dity macroform-the_simplicity \
             reno_project-system manolo_camp-morning_coffee; do
        sox "../mohmp3/${s}.wav" "${s}.wav" vol 0.25 2>>"$LOG_FILE" || true
        sox "../mohmp3/${s}.gsm" "${s}.gsm" vol 0.25 2>>"$LOG_FILE" || true
        sox -t ul -r 8000 -c 1 "../mohmp3/${s}.ulaw" -t ul "${s}.ulaw" vol 0.25 2>>"$LOG_FILE" || true
    done
}

#-------------------------------------------------------------------------------
# STEP 12 — system integration: crontab, boot service, apache, perms, tmpfs
#-------------------------------------------------------------------------------
step_integration() {
    # ---- root crontab (written fresh — idempotent, never duplicated) ----
    cat > /root/vicidial-crontab <<'CRONTAB'
### VICIdial crontab — managed by install-vicidial.sh
### Daily DB backup
0 2 * * * /usr/share/astguiclient/ADMIN_backup.pl

### recording mixing/compressing scripts
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_mix.pl --MIX
0,3,6,9,12,15,18,21,24,27,30,33,36,39,42,45,48,51,54,57 * * * * /usr/share/astguiclient/AST_CRON_audio_1_move_VDonly.pl
1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46,49,52,55,58 * * * * /usr/share/astguiclient/AST_CRON_audio_2_compress.pl --MP3 --HTTPS
#2,5,8,...  * * * * /usr/share/astguiclient/AST_CRON_audio_3_ftp.pl --MP3

### keepalive for astguiclient processes
* * * * * /usr/share/astguiclient/ADMIN_keepalive_ALL.pl

### kill hung Asterisk updaters
* * * * * /usr/share/astguiclient/AST_manager_kill_hung_congested.pl

### voicemail updater
* * * * * /usr/share/astguiclient/AST_vm_update.pl

### flush queue DB table hourly
11 * * * * /usr/share/astguiclient/AST_flush_DBqueue.pl -q

### fix vicidial_agent_log hourly + nightly full
33 * * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl
50 0 * * * /usr/share/astguiclient/AST_cleanup_agent_log.pl --last-24hours

### VICIDIAL hopper
* * * * * /usr/share/astguiclient/AST_VDhopper.pl -q

### GMT offset adjust
1 1,7 * * * /usr/share/astguiclient/ADMIN_adjust_GMTnow_on_leads.pl --debug

### reset temp tables / optimize DB nightly
2 1 * * * /usr/share/astguiclient/AST_reset_mysql_vars.pl
3 1 * * * /usr/share/astguiclient/AST_DB_optimize.pl

### agent time log summaries
2 0 * * 0 /usr/share/astguiclient/AST_agent_week.pl
22 0 * * * /usr/share/astguiclient/AST_agent_day.pl

### remove old ORIG recordings (adjust retention to taste)
24 1 * * * /usr/bin/find /var/spool/asterisk/monitorDONE/ORIG -maxdepth 2 -type f -mtime +1 -print | xargs rm -f

### roll logs monthly
30 1 1 * * /usr/share/astguiclient/ADMIN_archive_log_tables.pl --days=90

### remove old vicidial/asterisk logs
28 0 * * * /usr/bin/find /var/log/astguiclient -maxdepth 1 -type f -mtime +2 -print | xargs rm -f
29 0 * * * /usr/bin/find /var/log/asterisk -maxdepth 3 -type f -mtime +2 -print | xargs rm -f
30 0 * * * /usr/bin/find / -maxdepth 1 -name "screenlog.0*" -mtime +4 -print | xargs rm -f

### dead callback purge
25 0 * * * /usr/share/astguiclient/AST_DB_dead_cb_purge.pl --purge-non-cb -q

### dialer inventory snapshot
1 7 * * * /usr/share/astguiclient/AST_dialer_inventory_snapshot.pl -q --override-24hours

### inbound email parser
* * * * * /usr/share/astguiclient/AST_inbound_email_parser.pl
CRONTAB

    if [[ "$WITH_DYNPORTAL" == "yes" ]]; then
        cat >> /root/vicidial-crontab <<'CRONTAB'

### DynPortal dynamic firewall whitelist
@reboot /usr/bin/VB-firewall --whitelist=ViciWhite --dynamic --quiet
* * * * * /usr/bin/VB-firewall --whitelist=ViciWhite --dynamic --quiet
* * * * * sleep 10; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 20; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 30; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 40; /usr/bin/VB-firewall --white --dynamic --quiet
* * * * * sleep 50; /usr/bin/VB-firewall --white --dynamic --quiet
CRONTAB
    fi
    if [[ -n "$SSL_DOMAIN" ]]; then
        echo '@monthly /usr/local/sbin/vicidial-certbot-renew.sh' >> /root/vicidial-crontab
    fi
    crontab /root/vicidial-crontab
    systemctl enable --now crond >>"$LOG_FILE" 2>&1 || true

    # ---- boot service (replaces fragile rc.local chain) ----
    cat > /usr/local/sbin/vicidial-boot.sh <<'BOOT'
#!/usr/bin/env bash
# VICIdial boot sequence — managed by install-vicidial.sh
/usr/share/astguiclient/ip_relay/relay_control start 2>/dev/null 1>&2 || true
/usr/bin/setterm -blank 0 -powersave off 2>/dev/null || true
systemctl start mariadb.service
systemctl start httpd.service
/usr/share/astguiclient/ADMIN_restart_roll_logs.pl
/usr/share/astguiclient/AST_reset_mysql_vars.pl
modprobe dahdi 2>/dev/null
modprobe dahdi_dummy 2>/dev/null
/usr/sbin/dahdi_cfg -v 2>/dev/null
sleep 20
/usr/share/astguiclient/start_asterisk_boot.pl
exit 0
BOOT
    chmod 755 /usr/local/sbin/vicidial-boot.sh

    cat > /etc/systemd/system/vicidial-boot.service <<'UNIT'
[Unit]
Description=VICIdial boot sequence (dahdi, asterisk, keepalives)
After=network-online.target mariadb.service httpd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vicidial-boot.sh
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable vicidial-boot.service >>"$LOG_FILE" 2>&1
    # Asterisk is managed by VICIdial screens, never by its own unit
    systemctl disable asterisk.service >>"$LOG_FILE" 2>&1 || true

    # ---- Apache: recordings alias + welcome redirect ----
    cat > /etc/httpd/conf.d/vicidial-recordings.conf <<'HTTPD'
Alias /RECORDINGS/MP3 "/var/spool/asterisk/monitorDONE/MP3/"
<Directory "/var/spool/asterisk/monitorDONE/MP3/">
    Options Indexes MultiViews
    AllowOverride None
    Require all granted
</Directory>
HTTPD
    if [[ ! -f /var/www/html/index.html ]] || ! grep -q vicidial /var/www/html/index.html; then
        cat > /var/www/html/index.html <<'WELCOME'
<META HTTP-EQUIV=REFRESH CONTENT="1; URL=/vicidial/welcome.php">
Please hold while I redirect you!
WELCOME
    fi

    # ---- permissions: no chmod 777 ----
    mkdir -p /var/spool/asterisk/monitor /var/spool/asterisk/monitorDONE/{MP3,GSM,WAV,ORIG,FTP}
    chown -R asterisk:apache /var/spool/asterisk 2>/dev/null \
        || chown -R root:apache /var/spool/asterisk
    chmod -R 775 /var/spool/asterisk

    # ---- tmpfs on live monitor dir (performance; recordings move out every 3 min) ----
    if [[ "$TMPFS_RECORDINGS" == "yes" ]]; then
        grep -q '/var/spool/asterisk/monitor ' /etc/fstab || \
            echo "tmpfs /var/spool/asterisk/monitor tmpfs nodev,nosuid,noexec,nodiratime,size=${TMPFS_SIZE} 0 0" >> /etc/fstab
        mountpoint -q /var/spool/asterisk/monitor || mount /var/spool/asterisk/monitor || true
    fi

    # ---- SSH ----
    if [[ "$PERMIT_ROOT_SSH" == "yes" ]]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        systemctl reload sshd || true
    fi
    if ! grep -q 'sshd_banner' /etc/ssh/sshd_config; then
        cat > /etc/ssh/sshd_banner <<EOF
=====================================================================
 VICIdial Production Server — installed with vicidial-scratch-install
 Debjit Pal — Systems & VoIP Infrastructure Engineer
=====================================================================
EOF
        sed -i 's|^#Banner none|Banner /etc/ssh/sshd_banner|' /etc/ssh/sshd_config
        systemctl reload sshd || true
    fi

    # Remove debug kernels if any slipped in
    dnf -y remove 'kernel-debug*' >>"$LOG_FILE" 2>&1 || true
}

#-------------------------------------------------------------------------------
# STEP 13 — optional components
#-------------------------------------------------------------------------------
step_webphone() {
    [[ "$WITH_WEBPHONE" == "yes" ]] || { info "WebPhone skipped."; return 0; }
    cd /var/www/html
    [[ -d CyburPhone ]] || retry 3 10 git clone --depth 1 https://github.com/carpenox/CyburPhone.git >>"$LOG_FILE" 2>&1 \
        || { warn "CyburPhone clone failed — skipping webphone"; return 0; }
    chmod -R 755 CyburPhone
    chown -R apache:apache CyburPhone
}

step_dynportal() {
    [[ "$WITH_DYNPORTAL" == "yes" ]] || { info "DynPortal skipped."; return 0; }
    pkg firewalld
    local t=/tmp/dynportal.$$; mkdir -p "$t"
    if ! fetch "https://dialer.one/dynportal.zip" "$t/dynportal.zip" \
       || ! fetch "https://dialer.one/firewall.zip" "$t/firewall.zip" \
       || ! fetch "https://dialer.one/aggregate"    "$t/aggregate" \
       || ! fetch "https://dialer.one/VB-firewall"  "$t/VB-firewall"; then
        warn "dialer.one downloads failed — DynPortal skipped. Re-run later or host mirrors."
        return 0
    fi
    mkdir -p /var/www/vhosts/dynportal
    unzip -o "$t/dynportal.zip" -d /var/www/vhosts/dynportal >>"$LOG_FILE" 2>&1
    chmod -R 755 /var/www/vhosts/dynportal
    chown -R apache:apache /var/www/vhosts/dynportal
    [[ -f /var/www/vhosts/dynportal/etc/httpd/conf.d/viciportal.conf ]] && \
        mv -f /var/www/vhosts/dynportal/etc/httpd/conf.d/viciportal.conf /etc/httpd/conf.d/
    unzip -o "$t/firewall.zip" -d /etc/firewalld >>"$LOG_FILE" 2>&1
    if [[ -f /etc/firewalld/public.xml ]]; then
        mv -bf /etc/firewalld/public.xml /etc/firewalld/trusted.xml /etc/firewalld/zones/ 2>/dev/null || true
    fi
    install -m 755 "$t/aggregate"   /usr/bin/aggregate
    install -m 755 "$t/VB-firewall" /usr/bin/VB-firewall
    rm -rf "$t"
    firewall-offline-cmd --add-port=446/tcp --zone=public >>"$LOG_FILE" 2>&1 || true
}

step_g729() {
    [[ "$WITH_G729" == "yes" ]] || return 0
    cd /usr/lib64/asterisk/modules
    if fetch "http://asterisk.hosting.lv/bin/codec_g729-ast160-gcc4-glibc-x86_64-core2-sse4.so" codec_g729.so; then
        chmod 755 codec_g729.so
        ok "g729 codec installed"
    else
        warn "g729 download failed — skipped"
    fi
}

step_cockpit() {
    [[ "$WITH_COCKPIT" == "yes" ]] || return 0
    pkg cockpit cockpit-storaged
    dnf -y install cockpit-navigator >>"$LOG_FILE" 2>&1 || true
    sed -i 's/^root$/#root/' /etc/cockpit/disallowed-users 2>/dev/null || true
    systemctl enable --now cockpit.socket >>"$LOG_FILE" 2>&1
}

#-------------------------------------------------------------------------------
# STEP 14 — SSL + WebRTC (only with --domain)
#-------------------------------------------------------------------------------
step_ssl_webrtc() {
    # If no --domain was given on this run, this step is marked "done" like
    # any other skipped step, even though no SSL was actually configured.
    # To add SSL/WebRTC later: delete the step marker and re-run with
    # --domain (see README "Adding SSL after the fact" for the exact
    # commands) — this is a manual, deliberate action, not automatic.
    [[ -n "$SSL_DOMAIN" ]] || { info "No --domain given — skipping SSL/WebRTC (HTTP only)."; return 0; }
    pkg certbot python3-certbot-apache

    cat > "/etc/httpd/conf.d/${SSL_DOMAIN}.conf" <<EOF
<VirtualHost *:80>
    ServerAdmin admin@${SSL_DOMAIN}
    DocumentRoot "/var/www/html"
    DirectoryIndex index.html
    ServerName ${SSL_DOMAIN}
    ErrorLog "/var/log/httpd/${SSL_DOMAIN}.error_log"
    CustomLog "/var/log/httpd/${SSL_DOMAIN}.access_log" common
</VirtualHost>
EOF
    systemctl reload httpd

    # Port 80 must be reachable for http-01
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --add-service=http --zone=public >>"$LOG_FILE" 2>&1 || true
        firewall-cmd --add-service=https --zone=public >>"$LOG_FILE" 2>&1 || true
    fi

    local email_arg=(--register-unsafely-without-email)
    [[ -n "$SSL_EMAIL" ]] && email_arg=(-m "$SSL_EMAIL")
    if ! certbot --apache -n --agree-tos "${email_arg[@]}" -d "$SSL_DOMAIN" >>"$LOG_FILE" 2>&1; then
        warn "certbot failed for $SSL_DOMAIN — check DNS A record points to $SERVER_IP."
        warn "WebRTC/SSL skipped; re-run the script after fixing DNS."
        return 0
    fi
    ok "Let's Encrypt certificate issued for $SSL_DOMAIN"

    # Asterisk http.conf for WSS
    cat > /etc/asterisk/http.conf <<EOF
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
enablestatic=yes
tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=/etc/letsencrypt/live/${SSL_DOMAIN}/fullchain.pem
tlsprivatekey=/etc/letsencrypt/live/${SSL_DOMAIN}/privkey.pem
EOF

    # sip.conf WebRTC general section from repo template
    if [[ -f "$SCRIPTS_DIR/asterisk-sip.conf" ]]; then
        sed "s/DOMAINNAME/${SSL_DOMAIN}/g" "$SCRIPTS_DIR/asterisk-sip.conf" > /etc/asterisk/sip.conf
    fi

    # DB: web socket / webphone / sounds URLs + SIP_generic WebRTC template
    mysql -u root -e "USE ${DB_NAME};
        UPDATE servers SET web_socket_url='wss://${SSL_DOMAIN}:8089/ws';
        UPDATE system_settings SET sounds_web_server='https://${SSL_DOMAIN}';"
    if [[ "$WITH_WEBPHONE" == "yes" ]]; then
        mysql -u root -e "USE ${DB_NAME};
            UPDATE system_settings SET webphone_url='https://${SSL_DOMAIN}/CyburPhone/cyburphone.php';
            ALTER TABLE phones MODIFY COLUMN is_webphone ENUM('Y','N','Y_API_LAUNCH') DEFAULT 'Y';"
    fi
    mysql -u root -e "USE ${DB_NAME}; UPDATE vicidial_conf_templates SET template_contents='type=friend
host=dynamic
context=default
trustrpid=yes
sendrpid=no
qualify=yes
qualifyfreq=600
transport=ws,wss,udp
encryption=yes
avpf=yes
icesupport=yes
rtcp_mux=yes
directmedia=no
disallow=all
allow=ulaw,opus
nat=force_rport,comedia
dtlsenable=yes
dtlsverify=no
dtlscertfile=/etc/letsencrypt/live/${SSL_DOMAIN}/cert.pem
dtlsprivatekey=/etc/letsencrypt/live/${SSL_DOMAIN}/privkey.pem
dtlssetup=actpass' WHERE template_id='SIP_generic';" || true

    # DynPortal SSL vhost on 446
    if [[ "$WITH_DYNPORTAL" == "yes" && -d /var/www/vhosts/dynportal ]]; then
        sed "s/DOMAINNAME/${SSL_DOMAIN}/g" "$SCRIPTS_DIR/viciportal-ssl.conf" > /etc/httpd/conf.d/viciportal-ssl.conf 2>/dev/null || true
        [[ -f /var/www/vhosts/dynportal/inc/defaults.inc.php ]] && \
            sed -i "s/DOMAINNAME/${SSL_DOMAIN}/g" /var/www/vhosts/dynportal/inc/defaults.inc.php
    fi

    # Cockpit cert
    if [[ "$WITH_COCKPIT" == "yes" ]]; then
        mkdir -p /etc/cockpit/ws-certs.d
        cp "/etc/letsencrypt/live/${SSL_DOMAIN}/fullchain.pem" "/etc/cockpit/ws-certs.d/${SSL_DOMAIN}.cert"
        cp "/etc/letsencrypt/live/${SSL_DOMAIN}/privkey.pem"   "/etc/cockpit/ws-certs.d/${SSL_DOMAIN}.key"
        systemctl restart cockpit.socket || true
    fi

    # Renewal helper (firewall-aware, replaces old certbot.sh)
    cat > /usr/local/sbin/vicidial-certbot-renew.sh <<'RENEW'
#!/usr/bin/env bash
# Open 80 to Let's Encrypt, renew, close again — managed by install-vicidial.sh
set -u
systemctl is-active --quiet firewalld && firewall-cmd --add-service=http --zone=public >/dev/null 2>&1
certbot renew --quiet
systemctl is-active --quiet firewalld && firewall-cmd --remove-service=http --zone=public >/dev/null 2>&1
systemctl reload httpd 2>/dev/null
RENEW
    chmod 755 /usr/local/sbin/vicidial-certbot-renew.sh
    systemctl enable --now certbot-renew.timer >>"$LOG_FILE" 2>&1 || true

    systemctl reload httpd || true
}

#-------------------------------------------------------------------------------
# STEP 15 — firewall
#-------------------------------------------------------------------------------
step_firewall() {
    pkg firewalld
    systemctl enable --now firewalld >>"$LOG_FILE" 2>&1

    # Web admin + agent
    firewall-cmd --permanent --add-service=https            >>"$LOG_FILE" 2>&1 || true
    firewall-cmd --permanent --add-service=http             >>"$LOG_FILE" 2>&1 || true
    # RTP
    firewall-cmd --permanent --add-port=10000-20000/udp     >>"$LOG_FILE" 2>&1 || true
    # WebRTC WSS
    [[ -n "$SSL_DOMAIN" ]] && firewall-cmd --permanent --add-port=8089/tcp >>"$LOG_FILE" 2>&1 || true
    # Cockpit
    [[ "$WITH_COCKPIT" == "yes" ]] && firewall-cmd --permanent --add-port=9090/tcp >>"$LOG_FILE" 2>&1 || true
    # DynPortal
    [[ "$WITH_DYNPORTAL" == "yes" ]] && firewall-cmd --permanent --add-port=446/tcp >>"$LOG_FILE" 2>&1 || true

    # SIP: restrict to carriers if provided
    if [[ -n "$CARRIER_IPS" ]]; then
        local ip
        IFS=',' read -ra ips <<< "$CARRIER_IPS"
        for ip in "${ips[@]}"; do
            ip=$(echo "$ip" | xargs)
            firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${ip}' port port='5060' protocol='udp' accept" >>"$LOG_FILE" 2>&1 || true
            firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${ip}' port port='5060' protocol='tcp' accept" >>"$LOG_FILE" 2>&1 || true
        done
        ok "SIP 5060 restricted to: $CARRIER_IPS"
    else
        firewall-cmd --permanent --add-port=5060/udp >>"$LOG_FILE" 2>&1 || true
        warn "SIP 5060/udp is OPEN TO THE WORLD. Expect scanners."
        warn "Re-run with --carrier-ips '1.2.3.4,5.6.7.8' or lock it down manually ASAP."
    fi

    firewall-cmd --reload >>"$LOG_FILE" 2>&1 || true
}

#-------------------------------------------------------------------------------
# STEP 16 — verification + report
#-------------------------------------------------------------------------------
step_verify() {
    local problems=0

    systemctl is-active --quiet mariadb && ok "MariaDB running" || { warn "MariaDB NOT running"; problems=$((problems+1)); }
    systemctl is-active --quiet httpd   && ok "Apache running"  || { warn "Apache NOT running"; problems=$((problems+1)); }

    local tables
    tables=$(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo 0)
    (( tables > 100 )) && ok "VICIdial schema present ($tables tables)" \
        || { warn "Schema looks incomplete ($tables tables)"; problems=$((problems+1)); }

    mysql -u "$DB_CRON_USER" -p"$DB_CRON_PASS" -e "SELECT 1" "$DB_NAME" >/dev/null 2>&1 \
        && ok "DB user '$DB_CRON_USER' can connect" \
        || { warn "DB user '$DB_CRON_USER' cannot connect"; problems=$((problems+1)); }

    [[ -x /usr/sbin/asterisk ]] && ok "Asterisk binary: $(/usr/sbin/asterisk -V 2>/dev/null)" \
        || { warn "Asterisk binary missing"; problems=$((problems+1)); }

    lsmod | grep -q '^dahdi' && ok "DAHDI module loaded" \
        || { warn "DAHDI module not loaded"; problems=$((problems+1)); }

    curl -fs "http://127.0.0.1/vicidial/admin.php" -o /dev/null 2>>"$LOG_FILE" \
        && ok "VICIdial web UI responds" \
        || warn "Web UI check inconclusive (may need reboot first)"

    # ---- credentials / summary report ----
    local report="/root/vicidial-install-report.txt"
    cat > "$report" <<EOF
==================================================================
 VICIdial Installation Report — $(date '+%F %T')
 Installer v${INSTALLER_VERSION} | $PRETTY_NAME | Asterisk $(ast_version)
==================================================================

 Server IP       : ${SERVER_IP}
 Hostname        : ${VD_HOSTNAME}
 Timezone        : ${VD_TIMEZONE}

 WEB ADMIN
   URL           : http://${SERVER_IP}/vicidial/admin.php
$( [[ -n "$SSL_DOMAIN" ]] && echo "   SSL URL       : https://${SSL_DOMAIN}/vicidial/admin.php" )
   User          : 6666
   Password      : ${VD_ADMIN_PASS}

 AGENT SCREEN    : http://${SERVER_IP}/agc/vicidial.php

 DATABASE (${DB_NAME})
   ${DB_CRON_USER} / ${DB_CRON_PASS}
   ${DB_CUSTOM_USER} / ${DB_CUSTOM_PASS}
   Remote access : ${ALLOW_DB_REMOTE:-localhost only}

 COMPONENTS
   WebPhone      : ${WITH_WEBPHONE}
   DynPortal     : ${WITH_DYNPORTAL}$( [[ "$WITH_DYNPORTAL" == yes ]] && echo " (https://${SSL_DOMAIN:-$SERVER_IP}:446)" )
   Cockpit       : ${WITH_COCKPIT}$( [[ "$WITH_COCKPIT" == yes ]] && echo " (https://${SERVER_IP}:9090)" )
   g729          : ${WITH_G729}
   tmpfs monitor : ${TMPFS_RECORDINGS} (${TMPFS_SIZE})

 FIREWALL
   SIP 5060      : $( [[ -n "$CARRIER_IPS" ]] && echo "restricted to ${CARRIER_IPS}" || echo "OPEN — restrict to carrier IPs ASAP" )
   RTP           : 10000-20000/udp open

 POST-INSTALL CHECKLIST
   [ ] Reboot the server (first boot starts keepalive screens)
   [ ] Log in, change any remaining default passwords (Admin > Users)
   [ ] Add your carrier (Admin > Carriers) and test a call
   [ ] Restrict port 443/80 to office IPs or rely on DynPortal whitelist
   [ ] Set up off-box recording archiving (FTP/SFTP) if required
   [ ] Take a baseline backup: /usr/share/astguiclient/ADMIN_backup.pl

 Logs: ${LOG_FILE}
==================================================================
EOF
    chmod 600 "$report"
    ok "Report written to $report"

    if (( problems > 0 )); then
        warn "$problems check(s) flagged — review above before going live."
    fi
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
main() {
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    load_config
    parse_args "$@"
    detect_os   # always run — never skipped, so EL/PRETTY_NAME/OS_ID always set
    detect_ip   # always run — never skipped, so SERVER_IP always set
    log "=== installer start v${INSTALLER_VERSION} args: $* ==="

    run_step preflight       step_preflight
    run_step configure       step_configure
    run_step system_prep     step_system_prep
    reboot_checkpoint
    run_step packages        step_packages
    run_step database        step_database
    run_step php             step_php
    run_step perl            step_perl
    run_step dahdi           step_dahdi
    run_step asterisk        step_asterisk
    run_step vicidial_src    step_vicidial_src
    run_step vicidial_db     step_vicidial_db
    run_step vicidial_conf   step_vicidial_conf
    run_step ip_relay        step_ip_relay
    run_step sounds          step_sounds
    run_step integration     step_integration
    run_step webphone        step_webphone
    run_step dynportal       step_dynportal
    run_step g729            step_g729
    run_step cockpit         step_cockpit
    run_step ssl_webrtc      step_ssl_webrtc
    run_step firewall        step_firewall
    run_step verify          step_verify

    # clean up resume unit if present
    systemctl disable vicidial-installer-resume.service >>"$LOG_FILE" 2>&1 || true
    rm -f /etc/systemd/system/vicidial-installer-resume.service

    echo
    ok "VICIdial installation complete."
    echo "   Credentials + checklist: /root/vicidial-install-report.txt"
    echo
    cat <<EOF
======================================================================
 If this server's IP address ever changes (new VM, re-deploy, DR
 failover), update it in the VICIdial database with:

   /usr/share/astguiclient/ADMIN_update_server_ip.pl \\
       --old-server_ip=${SERVER_IP} --server_ip=<NEW_IP> --auto

 To add a domain/SSL/WebRTC after the fact (not configured on this run):

   rm -f /var/lib/vicidial-installer/step.ssl_webrtc.done
   ./$(basename "$0") --domain yourdomain.com --email you@example.com

 Official paid VICIdial support:  http://www.vicidial.com
 Free community VICIdial forum:   http://www.vicidial.org/VICIDIALforum

 Installed by install-vicidial.sh v${INSTALLER_VERSION}
 Debjit Pal — Systems & VoIP Infrastructure Engineer
 Beltalk Technologies Pvt. Ltd.
======================================================================
EOF
    echo
    if confirm "Reboot now to finish (recommended)?"; then
        info "Rebooting..."
        sleep 3
        reboot
    else
        warn "Remember to reboot before dialing — keepalive screens start at boot."
    fi
}

main "$@"
