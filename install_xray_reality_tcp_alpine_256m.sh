#!/bin/sh
# Alpine Linux 3.22 / amd64 / 256MiB NAT VPS
# VLESS + TCP + REALITY (Vision) 测试节点；不修改已经运行的 Hysteria2。
# 请先确认 NAT 服务商分配了单独可用的 TCP 映射（不能占用 SSH 入口）。
set -eu
umask 077

# ====== 可手工修改的参数 ======
PUBLIC_IP="155.94.145.240"    # NAT 公网 IPv4；若不是此 IP，请修改
PUBLIC_TCP_PORT="38610"             # 公网 TCP 高位端口（必填，空着则启动时询问）
LOCAL_TCP_PORT="38610"              # VPS 内部 TCP 监听端口（空着则询问，默认同公网端口）
REALITY_SNI="www.microsoft.com" # REALITY 目标域名；需要支持 TLS 1.3
XRAY_VERSION="v26.10.10"       # 官方 Xray-core 发布版本（2026-10-10）
GOMEMLIMIT="96MiB"             # Go 运行时软内存目标；不是进程 RSS 硬上限
# ============================

fail() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
info() { printf '\n[REALITY] %s\n' "$*"; }
ask() {
    [ -r /dev/tty ] || fail "无法交互输入。请先下载脚本、修改顶部 TCP 端口变量，再执行。"
    printf '%s' "$1" >/dev/tty
    IFS= read -r REPLY </dev/tty || fail "读取输入失败"
}
valid_port() {
    case "$1" in ''|*[!0-9]*) return 1;; esac
    [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}

[ "$(id -u)" -eq 0 ] || fail "请使用 root 运行"
[ -f /etc/alpine-release ] || fail "本脚本只适用于 Alpine Linux"
[ "$(uname -m)" = "x86_64" ] || fail "本脚本只适用于 amd64 / x86_64"
command -v rc-service >/dev/null 2>&1 || fail "需要 OpenRC 服务管理"

# 支持：sh 脚本 公网IP 外部TCP端口 内部TCP端口
[ "${1:-}" = "" ] || PUBLIC_IP=$1
[ "${2:-}" = "" ] || PUBLIC_TCP_PORT=$2
[ "${3:-}" = "" ] || LOCAL_TCP_PORT=$3

if [ -z "$PUBLIC_IP" ]; then
    ask "请输入 NAT 公网 IPv4："
    PUBLIC_IP=$REPLY
fi
if [ -z "$PUBLIC_TCP_PORT" ]; then
    ask "请输入服务商分配的公网 TCP 端口："
    PUBLIC_TCP_PORT=$REPLY
fi
if [ -z "$LOCAL_TCP_PORT" ]; then
    ask "请输入 VPS 内部 TCP 端口 [直接回车等于公网端口 $PUBLIC_TCP_PORT]："
    LOCAL_TCP_PORT=${REPLY:-$PUBLIC_TCP_PORT}
fi

printf '%s\n' "$PUBLIC_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || fail "公网 IP 格式不正确：$PUBLIC_IP"
valid_port "$PUBLIC_TCP_PORT" || fail "公网 TCP 端口不正确：$PUBLIC_TCP_PORT"
valid_port "$LOCAL_TCP_PORT" || fail "内部 TCP 端口不正确：$LOCAL_TCP_PORT"
printf '%s\n' "$REALITY_SNI" | grep -Eq '^[a-zA-Z0-9.-]+$' || fail "REALITY_SNI 格式不正确"

# 防止误覆盖其他 Xray 安装或本脚本以前生成的节点。
[ ! -e /etc/init.d/xray-reality ] || fail "检测到 xray-reality 服务，停止以免覆盖现有配置"
[ ! -e /etc/xray-reality/config.json ] || fail "检测到现有 /etc/xray-reality/config.json，停止以免覆盖"
[ ! -e /usr/local/bin/xray-reality ] || fail "检测到现有 /usr/local/bin/xray-reality，停止以免覆盖"

if command -v netstat >/dev/null 2>&1; then
    if netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "[:.]${LOCAL_TCP_PORT}$"; then
        fail "内部 TCP 端口 $LOCAL_TCP_PORT 已有监听服务。不要覆盖 SSH 端口，请换端口。"
    fi
fi

info "准备部署：$PUBLIC_IP:$PUBLIC_TCP_PORT/TCP -> 0.0.0.0:$LOCAL_TCP_PORT/TCP"
printf '必须确认服务商映射的是 TCP，不是之前 HY2 的 UDP；且此 TCP 端口没有占用 SSH。\n'

