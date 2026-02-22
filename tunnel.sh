#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

CONFIG_FILE="/etc/fou_tunnel_config"
SERVICE_FILE="/etc/systemd/system/fou-tunnel.service"
RUNNER_FILE="/usr/local/sbin/fou-tunnel-runner.sh"
IPSEC_CONN_FILE="/etc/ipsec.d/fou-tunnel.conf"
IPSEC_SECRET_FILE="/etc/ipsec.d/fou-tunnel.secrets"
IPSEC_MAIN_CONF="/etc/ipsec.conf"
IPSEC_MAIN_SECRETS="/etc/ipsec.secrets"
TCP_PORTS="443"
BBR_SCRIPT_URL="https://raw.githubusercontent.com/teddysun/across/ac11f0d4c51e82b9d6b119e19601232c63a62d2d/bbr.sh"
BBR_SCRIPT_SHA256="17f447d78ba82468727e97cfdaa2a18150840a4c00c207592e5329df36544e85"
TCP_SCRIPT_URL="https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/351f4c53e5153c511de4e737ff54e35c73abb1a5/tcp.sh"
TCP_SCRIPT_SHA256="427b7e97c25404dfde248549975474f84ca7d50f38319744a05a0fb2bf37afcb"

REMOTE_TUNNEL_IP=""

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
    local value normalized

    while true; do
        read -r -p "Enter forwarding port(s) (e.g., 443 or 201,443): " value
        if normalize_ports "$value" normalized; then
            TCP_PORTS="$normalized"
            return
        fi
        echo "Invalid ports. Use 1-65535, comma-separated."
    done
}

save_config() {
    local psk_b64
    local old_umask

    psk_b64="$(printf '%s' "$IPSEC_PSK" | base64 | tr -d '\n')"

    old_umask="$(umask)"
    umask 077

    cat > "$CONFIG_FILE" <<EOC
LOCAL_IP=$LOCAL_IP
REMOTE_IP=$REMOTE_IP
LOCAL_TUNNEL_IP=$LOCAL_TUNNEL_IP
REMOTE_TUNNEL_IP=$REMOTE_TUNNEL_IP
TCP_PORTS=$TCP_PORTS
IPSEC_PSK_B64=$psk_b64
EOC

    chmod 600 "$CONFIG_FILE"
    umask "$old_umask"
}

load_config() {
    local line key value
    local psk_b64=""

    [ -f "$CONFIG_FILE" ] || return 1

    LOCAL_IP=""
    REMOTE_IP=""
    LOCAL_TUNNEL_IP=""
    REMOTE_TUNNEL_IP=""
    TCP_PORTS="443"
    IPSEC_PSK=""

    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            LOCAL_IP) LOCAL_IP="$value" ;;
            REMOTE_IP) REMOTE_IP="$value" ;;
            LOCAL_TUNNEL_IP) LOCAL_TUNNEL_IP="$value" ;;
            REMOTE_TUNNEL_IP) REMOTE_TUNNEL_IP="$value" ;;
            TCP_PORTS) TCP_PORTS="$value" ;;
            IPSEC_PSK_B64) psk_b64="$value" ;;
        esac
    done < "$CONFIG_FILE"

    if [ -n "$psk_b64" ]; then
        if ! IPSEC_PSK="$(printf '%s' "$psk_b64" | base64 -d 2>/dev/null)"; then
            echo "Failed to decode IPSec PSK from config."
            return 1
        fi
    fi

    validate_ipv4 "$LOCAL_IP" || return 1
    validate_ipv4 "$REMOTE_IP" || return 1
    validate_ipv4 "$LOCAL_TUNNEL_IP" || return 1
    validate_ipv4 "$REMOTE_TUNNEL_IP" || return 1
    normalize_ports "$TCP_PORTS" TCP_PORTS || return 1
    validate_psk "$IPSEC_PSK" || return 1

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

    if ! systemctl list-unit-files --type=service | grep -qE '^strongswan(\.service)?|^strongswan-starter\.service'; then
        packages+=("strongswan" "strongswan-pki")
    fi

    if [ "${#packages[@]}" -gt 0 ]; then
        echo "Installing required packages: ${packages[*]}"
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
    if systemctl list-unit-files --type=service | grep -q '^strongswan\.service'; then
        echo "strongswan"
        return
    fi
    if systemctl list-unit-files --type=service | grep -q '^strongswan-starter\.service'; then
        echo "strongswan-starter"
        return
    fi
    echo ""
}

