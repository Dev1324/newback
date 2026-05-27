#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="v1.0.1-personal"
CORE_NAME="backhaul_premium"
INSTALL_DIR="/root/backhaul-core"
SERVICE_DIR="/etc/systemd/system"

CORE_URL="https://raw.githubusercontent.com/Dev1324/newback/main/backhaul_premium"
SCRIPT_URL="https://raw.githubusercontent.com/Dev1324/newback/main/main.sh"

DEFAULT_TOKEN="e4d083d48ad8be4b962e48a7386fa6b5931f07250be4335a1837df3bca9cd062"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED}Run as root.${NC}"
    exit 1
  fi
}

pause() {
  read -rp "Press Enter to continue..."
}

msg() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
err() { echo -e "${RED}$*${NC}"; }
info() { echo -e "${CYAN}$*${NC}"; }

ensure_deps() {
  apt update -y
  apt install -y curl wget tar unzip jq nano net-tools iproute2 openssl
}

install_core_from_github() {
  mkdir -p "$INSTALL_DIR"

  info "Downloading backhaul_premium from GitHub..."

  if curl -fL --retry 3 --connect-timeout 15 \
    -o "$INSTALL_DIR/$CORE_NAME" \
    "$CORE_URL"; then

    chmod +x "$INSTALL_DIR/$CORE_NAME"
    msg "Core installed: $INSTALL_DIR/$CORE_NAME"
  else
    err "Failed to download core:"
    err "$CORE_URL"
    return 1
  fi

  "$INSTALL_DIR/$CORE_NAME" -v || true
}

update_menu_script() {
  info "Updating menu command..."

  if curl -fL --retry 3 --connect-timeout 15 \
    -o /usr/bin/backhaul \
    "$SCRIPT_URL"; then

    chmod +x /usr/bin/backhaul
    msg "Menu updated. Run: backhaul"
  else
    err "Failed to download menu script:"
    err "$SCRIPT_URL"
    return 1
  fi
}

core_ready_or_install() {
  if [[ ! -x "$INSTALL_DIR/$CORE_NAME" ]]; then
    warn "Core not found. Installing now..."
    install_core_from_github
  fi
}

check_port() {
  local port="$1"
  ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
}

write_service() {
  local name="$1"
  local config="$2"
  local service_path="$SERVICE_DIR/${name}.service"

  cat > "$service_path" <<EOF
[Unit]
Description=Personal Backhaul Tunnel - ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${CORE_NAME} -c ${config}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$name.service"
  msg "Service enabled and started: $name.service"
}

restart_service() {
  local name="$1"
  systemctl restart "$name.service"
  msg "Restarted: $name.service"
}

show_logs() {
  local name="$1"
  journalctl -u "$name.service" -f
}

show_status() {
  local name="$1"
  systemctl status "$name.service" --no-pager
}

remove_tunnel() {
  local name="$1"
  local config="$2"

  systemctl disable --now "$name.service" 2>/dev/null || true
  rm -f "$SERVICE_DIR/${name}.service"
  rm -f "$config"
  systemctl daemon-reload

  msg "Removed: $name"
}

