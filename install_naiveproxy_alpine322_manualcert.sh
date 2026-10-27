#!/usr/bin/env bash
# NaiveProxy / Caddy forwardproxy (naive fork) on Alpine Linux 3.22 x86_64.
# NAT: PUBLIC 10010/TCP -> VPS 80/TCP -> HAProxy -> Caddy 127.0.0.1:443.
# TLS certificate is PROVIDED AND RENEWED MANUALLY by the operator.
# No Docker, Go compiler, DNS token, acme.sh, or Cloudflare proxying.
set -Eeuo pipefail
umask 077

# ================== 修改区 ==================
DOMAIN="CHANGE_ME"                  # 必填：例如 naive.example.com
PUBLIC_TCP_PORT="10010"              # 你的 NAT 公网 TCP 端口
LOCAL_TCP_PORT="80"                  # NAT 映射的 VPS 内部 TCP 端口
LOCAL_CADDY_PORT="443"               # Caddy 仅在 127.0.0.1 监听
NAIVE_USER="naiveuser"               # 代理用户名，英文和数字
GOMEMLIMIT_VALUE="128MiB"            # Go 运行时软限制，不是进程硬限制
ALLOW_ROOT_FALLBACK="no"             # 如果 LXC 禁止 setcap，需自行评估再改成 yes
# ===========================================

# 作者官方发布的 Caddy + naive forwardproxy 预编译版本（2026-10-22）。
CADDY_RELEASE="v2.11.7-naive2"
CADDY_TAR_SHA256="c273dc07dd79c5919f97639cbdcb559d40ce90475dbd8aac80641b0a8c8065ff"
CADDY_BIN="/usr/local/bin/caddy-naive"
CADDY_CONFIG="/etc/naiveproxy/Caddyfile"
CERT="/etc/naiveproxy/fullchain.pem"
KEY="/etc/naiveproxy/key.pem"

info() { printf '\n[NaiveProxy] %s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
trap 'printf "\n[错误] 安装在第 %d 行终止；未对 SSH 做任何修改。\n" "$LINENO" >&2' ERR

[[ $(id -u) -eq 0 ]] || die '请以 root 执行'
[[ -r /etc/os-release ]] || die '找不到系统信息'
. /etc/os-release
[[ "${ID:-}" == 'alpine' && "${VERSION_ID:-}" == '3.22'* ]] || die '此脚本只适配 Alpine Linux 3.22'
[[ "$(uname -m)" == 'x86_64' ]] || die '只支持 AMD64 / x86_64'
[[ "$PUBLIC_TCP_PORT" =~ ^[0-9]+$ && "$LOCAL_TCP_PORT" =~ ^[0-9]+$ && "$LOCAL_CADDY_PORT" =~ ^[0-9]+$ ]] || die '端口必须是整数'
for p in "$PUBLIC_TCP_PORT" "$LOCAL_TCP_PORT" "$LOCAL_CADDY_PORT"; do
  (( 10#$p > 0 && 10#$p < 65536 )) || die '端口必须在 1–65535 之间'
done
[[ "$NAIVE_USER" =~ ^[A-Za-z0-9_-]+$ ]] || die '用户名只能包含字母、数字、下划线、连字符'

if [[ "$DOMAIN" == 'CHANGE_ME' ]]; then
  read -r -p '输入 NaiveProxy 子域名（例如 naive.example.com）: ' DOMAIN
fi
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^([a-z0-9][a-z0-9-]*\.)+[a-z][a-z0-9-]+$ ]] || die '域名格式不符合预期'
[[ "$DOMAIN" != *'..'* ]] || die '域名不能包含连续点号'
[[ ! -e /etc/init.d/naive-caddy && ! -e "$CADDY_CONFIG" ]] || die '检测到已有 NaiveProxy 配置；为防止覆盖密码，拒绝重复安装'

info '检查证书文件（你需要先手动上传证书和对应的私钥）'
[[ -s "$CERT" ]] || die "未找到 $CERT；请先上传完整证书链"
[[ -s "$KEY" ]] || die "未找到 $KEY；请先上传证书私钥"

info '检查内部 TCP 80 / 443 端口是否已被使用'
if netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}' | grep -Eq "(^|:)(${LOCAL_TCP_PORT}|${LOCAL_CADDY_PORT})$"; then
  netstat -lnt 2>/dev/null | grep -E ":(${LOCAL_TCP_PORT}|${LOCAL_CADDY_PORT})[[:space:]]" || true
  die '80 或 443 端口已经被占用，请先停止旧代理 / Web 服务'
