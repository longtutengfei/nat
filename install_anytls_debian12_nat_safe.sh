#!/usr/bin/env bash
# AnyTLS over sing-box, Debian 12 amd64, NAT IPv4.
# This script intentionally does NOT use AnyTLS-Manager's insecure example TLS settings.
set -Eeuo pipefail
umask 077

# ========= CHANGE THESE AT THE TOP =========
PUBLIC_IP="CHANGE_ME"        # NAT public IPv4 used by client (prompted if unchanged)
PUBLIC_TCP_PORT="10010"      # NAT EXTERNAL TCP port
LOCAL_TCP_PORT="80"          # VPS INTERNAL TCP port
GO_MEMORY_TARGET="128MiB"   # Go soft memory target; not a hard RSS cap
# ===========================================

fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '\n[INFO] %s\n' "$*"; }

[[ $(id -u) -eq 0 ]] || fail "Run as root: bash install_anytls_debian12_nat_safe.sh"
[[ "$(uname -m)" == 'x86_64' ]] || fail "This edition supports amd64/x86_64 only"
[[ -r /etc/os-release ]] || fail "Cannot identify operating system"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == 'debian' && "${VERSION_ID%%.*}" == '12' ]] || fail "This edition is for Debian 12"

[[ "$PUBLIC_TCP_PORT" =~ ^[0-9]+$ ]] && (( PUBLIC_TCP_PORT >= 1 && PUBLIC_TCP_PORT <= 65535 )) || fail "Invalid public TCP port"
[[ "$LOCAL_TCP_PORT" =~ ^[0-9]+$ ]] && (( LOCAL_TCP_PORT >= 1 && LOCAL_TCP_PORT <= 65535 )) || fail "Invalid local TCP port"
if [[ "$PUBLIC_IP" == 'CHANGE_ME' || -z "$PUBLIC_IP" ]]; then
  read -r -p 'Enter NAT public IPv4 (for client): ' PUBLIC_IP
