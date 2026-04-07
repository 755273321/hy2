#!/bin/bash
set -e

# 脚本自身真实路径。支持 bash <(curl ...)：此时 BASH_SOURCE 为 /dev/fd/N，无法作为持久路径 cp，需先落盘
case "${BASH_SOURCE[0]:-$0}" in
  /dev/fd/* | /proc/self/fd/* | /proc/[0-9]*/fd/[0-9]*)
    _SB_SRC="${BASH_SOURCE[0]}"
    SCRIPT_FILE="$(mktemp /tmp/sing-box-bootstrap.XXXXXX.sh)"
    cat "$_SB_SRC" >"$SCRIPT_FILE"
    chmod 700 "$SCRIPT_FILE"
    unset _SB_SRC
    ;;
  *)
    _SB_SRC="${BASH_SOURCE[0]}"
    SCRIPT_FILE="$(cd "$(dirname "$_SB_SRC")" && pwd)/$(basename "$_SB_SRC")"
    unset _SB_SRC
    ;;
esac

INSTALL_DIR="/usr/local/sing-box"
BIN_REAL="$INSTALL_DIR/sing-box-bin"
# 菜单/子命令入口（原 sing-box 易与真二进制混淆，改为 sb；SB 为同文件符号链接便于大小写）
BIN_WRAPPER="/usr/local/bin/sb"
BIN_WRAPPER_UPPER="/usr/local/bin/SB"
MANAGER="$INSTALL_DIR/sing-box-manager.sh"
CONFIG_FILE="$INSTALL_DIR/config.json"
STATE_FILE="$INSTALL_DIR/state.env"
CERT_DIR="$INSTALL_DIR/certs"

SERVICE_FILE="/etc/systemd/system/sing-box.service"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "请用 root 运行（例如：sudo bash $0）"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 缺少 curl / tar 时按发行版自动安装（需 root）
try_install_curl_tar() {
  require_root
  local need=0
  have_cmd curl || need=1
  have_cmd tar || need=1
  ((need)) || return 0

  echo "===> 未检测到 curl 或 tar，正在按系统尝试自动安装..."
  if have_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y curl tar gzip
  elif have_cmd dnf; then
    dnf install -y curl tar gzip
  elif have_cmd yum; then
    yum install -y curl tar gzip
  elif have_cmd apk; then
    apk add --no-cache curl tar gzip
  elif have_cmd zypper; then
    zypper --non-interactive install -y curl tar gzip
  elif have_cmd pacman; then
    pacman -Sy --noconfirm curl tar gzip
  elif have_cmd opkg; then
    opkg update
    opkg install curl tar gzip
  elif have_cmd emerge; then
    emerge -qv net-misc/curl app-arch/tar app-arch/gzip
  else
    echo "无法识别本机包管理器（未找到 apt-get/dnf/yum/apk/zypper/pacman/opkg/emerge）。"
    echo "请手动安装: curl tar gzip（解压 .tar.gz 需要 gzip）"
    exit 1
  fi

  if ! have_cmd curl || ! have_cmd tar; then
    echo "自动安装后仍缺少 curl 或 tar，请手动安装。"
    exit 1
  fi
  echo "curl / tar 已就绪。"
}

ensure_deps() {
  if ! have_cmd curl || ! have_cmd tar; then
    try_install_curl_tar
  fi
  echo "===> 检查依赖 (curl / tar 解压)..."
  if ! curl --version >/dev/null 2>&1; then
    echo "curl 无法执行，请检查 PATH 与安装是否完整。"
    exit 1
  fi
  local _td
  _td="$(mktemp -d)"
  echo "sb-tar-test" >"$_td/t"
  if ! (cd "$_td" && tar -czf "$_td/a.tar.gz" t); then
    echo "tar 无法创建 gzip 压缩包，请确认 tar 支持 -z（gzip）。"
    rm -rf "$_td"
    exit 1
  fi
  mkdir -p "$_td/out"
  if ! tar -xzf "$_td/a.tar.gz" -C "$_td/out"; then
    echo "tar 无法解压 .tar.gz，请检查 tar/gzip 是否可用。"
    rm -rf "$_td"
    exit 1
  fi
  if [[ ! -f "$_td/out/t" ]] || [[ "$(cat "$_td/out/t")" != "sb-tar-test" ]]; then
    echo "tar 解压结果异常。"
    rm -rf "$_td"
    exit 1
  fi
  rm -rf "$_td"
  echo "依赖检查通过。"
}

# 仅在下载 sing-box 前调用：确认能连 GitHub
ensure_curl_github_ok() {
  echo "===> 检测 curl 能否访问 GitHub（下载需要）..."
  if ! curl -fsSLI --connect-timeout 8 --max-time 30 -o /dev/null "https://github.com" 2>/dev/null; then
    echo "curl 无法访问 https://github.com，请检查网络、DNS、代理或防火墙。"
    exit 1
  fi
  echo "GitHub 连通性正常。"
}

