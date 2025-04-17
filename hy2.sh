#!/bin/bash
# 检测当前用户是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户执行此脚本！"
  echo "你可以使用 'sudo -i' 进入 root 用户模式。"
  exit 1
fi

# 设置架构
set_architecture() {
  case "$(uname -m)" in
    'i386' | 'i686')
      arch='386'
      ;;
    'amd64' | 'x86_64')
      arch='amd64'
      ;;
    'armv5tel' | 'armv6l' | 'armv7' | 'armv7l')
      arch='arm'
      ;;
    'armv8' | 'aarch64')
      arch='arm64'
      ;;
    'mips' | 'mipsle' | 'mips64' | 'mips64le')
      arch='mipsle'
      ;;
    's390x')
      arch='s390x'
      ;;
    *)
      echo "暂时不支持你的系统哦，可能是因为不在已知架构范围内。"
      exit 1
      ;;
  esac
}

# 安装必要软件包
install_custom_packages() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
    else
        echo "无法确定操作系统类型。"
        exit 1
    fi

    if [ "$OS_TYPE" = "debian" ] || [ "$OS_TYPE" = "ubuntu" ]; then
        apt update
        apt install -y wget sed sudo openssl net-tools psmisc procps iptables iproute2 ca-certificates jq
    elif [ "$OS_TYPE" = "centos" ] || [ "$OS_TYPE" = "rhel" ] || [ "$OS_TYPE" = "fedora" ] || [ "$OS_TYPE" = "rocky" ]; then
        yum install -y epel-release
        yum install -y wget sed sudo openssl net-tools psmisc procps-ng iptables iproute ca-certificates jq
    else
        echo "不支持的操作系统。"
        exit 1
    fi
}

# 卸载旧版本
uninstall_hysteria() {
  systemctl stop hysteria.service 2>/dev/null
  systemctl disable hysteria.service 2>/dev/null
  rm -f "/etc/systemd/system/hysteria.service" 2>/dev/null
  
  process_name="hysteria-linux-$arch"
  pid=$(pgrep -f "$process_name")
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
  fi
  
  rm -rf /root/hy3 2>/dev/null
  systemctl stop ipppp.service 2>/dev/null
  systemctl disable ipppp.service 2>/dev/null
  rm -f /etc/systemd/system/ipppp.service 2>/dev/null
  rm -f /bin/hy2 2>/dev/null
}

# 安装 Hysteria2
install_hysteria2() {
  # 创建目录
  mkdir -p ~/hy3
  cd ~/hy3

  # 下载 Hysteria2
  if wget -O hysteria-linux-$arch https://download.hysteria.network/app/latest/hysteria-linux-$arch; then
    chmod +x hysteria-linux-$arch
  else
    REPO_URL="https://github.com/apernet/hysteria/releases"
    LATEST_RELEASE=$(curl -s $REPO_URL/latest | jq -r '.tag_name')
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/$LATEST_RELEASE/hysteria-linux-$arch"
    
    if wget -O hysteria-linux-$arch $DOWNLOAD_URL; then
      chmod +x hysteria-linux-$arch
    else
      echo "无法下载 Hysteria2"
      exit 1
    fi
  fi

  # 生成自签名证书
  domain_name="bing.com"
  mkdir -p /etc/ssl/private
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "/etc/ssl/private/$domain_name.key" -out "/etc/ssl/private/$domain_name.crt" -subj "/CN=$domain_name" -days 36500
  chmod 777 "/etc/ssl/private/$domain_name.key" "/etc/ssl/private/$domain_name.crt"

  # 创建配置文件
  cat <<EOL > config.yaml
listen: :12341

tls:
  cert: /etc/ssl/private/$domain_name.crt
  key: /etc/ssl/private/$domain_name.key

auth:
  type: password
  password: huise123

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

bandwidth:
  up: 0 gbps
  down: 0 gbps

udpIdleTimeout: 90s
EOL

  # 获取 IP 地址
  ipwan=$(wget -4 -qO- --no-check-certificate --user-agent=Mozilla --tries=2 --timeout=3 http://ip-api.com/json/ | grep -o '"query":"[^"]*' | cut -d'"' -f4)

  # 创建 Clash 配置
  cat <<EOL > clash-mate.yaml
system-port: 7890
external-controller: 127.0.0.1:9090
allow-lan: false
mode: rule
log-level: info
ipv6: true
unified-delay: true
profile:
  store-selected: true
  store-fake-ip: true
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
dns:
  enable: true
  prefer-h3: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  nameserver:
    - 223.5.5.5
    - 8.8.8.8
proxies:
  - name: Hysteria2
    type: hysteria2
    server: $ipwan
    port: 12341
    password: huise123
    sni: $domain_name
    skip-cert-verify: true
proxy-groups:
  - name: auto
    type: select
    proxies:
      - Hysteria2
rules:
  - MATCH,auto
EOL

  # 创建 Nekobox 配置
  echo "hysteria2://huise123@$ipwan:12341/?insecure=1&sni=$domain_name#Hysteria2" > neko.txt

  # 创建服务文件
  cat > "/etc/systemd/system/hysteria.service" <<EOF
[Unit]
Description=Hysteria Server

[Service]
Type=simple
WorkingDirectory=/root/hy3
ExecStart=/root/hy3/hysteria-linux-$arch server
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  # 启用并启动服务
  systemctl daemon-reload
  systemctl enable hysteria.service
  systemctl start hysteria.service
}

# 主程序
echo "开始安装 Hysteria2..."
set_architecture
install_custom_packages
uninstall_hysteria
install_hysteria2

echo "Hysteria2 安装完成！"
echo "端口: 12341"
echo "密码: huise123"
echo "证书: 自签名 (bing.com)"

echo "Nekobox 配置:"
cat /root/hy3/neko.txt

echo "Clash 配置已保存到 /root/hy3/clash-mate.yaml"