fi
# Check IPv4 syntax without introducing Python dependency.
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "Public IPv4 address format is invalid"
IFS='.' read -r b1 b2 b3 b4 <<< "$PUBLIC_IP"
for n in "$b1" "$b2" "$b3" "$b4"; do
  [[ "$n" =~ ^[0-9]+$ ]] && ((10#$n <= 255)) || fail "Invalid IPv4 octet"
done

[[ ! -e /etc/anytls-nat/config.json ]] || fail "Existing /etc/anytls-nat/config.json found. Refusing to overwrite it."
if command -v ss >/dev/null 2>&1; then
  if ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${LOCAL_TCP_PORT}$"; then
    fail "TCP ${LOCAL_TCP_PORT} is occupied. Stop the existing service or change the mapping; do not overwrite it blindly."
  fi
else
  info "ss not found; will perform port availability check after dependencies are installed."
fi

info "Installing tools and official sing-box APT repository"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl openssl jq iproute2

if ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${LOCAL_TCP_PORT}$"; then
  fail "TCP ${LOCAL_TCP_PORT} is occupied."
fi
install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF_REPO'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF_REPO
apt-get update
apt-get install -y --no-install-recommends sing-box
SING_BOX_BIN=$(command -v sing-box) || fail "sing-box executable missing after package installation"

# Never override the distribution's sing-box service; create an independent service.
if ! getent group anytls-nat >/dev/null; then
  groupadd --system anytls-nat
fi
if ! id anytls-nat >/dev/null 2>&1; then
  useradd --system --gid anytls-nat --no-create-home --shell /usr/sbin/nologin anytls-nat
fi
install -d -m 0750 -o root -g anytls-nat /etc/anytls-nat
install -d -m 0700 /root/anytls-nat-client

info "Generating stable TLS CA and server certificate (IP SAN)"
CA_DIR=/etc/anytls-nat
openssl req -new -x509 -newkey rsa:3072 -noenc -sha256 -days 3650 \
  -keyout "$CA_DIR/ca.key" -out "$CA_DIR/ca.crt" -subj '/CN=Personal AnyTLS NAT CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
  -keyout "$CA_DIR/server.key" -out "$CA_DIR/server.csr" -subj "/CN=$PUBLIC_IP" >/dev/null 2>&1
cat > "$CA_DIR/server.ext" <<EOF_EXT
subjectAltName=IP:$PUBLIC_IP
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
EOF_EXT
openssl x509 -req -in "$CA_DIR/server.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -CAcreateserial -days 397 -sha256 -out "$CA_DIR/server.crt" -extfile "$CA_DIR/server.ext" >/dev/null 2>&1
openssl verify -CAfile "$CA_DIR/ca.crt" "$CA_DIR/server.crt" || fail "Certificate chain verification failed"

PASSWORD=$(openssl rand -hex 24)

jq -n --arg pwd "$PASSWORD" --argjson port "$LOCAL_TCP_PORT" \
  --arg crt "$CA_DIR/server.crt" --arg key "$CA_DIR/server.key" \
  '{log:{level:"warn"},inbounds:[{type:"anytls",tag:"anytls-in",listen:"0.0.0.0",listen_port:$port,users:[{name:"personal",password:$pwd}],tls:{enabled:true,min_version:"1.3",certificate_path:$crt,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}],route:{final:"direct"}}' \
  > "$CA_DIR/config.json"

# Secret files readable only by root; the service user gets access only where required.
chown root:anytls-nat "$CA_DIR" "$CA_DIR/config.json" "$CA_DIR/server.crt" "$CA_DIR/server.key"
chmod 0750 "$CA_DIR"
chmod 0640 "$CA_DIR/config.json" "$CA_DIR/server.crt" "$CA_DIR/server.key"
chmod 0600 "$CA_DIR/ca.key"
rm -f "$CA_DIR/server.csr" "$CA_DIR/server.ext" "$CA_DIR/ca.srl"

info "Checking sing-box configuration"
"$SING_BOX_BIN" check -c "$CA_DIR/config.json" || fail "sing-box config check failed"

cat > /etc/systemd/system/anytls-nat.service <<EOF_SERVICE
[Unit]
Description=AnyTLS NAT secure server (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=anytls-nat
Group=anytls-nat
Environment=GOMEMLIMIT=$GO_MEMORY_TARGET
ExecStart=$SING_BOX_BIN run -c /etc/anytls-nat/config.json
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_SERVICE
chmod 0644 /etc/systemd/system/anytls-nat.service
systemctl daemon-reload
systemctl enable --now anytls-nat
if ! systemctl is-active --quiet anytls-nat; then
  journalctl -u anytls-nat --no-pager -n 30 || true
  fail "Service did not start"
fi

info "Creating client files with verified TLS (not insecure mode)"
# Sing-box outbound snippet: embed public CA certificate and verify server IP SAN.
jq -n --arg ip "$PUBLIC_IP" --argjson port "$PUBLIC_TCP_PORT" \
  --arg pwd "$PASSWORD" --rawfile ca "$CA_DIR/ca.crt" \
  '{type:"anytls",tag:"LA-NAT-AnyTLS",server:$ip,server_port:$port,password:$pwd,tls:{enabled:true,min_version:"1.3",server_name:$ip,insecure:false,certificate:$ca}}' \
  > /root/anytls-nat-client/singbox-outbound.json

# Optional desktop test profile, local mixed proxy 127.0.0.1:2080.
jq -n --slurpfile outbound /root/anytls-nat-client/singbox-outbound.json \
  '{log:{level:"warn"},inbounds:[{type:"mixed",tag:"local",listen:"127.0.0.1",listen_port:2080}],outbounds:[$outbound[0],{type:"direct",tag:"direct"}],route:{final:"LA-NAT-AnyTLS"}}' \
  > /root/anytls-nat-client/singbox-desktop.json

FINGERPRINT=$(openssl x509 -in "$CA_DIR/server.crt" -noout -fingerprint -sha256 | sed 's/.*=//' | tr -d ':')
cat > /root/anytls-nat-client/mihomo-node.yaml <<EOF_MIHOMO
# AnyTLS - leaf certificate fingerprint is pinned, no insecure bypass
proxies:
  - name: LA-NAT-AnyTLS
    type: anytls
    server: "$PUBLIC_IP"
    port: $PUBLIC_TCP_PORT
    password: "$PASSWORD"
    sni: "$PUBLIC_IP"
    fingerprint: "$FINGERPRINT"
    skip-cert-verify: false
    udp: true
EOF_MIHOMO

cp -p "$CA_DIR/ca.crt" /root/anytls-nat-client/trusted-ca.crt
chmod 600 /root/anytls-nat-client/*
cat > /root/anytls-nat-client/README.txt <<EOF_README
AnyTLS NAT node
EXTERNAL TCP: $PUBLIC_IP:$PUBLIC_TCP_PORT
INTERNAL TCP LISTENER: 0.0.0.0:$LOCAL_TCP_PORT
Service: systemctl status anytls-nat
Server config: /etc/anytls-nat/config.json

singbox-outbound.json: use this outbound in a sing-box config; TLS CA trust is embedded.
singbox-desktop.json: local SOCKS/HTTP proxy test on 127.0.0.1:2080 (not an Android TUN profile).
mihomo-node.yaml: node snippet; certificate SHA-256 fingerprint pinning is required.
trusted-ca.crt: public CA certificate for clients that support custom trusted CAs.
TLS server certificate expires approximately 397 days after installation.
Do NOT upload client JSON or node YAML to a public GitHub repository: they contain password.
EOF_README
chmod 600 /root/anytls-nat-client/README.txt

printf '\n========================================\n'
printf '[OK] AnyTLS running: TCP external %s:%s -> internal %s\n' "$PUBLIC_IP" "$PUBLIC_TCP_PORT" "$LOCAL_TCP_PORT"
printf '[OK] systemd: systemctl status anytls-nat\n'
printf '[OK] Client files: /root/anytls-nat-client/\n'
printf '[OK] Certificate validity: ~397 days; renew before expiry\n'
printf '[NOTE] Do NOT install nginx/apache on internal port %s, or it will conflict.\n' "$LOCAL_TCP_PORT"
printf '========================================\n'