# 卸载此前用「独立 apernet Hysteria2 + ~/hy3」类脚本安装的旧服务，避免与 sing-box 抢端口（如 12341）
remove_legacy_apernet_hysteria() {
  local had=0
  [[ -f /etc/systemd/system/hysteria.service ]] && had=1
  [[ -d /root/hy3 ]] && had=1
  [[ -x /bin/hy2 ]] && had=1
  if have_cmd systemctl; then
    systemctl is-active --quiet hysteria.service 2>/dev/null && had=1
    systemctl is-active --quiet ipppp.service 2>/dev/null && had=1
  fi
  ((had)) || return 0

  echo "===> 检测到旧版独立 Hysteria2（apernet/hy3）残留，正在清理..."
  systemctl stop hysteria.service 2>/dev/null || true
  systemctl disable hysteria.service 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria.service 2>/dev/null || true
  if have_cmd pkill; then
    pkill -f 'hysteria-linux' 2>/dev/null || true
  fi
  rm -rf /root/hy3 2>/dev/null || true
  rm -rf "${HOME}/hy3" 2>/dev/null || true
  if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}/hy3" ]]; then
    rm -rf "/home/${SUDO_USER}/hy3" 2>/dev/null || true
  fi
  systemctl stop ipppp.service 2>/dev/null || true
  systemctl disable ipppp.service 2>/dev/null || true
  rm -f /etc/systemd/system/ipppp.service 2>/dev/null || true
  rm -f /bin/hy2 2>/dev/null || true
  # 旧脚本常用 bing.com 自签路径（与 sing-box 证书目录无关）
  rm -f /etc/ssl/private/bing.com.crt /etc/ssl/private/bing.com.key 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  echo "旧版 Hysteria2 已清理。"
}

# 卸载此前用「apt install dante-server + /etc/danted.conf」脚本装的独立 SOCKS5，避免与 sing-box SOCKS 并存
remove_legacy_dante_socks() {
  local had=0
  [[ -f /etc/danted.conf ]] && had=1
  [[ -f /root/socks.sh ]] && had=1
  if have_cmd systemctl; then
    systemctl is-active --quiet danted.service 2>/dev/null && had=1
  fi
  ((had)) || return 0

  echo "===> 检测到旧版 Dante SOCKS（danted）残留，正在清理..."
  systemctl stop danted.service 2>/dev/null || true
  systemctl disable danted.service 2>/dev/null || true
  if have_cmd pkill; then
    pkill -x danted 2>/dev/null || true
  fi
  rm -f /etc/danted.conf /etc/danted.conf.bak 2>/dev/null || true
  rm -f /root/socks.sh 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  if have_cmd apt-get && have_cmd dpkg && dpkg -l dante-server 2>/dev/null | grep -q '^ii'; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get remove -y --purge dante-server 2>/dev/null || true
  elif have_cmd rpm && rpm -q dante-server 2>/dev/null | grep -q dante-server; then
    if have_cmd dnf; then
      dnf remove -y dante-server 2>/dev/null || true
    elif have_cmd yum; then
      yum remove -y dante-server 2>/dev/null || true
    fi
  fi
  echo "Dante SOCKS 已清理。（脚本创建的 Linux 用户如 huise123 不会自动删除，不需要可手动 userdel）"
}

remove_legacy_third_party_proxies() {
  remove_legacy_apernet_hysteria
  remove_legacy_dante_socks
}

load_state() {
  ENABLE_HY2=0
  ENABLE_REALITY=0
  ENABLE_SOCKS=0
  HY2_PORT=12341
  HY2_SNI=intel.com
  REALITY_PORT=12343
  REALITY_SNI=intel.com
  REALITY_HS_SERVER=intel.com
  REALITY_HS_PORT=443
  SOCKS_PORT=12342
  SOCKS_USER=huise
  SOCKS_PASS=huise123
  [[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || true
}

save_state() {
  umask 077
  cat >"$STATE_FILE" <<EOF
ENABLE_HY2=${ENABLE_HY2:-0}
ENABLE_REALITY=${ENABLE_REALITY:-0}
ENABLE_SOCKS=${ENABLE_SOCKS:-0}
HY2_PORT=${HY2_PORT:-12341}
HY2_SNI=$(printf '%q' "${HY2_SNI:-intel.com}")
REALITY_PORT=${REALITY_PORT:-12343}
REALITY_SNI=$(printf '%q' "${REALITY_SNI:-intel.com}")
REALITY_HS_SERVER=$(printf '%q' "${REALITY_HS_SERVER:-intel.com}")
REALITY_HS_PORT=${REALITY_HS_PORT:-443}
SOCKS_PORT=${SOCKS_PORT:-12342}
SOCKS_USER=$(printf '%q' "${SOCKS_USER:-huise}")
SOCKS_PASS=$(printf '%q' "${SOCKS_PASS:-huise123}")
EOF
}

sanitize_name() {
  echo "$1" | tr -cd 'a-zA-Z0-9._-' | head -c 200
}

read_port() {
  local prompt="$1" default="$2" var_name="$3"
  local input
  while true; do
    read -r -p "$prompt [默认 $default]: " input
    if [[ -z "${input// }" ]]; then
      printf -v "$var_name" '%s' "$default"
      break
    fi
    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 65535 )); then
      printf -v "$var_name" '%s' "$input"
      break
    fi
    echo "请输入 1-65535 之间的数字端口。"
  done
}