configure_ipsec() {
    local ipsec_service
    local old_umask

    mkdir -p /etc/ipsec.d

    cat > "$IPSEC_CONN_FILE" <<EOC
conn fou-tunnel
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
TCP_PORTS="$TCP_PORTS"

create_gre() {
    modprobe ip_gre

    if ip link show gre1 >/dev/null 2>&1; then
        ip link set gre1 down >/dev/null 2>&1 || true
        ip link del gre1 >/dev/null 2>&1 || true
    fi

    ip link add gre1 type gre remote "\$REMOTE_IP" local "\$LOCAL_IP" ttl 255
    ip addr add "\${LOCAL_TUNNEL_IP}/24" dev gre1
    ip link set gre1 mtu 1300
    ip link set gre1 up
    ip route replace "\${REMOTE_TUNNEL_IP}/32" dev gre1
}

run_socat() {
    local -a ports pids
    local port pid

    IFS=',' read -r -a ports <<< "\$TCP_PORTS"
    if [ "\${#ports[@]}" -eq 0 ]; then
        echo "No forwarding ports configured."
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

    for port in "\${ports[@]}"; do
        socat "TCP-LISTEN:\${port},fork,reuseaddr" "TUN:gre1,up" &
        pids+=("\$!")
    done

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
        if ip link show gre1 >/dev/null 2>&1; then
            ip link set gre1 down >/dev/null 2>&1 || true
            ip link del gre1 >/dev/null 2>&1 || true
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
Description=FOU Tunnel Runtime
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
    systemctl enable fou-tunnel.service
    systemctl restart fou-tunnel.service
}

prompt_for_config() {
    read_ipv4_value "Enter local IP address: " LOCAL_IP
    read_ipv4_value "Enter remote IP address: " REMOTE_IP
    read_ipv4_value "Enter local tunnel IP (e.g., 30.30.30.2): " LOCAL_TUNNEL_IP
    read_ipv4_value "Enter remote tunnel IP (e.g., 30.30.30.1): " REMOTE_TUNNEL_IP
    read_port_list_value
    read_psk_value
}

configure_tunnel() {
    local reuse

    if [ -f "$CONFIG_FILE" ]; then
        echo "Existing config found at $CONFIG_FILE"
        read -r -p "Reuse existing config? (y/n): " reuse
        if [[ "$reuse" =~ ^[Yy]$ ]]; then
            if ! load_config; then
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

    echo "Configuration applied."
    pause_screen
}

check_remote() {
    if ! load_config; then
        echo "Configuration file is missing or invalid. Configure the tunnel first."
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
    if ! load_config; then
        echo "Configuration file is missing or invalid. Configure the tunnel first."
        pause_screen
        return
    fi

    if ping -c 4 "$REMOTE_TUNNEL_IP" >/dev/null 2>&1; then
        echo "Tunnel endpoint $REMOTE_TUNNEL_IP is reachable."
    else
        echo "Tunnel endpoint $REMOTE_TUNNEL_IP is not reachable."
    fi

    pause_screen
}

remove_tunnel() {
    local confirm ipsec_service

    read -r -p "Remove this tunnel configuration? (y/n): " confirm
    if [[ ! "$confirm" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
        echo "Tunnel removal cancelled."
        pause_screen
        return
    fi

    systemctl stop fou-tunnel.service >/dev/null 2>&1 || true
    systemctl disable fou-tunnel.service >/dev/null 2>&1 || true

    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi

    if [ -f "$RUNNER_FILE" ]; then
        "$RUNNER_FILE" stop-gre >/dev/null 2>&1 || true
        rm -f "$RUNNER_FILE"
    fi

    if ip link show gre1 >/dev/null 2>&1; then
        ip link set gre1 down >/dev/null 2>&1 || true
        ip link del gre1 >/dev/null 2>&1 || true
    fi

    rm -f "$IPSEC_CONN_FILE"
    rm -f "$IPSEC_SECRET_FILE"

    remove_line_from_file "include $IPSEC_CONN_FILE" "$IPSEC_MAIN_CONF"
    remove_line_from_file "include $IPSEC_SECRET_FILE" "$IPSEC_MAIN_SECRETS"

    ipsec_service="$(get_ipsec_service_name)"
    if [ -n "$ipsec_service" ]; then
        systemctl restart "$ipsec_service" || true
    fi

    rm -f "$CONFIG_FILE"

    echo "Tunnel removed."
    pause_screen
}

show_menu() {
    while true; do
        clear
        echo "GRE over IPSec Tunnel"
        echo "1. Configure Tunnel"
        echo "2. Check Remote Connection"
        echo "3. Install bbr.sh and tcp.sh"
        echo "4. Check Tunnel Status"
        echo "5. Remove Tunnel"
        echo "6. Exit"

        read -r -p "Choose an option: " choice
        case "$choice" in
            1) configure_tunnel ;;
            2) check_remote ;;
            3) install_scripts ;;
            4) check_tunnel_status ;;
            5) remove_tunnel ;;
            6) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

require_root
show_menu