create_iran() {
  clear
  info "IRAN server config"
  echo "This side accepts users on public ports and waits for Kharej client."
  echo

  core_ready_or_install

  local tunnel_port transport token nodelay heartbeat channel_size ports web_port sniffer proxy_protocol accept_udp

  read -rp "Tunnel port [3080]: " tunnel_port
  tunnel_port="${tunnel_port:-3080}"

  if check_port "$tunnel_port"; then
    err "Port $tunnel_port is already in use."
    pause
    return 1
  fi

  read -rp "Transport tcp/tcpmux/ws/wsmux/udp [tcp]: " transport
  transport="${transport:-tcp}"

  read -rp "Security token [default]: " token
  token="${token:-$DEFAULT_TOKEN}"

  read -rp "TCP_NODELAY true/false [true]: " nodelay
  nodelay="${nodelay:-true}"

  read -rp "Heartbeat seconds [30]: " heartbeat
  heartbeat="${heartbeat:-30}"

  read -rp "Channel size [2048]: " channel_size
  channel_size="${channel_size:-2048}"

  read -rp "Sniffer true/false [false]: " sniffer
  sniffer="${sniffer:-false}"

  read -rp "Web panel port, 0 disabled [0]: " web_port
  web_port="${web_port:-0}"

  read -rp "Proxy Protocol true/false [false]: " proxy_protocol
  proxy_protocol="${proxy_protocol:-false}"

  if [[ "$transport" == "tcp" ]]; then
    read -rp "Accept UDP over TCP true/false [false]: " accept_udp
    accept_udp="${accept_udp:-false}"
  else
    accept_udp="false"
  fi

  echo
  warn "Port mapping examples:"
  echo "  6000                 listen on Iran:6000 and forward to Kharej:6000"
  echo "  6000=6000            same"
  echo "  6000=127.0.0.1:6000  forward to specific remote target"
  echo "  443-600              range"
  echo
  read -rp "Ports/mappings separated by comma [6000]: " ports
  ports="${ports:-6000}"

  local cfg="$INSTALL_DIR/iran${tunnel_port}.toml"
  mkdir -p "$INSTALL_DIR"

  cat > "$cfg" <<EOF
[server]
bind_addr = ":${tunnel_port}"
transport = "${transport}"
accept_udp = ${accept_udp}
token = "${token}"
keepalive_period = 75
nodelay = ${nodelay}
channel_size = ${channel_size}
heartbeat = ${heartbeat}
mux_con = 8
mux_version = 2
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 2000000
sniffer = ${sniffer}
web_port = ${web_port}
sniffer_log = "/root/log.json"
log_level = "info"
proxy_protocol = ${proxy_protocol}

ports = [
EOF

  IFS=',' read -ra arr <<< "${ports// /}"
  for p in "${arr[@]}"; do
    [[ -n "$p" ]] && echo "    \"$p\"," >> "$cfg"
  done

  echo "]" >> "$cfg"

  local service="backhaul-iran${tunnel_port}"
  write_service "$service" "$cfg"

  echo
  msg "Iran config: $cfg"
  msg "Tunnel port: $tunnel_port"
  msg "Public/user ports: $ports"
}

create_kharej() {
  clear
  info "KHAREJ server config"
  echo "This side connects to Iran and forwards to local Xray/Sanaei."
  echo

  core_ready_or_install

  local server_addr tunnel_port transport token nodelay pool sniffer web_port ip_limit edge_ip

  read -rp "Iran server IP/domain: " server_addr
  if [[ -z "$server_addr" ]]; then
    err "Iran address cannot be empty."
    pause
    return 1
  fi

  read -rp "Tunnel port on Iran [3080]: " tunnel_port
  tunnel_port="${tunnel_port:-3080}"

  read -rp "Transport tcp/tcpmux/ws/wsmux/udp [tcp]: " transport
  transport="${transport:-tcp}"

  if [[ "$transport" =~ ^(ws|wsmux|uwsmux)$ ]]; then
    read -rp "Edge IP/domain optional, empty disabled: " edge_ip
  else
    edge_ip=""
  fi

  read -rp "Security token [default]: " token
  token="${token:-$DEFAULT_TOKEN}"

  read -rp "TCP_NODELAY true/false [true]: " nodelay
  nodelay="${nodelay:-true}"

  read -rp "Connection pool [8]: " pool
  pool="${pool:-8}"

  read -rp "Sniffer true/false [false]: " sniffer
  sniffer="${sniffer:-false}"

  read -rp "Web panel port, 0 disabled [0]: " web_port
  web_port="${web_port:-0}"

  read -rp "IP limit for X-UI true/false [false]: " ip_limit
  ip_limit="${ip_limit:-false}"

  local cfg="$INSTALL_DIR/kharej${tunnel_port}.toml"
  mkdir -p "$INSTALL_DIR"

  cat > "$cfg" <<EOF
[client]
remote_addr = "${server_addr}:${tunnel_port}"
transport = "${transport}"
token = "${token}"
connection_pool = ${pool}
aggressive_pool = false
keepalive_period = 75
nodelay = ${nodelay}
retry_interval = 3
dial_timeout = 10
mux_version = 2
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 2000000
sniffer = ${sniffer}
web_port = ${web_port}
sniffer_log = "/root/log.json"
log_level = "info"
ip_limit = ${ip_limit}
EOF

  if [[ -n "$edge_ip" ]]; then
    echo "edge_ip = \"${edge_ip}\"" >> "$cfg"
  fi

  local service="backhaul-kharej${tunnel_port}"
  write_service "$service" "$cfg"

  echo
  msg "Kharej config: $cfg"
  msg "Connects to: ${server_addr}:${tunnel_port}"
}

list_tunnels() {
  clear
  info "Existing Backhaul tunnels"
  echo

  shopt -s nullglob
  local files=("$INSTALL_DIR"/iran*.toml "$INSTALL_DIR"/kharej*.toml)

  if (( ${#files[@]} == 0 )); then
    warn "No config files found in $INSTALL_DIR"
    pause
    return 1
  fi

  local i=1
  for f in "${files[@]}"; do
    local base service state
    base="$(basename "$f" .toml)"
    service="backhaul-${base}"

    if systemctl is-active --quiet "$service.service"; then
      state="running"
    else
      state="stopped"
    fi

    echo "[$i] $base | $state | $f"
    ((i++))
  done

  echo
}

manage_tunnels() {
  shopt -s nullglob
  local files=("$INSTALL_DIR"/iran*.toml "$INSTALL_DIR"/kharej*.toml)

  if (( ${#files[@]} == 0 )); then
    warn "No tunnels found."
    pause
    return
  fi

  list_tunnels

  read -rp "Select tunnel number, 0 back: " idx
  [[ "$idx" == "0" ]] && return

  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#files[@]} )); then
    err "Invalid choice."
    pause
    return
  fi

  local cfg="${files[$((idx-1))]}"
  local base
  base="$(basename "$cfg" .toml)"

  local service="backhaul-${base}"

  clear
  info "Manage: $service"
  echo "1) Restart"
  echo "2) Stop"
  echo "3) Start"
  echo "4) Logs"
  echo "5) Status"
  echo "6) Edit config"
  echo "7) Remove tunnel"
  echo "0) Back"
  echo

  read -rp "Choice: " c

  case "$c" in
    1) restart_service "$service"; pause ;;
    2) systemctl stop "$service.service"; msg "Stopped"; pause ;;
    3) systemctl start "$service.service"; msg "Started"; pause ;;
    4) show_logs "$service" ;;
    5) show_status "$service"; pause ;;
    6) nano "$cfg"; restart_service "$service"; pause ;;
    7) remove_tunnel "$service" "$cfg"; pause ;;
    0) return ;;
    *) err "Invalid choice"; pause ;;
  esac
}