read_str() {
  local prompt="$1" default="$2" var_name="$3"
  local input
  read -r -p "$prompt [默认 $default]: " input
  if [[ -z "${input// }" ]]; then
    printf -v "$var_name" '%s' "$default"
  else
    printf -v "$var_name" '%s' "$input"
  fi
}

is_installed() {
  [[ -x "$BIN_REAL" ]] && [[ -f "$SERVICE_FILE" ]]
}

random_hex() {
  local nbytes="$1"
  if have_cmd openssl; then
    openssl rand -hex "$nbytes"
  else
    # fallback: not cryptographically strong, but avoids hard failure
    hexdump -vn "$nbytes" -e '1/1 "%02x"' /dev/urandom
  fi
}

gen_uuid() {
  if have_cmd "$BIN_REAL"; then
    "$BIN_REAL" generate uuid
  elif have_cmd uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    # fallback pseudo-uuid
    printf "%s-%s-%s-%s-%s\n" \
      "$(random_hex 4)" "$(random_hex 2)" "$(random_hex 2)" "$(random_hex 2)" "$(random_hex 6)"
  fi
}

ensure_wrapper() {
  mkdir -p "$INSTALL_DIR"
  # bash <(curl ...)：SCRIPT_FILE 可能仍为 /dev/fd/N，或开头落盘未执行（旧版脚本）；在此从 BASH_SOURCE 再落盘一次
  local _need=0
  case "$SCRIPT_FILE" in
    /dev/fd/* | /proc/self/fd/* | /proc/*/fd/*)
      _need=1
      ;;
  esac
  [[ ! -f "$SCRIPT_FILE" ]] && _need=1
  if ((_need)); then
    local _bs="${BASH_SOURCE[0]:-$0}"
    if [[ -r "$_bs" ]]; then
      SCRIPT_FILE="$(mktemp /tmp/sing-box-bootstrap.XXXXXX.sh)"
      cat "$_bs" >"$SCRIPT_FILE"
      chmod 700 "$SCRIPT_FILE"
    fi
  fi
  if [[ ! -f "$SCRIPT_FILE" ]]; then
    echo "无法定位脚本文件: $SCRIPT_FILE"
    echo "建议: curl -fsSL <URL> -o sing-box.sh && bash sing-box.sh ..."
    exit 1
  fi
  # 从已安装的 sing-box-manager.sh 运行时 SCRIPT_FILE 与 MANAGER 为同一路径，勿 cp
  local _src _dst
  _src="$(readlink -f "$SCRIPT_FILE" 2>/dev/null || echo "$SCRIPT_FILE")"
  _dst="$(readlink -f "$MANAGER" 2>/dev/null || echo "$MANAGER")"
  if [[ "$_src" != "$_dst" ]]; then
    cp -f "$SCRIPT_FILE" "$MANAGER"
  fi
  chmod +x "$MANAGER"

  cat >"$BIN_WRAPPER" <<EOF
#!/bin/bash
set -e
REAL="$BIN_REAL"
MANAGER="$MANAGER"

if [[ "\$#" -eq 0 ]]; then
  exec "\$MANAGER" menu
fi

if [[ "\$1" == "menu" ]]; then
  shift
  exec "\$MANAGER" menu "\$@"
fi

if [[ "\$1" == "all" ]]; then
  shift
  exec "\$MANAGER" all "\$@"
fi

if [[ "\$1" == "install-all" ]]; then
  shift
  exec "\$MANAGER" install-all "\$@"
fi

if [[ -x "\$REAL" ]]; then
  exec "\$REAL" "\$@"
fi

echo "未找到 sing-box 程序：\$REAL"
echo "请先运行：sudo sb install-core   或   sudo bash \$MANAGER install-core"
exit 1
EOF
  chmod +x "$BIN_WRAPPER"
  ln -sf "$BIN_WRAPPER" "$BIN_WRAPPER_UPPER"
  # 部分环境 PATH 不含 /usr/local/bin，额外链到 /usr/bin 便于直接打 sb
  ln -sf "$BIN_WRAPPER" /usr/bin/sb 2>/dev/null || true
  ln -sf "$BIN_WRAPPER" /usr/bin/SB 2>/dev/null || true
  rm -f /usr/local/bin/sing-box
}

download_core() {
  # install_core 已调用 ensure_deps；此处仅检测访问 GitHub（下载前）
  ensure_curl_github_ok
  echo "===> 获取最新版本"
  local latest version arch file url
  latest="$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f 4)"
  version="${latest#v}"
  arch="$(uname -m)"

  if [[ "$arch" == "x86_64" ]]; then
    file="sing-box-${version}-linux-amd64.tar.gz"
  elif [[ "$arch" == "aarch64" ]]; then
    file="sing-box-${version}-linux-arm64.tar.gz"
  else
    echo "不支持架构: $arch"
    exit 1
  fi

  echo "===> 下载 sing-box: $latest"
  url="https://github.com/SagerNet/sing-box/releases/download/${latest}/${file}"
  cd /tmp
  rm -f "$file"
  curl -fL -o "$file" "$url"

  echo "===> 解压并安装"
  # 勿用 rm -rf /tmp/sing-box-*：会误删刚下载的 sing-box-x.y.z-linux-*.tar.gz
  find /tmp -maxdepth 1 -type d -name 'sing-box-*' -exec rm -rf {} + 2>/dev/null || true
  tar -xzf "$file"
  install -m 0755 sing-box-*/sing-box "$BIN_REAL"
}

