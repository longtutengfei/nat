#!/bin/sh
# ============================================================================
# Hysteria2 for Alpine Linux 3.22 (amd64/x86_64), 256MiB NAT VPS / 1Gbps shared / 150ms RTT
# 无 Cloudflare / 不需要公网 80、443 / 无 Docker / 无面板
# 用法：先编辑下方参数，再以 root 运行：sh install_hy2_alpine_256m_1g_150ms.sh
# 如果已安装，切勿靠重新运行安装器来调优：它会重置密码和证书。改已有 YAML/OpenRC 即可。
# 注意：服务商控制台必须已经配置 UDP 外部端口 -> VPS 内部端口映射。
# ============================================================================

# ================== [A] 必须手动修改：只有下面 3 项 =========================
PUBLIC_IP="155.94.145.240"         # NAT 共享公网 IPv4，例如 203.0.113.10
PUBLIC_UDP_PORT="31086"   # 服务商分配的公网 UDP 端口，例如 30001
LOCAL_UDP_PORT="31086"    # 映射到小鸡的内部 UDP 端口，例如 20001
# 如果服务商是同端口映射，PUBLIC_UDP_PORT 和 LOCAL_UDP_PORT 填相同值即可。

# ================== [B] 可选配置：不懂就保持默认 =============================
SNI="la-nat.invalid"         # TLS 自签证书名称；不需要 DNS 解析
HY2_PASSWORD=""              # 留空 = 自动生成安全随机密码；建议留空
NODE_NAME="LA-NAT-HY2"       # Mihomo 节点显示名称
GOMEMLIMIT="128MiB"         # Go 运行时管理的内存软目标；不是 VPS 总内存/进程 RSS 硬上限
QUIC_STREAM_WINDOW="4194304" # 服务端 4MiB：控制客户端上传时单流接收窗口
QUIC_CONN_WINDOW="10485760"  # 服务端 10MiB：控制客户端上传时整连接接收窗口
MIHOMO_STREAM_WINDOW="20971520" # 客户端 20MiB：客户端下载的单流接收窗口
MIHOMO_CONN_WINDOW="52428800"   # 客户端 50MiB：客户端下载的整连接接收窗口
OVERWRITE_EXISTING="no"      # 默认禁止覆盖旧节点；确认要覆盖时改为 yes
# ============================================================================

set -eu
umask 077

info() { printf '\n[HY2] %s\n' "$*"; }
warn() { printf '[提醒] %s\n' "$*" >&2; }
fail() { printf '[错误] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail '请以 root 身份运行：sh install_hy2_alpine_256m_1g_150ms.sh'
[ -f /etc/os-release ] || fail '找不到 /etc/os-release'
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = alpine ] || fail '本脚本只支持 Alpine Linux，不适用于 Debian/Ubuntu'
case "${VERSION_ID:-}" in
  3.22|3.22.*) ;;
  *) fail "脚本目标系统是 Alpine 3.22；当前检测为 ${VERSION_ID:-未知}，请勿直接执行" ;;
esac
[ "$(uname -m)" = x86_64 ] || fail '本脚本下载 amd64 版本，当前 CPU 架构不是 x86_64'
command -v apk >/dev/null 2>&1 || fail '未找到 apk 包管理器'

# 配置检查：在安装依赖或写文件之前完成。
[ "$PUBLIC_IP" != CHANGE_ME ] && [ -n "$PUBLIC_IP" ] || fail '请修改 PUBLIC_IP：填 NAT 共享公网 IPv4'
[ "$PUBLIC_UDP_PORT" != CHANGE_ME ] || fail '请修改 PUBLIC_UDP_PORT：填公网 UDP 端口'
[ "$LOCAL_UDP_PORT" != CHANGE_ME ] || fail '请修改 LOCAL_UDP_PORT：填 VPS 内部 UDP 端口'

printf '%s\n' "$PUBLIC_IP" | awk -F. '
  NF != 4 {exit 1}
  {for (i=1;i<=4;i++) {
     if ($i !~ /^[0-9]+$/ || length($i)>3 || $i+0>255) exit 1;
     if (length($i)>1 && substr($i,1,1)=="0") exit 1;
   }}