info "安装 Alpine 最小依赖（不安装 Docker、面板、Nginx）..."
apk add --no-cache ca-certificates curl unzip openssl

mkdir -p /var/tmp
TMPD=$(mktemp -d /var/tmp/xray-reality-inst.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

ASSET="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
info "下载官方 Xray-core ${XRAY_VERSION} Linux amd64 ..."
curl -fL --retry 3 --connect-timeout 15 --max-time 240 "$ASSET" -o "$TMPD/xray.zip" || fail "下载失败，请检查 GitHub 网络和版本"
unzip -p "$TMPD/xray.zip" xray > "$TMPD/xray" || fail "官方 ZIP 中没有 xray 二进制"
chmod 755 "$TMPD/xray"
"$TMPD/xray" version || fail "Xray 二进制无法在本机启动"

info "生成 UUID、REALITY 密钥及 Short ID ..."
UUID=$("$TMPD/xray" uuid | tr -d '\r\n')
KEYS=$("$TMPD/xray" x25519)
PRIVATE_KEY=$(printf '%s\n' "$KEYS" | awk -F': *' '/^PrivateKey:/ {print $2; exit}')
PUBLIC_KEY=$(printf '%s\n' "$KEYS" | awk -F': *' '/^(Password|PublicKey)/ {print $2; exit}')
SHORT_ID=$(openssl rand -hex 8)
[ -n "$UUID" ] && [ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || fail "密钥生成结果不完整，停止安装"

cat > "$TMPD/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $LOCAL_TCP_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {"id": "$UUID", "flow": "xtls-rprx-vision"}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$REALITY_SNI:443",
          "serverNames": ["$REALITY_SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"],
          "minClientVer": "1.8.2"
        }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF
chmod 600 "$TMPD/config.json"
"$TMPD/xray" run -test -config "$TMPD/config.json" || fail "Xray 配置校验未通过，服务没有安装/启动，请查看上方错误"

info "创建最小化 OpenRC 服务 ..."
if ! id xrayreality >/dev/null 2>&1; then
    adduser -D -H -s /bin/false -g "Xray Reality" xrayreality
fi
mkdir -p /etc/xray-reality
chown root:xrayreality /etc/xray-reality
chmod 750 /etc/xray-reality
install -m 640 "$TMPD/config.json" /etc/xray-reality/config.json
chown root:xrayreality /etc/xray-reality/config.json
install -m 755 "$TMPD/xray" /usr/local/bin/xray-reality
: > /var/log/xray-reality.log
chown xrayreality:xrayreality /var/log/xray-reality.log

cat > /etc/init.d/xray-reality <<EOF
#!/sbin/openrc-run
description="Xray VLESS REALITY TCP NAT test"
command="/usr/local/bin/xray-reality"
command_args="run -config /etc/xray-reality/config.json"
command_user="xrayreality:xrayreality"
command_background=true
pidfile="/run/xray-reality.pid"
output_log="/var/log/xray-reality.log"
error_log="/var/log/xray-reality.log"
export GOMEMLIMIT="$GOMEMLIMIT"
depend() {
    need net
}
EOF
chmod 755 /etc/init.d/xray-reality

rc-update add xray-reality default
if ! rc-service xray-reality start; then
    printf '\n服务启动失败，最近日志：\n' >&2
    tail -n 30 /var/log/xray-reality.log >&2 || true
    fail "请查看日志修复配置"
fi

# 链接只写入 root 私有文件，不在公共日志中打印。
SHARE_URI="vless://${UUID}@${PUBLIC_IP}:${PUBLIC_TCP_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#LA-NAT-TCP-REALITY"
printf '%s\n' "$SHARE_URI" > /root/LA-NAT-TCP-REALITY.txt
chmod 600 /root/LA-NAT-TCP-REALITY.txt

printf '\n====================================================\n'
printf '安装完成！独立 TCP 代理节点，不影响旧 HY2。\n'
printf '公网入口：%s:%s/TCP\n' "$PUBLIC_IP" "$PUBLIC_TCP_PORT"
printf '内部监听：0.0.0.0:%s/TCP\n' "$LOCAL_TCP_PORT"
printf '协议：VLESS + REALITY + Vision\n'
printf '服务管理：rc-service xray-reality status\n'
printf '查看日志：tail -n 50 /var/log/xray-reality.log\n'
printf '查看客户端链接：cat /root/LA-NAT-TCP-REALITY.txt\n'
printf '请不要公开分享包含 UUID、REALITY 公钥等信息的完整连接链接。\n'
printf '注意：服务启动成功不等于 NAT 公网 TCP 映射成功，需从客户端验证。\n'
printf '====================================================\n'