optimize_system() {
  cp /etc/sysctl.conf "/etc/sysctl.conf.bak.$(date +%s)"

  cat > /etc/sysctl.d/99-backhaul-personal.conf <<'EOF'
fs.file-max = 67108864
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65536
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.ipv4.tcp_rmem = 4096 87380 268435456
net.ipv4.tcp_wmem = 4096 65536 268435456
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOF

  sysctl --system

  mkdir -p /etc/systemd/system.conf.d

  cat > /etc/systemd/system.conf.d/99-backhaul-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

  msg "Network/system limits optimized. Reboot recommended."
  pause
}

show_info() {
  clear
  echo -e "${MAGENTA}Personal Backhaul Manager ${SCRIPT_VERSION}${NC}"
  echo "Install dir: $INSTALL_DIR"
  echo "Core: $INSTALL_DIR/$CORE_NAME"
  echo

  if [[ -x "$INSTALL_DIR/$CORE_NAME" ]]; then
    "$INSTALL_DIR/$CORE_NAME" -v || true
  else
    warn "Core not installed."
  fi

  echo
  ss -lntup | grep -E 'backhaul|6000|3080|3081|4080' || true
  echo
  pause
}

menu() {
  while true; do
    clear
    echo -e "${CYAN}========== Personal Backhaul Manager ==========${NC}"
    echo "1) Install/update core from GitHub"
    echo "2) Configure IRAN server"
    echo "3) Configure KHAREJ server"
    echo "4) Manage tunnels"
    echo "5) Show info / listening ports"
    echo "6) Optimize network"
    echo "7) Update menu script"
    echo "0) Exit"
    echo

    read -rp "Choice: " choice

    case "$choice" in
      1) ensure_deps; install_core_from_github; pause ;;
      2) create_iran; pause ;;
      3) create_kharej; pause ;;
      4) manage_tunnels ;;
      5) show_info ;;
      6) optimize_system ;;
      7) ensure_deps; update_menu_script; pause ;;
      0) exit 0 ;;
      *) err "Invalid choice"; sleep 1 ;;
    esac
  done
}

need_root
menu
