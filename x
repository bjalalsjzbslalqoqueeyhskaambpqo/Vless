#!/bin/bash
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then error "Ejecutar como root."; exit 1; fi

info "Actualizando paquetes..."
apt-get update -qq
apt-get install -y -qq curl wget python3 python3-pip ca-certificates iproute2 unzip systemd

FRESH_INSTALL=true
if [ -f /opt/btserver/token.txt ] && systemctl is-active --quiet btserver 2>/dev/null; then
    FRESH_INSTALL=false
    warn "Instalaci\u00f3n existente \u2192 modo ACTUALIZACI\u00d3N"
else
    info "No se detect\u00f3 instalaci\u00f3n previa \u2192 modo INSTALACI\u00d3N NUEVA"
fi

mkdir -p /opt/btserver

if [ -f /opt/btserver/token.txt ] && [ -s /opt/btserver/token.txt ]; then
    PANEL_TOKEN=$(cat /opt/btserver/token.txt)
    info "Token existente conservado."
else
    PANEL_TOKEN=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 64 || true)
    echo "${PANEL_TOKEN}" > /opt/btserver/token.txt
    chmod 600 /opt/btserver/token.txt
    info "Nuevo token generado."
fi

PANEL_PORT=8090
SERVER_IP=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1 || echo "0.0.0.0")

# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# DROPBEAR \u2014 unit nativo systemd (Debian 11 solo trae init SysV, no unit real)
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
info "Instalando dropbear..."
apt-get install -y dropbear

# Detectar binario (puede estar en /usr/sbin o /usr/bin seg\u00fan distro)
DROPBEAR_BIN=""
for p in /usr/sbin/dropbear /usr/bin/dropbear; do
    [ -x "$p" ] && { DROPBEAR_BIN="$p"; break; }
done
if [ -z "$DROPBEAR_BIN" ]; then
    error "No se encontr\u00f3 el binario de dropbear."; exit 1
fi
info "Dropbear binario: $DROPBEAR_BIN"

# Parar el servicio antes de reconfigurar
systemctl stop dropbear 2>/dev/null || true

# Deshabilitar el init SysV para que no compita con nuestro unit nativo
update-rc.d dropbear disable 2>/dev/null || true

# Marcar NO_START=1 en /etc/default/dropbear para que el init.d no arranque nada
cat > /etc/default/dropbear << 'DBEOF'
NO_START=1
DROPBEAR_PORT=2222
DROPBEAR_EXTRA_ARGS="-w -R"
DBEOF

# Eliminar el override.conf si qued\u00f3 de versiones anteriores (era ignorado de todos modos)
rm -f /etc/systemd/system/dropbear.service.d/override.conf
rmdir /etc/systemd/system/dropbear.service.d 2>/dev/null || true

# Generar claves de host si no existen
mkdir -p /etc/dropbear
dropbearkey -t rsa    -f /etc/dropbear/dropbear_rsa_host_key    2>/dev/null || true
dropbearkey -t ecdsa  -f /etc/dropbear/dropbear_ecdsa_host_key  2>/dev/null || true
dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true

# Escribir unit nativo completo \u2014 tiene precedencia total sobre el generador SysV
# en /run/systemd/generator.late/, por lo que ya no aparece "is not a native service"
cat > /etc/systemd/system/dropbear.service << DBSVC
[Unit]
Description=Dropbear SSH server (127.0.0.1:2222)
After=network.target
Documentation=man:dropbear(8)

[Service]
ExecStart=${DROPBEAR_BIN} -F -E -p 127.0.0.1:2222 -w -R
Restart=on-failure
RestartSec=3
KillMode=process

[Install]
WantedBy=multi-user.target
DBSVC

systemctl daemon-reload
systemctl enable dropbear 2>/dev/null || true
info "Dropbear configurado en 127.0.0.1:2222 (unit nativo systemd, SysV deshabilitado)"

# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# BADVPN-UDPGW \u2014 compilar desde source (el repo oficial no tiene binarios)
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
UDPGW_PORT=7300
BADVPN_INSTALLED=false

if command -v badvpn-udpgw &>/dev/null; then
    info "badvpn-udpgw ya instalado \u2014 omitiendo compilaci\u00f3n."
    BADVPN_INSTALLED=true
else
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ]; then
        info "Instalando dependencias para compilar badvpn..."
        apt-get install -y -qq cmake gcc make git 2>/dev/null || \
            apt-get install -y cmake gcc make git
        BADVPN_TMP=$(mktemp -d)
        info "Descargando badvpn desde source..."
        if git clone --depth=1 https://github.com/ambrop72/badvpn.git "$BADVPN_TMP/badvpn" 2>/dev/null; then
            mkdir -p "$BADVPN_TMP/build"
            cd "$BADVPN_TMP/build"
            if cmake "$BADVPN_TMP/badvpn" \
                    -DBUILD_NOTHING_BY_DEFAULT=1 \
                    -DBUILD_UDPGW=1 \
                    -DCMAKE_BUILD_TYPE=Release \
                    -DCMAKE_INSTALL_PREFIX=/usr/local \
                    2>/dev/null && make -j"$(nproc)" 2>/dev/null; then
                cp udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
                chmod +x /usr/local/bin/badvpn-udpgw
                BADVPN_INSTALLED=true
                info "badvpn-udpgw compilado e instalado correctamente."
            else
                warn "Fall\u00f3 la compilaci\u00f3n de badvpn \u2014 omitiendo."
            fi
            cd - > /dev/null
        else
            warn "No se pudo clonar el repositorio de badvpn \u2014 omitiendo."
        fi
        rm -rf "$BADVPN_TMP"
    else
        warn "badvpn no soportado en arquitectura $ARCH \u2014 omitiendo."
    fi
