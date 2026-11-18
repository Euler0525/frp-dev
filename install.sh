#!/usr/bin/env bash
# Install the official frp binaries as restricted systemd services.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR=/usr/local/bin
CONFIG_DIR=/etc/frp
UNIT_DIR=/etc/systemd/system
BACKUP_ROOT=/var/backups/frp-deploy
DASHBOARD_DIR=/usr/local/share/frp-deploy/dashboard
DASHBOARD_SOURCE="$SCRIPT_DIR/dashboard"
VERSION=0.71.1
ROLE=
INPUT_CONFIG=
WORK_DIR=
BACKUP_DIR=
PENDING_BINARY=
PENDING_DASHBOARD=
DASHBOARD_CHANGED=false
DEPLOYING=false
COMMITTED=false
WAS_ACTIVE=false
WAS_ENABLED=false

usage() {
    cat <<'EOF'
Usage: sudo bash install.sh server|client [options]

Options:
  --config PATH       Install a prepared TOML configuration.
  --version X.Y.Z     Select an official frp release (default: 0.71.1).
  -h, --help          Show this help.

Without --config, an existing configuration is preserved. A fresh installation
opens an interactive configuration wizard. Linux with systemd is required.
The server installer also needs the dashboard directory beside this script.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; return 1; }

parse_args() {
    while (($#)); do
        case "$1" in
            server|client)
                [[ -z $ROLE ]] || { die 'Specify only one role.'; return 1; }
                ROLE=$1; shift ;;
            --config|--version)
                (($# >= 2)) || { die "Missing value for $1."; return 1; }
                if [[ $1 == --config ]]; then INPUT_CONFIG=$2; else VERSION=$2; fi
                shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1"; return 1 ;;
        esac
    done
    [[ -n $ROLE ]] || { usage >&2; return 1; }
    [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { die 'Version must use X.Y.Z format.'; return 1; }
    if [[ -n $INPUT_CONFIG && ! -f $INPUT_CONFIG ]]; then
        die "Configuration not found: $INPUT_CONFIG"; return 1
    fi
    if [[ $ROLE == server ]]; then SERVICE=frps; else SERVICE=frpc; fi
    BINARY="$BIN_DIR/$SERVICE"
    CONFIG="$CONFIG_DIR/$SERVICE.toml"
    UNIT="$UNIT_DIR/$SERVICE.service"
}

preflight() {
    ((BASH_VERSINFO[0] >= 4)) || { die 'Bash 4 or newer is required.'; return 1; }
    [[ $(uname -s) == Linux ]] || { die 'Only Linux with systemd is supported.'; return 1; }
    [[ $(id -u) == 0 ]] || { die 'Run this installer with sudo or as root.'; return 1; }
    local command
    for command in curl tar sha256sum openssl install getent useradd nologin systemctl awk grep cp chmod date mktemp mv rm sleep; do
        command -v "$command" >/dev/null || {
            die "Missing command: $command. Install curl, ca-certificates, tar, openssl, coreutils and the system account tools with your package manager."
            return 1
        }
    done
    systemctl show-environment >/dev/null || { die 'A running systemd instance is required.'; return 1; }
    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die 'Supported architectures: x86_64 (amd64) and aarch64 (arm64).'; return 1 ;;
    esac
    local path
    for path in "$BINARY" "$CONFIG" "$UNIT"; do
        [[ ! -L $path ]] || { die "Refusing to replace a symbolic link: $path"; return 1; }
    done
    if [[ $ROLE == server ]]; then check_dashboard_assets; fi
}

check_dashboard_assets() {
    local file path
    for file in index.html app.js styles.css; do
        path="$DASHBOARD_SOURCE/$file"
        [[ -f $path && ! -L $path ]] || {
            die "Missing dashboard asset: $path. Download the complete project before installing the server."; return 1
        }
    done
    for path in "$DASHBOARD_DIR" "${DASHBOARD_DIR%/*}"; do
        [[ ! -L $path ]] || { die "Refusing a symbolic link in the dashboard destination: $path"; return 1; }
    done
    if [[ -e $DASHBOARD_DIR && ( ! -d $DASHBOARD_DIR || ! -O $DASHBOARD_DIR || ! -f $DASHBOARD_DIR/.frp-deploy-managed || -L $DASHBOARD_DIR/.frp-deploy-managed ) ]]; then
        die "The dashboard destination is not managed by this installer: $DASHBOARD_DIR"; return 1
    fi
}

validate_port() {
    local port=$1 minimum=${2:-1}
    if [[ ! $port =~ ^[1-9][0-9]{0,4}$ ]] || ((port < minimum || port > 65535)); then
        die "Port must be an integer between $minimum and 65535: $port"; return 1
    fi
}

validate_ports() {
    local value=$1 port
    [[ $value =~ ^[0-9]+(,[0-9]+)*$ ]] || { die 'Use comma-separated port numbers, for example 6000,6001.'; return 1; }
    local -a ports
    IFS=, read -r -a ports <<< "$value"
    for port in "${ports[@]}"; do validate_port "$port" 1024 || return 1; done
}

toml_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '"%s"' "$value"
}

render_server_config() {
    local bind_port=$1 allowed_ports=$2 token=$3 port separator=
    local -a ports
    IFS=, read -r -a ports <<< "$allowed_ports"
    printf 'bindAddr = "0.0.0.0"\nbindPort = %s\n\nallowPorts = [' "$bind_port"
    for port in "${ports[@]}"; do
        printf '%s{ single = %s }' "$separator" "$port"
        separator=', '
    done
    cat <<EOF
]

auth.method = "token"
auth.token = $(toml_quote "$token")
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tls.force = true
log.to = "console"
log.level = "info"
EOF
}

render_client_config() {
    cat <<EOF
serverAddr = $(toml_quote "$1")
serverPort = $2
loginFailExit = false

auth.method = "token"
auth.token = $(toml_quote "$3")
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tls.enable = true
log.to = "console"
log.level = "info"

[[proxies]]
name = $(toml_quote "$4")
type = "tcp"
localIP = $(toml_quote "$5")
localPort = $6
remotePort = $7
EOF
}

render_dashboard_config() {
    cat <<EOF

# Keep this listener private; use SSH forwarding or an HTTPS reverse proxy.
webServer.addr = $(toml_quote "$1")
webServer.port = $2
webServer.user = $(toml_quote "$3")
webServer.password = $(toml_quote "$4")
webServer.assetsDir = $(toml_quote "$DASHBOARD_DIR")
EOF
}

prompt() {
    local label=$1 default=${2:-} secret=${3:-false}
    printf '%s' "$label" >&3
    [[ -z $default ]] || printf ' [%s]' "$default" >&3
    printf ': ' >&3
    if [[ $secret == true ]]; then
        IFS= read -r -s -u 3 REPLY || { die 'Input cancelled.'; return 1; }
        printf '\n' >&3
    else
        IFS= read -r -u 3 REPLY || { die 'Input cancelled.'; return 1; }
    fi
    REPLY=${REPLY:-$default}
}

wizard() {
    exec 3<>/dev/tty || { die 'A terminal is required for the wizard. Use --config PATH for unattended installation.'; return 1; }
    local token port address allowed name local_ip local_port remote_port
    local dashboard_enabled dashboard_address dashboard_port dashboard_user dashboard_password
    if [[ $ROLE == server ]]; then
        prompt 'FRP listening TCP port' 7000; port=$REPLY
        validate_port "$port" 1024
        prompt 'Allowed public proxy ports (comma-separated)' 6000; allowed=$REPLY
        validate_ports "$allowed"
        [[ ,$allowed, != *,$port,* ]] || { die 'Proxy ports must differ from the FRP listening port.'; return 1; }
        prompt 'Token (hidden; leave empty to generate)' '' true; token=$REPLY
        [[ -n $token ]] || token=$(openssl rand -hex 32)
        ((${#token} >= 16)) || { die 'Use a token of at least 16 characters.'; return 1; }
        render_server_config "$port" "$allowed" "$token" > "$WORK_DIR/config.toml"
        prompt 'Enable the monitoring dashboard (yes/no)' yes; dashboard_enabled=$REPLY
        case "$dashboard_enabled" in
            y|Y|yes|YES)
                dashboard_address=127.0.0.1
                printf 'The dashboard listens on 127.0.0.1; use SSH forwarding for protected access.\n' >&3
                prompt 'Dashboard TCP port' 7500; dashboard_port=$REPLY
                validate_port "$dashboard_port" 1024
                [[ $dashboard_port != "$port" && ,$allowed, != *,$dashboard_port,* ]] || {
                    die 'The dashboard port must differ from the FRP listening and proxy ports.'; return 1
                }
                prompt 'Dashboard username' admin; dashboard_user=$REPLY
                prompt 'Dashboard password (hidden; leave empty to generate)' '' true; dashboard_password=$REPLY
                [[ -n $dashboard_password ]] || dashboard_password=$(openssl rand -hex 32)
                ((${#dashboard_password} >= 16)) || { die 'Use a dashboard password of at least 16 characters.'; return 1; }
                [[ $dashboard_password != "$token" ]] || { die 'Use a dashboard password different from the FRP token.'; return 1; }
                render_dashboard_config "$dashboard_address" "$dashboard_port" "$dashboard_user" "$dashboard_password" >> "$WORK_DIR/config.toml"
                ;;
            n|N|no|NO) ;;
            *) die 'Enter yes or no.'; return 1 ;;
        esac
    else
        prompt 'Public server IP address or DNS name'; address=$REPLY
        [[ -n $address ]] || { die 'Server address is required.'; return 1; }
        prompt 'FRP server TCP port' 7000; port=$REPLY
        validate_port "$port" 1024
        prompt 'Server token (hidden)' '' true; token=$REPLY
        ((${#token} >= 16)) || { die 'Enter the same token as the server (at least 16 characters).'; return 1; }
        prompt 'Unique proxy name' "ssh-$(uname -n)"; name=$REPLY
        prompt 'Local SSH address' 127.0.0.1; local_ip=$REPLY
        prompt 'Local SSH port' 22; local_port=$REPLY
        validate_port "$local_port"
        prompt 'Public proxy TCP port' 6000; remote_port=$REPLY
        validate_port "$remote_port" 1024
        [[ $remote_port != "$port" ]] || { die 'The proxy port must differ from the FRP server port.'; return 1; }
        render_client_config "$address" "$port" "$token" "$name" "$local_ip" "$local_port" "$remote_port" > "$WORK_DIR/config.toml"
    fi
    exec 3>&-
}

prepare_config() {
    if [[ -n $INPUT_CONFIG ]]; then
        cp -- "$INPUT_CONFIG" "$WORK_DIR/config.toml"
    elif [[ -f $CONFIG ]]; then
        printf 'Preserving existing configuration: %s\n' "$CONFIG"
        cp -- "$CONFIG" "$WORK_DIR/config.toml"
    else
        wizard
    fi
    chmod 600 "$WORK_DIR/config.toml"
    if grep -Eq 'CHANGE_ME|<FRP_TOKEN>|<PUBLIC_SERVER_IP>|REPLACE_WITH_' "$WORK_DIR/config.toml"; then
        die 'Replace the example placeholders in your configuration before installing.'; return 1
    fi
}

verify_archive() {
    local directory=$1 archive=$2
    awk -v name="$archive" '
        $2 == name || $2 == "*" name { print $1 "  " name; count++ }
        END { if (count != 1) exit 1 }
    ' "$directory/frp_sha256_checksums.txt" > "$directory/selected-checksum.txt" || {
        die 'The official checksum list must contain exactly one matching archive.'; return 1
    }
    (cd "$directory" && sha256sum --check --status selected-checksum.txt) || {
        die 'Archive SHA-256 verification failed.'; return 1
    }
}

download_binary() {
    local folder="frp_${VERSION}_linux_${ARCH}" archive="frp_${VERSION}_linux_${ARCH}.tar.gz"
    local base="https://github.com/fatedier/frp/releases/download/v${VERSION}"
    printf 'Downloading official frp %s for linux_%s...\n' "$VERSION" "$ARCH"
    local filename
    for filename in "$archive" frp_sha256_checksums.txt; do
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --retry 3 --connect-timeout 15 --max-time 300 "$base/$filename" -o "$WORK_DIR/$filename"
    done
    verify_archive "$WORK_DIR" "$archive"
    tar -xzf "$WORK_DIR/$archive" -C "$WORK_DIR" "$folder/$SERVICE"
    STAGED_BINARY="$WORK_DIR/$folder/$SERVICE"
    chmod 755 "$STAGED_BINARY"
    "$STAGED_BINARY" verify -c "$WORK_DIR/config.toml"
}

ensure_account() {
    local entry uid shell
    if entry=$(getent passwd frp); then
        IFS=: read -r _ _ uid _ _ _ shell <<< "$entry"
        [[ $uid != 0 && ( $shell == */nologin || $shell == */false ) ]] || {
            die 'The existing frp account must be non-root with a nologin or false shell.'; return 1
        }
        getent group frp >/dev/null || { die 'The existing frp account needs an frp group.'; return 1; }
    elif getent group frp >/dev/null; then
        useradd --system --gid frp --no-create-home --shell "$(command -v nologin)" frp
    else
        useradd --system --user-group --no-create-home --shell "$(command -v nologin)" frp
    fi
}

write_unit() {
    cat <<EOF
[Unit]
Description=FRP $ROLE
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=frp
Group=frp
ExecStart=$BINARY -c $CONFIG
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

snapshot() {
    BACKUP_DIR="$BACKUP_ROOT/$SERVICE-$(date -u +%Y%m%d%H%M%S)-$$"
    install -d -m 700 "$BACKUP_ROOT" "$BACKUP_DIR"
    local entry path
    for entry in binary config unit; do
        case "$entry" in binary) path=$BINARY ;; config) path=$CONFIG ;; unit) path=$UNIT ;; esac
        if [[ -e $path ]]; then cp -a -- "$path" "$BACKUP_DIR/$entry"; fi
    done
    if [[ $ROLE == server && -d $DASHBOARD_DIR ]]; then
        cp -a -- "$DASHBOARD_DIR" "$BACKUP_DIR/dashboard"
    fi
    if systemctl is-active --quiet "$SERVICE"; then WAS_ACTIVE=true; fi
    if systemctl is-enabled --quiet "$SERVICE"; then WAS_ENABLED=true; fi
    printf 'was_active=%s\nwas_enabled=%s\n' "$WAS_ACTIVE" "$WAS_ENABLED" > "$BACKUP_DIR/state"
}

rollback() {
    printf 'Deployment failed; restoring the previous files and service state.\n' >&2
    local failed=0 entry path
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE" >/dev/null 2>&1 || true
    for entry in binary config unit; do
        case "$entry" in binary) path=$BINARY ;; config) path=$CONFIG ;; unit) path=$UNIT ;; esac
        if [[ -e $BACKUP_DIR/$entry ]]; then
            cp -a -- "$BACKUP_DIR/$entry" "$path" || failed=1
        else
            rm -f -- "$path" || failed=1
        fi
    done
    if [[ $DASHBOARD_CHANGED == true ]]; then
        if [[ -d $DASHBOARD_DIR ]]; then
            mv -- "$DASHBOARD_DIR" "$BACKUP_DIR/dashboard-failed" || failed=1
        fi
        if [[ -d $BACKUP_DIR/dashboard ]]; then
            if [[ ! -e $DASHBOARD_DIR ]]; then
                cp -a -- "$BACKUP_DIR/dashboard" "$DASHBOARD_DIR" || failed=1
            else
                failed=1
            fi
        fi
    fi
    systemctl daemon-reload || failed=1
    if [[ $WAS_ENABLED == true ]]; then systemctl enable "$SERVICE" || failed=1; fi
    if [[ $WAS_ACTIVE == true ]]; then systemctl start "$SERVICE" || failed=1; fi
    if ((failed)); then
        printf 'Automatic recovery was incomplete. Inspect the backup at %s.\n' "$BACKUP_DIR" >&2
    else
        printf 'Previous files and service state restored. Backup: %s\n' "$BACKUP_DIR" >&2
    fi
    return "$failed"
}

deploy_dashboard() {
    local file
    install -d -m 755 -o root -g root "${DASHBOARD_DIR%/*}"
    PENDING_DASHBOARD=$(mktemp -d "${DASHBOARD_DIR%/*}/.dashboard.XXXXXXXX")
    chmod 755 "$PENDING_DASHBOARD"
    for file in index.html app.js styles.css; do
        install -m 644 -o root -g root "$DASHBOARD_SOURCE/$file" "$PENDING_DASHBOARD/$file"
    done
    printf 'Managed by frp-deploy.\n' > "$PENDING_DASHBOARD/.frp-deploy-managed"
    chmod 644 "$PENDING_DASHBOARD/.frp-deploy-managed"
    DASHBOARD_CHANGED=true
    if [[ -d $DASHBOARD_DIR ]]; then
        mv -- "$DASHBOARD_DIR" "$BACKUP_DIR/dashboard-replaced"
    fi
    mv -- "$PENDING_DASHBOARD" "$DASHBOARD_DIR"
    PENDING_DASHBOARD=
}

deploy() {
    ensure_account
    snapshot
    DEPLOYING=true
    install -d -m 755 "$BIN_DIR" "$UNIT_DIR"
    install -d -m 750 -o root -g frp "$CONFIG_DIR"
    PENDING_BINARY=$(mktemp "$BIN_DIR/.$SERVICE.XXXXXXXX")
    install -m 755 "$STAGED_BINARY" "$PENDING_BINARY"
    mv -f -- "$PENDING_BINARY" "$BINARY"
    PENDING_BINARY=
    install -m 640 -o root -g frp "$WORK_DIR/config.toml" "$CONFIG"
    if [[ $ROLE == server ]]; then deploy_dashboard; fi
    write_unit > "$WORK_DIR/service"
    install -m 644 "$WORK_DIR/service" "$UNIT"
    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    sleep 2
    systemctl is-active --quiet "$SERVICE" || {
        die "The service is not active. Check: journalctl -u $SERVICE -n 50 --no-pager"; return 1
    }
    COMMITTED=true
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ $DEPLOYING == true && $COMMITTED == false ]]; then
        rollback || true
        ((status != 0)) || status=1
    fi
    if [[ -n $PENDING_BINARY ]]; then rm -f -- "$PENDING_BINARY"; fi
    if [[ -n $PENDING_DASHBOARD ]]; then rm -rf -- "$PENDING_DASHBOARD"; fi
    if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi
    exit "$status"
}