fi
if [[ -e /etc/init.d/haproxy ]] && rc-service haproxy status >/dev/null 2>&1; then
  die 'HAProxy 已在运行；为了不覆盖其现有转发规则，拒绝继续'
fi

info '安装 Alpine 最小依赖（不装 Docker、Go 或证书签发服务）'
apk add --no-cache bash curl ca-certificates openssl haproxy tar xz libcap coreutils gcompat

# Verify certificate time, hostname and private key before touching service configuration.
openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null || die '证书已过期或将在 24 小时内过期'
openssl x509 -in "$CERT" -noout -checkhost "$DOMAIN" >/dev/null || die "证书不包含域名 $DOMAIN"
cert_pub=$(openssl x509 -in "$CERT" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum | awk '{print $1}')
key_pub=$(openssl pkey -in "$KEY" -pubout -outform DER | sha256sum | awk '{print $1}')
[[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || die '证书和私钥不匹配'
unset cert_pub key_pub

info "下载 Naive 作者提供的 Caddy 预编译发行包 ${CADDY_RELEASE}"
TMP_DIR=$(mktemp -d /tmp/naive-alpine.XXXXXX)
trap 'rm -rf "${TMP_DIR:-/tmp/no-such-directory}"' EXIT
URL="https://github.com/klzgrad/forwardproxy/releases/download/${CADDY_RELEASE}/caddy-forwardproxy-naive.tar.xz"
curl -fL --retry 3 --connect-timeout 15 -o "$TMP_DIR/caddy.tar.xz" "$URL" || die '下载失败，先检查 VPS 能否访问 GitHub'
printf '%s  %s\n' "$CADDY_TAR_SHA256" "$TMP_DIR/caddy.tar.xz" | sha256sum -c - >/dev/null || die '预编译文件 SHA-256 校验失败'
mkdir -p "$TMP_DIR/unpack"
tar -xJf "$TMP_DIR/caddy.tar.xz" -C "$TMP_DIR/unpack"
CADDY_SRC=$(find "$TMP_DIR/unpack" -type f -name 'caddy' -print -quit)
[[ -n "$CADDY_SRC" ]] || die '安装包中没有 Caddy 二进制'
install -m 755 "$CADDY_SRC" "$CADDY_BIN"
"$CADDY_BIN" version >/dev/null 2>&1 || die "Caddy 预编译二进制在 Alpine 不能运行（可能依赖 glibc）；停止安装，请改用静态编译版本"
"$CADDY_BIN" list-modules | grep -qx 'http.handlers.forward_proxy' || die 'Caddy 缺少 naive forward_proxy 模块'

info '创建专用服务用户'
if ! id naive >/dev/null 2>&1; then
  adduser -S -D -H -h /var/lib/naiveproxy -s /bin/false naive
fi
install -d -o naive -g naive -m 750 /var/lib/naiveproxy
install -d -o naive -g naive -m 750 /var/lib/naiveproxy/data
install -d -o naive -g naive -m 750 /var/lib/naiveproxy/config
install -d -o root -g naive -m 750 /etc/naiveproxy
install -d -o root -g root -m 755 /srv/naive-site
printf '%s\n' '<!doctype html><html lang="en"><meta charset="utf-8"><title>Welcome</title><h1>Welcome</h1></html>' > /srv/naive-site/index.html
chmod 644 /srv/naive-site/index.html
chown root:naive "$CERT" "$KEY"
chmod 640 "$KEY"
chmod 640 "$CERT"

SERVICE_USER='naive:naive'
if setcap 'cap_net_bind_service=+ep' "$CADDY_BIN"; then
  info 'Caddy 获得绑定本地 443 所需的最小权限（专用用户运行）'
elif [[ "$ALLOW_ROOT_FALLBACK" == 'yes' ]]; then
  SERVICE_USER='root:root'
  info '警告：当前容器不允许 setcap，将按明确设置使用 root 运行 Caddy'
else
  die '容器禁止 setcap；未自动切换到 root。若理解风险，可将 ALLOW_ROOT_FALLBACK 改成 yes 再重试'
fi

touch /var/log/naive-caddy.log
chown naive:naive /var/log/naive-caddy.log
chmod 640 /var/log/naive-caddy.log

NAIVE_PASS=$(openssl rand -hex 20)
cat > "$CADDY_CONFIG" <<EOF
{
    auto_https off
    admin off
    order forward_proxy before file_server
}

:443, ${DOMAIN} {
    bind 127.0.0.1
    tls ${CERT} ${KEY}
    forward_proxy {
        basic_auth ${NAIVE_USER} ${NAIVE_PASS}
        hide_ip
        hide_via
        probe_resistance
    }
    root * /srv/naive-site
    file_server
}
EOF
chown root:naive "$CADDY_CONFIG"
chmod 640 "$CADDY_CONFIG"

cat > /etc/init.d/naive-caddy <<EOF
#!/sbin/openrc-run
name="NaiveProxy Caddy"
description="Caddy with naive forwardproxy"
command="${CADDY_BIN}"
command_args="run --config ${CADDY_CONFIG} --adapter caddyfile"
command_user="${SERVICE_USER}"
command_background="yes"
pidfile="/run/naiveproxy/naive-caddy.pid"
output_log="/var/log/naive-caddy.log"
error_log="/var/log/naive-caddy.log"
export HOME="/var/lib/naiveproxy"
export XDG_DATA_HOME="/var/lib/naiveproxy/data"
export XDG_CONFIG_HOME="/var/lib/naiveproxy/config"
export GOMEMLIMIT="${GOMEMLIMIT_VALUE}"
depend() { need net; }
start_pre() { checkpath --directory --owner naive:naive --mode 0750 /run/naiveproxy; }
EOF
chmod 755 /etc/init.d/naive-caddy

# Backup a pristine haproxy.cfg when available (this script should be run on a fresh VPS).
if [[ -e /etc/haproxy/haproxy.cfg ]]; then
  cp -p /etc/haproxy/haproxy.cfg "/root/haproxy-before-naive.$(date +%Y%m%d%H%M%S).cfg"
fi
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    maxconn 64

defaults
    mode tcp
    timeout connect 10s
    timeout client 1h
    timeout server 1h

frontend naive_nat_in
    bind 0.0.0.0:${LOCAL_TCP_PORT}
    default_backend naive_tls_local

backend naive_tls_local
    server caddy 127.0.0.1:${LOCAL_CADDY_PORT} check
EOF

info '校验 Caddy 和 HAProxy 配置'
"$CADDY_BIN" validate --config "$CADDY_CONFIG" --adapter caddyfile || die 'Caddyfile 校验失败'
haproxy -c -f /etc/haproxy/haproxy.cfg || die 'HAProxy 配置校验失败'

info '启动 OpenRC 服务'
rc-service naive-caddy start || { tail -n 40 /var/log/naive-caddy.log 2>/dev/null || true; die 'Caddy 启动失败'; }
rc-service haproxy start || die 'HAProxy 启动失败'
rc-update add naive-caddy default
rc-update add haproxy default

printf '{\n  "listen": "socks://127.0.0.1:1080",\n  "proxy": "https://%s:%s@%s:%s"\n}\n' "$NAIVE_USER" "$NAIVE_PASS" "$DOMAIN" "$PUBLIC_TCP_PORT" > /root/naive-client.json
chmod 600 /root/naive-client.json

info '安装完成。证书由你手动管理，本脚本不自动续签。'
if curl -fsS --connect-timeout 5 --max-time 10 --resolve "${DOMAIN}:${LOCAL_TCP_PORT}:127.0.0.1" "https://${DOMAIN}:${LOCAL_TCP_PORT}/" -o /dev/null; then
  info "本机 HTTPS/NAT 内部端口转发测试成功"
else
  info "提醒：本机 HTTPS 测试失败，请看 HAProxy / Caddy 日志与证书链；服务已安装"
fi
printf '公网连接：%s:%s TCP -> NAT 内部 %s -> Caddy localhost:%s\n' "$DOMAIN" "$PUBLIC_TCP_PORT" "$LOCAL_TCP_PORT" "$LOCAL_CADDY_PORT"
printf '客户端配置：cat /root/naive-client.json  （含密码，勿公开）\n'
printf '状态：rc-service naive-caddy status && rc-service haproxy status\n'
printf '证书更新后：chgrp naive /etc/naiveproxy/fullchain.pem /etc/naiveproxy/key.pem && chmod 640 /etc/naiveproxy/fullchain.pem /etc/naiveproxy/key.pem && rc-service naive-caddy restart\n'
printf '日志：tail -n 40 /var/log/naive-caddy.log\n'
printf '查看内存：free -m\n'