' || fail "PUBLIC_IP 不是合法 IPv4：$PUBLIC_IP"

validate_port() {
  case "$2" in
    ''|*[!0-9]*) fail "$1 必须是 1–65535 范围内的数字" ;;
    0|0*) fail "$1 不可为 0 或以 0 开头" ;;
  esac
  [ "$2" -le 65535 ] || fail "$1 超出范围：$2"
}
validate_port PUBLIC_UDP_PORT "$PUBLIC_UDP_PORT"
validate_port LOCAL_UDP_PORT "$LOCAL_UDP_PORT"

printf '%s\n' "$SNI" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || fail 'SNI 仅可包含英文字母、数字、点、横线'
printf '%s\n' "$NODE_NAME" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' || fail 'NODE_NAME 仅可包含英文字母、数字、点、下划线、横线'
if [ -n "$HY2_PASSWORD" ]; then
  printf '%s\n' "$HY2_PASSWORD" | grep -Eq '^[A-Za-z0-9_-]{16,128}$' || fail '手动密码须为 16–128 位英数字、下划线或横线；建议留空自动生成'
fi
printf '%s\n' "$GOMEMLIMIT" | grep -Eq '^[0-9]+MiB$' || fail 'GOMEMLIMIT 请输入例如 96MiB'
for w in "$QUIC_STREAM_WINDOW" "$QUIC_CONN_WINDOW" "$MIHOMO_STREAM_WINDOW" "$MIHOMO_CONN_WINDOW"; do
  printf '%s\n' "$w" | grep -Eq '^[1-9][0-9]{5,8}$' || fail 'QUIC 窗口须填写字节数，例如 2097152 / 5242880'
done
[ "$QUIC_CONN_WINDOW" -ge "$QUIC_STREAM_WINDOW" ] || fail '服务端连接窗口不得小于流窗口'
[ "$MIHOMO_CONN_WINDOW" -ge "$MIHOMO_STREAM_WINDOW" ] || fail 'Mihomo 连接窗口不得小于流窗口'
case "$OVERWRITE_EXISTING" in yes|no) ;; *) fail 'OVERWRITE_EXISTING 只能是 yes 或 no' ;; esac

CFG_DIR=/etc/hysteria
CFG_FILE="$CFG_DIR/config.yaml"
CRT_FILE="$CFG_DIR/server.crt"
KEY_FILE="$CFG_DIR/server.key"
INIT_FILE=/etc/init.d/hysteria
BIN_FILE=/usr/local/bin/hysteria
CLIENT_FILE="/root/${NODE_NAME}-mihomo.yaml"
BACKUP_DIR=''

if [ -e "$CFG_FILE" ] || [ -e "$INIT_FILE" ]; then
  [ "$OVERWRITE_EXISTING" = yes ] || fail '检测到旧节点；为避免覆盖，脚本已退出。确认备份后将 OVERWRITE_EXISTING 改为 yes 才能重装'
  BACKUP_DIR="/root/hy2-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for p in "$CFG_FILE" "$CRT_FILE" "$KEY_FILE" "$INIT_FILE" "$BIN_FILE" "$CLIENT_FILE"; do
    if [ -f "$p" ]; then cp -p "$p" "$BACKUP_DIR/"; fi
  done
  info "原配置已备份：$BACKUP_DIR"
fi

info "NAT 外部 ${PUBLIC_IP}:${PUBLIC_UDP_PORT}/UDP -> 内部 :${LOCAL_UDP_PORT}/UDP"
info '通过 apk 安装最少依赖（不安装 Docker、Nginx、面板）...'
apk add --no-cache ca-certificates curl openssl openrc
command -v rc-service >/dev/null 2>&1 || fail 'OpenRC 不可用，无法创建开机自启服务'
command -v rc-update >/dev/null 2>&1 || fail 'rc-update 不可用'

