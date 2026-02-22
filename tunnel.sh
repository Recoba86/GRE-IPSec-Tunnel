#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

CONFIG_DIR="/etc/fou-tunnels"
RUNNER_DIR="/usr/local/sbin"
SERVICE_DIR="/etc/systemd/system"
IPSEC_MAIN_CONF="/etc/ipsec.conf"
IPSEC_MAIN_SECRETS="/etc/ipsec.secrets"

CURRENT_TUNNEL_NAME=""
CONFIG_FILE=""
SERVICE_NAME=""
SERVICE_FILE=""
RUNNER_FILE=""
IPSEC_CONN_FILE=""
IPSEC_SECRET_FILE=""
AF_RESTART_SCRIPT=""
AF_DUMMY_SCRIPT=""
AF_DUMMY_SERVICE_NAME=""
AF_DUMMY_SERVICE_FILE=""

TUNNEL_NAME=""
LOCAL_IP=""
REMOTE_IP=""
LOCAL_TUNNEL_IP=""
REMOTE_TUNNEL_IP=""
IFACE_NAME=""
TCP_PORTS="443"
UDP_ENABLED="no"
UDP_PORTS=""
IPSEC_PSK=""

BBR_SCRIPT_URL="https://raw.githubusercontent.com/teddysun/across/ac11f0d4c51e82b9d6b119e19601232c63a62d2d/bbr.sh"
BBR_SCRIPT_SHA256="17f447d78ba82468727e97cfdaa2a18150840a4c00c207592e5329df36544e85"
TCP_SCRIPT_URL="https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/351f4c53e5153c511de4e737ff54e35c73abb1a5/tcp.sh"
TCP_SCRIPT_SHA256="427b7e97c25404dfde248549975474f84ca7d50f38319744a05a0fb2bf37afcb"

require_root() {
    if [ "${EUID:-0}" -ne 0 ]; then
        echo "This script must run as root. Use: sudo bash $0"
        exit 1
    fi
}

pause_screen() {
    read -r -p "Press Enter to continue..."
}

