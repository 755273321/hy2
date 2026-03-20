#!/bin/bash
# 本脚本需要 root 权限执行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本"
  exit 1
fi

echo "更新软件包列表..."
apt update -y

echo "安装 dante-server..."
apt install -y dante-server

# 备份原有配置文件（如果存在）
if [ -f /etc/danted.conf ]; then
    cp /etc/danted.conf /etc/danted.conf.bak
    echo "已备份原有 /etc/danted.conf 到 /etc/danted.conf.bak"
fi

# 获取本机外网 IP（此处取默认路由出口 IP，可能需根据实际情况调整）
EXTERNAL_IP=$(ip route get 8.8.8.8 | awk '{print $7}' | head -n1)
if [ -z "$EXTERNAL_IP" ]; then
    EXTERNAL_IP="0.0.0.0"
fi

echo "生成新的 /etc/danted.conf 配置文件..."
cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log

# 内部监听：所有 IP，端口 1234
internal: 0.0.0.0 port = 1234
# 外部出口 IP（根据实际情况调整）
external: ${EXTERNAL_IP}

# 全局认证方式只允许 username 认证
method: username

user.privileged: root
user.notprivileged: nobody

# 客户端访问规则（允许所有）
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# 转发规则，要求 username 认证
pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    method: username
    log: connect disconnect error
}
EOF

echo "配置文件生成完毕。"

# 检查并添加认证用户 "huise123"
if id "huise123" &>/dev/null; then
    echo "用户 huise123 已存在。"
else
    echo "添加用户 huise123..."
    useradd -m -s /bin/false huise123
    echo "huise123:huise123" | chpasswd
fi

echo "重启 Dante 服务..."
systemctl restart danted

echo "设置 Dante 服务开机自启..."
systemctl enable danted

rm -rf /root/socks.sh
echo "安装并配置 Socks5 成功！代理端口：1234，账号密码：huise123。"