fi

# Crear unit systemd para badvpn-udpgw si est\u00e1 disponible
if [ "$BADVPN_INSTALLED" = true ]; then
    cat > /etc/systemd/system/badvpn.service << BVSVC
[Unit]
Description=BadVPN UDP Gateway (puerto ${UDPGW_PORT})
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:${UDPGW_PORT} --max-clients 500 --max-connections-for-client 10
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
BVSVC
    systemctl daemon-reload
    systemctl enable badvpn 2>/dev/null || true
fi

# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# TUNNEL-ONLY SHELL
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
cat > /usr/local/bin/tunnel-only << 'SHEOF'
#!/bin/bash
echo "Tunneling only. No shell access."
sleep 86400
SHEOF
chmod +x /usr/local/bin/tunnel-only
grep -qxF "/usr/local/bin/tunnel-only" /etc/shells || echo "/usr/local/bin/tunnel-only" >> /etc/shells

id -u sshtunnel &>/dev/null || useradd -r -s /usr/sbin/nologin -M sshtunnel 2>/dev/null || true

# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# XRAY
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
info "Instalando/actualizando Xray..."
if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
    info "Xray instalado correctamente."
else
    error "Fall\u00f3 la instalaci\u00f3n de Xray."
    exit 1
fi

# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# BBR
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
info "Activando BBR..."
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
    grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || {
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    }
    sysctl -p -q 2>/dev/null || true
    info "BBR activado."
else
    warn "BBR no disponible en este kernel."
fi

# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# XRAY CONFIG
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
XRAY_CONFIG=/usr/local/etc/xray/config.json
mkdir -p "$(dirname "$XRAY_CONFIG")"

if [ "$FRESH_INSTALL" = true ] || [ ! -f "$XRAY_CONFIG" ]; then
    info "Escribiendo configuraci\u00f3n de Xray..."
    cat > "$XRAY_CONFIG" << 'XEOF'
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": ["8.8.8.8", "1.1.1.1"],
    "queryStrategy": "UseIPv4"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 600,
        "uplinkOnly": 30,
        "downlinkOnly": 30,
        "bufferSize": 512
      }
    },
    "system": {
      "udpTimeout": 0,
      "connIdle": 600,
      "downlinkOnly": 30,
      "uplinkOnly": 30
    }
  },
  "inbounds": [
    {
      "port": 10809,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "a3482e88-686a-4a58-8126-99c9df64b7bf" }],
        "decryption": "none"
      },
      "streamSettings": { "network": "tcp", "security": "none" }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true,
          "tcpCongestion": "bbr",
          "tcpKeepAliveInterval": 30,
          "tcpKeepAliveIdle": 60,
          "tcpUserTimeout": 10000
        }
      }
    }
  ]
}
XEOF
else
    warn "Config de Xray existente conservada."
fi

# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
# BTSERVER.PY
# \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
info "Escribiendo btserver.py..."
cat > /opt/btserver/btserver.py << 'PYEOF'
#!/usr/bin/env python3
import asyncio, struct, time, json, threading
from pathlib import Path

TYPE_OPEN  = 0x01
TYPE_DATA  = 0x02
TYPE_CLOSE = 0x03

DB_PATH    = Path("/opt/btserver/clients.json")
DB_CACHE   = {}
DB_MTIME   = 0.0
ACTIVE_SESSIONS = {}

XRAY_HOST  = "127.0.0.1"
XRAY_PORT  = 10809
SSH_HOST   = "127.0.0.1"
SSH_PORT   = 2222

def load_db():
    global DB_CACHE, DB_MTIME
    if not DB_PATH.exists():
        return {}
    try:
        mtime = DB_PATH.stat().st_mtime
        if mtime == DB_MTIME and DB_CACHE:
            return DB_CACHE
        DB_CACHE = json.loads(DB_PATH.read_text())
        DB_MTIME = mtime
        return DB_CACHE
    except:
        return DB_CACHE

def ensure_client(client_id):
    db = load_db()
    item = db.get(client_id)
    now = int(time.time())
    if not item:
        return "UNKNOWN", 0, "", 0
    expires_at = int(item.get("expires_at", 0))
    name = str(item.get("name", "")).strip() or "sin-nombre"
    if now > expires_at:
        return "EXPIRED", 0, name, expires_at
    days_left = max(0, (expires_at - now +