validate_ipv4() {
    local ip="$1"
    local o1 o2 o3 o4

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

    for octet in "$o1" "$o2" "$o3" "$o4"; do
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

validate_psk() {
    local psk="$1"
    (( ${#psk} >= 12 ))
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

validate_tunnel_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}

prompt_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        read -r -p "$prompt" answer
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

normalize_ports() {
    local raw="$1"
    local __var_name="$2"
    local cleaned result port
    local -a ports

    cleaned="${raw// /}"
    [ -n "$cleaned" ] || return 1

    IFS=',' read -r -a ports <<< "$cleaned"
    [ "${#ports[@]}" -gt 0 ] || return 1

    result=""
    for port in "${ports[@]}"; do
        [ -n "$port" ] || return 1
        validate_port "$port" || return 1

        case ",$result," in
            *",$port,"*) continue ;;
        esac

        if [ -z "$result" ]; then
            result="$port"
        else
            result="$result,$port"
        fi
    done

    [ -n "$result" ] || return 1
    printf -v "$__var_name" '%s' "$result"
}

read_tunnel_name_value() {
    local prompt="$1"
    local __var_name="$2"
    local value

    while true; do
        read -r -p "$prompt" value
        if validate_tunnel_name "$value"; then
            printf -v "$__var_name" '%s' "$value"
            return
        fi
        echo "Invalid tunnel name. Use letters, numbers, underscore, hyphen."
    done
}

read_ipv4_value() {
    local prompt="$1"
    local __var_name="$2"
    local value

    while true; do
        read -r -p "$prompt" value
        if validate_ipv4 "$value"; then
            printf -v "$__var_name" '%s' "$value"
            return
        fi
        echo "Invalid IPv4 address: $value"
    done
}

read_psk_value() {
    local value

    while true; do
        read -r -s -p "Enter IPSec PSK (minimum 12 chars): " value
        echo
        if validate_psk "$value"; then
            IPSEC_PSK="$value"
            return
        fi
        echo "PSK is too short. Use at least 12 characters."
    done
}

read_port_list_value() {
    local prompt="$1"
    local __var_name="$2"
    local value normalized

    while true; do
        read -r -p "$prompt" value
        if normalize_ports "$value" normalized; then
            printf -v "$__var_name" '%s' "$normalized"
            return
        fi
        echo "Invalid ports. Use 1-65535, comma-separated."
    done
}

read_interval_minutes() {
    local __var_name="$1"
    local value

    while true; do
        read -r -p "Enter restart interval in minutes [15]: " value
        value="${value:-15}"
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 60 )); then
            printf -v "$__var_name" '%s' "$value"
            return
        fi
        echo "Invalid interval. Use 1-60."
    done
}

interface_name_for_tunnel() {
    local name="$1"
    local digest

    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(printf '%s' "$name" | sha256sum | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        digest="$(printf '%s' "$name" | shasum -a 256 | awk '{print $1}')"
    else
        digest="$(printf '%s' "$name" | cksum | awk '{print $1}')"
    fi

    echo "gr${digest:0:10}"
}

set_tunnel_context() {
    local name="$1"

    CURRENT_TUNNEL_NAME="$name"
    CONFIG_FILE="$CONFIG_DIR/${name}.conf"
    SERVICE_NAME="fou-tunnel-${name}.service"
    SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME"
    RUNNER_FILE="$RUNNER_DIR/fou-tunnel-${name}-runner.sh"
    IPSEC_CONN_FILE="/etc/ipsec.d/fou-tunnel-${name}.conf"
    IPSEC_SECRET_FILE="/etc/ipsec.d/fou-tunnel-${name}.secrets"
    AF_RESTART_SCRIPT="/usr/local/bin/fou-restart-${name}.sh"
    AF_DUMMY_SCRIPT="/usr/local/bin/fou-dummy-${name}.sh"
    AF_DUMMY_SERVICE_NAME="fou-dummy-${name}.service"
    AF_DUMMY_SERVICE_FILE="$SERVICE_DIR/$AF_DUMMY_SERVICE_NAME"
}

ensure_base_dirs() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$RUNNER_DIR"
    mkdir -p /etc/ipsec.d
}

list_tunnel_names() {
    local cfg

    ensure_base_dirs
    for cfg in "$CONFIG_DIR"/*.conf; do
        [ -e "$cfg" ] || continue
        basename "$cfg" .conf
    done | sort -u
}

select_tunnel_name() {
    local prompt="$1"
    local __var_name="$2"
    local choice
    local idx=1
    local -a names

    mapfile -t names < <(list_tunnel_names)
    if [ "${#names[@]}" -eq 0 ]; then
        echo "No tunnels found."
        return 1
    fi

    echo "$prompt"
    for name in "${names[@]}"; do
        echo "$idx) $name"
        idx=$((idx + 1))
    done
    echo "0) Cancel"

    while true; do
        read -r -p "Select tunnel: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -eq 0 ]; then
                return 1
            fi
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ]; then
                printf -v "$__var_name" '%s' "${names[$((choice - 1))]}"
                return 0
            fi
        fi
        echo "Invalid selection."
    done
}

save_config() {
    local psk_b64
    local old_umask

    psk_b64="$(printf '%s' "$IPSEC_PSK" | base64 | tr -d '\n')"

    old_umask="$(umask)"
    umask 077

    cat > "$CONFIG_FILE" <<EOC
TUNNEL_NAME=$TUNNEL_NAME
LOCAL_IP=$LOCAL_IP
REMOTE_IP=$REMOTE_IP
LOCAL_TUNNEL_IP=$LOCAL_TUNNEL_IP
REMOTE_TUNNEL_IP=$REMOTE_TUNNEL_IP
IFACE_NAME=$IFACE_NAME
TCP_PORTS=$TCP_PORTS
UDP_ENABLED=$UDP_ENABLED
UDP_PORTS=$UDP_PORTS
IPSEC_PSK_B64=$psk_b64
EOC

    chmod 600 "$CONFIG_FILE"
    umask "$old_umask"
}

load_config() {
    local mode="${1:-strict}"
    local line key value
    local psk_b64=""

    [ -f "$CONFIG_FILE" ] || return 1

    TUNNEL_NAME="$CURRENT_TUNNEL_NAME"
    LOCAL_IP=""
    REMOTE_IP=""
    LOCAL_TUNNEL_IP=""
    REMOTE_TUNNEL_IP=""
    IFACE_NAME=""
    TCP_PORTS="443"
    UDP_ENABLED="no"
    UDP_PORTS=""
    IPSEC_PSK=""

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            TUNNEL_NAME) TUNNEL_NAME="$value" ;;
            LOCAL_IP) LOCAL_IP="$value" ;;
            REMOTE_IP) REMOTE_IP="$value" ;;
            LOCAL_TUNNEL_IP) LOCAL_TUNNEL_IP="$value" ;;
            REMOTE_TUNNEL_IP) REMOTE_TUNNEL_IP="$value" ;;
            IFACE_NAME) IFACE_NAME="$value" ;;
            TCP_PORTS) TCP_PORTS="$value" ;;
            UDP_ENABLED) UDP_ENABLED="$value" ;;
            UDP_PORTS) UDP_PORTS="$value" ;;
            IPSEC_PSK_B64) psk_b64="$value" ;;
        esac
    done < "$CONFIG_FILE"

    if [ -z "$IFACE_NAME" ]; then
        IFACE_NAME="$(interface_name_for_tunnel "$CURRENT_TUNNEL_NAME")"
    fi

    if [ -n "$psk_b64" ]; then
        if ! IPSEC_PSK="$(printf '%s' "$psk_b64" | base64 -d 2>/dev/null)"; then
            echo "Failed to decode IPSec PSK from config."
            return 1
        fi
    fi

    [ "$TUNNEL_NAME" = "$CURRENT_TUNNEL_NAME" ] || TUNNEL_NAME="$CURRENT_TUNNEL_NAME"

    if [ "$mode" = "strict" ]; then
        validate_ipv4 "$LOCAL_IP" || return 1
        validate_ipv4 "$REMOTE_IP" || return 1
        validate_ipv4 "$LOCAL_TUNNEL_IP" || return 1
        validate_ipv4 "$REMOTE_TUNNEL_IP" || return 1
        normalize_ports "$TCP_PORTS" TCP_PORTS || return 1

        if [ "$UDP_ENABLED" != "yes" ] && [ "$UDP_ENABLED" != "no" ]; then
            return 1
        fi
        if [ "$UDP_ENABLED" = "yes" ]; then
            normalize_ports "$UDP_PORTS" UDP_PORTS || return 1
        else
            UDP_PORTS=""
        fi

        validate_psk "$IPSEC_PSK" || return 1
    fi

    return 0
}

ensure_packages() {
    local packages=()

    command -v apt-get >/dev/null 2>&1 || {
        echo "apt-get is required on this host."
        exit 1
    }

    command -v curl >/dev/null 2>&1 || packages+=("curl")
    command -v socat >/dev/null 2>&1 || packages+=("socat")

    if ! systemctl list-unit-files --type=service | grep -qE '^strongswan(\\.service)?|^strongswan-starter\\.service'; then
        packages+=("strongswan" "strongswan-pki")
    fi

    if [ "${#packages[@]}" -gt 0 ]; then
        echo "Installing required packages: ${packages[*]}"
        apt-get update
        apt-get install -y "${packages[@]}"
    fi
}

ensure_antifilter_packages() {
    local packages=()

    command -v nc >/dev/null 2>&1 || packages+=("netcat-openbsd")

    if [ "${#packages[@]}" -gt 0 ]; then
        echo "Installing anti-filter packages: ${packages[*]}"
        apt-get update
        apt-get install -y "${packages[@]}"
    fi
}

safe_download() {
    local url="$1"
    local output="$2"
    local expected_sha="$3"
    local actual_sha

    curl --proto '=https' --tlsv1.2 --fail --show-error --location \
        --retry 3 --retry-delay 2 --connect-timeout 10 \
        "$url" -o "$output"

    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha="$(sha256sum "$output" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual_sha="$(shasum -a 256 "$output" | awk '{print $1}')"
    else
        echo "No SHA256 tool found (sha256sum/shasum)."
        return 1
    fi

    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "Checksum mismatch for $url"
        echo "Expected: $expected_sha"
        echo "Actual:   $actual_sha"
        return 1
    fi

    chmod 700 "$output"
}

install_scripts() {
    local temp_dir
    local bbr_file tcp_file

    ensure_packages

    temp_dir="$(mktemp -d /tmp/fou-scripts.XXXXXX)"
    bbr_file="$temp_dir/bbr.sh"
    tcp_file="$temp_dir/tcp.sh"

    safe_download "$BBR_SCRIPT_URL" "$bbr_file" "$BBR_SCRIPT_SHA256"
    safe_download "$TCP_SCRIPT_URL" "$tcp_file" "$TCP_SCRIPT_SHA256"

    bash "$bbr_file"
    printf '10\n' | bash "$tcp_file"
    printf '4\n' | bash "$tcp_file"

    rm -rf "$temp_dir"
    pause_screen
}

ensure_line_in_file() {
    local line="$1"
    local file="$2"

    [ -f "$file" ] || touch "$file"
    grep -Fqx "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

remove_line_from_file() {
    local line="$1"
    local file="$2"
    local tmp

    [ -f "$file" ] || return 0

    tmp="$(mktemp)"
    awk -v target="$line" '$0 != target' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

get_ipsec_service_name() {
    if systemctl list-unit-files --type=service | grep -q '^strongswan\\.service'; then
        echo "strongswan"
        return
    fi
    if systemctl list-unit-files --type=service | grep -q '^strongswan-starter\\.service'; then
        echo "strongswan-starter"
        return
    fi
    echo ""
}

configure_ipsec() {
    local ipsec_service
    local old_umask

    cat > "$IPSEC_CONN_FILE" <<EOC
conn fou-tunnel-$TUNNEL_NAME
    auto=start
    keyexchange=ikev2
    authby=psk
    type=tunnel
    ike=aes256gcm16-prfsha384-ecp256,aes256-sha256-modp2048!
    esp=aes256gcm16,aes256-sha256!
    ikelifetime=60m
    lifetime=20m
    rekey=yes
    reauth=no
    keyingtries=%forever
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s
    left=$LOCAL_IP
    leftid=$LOCAL_IP
    leftsubnet=$LOCAL_IP/32
    right=$REMOTE_IP
    rightid=$REMOTE_IP
    rightsubnet=$REMOTE_IP/32
EOC

    old_umask="$(umask)"
    umask 077
    printf '%s %s : PSK "%s"\n' "$LOCAL_IP" "$REMOTE_IP" "$IPSEC_PSK" > "$IPSEC_SECRET_FILE"
    chmod 600 "$IPSEC_SECRET_FILE"
    umask "$old_umask"

    ensure_line_in_file "include $IPSEC_CONN_FILE" "$IPSEC_MAIN_CONF"
    ensure_line_in_file "include $IPSEC_SECRET_FILE" "$IPSEC_MAIN_SECRETS"

    ipsec_service="$(get_ipsec_service_name)"
    if [ -n "$ipsec_service" ]; then
        systemctl enable "$ipsec_service"
        systemctl restart "$ipsec_service"
    else
        echo "Warning: strongSwan service not found; IPSec may not be active."
    fi
}

generate_runner_script() {
    cat > "$RUNNER_FILE" <<EOR
#!/usr/bin/env bash

set -euo pipefail

LOCAL_IP="$LOCAL_IP"
REMOTE_IP="$REMOTE_IP"
LOCAL_TUNNEL_IP="$LOCAL_TUNNEL_IP"
REMOTE_TUNNEL_IP="$REMOTE_TUNNEL_IP"
IFACE_NAME="$IFACE_NAME"
TCP_PORTS="$TCP_PORTS"
UDP_ENABLED="$UDP_ENABLED"
UDP_PORTS="$UDP_PORTS"

create_gre() {
    modprobe ip_gre

    if ip link show "\$IFACE_NAME" >/dev/null 2>&1; then
        ip link set "\$IFACE_NAME" down >/dev/null 2>&1 || true
        ip link del "\$IFACE_NAME" >/dev/null 2>&1 || true
    fi

    ip link add "\$IFACE_NAME" type gre remote "\$REMOTE_IP" local "\$LOCAL_IP" ttl 255
    ip addr add "\${LOCAL_TUNNEL_IP}/24" dev "\$IFACE_NAME"
    ip link set "\$IFACE_NAME" mtu 1300
    ip link set "\$IFACE_NAME" up
    ip route replace "\${REMOTE_TUNNEL_IP}/32" dev "\$IFACE_NAME"
}

run_socat() {
    local -a tcp_ports udp_ports pids
    local port pid

    IFS=',' read -r -a tcp_ports <<< "\$TCP_PORTS"
    if [ "\${#tcp_ports[@]}" -eq 0 ]; then
        echo "No TCP forwarding ports configured."
        exit 1
    fi

    stop_children() {
        local child_pid
        for child_pid in "\${pids[@]}"; do
            kill "\$child_pid" >/dev/null 2>&1 || true
        done
        wait >/dev/null 2>&1 || true
    }

    trap 'stop_children; exit 0' TERM INT

    for port in "\${tcp_ports[@]}"; do
        socat "TCP-LISTEN:\${port},fork,reuseaddr" "TUN:\${IFACE_NAME},up" &
        pids+=("\$!")
    done

    if [ "\$UDP_ENABLED" = "yes" ]; then
        IFS=',' read -r -a udp_ports <<< "\$UDP_PORTS"
        for port in "\${udp_ports[@]}"; do
            socat "UDP-LISTEN:\${port},fork,reuseaddr" "TUN:\${IFACE_NAME},up" &
            pids+=("\$!")
        done
    fi

    while true; do
        for pid in "\${pids[@]}"; do
            if ! kill -0 "\$pid" >/dev/null 2>&1; then
                stop_children
                exit 1
            fi
        done
        sleep 1
    done
}

case "\${1:-}" in
    start-gre)
        create_gre
        ;;
    run-socat)
        run_socat
        ;;
    stop-gre)
        if ip link show "\$IFACE_NAME" >/dev/null 2>&1; then
            ip link set "\$IFACE_NAME" down >/dev/null 2>&1 || true
            ip link del "\$IFACE_NAME" >/dev/null 2>&1 || true
        fi
        ;;
    restart-gre)
        "\$0" stop-gre
        "\$0" start-gre
        ;;
    *)
        echo "Usage: \$0 {start-gre|run-socat|stop-gre|restart-gre}"
        exit 1
        ;;
esac
EOR

    chmod 700 "$RUNNER_FILE"
}

configure_service() {
    if ! command -v socat >/dev/null 2>&1; then
        echo "socat binary not found."
        exit 1
    fi

    cat > "$SERVICE_FILE" <<EOC
[Unit]
Description=FOU Tunnel Runtime ($TUNNEL_NAME)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=$RUNNER_FILE start-gre
ExecStart=$RUNNER_FILE run-socat
ExecStopPost=$RUNNER_FILE stop-gre
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOC

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
}

prompt_for_config() {
    read_ipv4_value "Enter local IP address: " LOCAL_IP
    read_ipv4_value "Enter remote IP address: " REMOTE_IP
    read_ipv4_value "Enter local tunnel IP (e.g., 30.30.30.2): " LOCAL_TUNNEL_IP
    read_ipv4_value "Enter remote tunnel IP (e.g., 30.30.30.1): " REMOTE_TUNNEL_IP
    read_port_list_value "Enter TCP forwarding port(s) (e.g., 443 or 201,443): " TCP_PORTS

    if prompt_yes_no "Do you want UDP forwarding too? (y/n): "; then
        UDP_ENABLED="yes"
        read_port_list_value "Enter UDP forwarding port(s) (e.g., 1080 or 1080,5353): " UDP_PORTS
    else
        UDP_ENABLED="no"
        UDP_PORTS=""
    fi

    read_psk_value
    IFACE_NAME="$(interface_name_for_tunnel "$TUNNEL_NAME")"
}

configure_tunnel() {
    read_tunnel_name_value "Enter tunnel name (letters, numbers, _, -): " TUNNEL_NAME
    set_tunnel_context "$TUNNEL_NAME"

    if [ -f "$CONFIG_FILE" ]; then
        echo "Existing config found at $CONFIG_FILE"
        if prompt_yes_no "Reuse existing config? (y/n): "; then
            if ! load_config strict; then
                echo "Existing config is invalid; please enter values again."
                prompt_for_config
                save_config
            fi
        else
            prompt_for_config
            save_config
        fi
    else
        prompt_for_config
        save_config
    fi

    ensure_packages
    configure_ipsec
    generate_runner_script
    configure_service

    echo "Tunnel '$TUNNEL_NAME' configured."
    pause_screen
}

check_remote() {
    local selected

    if ! select_tunnel_name "Available tunnels:" selected; then
        pause_screen
        return
    fi

    set_tunnel_context "$selected"
    if ! load_config strict; then
        echo "Configuration file is missing or invalid."
        pause_screen
        return
    fi

    if ping -c 4 "$REMOTE_IP" >/dev/null 2>&1; then
        echo "Remote IP $REMOTE_IP is reachable."
    else
        echo "Remote IP $REMOTE_IP is not reachable."
    fi

    pause_screen
}

check_tunnel_status() {
    local selected

    if ! select_tunnel_name "Available tunnels:" selected; then
        pause_screen
        return
    fi

    set_tunnel_context "$selected"
    if ! load_config strict; then
        echo "Configuration file is missing or invalid."
        pause_screen
        return
    fi

    if ping -c 4 "$REMOTE_TUNNEL_IP" >/dev/null 2>&1; then
        echo "Tunnel endpoint $REMOTE_TUNNEL_IP is reachable."
    else
        echo "Tunnel endpoint $REMOTE_TUNNEL_IP is not reachable."
    fi

    echo "Service: $SERVICE_NAME"
    systemctl --no-pager --full status "$SERVICE_NAME" 2>/dev/null | sed -n '1,8p' || true
    pause_screen
}

manage_tunnel_service() {
    local selected action

    if ! select_tunnel_name "Available tunnels:" selected; then
        pause_screen
        return
    fi

    set_tunnel_context "$selected"

    while true; do
        echo "Service management: $SERVICE_NAME"
        echo "1. Enable and Start"
        echo "2. Restart"
        echo "3. Stop and Disable"
        echo "4. Status"
        echo "5. Back"

        read -r -p "Choose an option: " action
        case "$action" in
            1)
                systemctl enable "$SERVICE_NAME"
                systemctl start "$SERVICE_NAME"
                ;;
            2)
                systemctl restart "$SERVICE_NAME"
                ;;
            3)
                systemctl stop "$SERVICE_NAME" || true
                systemctl disable "$SERVICE_NAME" || true
                ;;
            4)
                systemctl --no-pager --full status "$SERVICE_NAME" | sed -n '1,16p'
                ;;
            5)
                return
                ;;
            *)
                echo "Invalid option."
                ;;
        esac
    done
}

setup_antifilter() {
    local selected interval dummy_port default_dummy

    if ! select_tunnel_name "Select tunnel for anti-filter setup:" selected; then
        pause_screen
        return
    fi

    set_tunnel_context "$selected"
    if ! load_config strict; then
        echo "Configuration file is missing or invalid."
        pause_screen
        return
    fi

    ensure_antifilter_packages

    read_interval_minutes interval

    default_dummy="${TCP_PORTS%%,*}"
    while true; do
        read -r -p "Enter dummy HTTPS port [${default_dummy:-443}]: " dummy_port
        dummy_port="${dummy_port:-${default_dummy:-443}}"
        if validate_port "$dummy_port"; then
            break
        fi
        echo "Invalid port."
    done

    cat > "$AF_RESTART_SCRIPT" <<EOR
#!/usr/bin/env bash
systemctl restart $SERVICE_NAME
EOR
    chmod 700 "$AF_RESTART_SCRIPT"

    (crontab -l 2>/dev/null | grep -vF "$AF_RESTART_SCRIPT"; echo "*/$interval * * * * $AF_RESTART_SCRIPT") | crontab -

    cat > "$AF_DUMMY_SCRIPT" <<EOD
#!/usr/bin/env bash
set -euo pipefail
TARGET_HOST="www.google.com"
TARGET_PORT="$dummy_port"
while true; do
    TARGET_IP=\$(getent ahosts "\$TARGET_HOST" | awk '/STREAM/ {print \$1; exit}')
    if [ -n "\$TARGET_IP" ]; then
        printf "GET / HTTP/1.1\\r\\nHost: \$TARGET_HOST\\r\\nUser-Agent: Mozilla/5.0\\r\\nConnection: close\\r\\n\\r\\n" \
            | nc -w 3 "\$TARGET_IP" "\$TARGET_PORT" >/dev/null 2>&1 || true
    fi
    sleep \$((30 + RANDOM % 60))
done
EOD
    chmod 700 "$AF_DUMMY_SCRIPT"

    cat > "$AF_DUMMY_SERVICE_FILE" <<EOC
[Unit]
Description=Dummy HTTPS traffic for $CURRENT_TUNNEL_NAME
After=network-online.target $SERVICE_NAME
Wants=network-online.target

[Service]
Type=simple
ExecStart=$AF_DUMMY_SCRIPT
Restart=always
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
EOC

    systemctl daemon-reload
    systemctl enable --now "$AF_DUMMY_SERVICE_NAME"

    echo "Anti-filter enabled for $CURRENT_TUNNEL_NAME."
    pause_screen
}

remove_antifilter_artifacts() {
    crontab -l 2>/dev/null | grep -vF "$AF_RESTART_SCRIPT" | crontab - 2>/dev/null || true

    systemctl stop "$AF_DUMMY_SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$AF_DUMMY_SERVICE_NAME" >/dev/null 2>&1 || true

    rm -f "$AF_DUMMY_SERVICE_FILE"
    rm -f "$AF_DUMMY_SCRIPT"
    rm -f "$AF_RESTART_SCRIPT"

    systemctl daemon-reload >/dev/null 2>&1 || true
}

remove_antifilter() {
    local selected

    if ! select_tunnel_name "Select tunnel for anti-filter removal:" selected; then
        pause_screen
        return
    fi

    set_tunnel_context "$selected"
    remove_antifilter_artifacts

    echo "Anti-filter removed for $selected."
    pause_screen
}

remove_tunnel() {
    local selected confirm ipsec_service

    if ! select_tunnel_name "Select tunnel to remove:" selected; then
        pause_screen
        return
    fi

    set_tunnel_context "$selected"
    if ! load_config relaxed; then
        echo "Warning: config is invalid; proceeding with best-effort cleanup."
        IFACE_NAME="$(interface_name_for_tunnel "$selected")"
    fi

    read -r -p "Remove tunnel '$selected'? (y/n): " confirm
    if [[ ! "$confirm" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        echo "Tunnel removal cancelled."
        pause_screen
        return
    fi

    remove_antifilter_artifacts

    if systemctl list-units --full --all | grep -q "$SERVICE_NAME"; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl kill -s SIGKILL "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi

    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

    for d in /etc/systemd/system/*.wants /etc/systemd/system/*/*.wants; do
        rm -f "$d/$SERVICE_NAME" >/dev/null 2>&1 || true
    done

    if [ -f "$RUNNER_FILE" ]; then
        "$RUNNER_FILE" stop-gre >/dev/null 2>&1 || true
    fi

    ip route flush dev "$IFACE_NAME" 2>/dev/null || true
    ip addr flush dev "$IFACE_NAME" 2>/dev/null || true
    ip link set "$IFACE_NAME" down 2>/dev/null || true
    ip tunnel del "$IFACE_NAME" 2>/dev/null || true
    ip link del "$IFACE_NAME" 2>/dev/null || true
    ip route flush cache 2>/dev/null || true
    ip neigh flush all 2>/dev/null || true

    if command -v conntrack >/dev/null 2>&1; then
        conntrack -D -i "$IFACE_NAME" >/dev/null 2>&1 || true
        conntrack -D -o "$IFACE_NAME" >/dev/null 2>&1 || true
    fi

    rm -f "$SERVICE_FILE"
    rm -rf "${SERVICE_FILE}.d" >/dev/null 2>&1 || true
    rm -f "$RUNNER_FILE"

    rm -f "$IPSEC_CONN_FILE"
    rm -f "$IPSEC_SECRET_FILE"
    remove_line_from_file "include $IPSEC_CONN_FILE" "$IPSEC_MAIN_CONF"
    remove_line_from_file "include $IPSEC_SECRET_FILE" "$IPSEC_MAIN_SECRETS"

    ipsec_service="$(get_ipsec_service_name)"
    if [ -n "$ipsec_service" ]; then
        systemctl restart "$ipsec_service" || true
    fi

    rm -f "$CONFIG_FILE"

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true

    echo "Tunnel '$selected' removed."
    pause_screen
}

show_menu() {
    local choice

    while true; do
        clear
        echo "GRE over IPSec Tunnel"
        echo "1. Configure Tunnel"
        echo "2. Check Remote Connection"
        echo "3. Install bbr.sh and tcp.sh"
        echo "4. Check Tunnel Status"
        echo "5. Manage Tunnel Service"
        echo "6. Setup Anti-Filter"
        echo "7. Remove Anti-Filter"
        echo "8. Remove Tunnel"
        echo "9. Exit"

        read -r -p "Choose an option: " choice
        case "$choice" in
            1) configure_tunnel ;;
            2) check_remote ;;
            3) install_scripts ;;
            4) check_tunnel_status ;;
            5) manage_tunnel_service ;;
            6) setup_antifilter ;;
            7) remove_antifilter ;;
            8) remove_tunnel ;;
            9) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

require_root
ensure_base_dirs
show_menu