main() {
    set -Eeuo pipefail
    umask 077
    parse_args "$@"
    preflight
    WORK_DIR=$(mktemp -d /tmp/frp-deploy.XXXXXXXX)
    trap cleanup EXIT
    prepare_config
    download_binary
    deploy
    printf '\nInstalled %s %s. Configuration: %s\n' "$SERVICE" "$VERSION" "$CONFIG"
    printf 'Backup: %s\n' "$BACKUP_DIR"
    printf 'Status: sudo systemctl status %s --no-pager\n' "$SERVICE"
    printf 'Logs: sudo journalctl -u %s -f\n' "$SERVICE"
    if [[ $ROLE == server ]]; then
        printf 'Read the token and any dashboard credentials privately with: sudo less %s\n' "$CONFIG"
        printf 'Use the same token on every client. Allow the configured TCP ports in your firewall and cloud security group.\n'
        printf 'Dashboard assets: %s\n' "$DASHBOARD_DIR"
        printf 'Dashboard access uses the webServer address, port and credentials in the configuration.\n'
        printf 'For loopback listeners, connect through SSH forwarding as described in the README. Do not expose dashboard HTTP publicly.\n'
    else
        printf 'Check the logs for successful server login and proxy registration.\n'
    fi
    printf 'An active process does not guarantee tunnel connectivity. Test an SSH connection after both ends are configured.\n'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