ensure_systemd() {
  echo "===> 创建/更新 systemd"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box
After=network.target

[Service]
ExecStart=$BIN_REAL run -c $CONFIG_FILE
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
}

restart_service_if_possible() {
  systemctl restart sing-box 2>/dev/null || true
}

stop_disable_service_if_exists() {
  if systemctl list-unit-files | grep -q '^sing-box\.service'; then
    systemctl disable --now sing-box 2>/dev/null || true
  fi
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null || true
}

ensure_self_signed_cert() {
  load_state
  mkdir -p "$CERT_DIR"
  local cn="${HY2_SNI:-intel.com}"
  local base
  base="$(sanitize_name "$cn")"
  [[ -z "$base" ]] && base="server"
  local crt="$CERT_DIR/${base}.crt"
  local key="$CERT_DIR/${base}.key"
  if [[ -f "$crt" && -f "$key" ]]; then
    return 0
  fi
  if ! have_cmd openssl; then
    echo "缺少 openssl，无法生成自签证书。请先安装 openssl。"
    exit 1
  fi
  echo "===> 生成 HY2 自签证书 (CN=$cn)"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -subj "/CN=$cn" \
    -keyout "$key" -out "$crt" >/dev/null 2>&1
}

ensure_reality_keypair() {
  mkdir -p "$INSTALL_DIR"
  local keyfile="$INSTALL_DIR/reality_keypair.txt"
  if [[ -f "$keyfile" ]]; then
    return 0
  fi
  if [[ ! -x "$BIN_REAL" ]]; then
    echo "请先安装 sing-box 核心后再生成 Reality keypair。"
    exit 1
  fi
  echo "===> 生成 Reality keypair"
  "$BIN_REAL" generate reality-keypair >"$keyfile"
}

read_reality_private_key() {
  local keyfile="$INSTALL_DIR/reality_keypair.txt"
  [[ -f "$keyfile" ]] || return 1
  # sing-box 输出为 base64url，含 - _；勿用仅匹配 [A-Za-z0-9+/=] 的正则，否则会截断私钥导致 Reality 完全不可用
  awk '/^PrivateKey:/ { print $2; exit }' "$keyfile"
}

read_reality_public_key() {
  local keyfile="$INSTALL_DIR/reality_keypair.txt"
  [[ -f "$keyfile" ]] || return 1
  awk '/^PublicKey:/ { print $2; exit }' "$keyfile"
}

ensure_ids() {
  mkdir -p "$INSTALL_DIR"
  [[ -f "$INSTALL_DIR/uuid.txt" ]] || gen_uuid >"$INSTALL_DIR/uuid.txt"
  [[ -f "$INSTALL_DIR/short_id.txt" ]] || random_hex 8 >"$INSTALL_DIR/short_id.txt"
}