# Alpine 3.22 的 busybox ash 可执行本脚本，无需 bash。
info '下载 Hysteria2 官方 Linux amd64 可执行文件...'
TMP_DIR="$(mktemp -d /var/tmp/hy2-install.XXXXXX)"
cleanup() { [ -z "${TMP_DIR:-}" ] || rm -rf "$TMP_DIR"; }
trap cleanup 0
trap 'exit 1' 1 2 3 15
curl --fail --location --show-error --silent --retry 3 --connect-timeout 20 \
  'https://download.hysteria.network/app/latest/hysteria-linux-amd64' \
  -o "$TMP_DIR/hysteria"
chmod 755 "$TMP_DIR/hysteria"
"$TMP_DIR/hysteria" version >/dev/null 2>&1 || fail '下载的二进制无法在此 Alpine 系统运行；未覆盖目标程序'

if ! id hysteria >/dev/null 2>&1; then
  if ! grep -q '^hysteria:' /etc/group; then addgroup -S hysteria; fi
  adduser -S -D -H -G hysteria -s /sbin/nologin hysteria
fi

mkdir -p "$CFG_DIR"
chown root:hysteria "$CFG_DIR"
chmod 750 "$CFG_DIR"
if [ -z "$HY2_PASSWORD" ]; then HY2_PASSWORD="$(openssl rand -hex 24)"; fi

info '生成 ECDSA P-256 自签名证书、服务端 YAML 和 OpenRC 脚本...'
# ECDSA 证书通常比 RSA 2048 的 TLS 握手更省 CPU；证书到期前需更新指纹。
openssl ecparam -name prime256v1 -genkey -noout -out "$CRT_FILE.tmp.key"
openssl req -new -x509 -sha256 -days 825 \
  -key "$CRT_FILE.tmp.key" -out "$CRT_FILE.tmp.crt" \
  -subj "/CN=$SNI" \
  -addext "subjectAltName=DNS:$SNI" \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=serverAuth'
mv -f "$CRT_FILE.tmp.key" "$KEY_FILE"
mv -f "$CRT_FILE.tmp.crt" "$CRT_FILE"
chown root:hysteria "$KEY_FILE" "$CRT_FILE"
chmod 640 "$KEY_FILE"
chmod 644 "$CRT_FILE"

cat > "$CFG_FILE" <<YAML
# Alpine 256MiB NAT VPS: listen 使用 VPS 内部 UDP 端口，而不是公网端口。
listen: 0.0.0.0:${LOCAL_UDP_PORT}

tls:
  cert: ${CRT_FILE}
  key: ${KEY_FILE}
  sniGuard: strict

auth:
  type: password
  password: "${HY2_PASSWORD}"

# 服务端 QUIC 接收窗口：控制客户端上传；下载吞吐主要受客户端窗口影响。
quic:
  initStreamReceiveWindow: ${QUIC_STREAM_WINDOW}
  maxStreamReceiveWindow: ${QUIC_STREAM_WINDOW}
  initConnReceiveWindow: ${QUIC_CONN_WINDOW}
  maxConnReceiveWindow: ${QUIC_CONN_WINDOW}
  maxIncomingStreams: 64

# 不配置 bandwidth：保持默认 BBR，而不是误以共享 1Gbps 就启用 Brutal。
YAML
chown root:hysteria "$CFG_FILE"
chmod 640 "$CFG_FILE"

cat > "$INIT_FILE" <<OPENRC
#!/sbin/openrc-run
name="hysteria"
description="Hysteria2 UDP proxy (NAT low memory)"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_user="hysteria:hysteria"
command_background="yes"
pidfile="/run/hysteria.pid"
output_log="/dev/null"
error_log="/var/log/hysteria.log"
export GOMEMLIMIT="${GOMEMLIMIT}"
depend() {
    need net
}
OPENRC
chmod 755 "$INIT_FILE"
touch /var/log/hysteria.log
chown hysteria:hysteria /var/log/hysteria.log
chmod 640 /var/log/hysteria.log

# 下载和配置全部就绪后，再替换正式二进制，避免下载失败破坏旧节点。
if rc-service hysteria status >/dev/null 2>&1; then
  rc-service hysteria stop || fail '旧 hysteria 服务无法停止，未覆盖可执行文件'