write_config() {
  load_state
  mkdir -p "$INSTALL_DIR"
  ensure_ids
  if [[ "${ENABLE_HY2:-0}" -eq 1 ]] || [[ "${ENABLE_SOCKS:-0}" -eq 1 ]]; then
    remove_legacy_third_party_proxies
  fi

  local uuid short_id
  uuid="$(cat "$INSTALL_DIR/uuid.txt")"
  short_id="$(cat "$INSTALL_DIR/short_id.txt")"

  local hy2_base hy2_crt hy2_key
  hy2_base="$(sanitize_name "${HY2_SNI:-intel.com}")"
  [[ -z "$hy2_base" ]] && hy2_base="server"
  hy2_crt="$CERT_DIR/${hy2_base}.crt"
  hy2_key="$CERT_DIR/${hy2_base}.key"

  local blocks=() su sp
  if [[ "${ENABLE_HY2:-0}" -eq 1 ]]; then
    ensure_self_signed_cert
    blocks+=("$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "0.0.0.0",
  "listen_port": ${HY2_PORT:-12341},
  "users": [
    { "password": "${uuid}" }
  ],
  "tls": {
    "enabled": true,
    "server_name": "$(printf '%s' "${HY2_SNI:-intel.com}" | sed 's/"/\\"/g')",
    "alpn": [ "h3" ],
    "certificate_path": "${hy2_crt}",
    "key_path": "${hy2_key}"
  }
}
EOF
)")
  fi
  if [[ "${ENABLE_REALITY:-0}" -eq 1 ]]; then
    ensure_reality_keypair
    local reality_priv2
    reality_priv2="$(read_reality_private_key)"
    if [[ -z "$reality_priv2" ]]; then
      echo "Reality 私钥读取失败: $INSTALL_DIR/reality_keypair.txt"
      exit 1
    fi
    local rsni rhs rhp
    rsni="$(printf '%s' "${REALITY_SNI:-intel.com}" | sed 's/"/\\"/g')"
    rhs="$(printf '%s' "${REALITY_HS_SERVER:-intel.com}" | sed 's/"/\\"/g')"
    rhp="${REALITY_HS_PORT:-443}"
    blocks+=("$(cat <<EOF
{
  "type": "vless",
  "tag": "vless-reality-in",
  "listen": "0.0.0.0",
  "listen_port": ${REALITY_PORT:-12343},
  "users": [
    { "uuid": "${uuid}", "flow": "xtls-rprx-vision" }
  ],
  "tls": {
    "enabled": true,
    "server_name": "${rsni}",
    "reality": {
      "enabled": true,
      "handshake": { "server": "${rhs}", "server_port": ${rhp} },
      "private_key": "${reality_priv2}",
      "short_id": [ "${short_id}" ]
    }
  }
}
EOF
)")
  fi
  if [[ "${ENABLE_SOCKS:-0}" -eq 1 ]]; then
    su="$(printf '%s' "${SOCKS_USER:-huise}" | sed 's/"/\\"/g')"
    sp="$(printf '%s' "${SOCKS_PASS:-huise123}" | sed 's/"/\\"/g')"
    blocks+=("$(cat <<EOF
{
  "type": "socks",
  "tag": "socks-in",
  "listen": "0.0.0.0",
  "listen_port": ${SOCKS_PORT:-12342},
  "users": [
    { "username": "${su}", "password": "${sp}" }
  ]
}
EOF
)")
  fi
  # 若未启用任何协议，保留默认 SOCKS，避免空入站导致无法启动
  if ((${#blocks[@]}==0)); then
    su="$(printf '%s' "${SOCKS_USER:-huise}" | sed 's/"/\\"/g')"
    sp="$(printf '%s' "${SOCKS_PASS:-huise123}" | sed 's/"/\\"/g')"
    blocks+=("$(cat <<EOF
{
  "type": "socks",
  "tag": "socks-in",
  "listen": "0.0.0.0",
  "listen_port": ${SOCKS_PORT:-12342},
  "users": [
    { "username": "${su}", "password": "${sp}" }
  ]
}
EOF
)")
  fi

  local json_inbounds="["
  local i
  for i in "${!blocks[@]}"; do
    if [[ "$i" -gt 0 ]]; then json_inbounds+=", "; fi
    json_inbounds+="${blocks[$i]}"
  done
  json_inbounds+="]"

  echo "===> 写配置: $CONFIG_FILE"
  cat >"$CONFIG_FILE" <<EOF
{
  "log": { "level": "info" },
  "inbounds": $json_inbounds,
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  if [[ -x "$BIN_REAL" ]]; then
    echo "===> 校验配置 (sing-box check)"
    if ! "$BIN_REAL" check -c "$CONFIG_FILE"; then
      echo "配置校验失败，请根据上方 sing-box 输出修正 $CONFIG_FILE"
      exit 1
    fi
  fi
}

show_info() {
  load_state
  local ip
  ip="$(curl -fsSL ifconfig.me 2>/dev/null || echo "手动查IP")"
  echo "====== 当前信息 ======"
  echo "IP: $ip"
  echo "核心: $BIN_REAL"
  echo "配置: $CONFIG_FILE"
  echo "状态文件: $STATE_FILE"
  echo "HY2 端口 ${HY2_PORT:-12341} / SNI ${HY2_SNI:-intel.com}: $([[ "${ENABLE_HY2:-0}" -eq 1 ]] && echo "已启用" || echo "未启用")"
  echo "VLESS Reality 端口 ${REALITY_PORT:-12343} / SNI ${REALITY_SNI:-intel.com} / 握手 ${REALITY_HS_SERVER:-intel.com}:${REALITY_HS_PORT:-443}: $([[ "${ENABLE_REALITY:-0}" -eq 1 ]] && echo "已启用" || echo "未启用")"
  if [[ "${ENABLE_SOCKS:-0}" -eq 1 ]]; then
    echo "SOCKS 端口 ${SOCKS_PORT:-12342}: 已启用 (用户 ${SOCKS_USER:-huise} / 密码 ${SOCKS_PASS:-huise123})"
  elif [[ "${ENABLE_HY2:-0}" -eq 0 && "${ENABLE_REALITY:-0}" -eq 0 ]]; then
    echo "SOCKS 端口 ${SOCKS_PORT:-12342}: 默认兜底 (用户 ${SOCKS_USER:-huise} / 密码 ${SOCKS_PASS:-huise123})"
  else
    echo "SOCKS 端口 ${SOCKS_PORT:-12342}: 未启用"
  fi
  if [[ -f "$INSTALL_DIR/uuid.txt" ]]; then
    echo "UUID/密码: $(cat "$INSTALL_DIR/uuid.txt")"
  fi
  if [[ -f "$INSTALL_DIR/short_id.txt" ]]; then
    echo "Reality short_id: $(cat "$INSTALL_DIR/short_id.txt")"
  fi
  if [[ -f "$INSTALL_DIR/reality_keypair.txt" ]]; then
    echo "Reality public_key: $(read_reality_public_key || true)"
  fi
  echo "提示：HY2 客户端需设置 allow_insecure=true（自签证书）。"
}

get_public_ip() {
  curl -fsSL ifconfig.me 2>/dev/null || curl -fsSL api.ipify.org 2>/dev/null || echo "127.0.0.1"
}

socks_should_export() {
  load_state
  [[ "${ENABLE_SOCKS:-0}" -eq 1 ]] && return 0
  [[ "${ENABLE_HY2:-0}" -eq 0 && "${ENABLE_REALITY:-0}" -eq 0 ]] && return 0
  return 1
}

build_vless_share_uri() {
  local uuid="$1" ip="$2" pbk="$3" sid="$4" name="$5" port="${6:-12343}" sni="${7:-intel.com}"
  if have_cmd python3; then
    E_UUID="$uuid" E_IP="$ip" E_PBK="$pbk" E_SID="$sid" E_NAME="$name" E_PORT="$port" E_SNI="$sni" python3 - <<'PY'
import os, urllib.parse
q = urllib.parse.urlencode(
    {
        "flow": "xtls-rprx-vision",
        "security": "reality",
        "pbk": os.environ["E_PBK"],
        "fp": "chrome",
        "sni": os.environ["E_SNI"],
        "sid": os.environ["E_SID"],
        "type": "tcp",
    }
)
u = "vless://{}@{}:{}?{}#{}".format(
    os.environ["E_UUID"],
    os.environ["E_IP"],
    os.environ["E_PORT"],
    q,
    os.environ["E_NAME"],
)
print(u, end="")
PY
    return
  fi
  echo "vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&security=reality&pbk=${pbk}&fp=chrome&sni=${sni}&sid=${sid}&type=tcp#${name}"
}

# 仅输出分享链接行（供 export_share_links / export_all_nodes 复用）
_emit_share_links_uris() {
  load_state
  local ip uuid short_id pbk
  ip="$(get_public_ip)"
  uuid="$(cat "$INSTALL_DIR/uuid.txt")"
  short_id="$(cat "$INSTALL_DIR/short_id.txt")"
  local name_vless="sing-box-vless" name_hy2="sing-box-hy2" name_socks="sing-box-socks"
  local rp rsni hp
  rp="${REALITY_PORT:-12343}"
  rsni="${REALITY_SNI:-intel.com}"
  hp="${HY2_PORT:-12341}"
  local hsni="${HY2_SNI:-intel.com}"

  if [[ "${ENABLE_REALITY:-0}" -eq 1 ]]; then
    if [[ ! -f "$INSTALL_DIR/reality_keypair.txt" ]]; then
      echo "VLESS Reality 已启用但缺少 reality_keypair.txt，无法生成 vless:// 链接。"
    else
      pbk="$(read_reality_public_key || true)"
      if [[ -z "$pbk" ]]; then
        echo "无法读取 Reality public key，跳过 vless://。"
      else
        local vless_uri
        vless_uri="$(build_vless_share_uri "$uuid" "$ip" "$pbk" "$short_id" "$name_vless" "$rp" "$rsni")"
        echo "$vless_uri"
        echo
      fi
    fi
  fi

  if [[ "${ENABLE_HY2:-0}" -eq 1 ]]; then
    local hy2_uri
    hy2_uri="hysteria2://${uuid}@${ip}:${hp}?fastopen=0&insecure=1&sni=${hsni}#${name_hy2}"
    echo "$hy2_uri"
    echo
  fi

  if socks_should_export; then
    local socks_uri
    socks_uri="socks5://${SOCKS_USER:-huise}:${SOCKS_PASS:-huise123}@${ip}:${SOCKS_PORT:-12342}#${name_socks}"
    echo "$socks_uri"
    echo
  fi
}

# 汇总：基本信息 + 分享链接 → all-nodes.txt / share-links.txt，并 cat 一次
write_all_nodes_bundle() {
  load_state
  mkdir -p "$INSTALL_DIR"
  ensure_ids
  local out ip
  out="$INSTALL_DIR/all-nodes.txt"
  ip="$(get_public_ip)"
  {
    echo "=== sing-box 全节点信息 ==="
    echo "生成时间: $(date -Iseconds 2>/dev/null || date)"
    echo "主机: $(hostname 2>/dev/null || echo unknown)"
    echo "公网 IP(探测): $ip"
    echo
    show_info
    echo
    echo "=== 分享链接 (vless / hysteria2 / socks5) ==="
    echo
    _emit_share_links_uris
  } >"$out"
  cat "$out"
  echo
  echo "已写入: $out"
  {
    echo "====== 分享链接（服务器 IP: $ip）======"
    echo "（已按当前启用的协议生成；未启用的协议不会输出）"
    echo
    _emit_share_links_uris
  } >"$INSTALL_DIR/share-links.txt"
  echo "（已同步 $INSTALL_DIR/share-links.txt）"
}

export_share_links() {
  require_root
  load_state
  mkdir -p "$INSTALL_DIR"
  ensure_ids

  local ip out
  ip="$(get_public_ip)"
  out="$INSTALL_DIR/share-links.txt"
  {
    echo "====== 分享链接（服务器 IP: $ip）======"
    echo "（已按当前启用的协议生成；未启用的协议不会输出）"
    echo
    _emit_share_links_uris
  } | tee "$out"
  echo
  echo "已写入: $out"
}

export_all_nodes() {
  require_root
  mkdir -p "$INSTALL_DIR"
  if [[ ! -x "$BIN_REAL" ]]; then
    echo "===> 未检测到 sing-box 核心，将自动安装核心并启用 HY2+VLESS+SOCKS（与菜单「一键安装」相同），再导出节点。"
    install_all_protocols
    return 0
  fi
  ensure_ids
  load_state
  write_all_nodes_bundle
}

install_core() {
  require_root
  ensure_deps
  remove_legacy_third_party_proxies
  echo "===> 创建目录"
  mkdir -p "$INSTALL_DIR"
  download_core
  ensure_wrapper
  ensure_systemd
  load_state
  save_state
  write_config
  echo "===> 启动"
  systemctl restart sing-box
  echo "====== 完成 ======"
  if [[ "${1:-}" != "--no-show" ]]; then
    show_info
  fi
}

install_all_protocols() {
  require_root
  if [[ ! -x "$BIN_REAL" ]]; then
    install_core --no-show
  fi
  load_state
  ENABLE_HY2=1
  ENABLE_REALITY=1
  ENABLE_SOCKS=1
  HY2_PORT=12341
  HY2_SNI=intel.com
  REALITY_PORT=12343
  REALITY_SNI=intel.com
  REALITY_HS_SERVER=intel.com
  REALITY_HS_PORT=443
  SOCKS_PORT=12342
  SOCKS_USER=huise
  SOCKS_PASS=huise123
  save_state
  write_config
  ensure_systemd
  restart_service_if_possible
  mkdir -p "$INSTALL_DIR"
  ensure_ids
  echo "====== 一键安装完成 ======"
  echo "已同时启用 HY2 + VLESS Reality + SOCKS（默认端口/SNI/账号）。"
  echo
  write_all_nodes_bundle
}

configure_hy2_enable() {
  require_root
  ensure_deps
  if [[ ! -x "$BIN_REAL" ]]; then
    install_core
  fi
  load_state
  echo "=== 手动配置并启用 HY2 ==="
  echo "（自签证书 CN 与 TLS server_name 将使用你填写的 SNI；客户端 insecure 需开启）"
  read_port "监听端口" "${HY2_PORT:-12341}" HY2_PORT
  read_str "SNI / 证书域名" "${HY2_SNI:-intel.com}" HY2_SNI
  ENABLE_HY2=1
  save_state
  write_config
  ensure_systemd
  restart_service_if_possible
  echo "已启用 HY2 (端口 ${HY2_PORT}, SNI ${HY2_SNI})。"
}

disable_hy2() {
  require_root
  load_state
  ENABLE_HY2=0
  save_state
  write_config
  restart_service_if_possible
  echo "已卸载/停用 HY2。"
}

configure_reality_enable() {
  require_root
  ensure_deps
  if [[ ! -x "$BIN_REAL" ]]; then
    install_core
  fi
  load_state
  echo "=== 手动配置并启用 VLESS Reality ==="
  echo "（客户端分享链接中 sni 与下方 TLS server_name 一致；握手服务器需为可访问的 443 TLS 站点）"
  read_port "监听端口" "${REALITY_PORT:-12343}" REALITY_PORT
  read_str "TLS server_name (SNI)" "${REALITY_SNI:-intel.com}" REALITY_SNI
  read_str "Reality 握手服务器 (handshake server)" "${REALITY_HS_SERVER:-intel.com}" REALITY_HS_SERVER
  read_port "握手端口 (一般为 443)" "${REALITY_HS_PORT:-443}" REALITY_HS_PORT
  ENABLE_REALITY=1
  save_state
  write_config
  ensure_systemd
  restart_service_if_possible
  echo "已启用 VLESS Reality (端口 ${REALITY_PORT}, SNI ${REALITY_SNI}, 握手 ${REALITY_HS_SERVER}:${REALITY_HS_PORT})。"
}

disable_reality() {
  require_root
  load_state
  ENABLE_REALITY=0
  save_state
  write_config
  restart_service_if_possible
  echo "已卸载/停用 VLESS Reality。"
}

configure_socks_enable() {
  require_root
  ensure_deps
  if [[ ! -x "$BIN_REAL" ]]; then
    install_core
  fi
  load_state
  echo "=== 手动配置并启用 SOCKS ==="
  echo "（密码中请勿使用英文双引号；含特殊字符时分享链接可能需客户端手动填写）"
  read_port "监听端口" "${SOCKS_PORT:-12342}" SOCKS_PORT
  read_str "用户名" "${SOCKS_USER:-huise}" SOCKS_USER
  local _pw
  read -r -p "密码 [默认 ${SOCKS_PASS:-huise123}]: " _pw
  if [[ -n "${_pw// }" ]]; then
    SOCKS_PASS="$_pw"
  fi
  ENABLE_SOCKS=1
  save_state
  write_config
  ensure_systemd
  restart_service_if_possible
  echo "已启用 SOCKS (端口 ${SOCKS_PORT}, 用户 ${SOCKS_USER})。"
}

disable_socks() {
  require_root
  load_state
  ENABLE_SOCKS=0
  save_state
  write_config
  restart_service_if_possible
  echo "已卸载/停用 SOCKS（若当前无其它入站，将自动保留兜底 SOCKS 以保证服务可启动）。"
}

uninstall_all() {
  require_root
  echo "===> 停止并卸载服务"
  stop_disable_service_if_exists
  echo "===> 删除文件"
  rm -rf "$INSTALL_DIR"
  rm -f "$BIN_WRAPPER" "$BIN_WRAPPER_UPPER" /usr/local/bin/sing-box /usr/bin/sb /usr/bin/SB
  echo "====== 已卸载 sing-box ======"
}

menu() {
  require_root
  ensure_deps
  ensure_wrapper
  load_state

  while true; do
    echo
    echo "====== sing-box 菜单 ======"
    echo "（命令行可直接执行 sb 或 SB 打开本菜单）"
    echo "1) 安装/更新 sing-box 核心"
    echo "2) 一键安装所有节点 (HY2 + VLESS Reality + SOCKS，默认端口/SNI/账号)"
    echo "3) 手动配置并启用 HY2 (端口、SNI/证书域名)"
    echo "4) 卸载 HY2"
    echo "5) 手动配置并启用 VLESS Reality (端口、SNI、握手服务器与端口)"
    echo "6) 卸载 VLESS Reality"
    echo "7) 手动配置并启用 SOCKS (端口、用户名、密码)"
    echo "8) 卸载 SOCKS"
    echo "9) 查看当前信息"
    echo "10) 导出分享链接 (vless / hysteria2 / socks5)"
    echo "11) 导出全节点信息 (写入 all-nodes.txt，同命令 all)"
    echo "12) 卸载 sing-box(全部)"
    echo "0) 退出"
    read -r -p "请选择: " choice
    case "$choice" in
      1) install_core ;;
      2) install_all_protocols ;;
      3) configure_hy2_enable ;;
      4) disable_hy2 ;;
      5) configure_reality_enable ;;
      6) disable_reality ;;
      7) configure_socks_enable ;;
      8) disable_socks ;;
      9) show_info ;;
      10) export_share_links ;;
      11) export_all_nodes ;;
      12) uninstall_all ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

cmd="${1:-menu}"
shift || true
case "$cmd" in
  menu) menu ;;
  install-core) install_core ;;
  install-all) install_all_protocols ;;
  enable-hy2) configure_hy2_enable ;;
  disable-hy2) disable_hy2 ;;
  enable-reality) configure_reality_enable ;;
  disable-reality) disable_reality ;;
  enable-socks) configure_socks_enable ;;
  disable-socks) disable_socks ;;
  info) show_info ;;
  export-links) export_share_links ;;
  all) export_all_nodes ;;
  uninstall) uninstall_all ;;
  *)
    echo "用法:"
    echo "  sudo sb menu"
    echo "  sudo bash $0 menu"
    echo "  sudo bash $0 install-core"
    echo "  sudo bash $0 install-all"
    echo "  sudo bash $0 enable-hy2 | disable-hy2"
    echo "  sudo bash $0 enable-reality | disable-reality"
    echo "  sudo bash $0 enable-socks | disable-socks"
    echo "  sudo bash $0 info"
    echo "  sudo bash $0 export-links"
    echo "  sudo bash $0 all"
    echo "  sudo bash $0 uninstall"
    exit 1
    ;;
esac