fi
cp "$TMP_DIR/hysteria" "$BIN_FILE"
chmod 755 "$BIN_FILE"

FP="$(openssl x509 -in "$CRT_FILE" -noout -fingerprint -sha256 | sed 's/^[^=]*=//')"
cat > "$CLIENT_FILE" <<YAML
# Mihomo/Clash Verge Rev 完整示例；已有自己的配置时只需合并 proxies 节点。
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
proxies:
  - name: "${NODE_NAME}"
    type: hysteria2
    server: ${PUBLIC_IP}
    port: ${PUBLIC_UDP_PORT}
    password: "${HY2_PASSWORD}"
    sni: "${SNI}"
    alpn:
      - h3
    skip-cert-verify: false
    fingerprint: "${FP}"
    # 不填写 up/down：使用默认 BBR，避免共享端口上错误触发 Brutal 固定速率。
    bbr-profile: standard
    # 客户端窗口用于从 NAT VPS 下载；客户端电脑通常比 256MB 小鸡更有内存。
    initial-stream-receive-window: ${MIHOMO_STREAM_WINDOW}
    max-stream-receive-window: ${MIHOMO_STREAM_WINDOW}
    initial-connection-receive-window: ${MIHOMO_CONN_WINDOW}
    max-connection-receive-window: ${MIHOMO_CONN_WINDOW}
proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "${NODE_NAME}"
      - DIRECT
rules:
  - MATCH,PROXY
YAML
chmod 600 "$CLIENT_FILE"

info '设置 OpenRC 开机自启并启动 Hysteria2...'
rc-update add hysteria default
if ! rc-service hysteria start; then
  warn "启动失败。请检查：tail -n 50 /var/log/hysteria.log"
  fail '服务启动失败；请核对端口映射、配置及资源'
fi
sleep 2
if ! rc-service hysteria status >/dev/null 2>&1; then
  warn 'OpenRC 报告服务非运行状态。最近的错误日志：'
  tail -n 30 /var/log/hysteria.log >&2 || true
  fail '服务启动后退出；请查看日志'
fi

printf '\n==================================================\n'
printf ' 安装完成：Hysteria2 / Alpine 3.22 / OpenRC\n'
printf ' 公网入口：%s:%s/UDP\n' "$PUBLIC_IP" "$PUBLIC_UDP_PORT"
printf ' 内部监听：0.0.0.0:%s/UDP\n' "$LOCAL_UDP_PORT"
printf ' SNI：%s（不需要 DNS 解析）\n' "$SNI"
printf ' GOMEMLIMIT：%s（Go 运行时内存软目标，不是 RSS 硬上限）\n' "$GOMEMLIMIT"
printf ' 服务端窗口：%s / %s 字节\n' "$QUIC_STREAM_WINDOW" "$QUIC_CONN_WINDOW"
printf ' Mihomo 窗口：%s / %s 字节\n' "$MIHOMO_STREAM_WINDOW" "$MIHOMO_CONN_WINDOW"
printf ' 客户端配置：%s\n' "$CLIENT_FILE"
printf ' 服务端配置：%s\n' "$CFG_FILE"
if [ -n "$BACKUP_DIR" ]; then printf ' 旧配置备份：%s\n' "$BACKUP_DIR"; fi
printf '==================================================\n'
printf '\n操作命令：\n'
printf '  查看状态：rc-service hysteria status\n'
printf '  重启服务：rc-service hysteria restart\n'
printf '  查看日志：tail -n 50 /var/log/hysteria.log\n'
printf '  查看内存：free -m\n'
printf '  查看客户端：cat %s\n' "$CLIENT_FILE"
printf '\n重要：服务启动成功不代表公网 UDP 已通，请用客户端实际连接验证。\n'
printf '重要：如果小鸡本身启用了防火墙，须另外放行内部 UDP 端口 %s。\n' "$LOCAL_UDP_PORT"
printf '重要：证书是自签并以指纹固定；更新证书后必须同步更新客户端指纹。\n'
printf '重要：256MB 小鸡建议监控 MemAvailable / RSS / OOM；千兆共享不是保证独享 1Gbps。\n'
