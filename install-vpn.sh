#!/usr/bin/env bash
# ============================================================================
#  INSTALL VPN ALL-IN-ONE — Debian / Ubuntu (VPS)
#  ----------------------------------------------------------------------------
#  Yang diinstall dalam satu script:
#    1. ZET UI (panel Xray, fork 3x-ui) -> VMess, VLESS, Trojan, Shadowsocks, Reality, dll
#       + opsional SSL Let's Encrypt untuk panel (domain atau IP)
#    2. OpenVPN -> server + file client (.ovpn) siap pakai
#    3. L2TP/IPsec (Libreswan + xl2tpd) -> PSK/user/password dibuat otomatis
#    4. IKEv2/IPsec (strongSwan) -> sertifikat-based, cepat & stabil
#    5. WireGuard -> server + client (.conf + QR png)
#    6. Shadowsocks (shadowsocks-libev) -> user per-port, kelola via CLI
#    7. SSH     -> pastikan ssh aktif & port 22 terbuka
#       + Dropbear di port tambahan untuk akun SSH tunnel (user ssh add)
#
#  Kelola user VPN:
#     bash install-vpn.sh user openvpn   add NAMA
#     bash install-vpn.sh user openvpn   list
#     bash install-vpn.sh user openvpn   remove NAMA
#     bash install-vpn.sh user l2tp      add NAMA [password]
#     bash install-vpn.sh user l2tp      list
#     bash install-vpn.sh user l2tp      remove NAMA
#     bash install-vpn.sh user ikev2     add NAMA
#     bash install-vpn.sh user ikev2     list
#     bash install-vpn.sh user ikev2     remove NAMA
#     bash install-vpn.sh user wireguard add NAMA
#     bash install-vpn.sh user wireguard list
#     bash install-vpn.sh user wireguard remove NAMA
#     bash install-vpn.sh user shadowsocks add NAMA [port] [password]
#     bash install-vpn.sh user shadowsocks list
#     bash install-vpn.sh user shadowsocks remove NAMA
#     bash install-vpn.sh user ssh       add NAMA [hari] [password]
#     bash install-vpn.sh user ssh       list
#     bash install-vpn.sh user ssh       remove NAMA
#
#  Cek panel & konflik port:
#     bash install-vpn.sh panel check     # status panel/xray + deteksi inbound
#                                        # yang memakai port layanan sistem
#
#  Cara pakai install:
#     sudo -i
#     bash install-vpn.sh                  # install semua
#     bash install-vpn.sh uninstall        # hapus semua layanan VPN (ada konfirmasi)
#     bash install-vpn.sh help             # bantuan
#
#  Env yang bisa dipakai (untuk otomasi / tanpa prompt):
#     VPN_SSL_MODE=domain|ip|none     (default: none)
#     VPN_SSL_DOMAIN=sub.domain.com   (dipakai jika mode=domain)
#     VPN_IPSEC_MODE=l2tp|ikev2|none (pilih mode IPsec, default: ikev2)
#     VPN_INSTALL_WIREGUARD=no        (untuk melewati WireGuard)
#     VPN_INSTALL_SHADOWSOCKS=no      (untuk melewati Shadowsocks)
#     VPN_UNINSTALL_YES=yes           (uninstall tanpa konfirmasi)
#
#  Catatan:
#    - Harus dijalankan sebagai root.
#    - Buka port di panel VPS provider: 22/tcp, 54321/tcp (panel), 80/tcp (SSL),
#      1194/udp (OpenVPN), 500/udp+4500/udp+1701/udp (L2TP/IPsec),
#      500/udp+4500/udp (IKEv2/IPsec), 51820/udp (WireGuard).
#    - Port inbound Xray (VMess/VLESS/Trojan/SS) dibuat dari panel ZET UI;
#      jangan lupa buka port-nya juga di panel VPS provider.
#    - IKEv2 & L2TP/IPsec pakai port yang sama (500/4500/udp); jangan diinstall
#      bersamaan jika tidak perlu (keduanya pakai strongSwan/libreswan).
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Warna & helper
# ---------------------------------------------------------------------------
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
cyan='\033[0;36m'
plain='\033[0m'

info()  { echo -e "${blue}[INFO]${plain} $*"; }
ok()    { echo -e "${green}[OK]${plain} $*"; }
warn()  { echo -e "${yellow}[WARN]${plain} $*"; }
fail()  { echo -e "${red}[ERROR]${plain} $*"; exit 1; }
section() {
  echo
  echo -e "${cyan}==================================================${plain}"
  echo -e "${cyan}  $*${plain}"
  echo -e "${cyan}==================================================${plain}"
}

# ---------------------------------------------------------------------------
# Variabel global
# ---------------------------------------------------------------------------
SERVER_IP=""
OVPN_DIR="/etc/openvpn/server"
EASYRSA_DIR="$OVPN_DIR/easy-rsa"
PANEL_USER="admin"
PANEL_PASS="admin"
PANEL_PORT="54321"
PANEL_PATH="/"
ACCESS_URL=""
SSL_MODE="none"
SSL_DOMAIN=""
L2TP_PSK=""
L2TP_USER=""
L2TP_PASS=""
WG_CONF="/etc/wireguard/wg0.conf"
WG_DIR="/root/wireguard"
WG_CLIENT_DEFAULT="wgclient1"
SS_DIR="/etc/shadowsocks-libev"
SS_LAST_PORT=""
SSH_USERS_FILE="/etc/ssh-tunnel-users"        # tracking akun SSH tunnel: nama|expiry|password
SSH_TUNNEL_INFO="/root/ssh-tunnel-users.txt"  # info akun (mode 600)
DB_CONF="/etc/default/dropbear"
DB_PORT=""
IKEV2_DIR="/etc/ikev2"
IKEV2_CA_DIR="/etc/ikev2/ca"
IKEV2_CLIENT_DIR="/root/ikev2-clients"
IKEV2_CLIENT_DEFAULT="client1"
IKEV2_POOL="10.10.10.0/24"

# ---------------------------------------------------------------------------
# Fungsi dasar
# ---------------------------------------------------------------------------
detect_ip() {
  local ip
  ip="$(curl -4 -s --max-time 10 ifconfig.me 2>/dev/null \
        || curl -4 -s --max-time 10 api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  fi
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "$ip" ]] && ip="IP_ANDA"
  printf '%s' "$ip"
}

gen_rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

# Simpan aturan NAT agar persisten setelah reboot.
# - Jika ufw aktif: tulis ke /etc/ufw/before.rules (blok *nat) + reload ufw.
# - Lainnya: pakai netfilter-persistent.
persist_nat_rule() {
  local rule="$1"
  [[ -z "$rule" ]] && return 0

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local f="/etc/ufw/before.rules"
    [[ -f "$f" ]] || return 0
    if grep -Fq -- "$rule" "$f"; then
      return 0
    fi
    if grep -q '^\*nat' "$f"; then
      # sisipkan rule sebelum COMMIT pertama di blok *nat
      awk -v r="$rule" '
        /^\*nat$/ { in_nat=1 }
        in_nat && /^COMMIT$/ { print r; in_nat=0 }
        { print }
      ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
      # tidak ada blok *nat — tambahkan di akhir file
      {
        cat "$f"
        printf '\n*nat\n:POSTROUTING ACCEPT [0:0]\n%s\nCOMMIT\n' "$rule"
      } > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    chmod 644 "$f"
    ufw reload >/dev/null 2>&1 || true
    ok "Aturan NAT disimpan ke /etc/ufw/before.rules."
  else
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

human_bytes() {
  local b="${1:-0}"
  if (( b >= 1073741824 )); then awk -v n="$b" 'BEGIN{printf "%.1f GB", n/1073741824}'
  elif (( b >= 1048576 )); then awk -v n="$b" 'BEGIN{printf "%.1f MB", n/1048576}'
  elif (( b >= 1024 )); then awk -v n="$b" 'BEGIN{printf "%.1f KB", n/1024}'
  else printf '%s B' "$b"; fi
}

usage() {
  cat <<'EOF'
Cara pakai:
  bash install-vpn.sh                        # install semua: ZET UI + OpenVPN + L2TP/IPsec + WireGuard + Shadowsocks + SSH
  bash install-vpn.sh add-client NAMA        # (alias) tambah client OpenVPN
  bash install-vpn.sh user <svc> <aksi> [nama] [password]
  bash install-vpn.sh panel check            # cek panel ZET UI + konflik port inbound
  bash install-vpn.sh uninstall              # hapus SEMUA layanan VPN (SSH tetap)
  bash install-vpn.sh help                   # bantuan ini

Kelola user VPN:
  openvpn   : add NAMA | list | remove NAMA
  l2tp      : add NAMA [password] | list | remove NAMA
  ikev2     : add NAMA | list | remove NAMA
  wireguard : add NAMA | list | remove NAMA
  shadowsocks: add NAMA [port] [password] | list | remove NAMA
  ssh       : add NAMA [hari] [password] | list | remove NAMA

Contoh:
  bash install-vpn.sh user openvpn add budi
  bash install-vpn.sh user openvpn list
  bash install-vpn.sh user openvpn remove budi
  bash install-vpn.sh user l2tp add budi rahasia123
  bash install-vpn.sh user l2tp list
  bash install-vpn.sh user l2tp remove budi
  bash install-vpn.sh user ikev2 add budi
  bash install-vpn.sh user ikev2 list
  bash install-vpn.sh user ikev2 remove budi
  bash install-vpn.sh user wireguard add budi
  bash install-vpn.sh user wireguard list
  bash install-vpn.sh user wireguard remove budi
  bash install-vpn.sh user shadowsocks add budi
  bash install-vpn.sh user shadowsocks list
  bash install-vpn.sh user shadowsocks remove budi
  bash install-vpn.sh user ssh add budi 30
  bash install-vpn.sh user ssh list
  bash install-vpn.sh user ssh remove budi
EOF
}

# ---------------------------------------------------------------------------
# 1. Cek root & OS
# ---------------------------------------------------------------------------
check_root_os() {
  section "1. Cek root & sistem"
  [[ $EUID -ne 0 ]] && fail "Jalankan script ini sebagai root:  sudo -i  lalu  bash install-vpn.sh"

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    fail "Tidak bisa mendeteksi OS (/etc/os-release tidak ada)."
  fi

  case "$OS_ID" in
    debian|ubuntu|armbian) ok "OS terdeteksi: $PRETTY_NAME" ;;
    *) fail "Script ini khusus Debian/Ubuntu (terdeteksi: $OS_ID)." ;;
  esac
}

# ---------------------------------------------------------------------------
# 2. Update & dependensi
# ---------------------------------------------------------------------------
install_base() {
  section "2. Update sistem & install dependensi"
  export DEBIAN_FRONTEND=noninteractive

  # preseed biar iptables-persistent tidak bertanya saat install
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections

  apt-get update -y

  # iptables-persistent KONFLIK dengan ufw (apt akan menghapus ufw).
  # Jika ufw aktif, jangan install iptables-persistent — firewall user tidak boleh hilang.
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw aktif — iptables-persistent dilewati (konflik paket)."
    warn "Aturan NAT VPN akan disimpan via /etc/ufw/before.rules."
    apt-get install -y curl wget openssl ca-certificates openvpn easy-rsa
  else
    apt-get install -y \
      curl wget openssl ca-certificates \
      openvpn easy-rsa \
      iptables-persistent netfilter-persistent
  fi

  ok "Dependensi terinstall."
}

# ---------------------------------------------------------------------------
# 3. Pilihan SSL untuk panel ZET UI
# ---------------------------------------------------------------------------
prompt_ssl() {
  section "3. Konfigurasi SSL panel (opsional)"

  # Bisa di-set lewat env untuk otomasi
  if [[ -n "${VPN_SSL_MODE:-}" ]]; then
    case "$VPN_SSL_MODE" in
      domain|ip|none) SSL_MODE="$VPN_SSL_MODE" ;;
      *) warn "VPN_SSL_MODE tidak dikenal: $VPN_SSL_MODE (pakai none)"; SSL_MODE="none" ;;
    esac
    SSL_DOMAIN="${VPN_SSL_DOMAIN:-}"
    [[ "$SSL_MODE" != "none" ]] && ok "SSL mode: $SSL_MODE (dari env)"
    return 0
  fi

  [[ -t 0 ]] || return 0   # non-TTY -> lewati prompt

  echo
  echo "  SSL hanya dipasang saat ZET UI fresh install."
  echo "  1) Domain  — Let's Encrypt 90 hari (auto-renew). Butuh domain + port 80 terbuka"
  echo "  2) IP      — Let's Encrypt ~6 hari (auto-renew). Butuh port 80 terbuka"
  echo "  3) Lewati  — panel tetap HTTP (default)"
  read -rp "  Pilihan [1/2/3] (default 3): " choice
  case "${choice:-3}" in
    1)
      read -rp "  Masukkan domain (mis. vpn.example.com): " SSL_DOMAIN
      SSL_DOMAIN="$(printf '%s' "$SSL_DOMAIN" | tr -d ' ')"
      if [[ -z "$SSL_DOMAIN" ]]; then
        warn "Domain kosong, SSL dilewati."
        SSL_MODE="none"
      else
        SSL_MODE="domain"
        warn "Pastikan DNS A record $SSL_DOMAIN mengarah ke $SERVER_IP dan port 80 terbuka!"
      fi
      ;;
    2)
      SSL_MODE="ip"
      warn "Pastikan port 80 terbuka (untuk validasi Let's Encrypt)!"
      ;;
    *) SSL_MODE="none" ;;
  esac
}

# ---------------------------------------------------------------------------
# 4. Install ZET UI (panel Xray)
# ---------------------------------------------------------------------------
install_xui() {
  section "4. Install ZET UI (panel Xray)"

  if [[ -d /usr/local/x-ui ]]; then
    warn "ZET UI sudah terinstall, dilewati (SSL tidak diterapkan ulang)."
  else
    info "Mengunduh installer ZET UI..."
    curl -Ls -o /tmp/3x-ui-install.sh https://raw.githubusercontent.com/zuf1/zet-ui/main/install.sh \
      || fail "Gagal mengunduh installer ZET UI."
    [[ -s /tmp/3x-ui-install.sh ]] || fail "Installer ZET UI kosong (gagal diunduh)."
    chmod +x /tmp/3x-ui-install.sh
    if [[ "$SSL_MODE" == "domain" ]]; then
      XUI_NONINTERACTIVE=1 XUI_SSL_MODE=domain XUI_DOMAIN="$SSL_DOMAIN" bash /tmp/3x-ui-install.sh
    elif [[ "$SSL_MODE" == "ip" ]]; then
      XUI_NONINTERACTIVE=1 XUI_SSL_MODE=ip bash /tmp/3x-ui-install.sh
    else
      XUI_NONINTERACTIVE=1 bash /tmp/3x-ui-install.sh
    fi
    rm -f /tmp/3x-ui-install.sh
    ok "ZET UI terinstall."
  fi

  # Ambil kredensial panel dari file hasil install (mode non-interaktif)
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shellcheck disable=SC1091
    . /etc/x-ui/install-result.env
    PANEL_USER="${XUI_USERNAME:-$PANEL_USER}"
    PANEL_PASS="${XUI_PASSWORD:-$PANEL_PASS}"
    PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
    PANEL_PATH="${XUI_WEB_BASE_PATH:-/}"
  fi

  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui >/dev/null 2>&1 || true
  ok "Panel ZET UI aktif (port $PANEL_PORT)."
}

# ---------------------------------------------------------------------------
# 5. OpenVPN
# ---------------------------------------------------------------------------
write_ovpn_client() {
  local name="$1" out="$2"
  cat > "$out" <<EOF
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
key-direction 1
verb 3
<ca>
$(cat "$EASYRSA_DIR/pki/ca.crt")
</ca>
<cert>
$(sed -ne '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$EASYRSA_DIR/pki/issued/$name.crt")
</cert>
<key>
$(cat "$EASYRSA_DIR/pki/private/$name.key")
</key>
<tls-auth>
$(cat "$OVPN_DIR/ta.key")
</tls-auth>
EOF
  chmod 600 "$out"
}

setup_openvpn() {
  section "5. Install & konfigurasi OpenVPN"

  if [[ -f "$OVPN_DIR/server.conf" ]]; then
    warn "OpenVPN sudah dikonfigurasi, dilewati."
    return 0
  fi

  mkdir -p "$OVPN_DIR"

  # --- 5a. Setup PKI dengan easy-rsa (non-interaktif) ---
  info "Membuat sertifikat server OpenVPN (easy-rsa)..."
  rm -rf "$EASYRSA_DIR"
  make-cadir "$EASYRSA_DIR"
  cd "$EASYRSA_DIR"

  ./easyrsa --batch init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch gen-req server nopass
  ./easyrsa --batch sign-req server server
  ./easyrsa --batch gen-dh
  openvpn --genkey --secret ta.key

  cp pki/ca.crt "$OVPN_DIR/"
  cp pki/issued/server.crt "$OVPN_DIR/"
  cp pki/private/server.key "$OVPN_DIR/"
  cp pki/dh.pem "$OVPN_DIR/dh.pem"
  mv ta.key "$OVPN_DIR/ta.key"

  # --- 5b. Konfigurasi server ---
  cat > "$OVPN_DIR/server.conf" <<'EOF'
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
tls-auth ta.key 0
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
verb 3
explicit-exit-notify 1
EOF

  # --- 5c. IP forwarding + NAT ---
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  if [[ -n "$DEFAULT_IFACE" ]]; then
    iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$DEFAULT_IFACE" -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$DEFAULT_IFACE" -j MASQUERADE
    persist_nat_rule "-A POSTROUTING -s 10.8.0.0/24 -o $DEFAULT_IFACE -j MASQUERADE"
  else
    warn "Tidak menemukan interface default; NAT OpenVPN dilewati."
  fi

  # --- 5d. Jalankan service ---
  systemctl enable openvpn-server@server >/dev/null 2>&1 || true
  systemctl restart openvpn-server@server
  ok "OpenVPN server berjalan (port 1194/udp)."

  # --- 5e. Buat client pertama ---
  info "Membuat client OpenVPN (client1)..."
  cd "$EASYRSA_DIR"
  ./easyrsa --batch gen-req client1 nopass
  ./easyrsa --batch sign-req client client1
  write_ovpn_client client1 /root/client1.ovpn
  ok "File client: /root/client1.ovpn"
}

# --- Management OpenVPN ---
add_openvpn_client() {
  local name="$1"
  [[ -f "$OVPN_DIR/server.conf" ]] || fail "OpenVPN belum diinstall. Jalankan dulu: bash install-vpn.sh"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama client hanya boleh huruf/angka, tanda '-' atau '_'"
  [[ -d "$EASYRSA_DIR/pki" ]] || fail "PKI OpenVPN tidak ditemukan di $EASYRSA_DIR"
  [[ -f "$EASYRSA_DIR/pki/private/$name.key" ]] && fail "Client '$name' sudah ada!"

  [[ -z "$SERVER_IP" ]] && SERVER_IP="$(detect_ip)"

  cd "$EASYRSA_DIR"
  ./easyrsa --batch gen-req "$name" nopass
  ./easyrsa --batch sign-req client "$name"
  write_ovpn_client "$name" "/root/$name.ovpn"
  ok "Client OpenVPN '$name' dibuat: /root/$name.ovpn"
}

ovpn_list() {
  [[ -d "$EASYRSA_DIR/pki/issued" ]] || fail "OpenVPN belum diinstall."
  echo "Client OpenVPN:"
  local c found=0
  for c in "$EASYRSA_DIR"/pki/issued/*.crt; do
    [[ -e "$c" ]] || continue
    local n
    n="$(basename "$c" .crt)"
    [[ "$n" == "server" ]] && continue
    found=1
    local file=""
    [[ -f "/root/$n.ovpn" ]] && file=" (file: /root/$n.ovpn)"
    echo "  - $n$file"
  done
  [[ $found -eq 0 ]] && echo "  (belum ada client)"
}

ovpn_remove() {
  local name="$1"
  [[ -f "$OVPN_DIR/server.conf" ]] || fail "OpenVPN belum diinstall."
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama client hanya boleh huruf/angka, tanda '-' atau '_'"
  [[ "$name" == "server" ]] && fail "Tidak bisa menghapus client 'server'."
  [[ -f "$EASYRSA_DIR/pki/issued/$name.crt" ]] || fail "Client '$name' tidak ditemukan."

  cd "$EASYRSA_DIR"
  ./easyrsa --batch revoke "$name"
  ./easyrsa gen-crl
  cp pki/crl.pem "$OVPN_DIR/crl.pem"
  chmod 644 "$OVPN_DIR/crl.pem"
  if ! grep -q '^crl-verify' "$OVPN_DIR/server.conf"; then
    echo "crl-verify crl.pem" >> "$OVPN_DIR/server.conf"
  fi
  rm -f "/root/$name.ovpn"
  systemctl restart openvpn-server@server
  ok "Client '$name' dicabut (revoked) — sertifikatnya tidak bisa dipakai lagi."
}

# ---------------------------------------------------------------------------
# 6. L2TP/IPsec (Libreswan + xl2tpd)
# ---------------------------------------------------------------------------
install_l2tp() {
  section "6. Install L2TP/IPsec"

  if command -v xl2tpd >/dev/null 2>&1; then
    warn "L2TP/IPsec sudah terinstall, dilewati."
    # coba ambil kredensial lama dari file simpanan
    if [[ -f /root/vpn-credentials.txt ]]; then
      local sec
      sec="$(sed -n '/=== L2TP\/IPSEC ===/,/=== SSH ===/p' /root/vpn-credentials.txt)"
      L2TP_PSK="$(printf '%s\n' "$sec" | sed -n 's/^IPsec PSK  : //p' | head -1)"
      L2TP_USER="$(printf '%s\n' "$sec" | sed -n 's/^Username   : //p' | head -1)"
      L2TP_PASS="$(printf '%s\n' "$sec" | sed -n 's/^Password   : //p' | head -1)"
    fi
    return 0
  fi

  info "Menginstall L2TP/IPsec (Libreswan + xl2tpd), kredensial dibuat otomatis..."
  L2TP_PSK="$(gen_rand 20)"
  L2TP_USER="vpnuser"
  L2TP_PASS="$(gen_rand 16)"

  curl -fsSL https://get.vpnsetup.net -o /tmp/vpnsetup.sh || fail "Gagal mengunduh script L2TP/IPsec"

  if ! VPN_IPSEC_PSK="$L2TP_PSK" VPN_USER="$L2TP_USER" VPN_PASSWORD="$L2TP_PASS" \
       VPN_DNS_SRV1=1.1.1.1 VPN_DNS_SRV2=1.0.0.1 \
       sh /tmp/vpnsetup.sh; then
    warn "Instalasi L2TP/IPsec bermasalah — cek output di atas."
    L2TP_PSK=""; L2TP_USER=""; L2TP_PASS=""
  else
    ok "L2TP/IPsec terinstall."
  fi
  rm -f /tmp/vpnsetup.sh
}

install_l2tp_flow() {
  install_l2tp
}

# --- Management L2TP (user disimpan di /etc/ppp/chap-secrets) ---
l2tp_add() {
  local name="$1" pass="${2:-}"
  [[ "$name" =~ ^[a-zA-Z0-9_.-]+$ ]] || fail "Nama user hanya boleh huruf/angka/._-"
  local f="/etc/ppp/chap-secrets"
  [[ -f "$f" ]] || fail "L2TP belum diinstall (file $f tidak ada)."

  if awk -v u="$name" '!/^[[:space:]]*#/ && $1==u {found=1} END{exit !found}' "$f"; then
    fail "User L2TP '$name' sudah ada."
  fi

  [[ -z "$pass" ]] && pass="$(gen_rand 12)"
  [[ "$pass" == *[[:space:]]* ]] && fail "Password L2TP tidak boleh mengandung spasi/tab."
  printf '%s\t*\t%s\t*\n' "$name" "$pass" >> "$f"
  ok "User L2TP '$name' ditambahkan. Password: $pass"
}

l2tp_list() {
  local f="/etc/ppp/chap-secrets"
  [[ -f "$f" ]] || fail "L2TP belum diinstall."
  echo "User L2TP:"
  local out
  out="$(awk '!/^[[:space:]]*#/ && NF>=3 {print $1}' "$f" | sort -u)"
  if [[ -z "$out" ]]; then
    echo "  (belum ada user)"
  else
    printf '  - %s\n' "$out"
  fi
}

l2tp_remove() {
  local name="$1"
  local f="/etc/ppp/chap-secrets"
  [[ -f "$f" ]] || fail "L2TP belum diinstall."
  [[ "$name" =~ ^[a-zA-Z0-9_.-]+$ ]] || fail "Nama user hanya boleh huruf/angka/._-"

  if ! awk -v u="$name" '!/^[[:space:]]*#/ && $1==u {found=1} END{exit !found}' "$f"; then
    fail "User L2TP '$name' tidak ditemukan."
  fi

  cp "$f" "$f.bak"
  awk -v u="$name" '!/^[[:space:]]*#/ && $1==u {next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  ok "User L2TP '$name' dihapus (backup: $f.bak)."
}

# ---------------------------------------------------------------------------
# 7. WireGuard
# ---------------------------------------------------------------------------
wg_sync() {
  if ! systemctl is-active --quiet wg-quick@wg0; then
    warn "wg0 tidak aktif — konfigurasi disimpan, akan aktif saat wg-quick@wg0 jalan."
    return 0
  fi
  wg syncconf wg0 <(wg-quick strip wg0) || warn "Gagal sinkronisasi konfigurasi wg0."
}

wg_next_ip() {
  local conf="$WG_CONF" max=1 n
  while IFS= read -r line; do
    case "$line" in
      AllowedIPs\ =\ 10.66.66.*)
        n="${line##*10.66.66.}"
        n="${n%%/*}"
        [[ "$n" =~ ^[0-9]+$ ]] && (( n > max )) && max=$n
        ;;
    esac
  done < "$conf"
  (( max += 1 ))
  if (( max > 254 )); then
    return 1
  fi
  printf '10.66.66.%d' "$max"
}

install_wireguard() {
  section "7. Install WireGuard"

  if [[ -f "$WG_CONF" ]]; then
    warn "WireGuard sudah dikonfigurasi, dilewati."
    return 0
  fi

  info "Menginstall WireGuard..."
  apt-get install -y wireguard qrencode
  modprobe wireguard 2>/dev/null || warn "Modul wireguard tidak bisa dimuat — pastikan kernel mendukungnya."

  mkdir -p /etc/wireguard
  local srv_priv srv_pub iface
  srv_priv="$(wg genkey)"
  srv_pub="$(printf '%s' "$srv_priv" | wg pubkey)"
  iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

  umask 077
  {
    echo "[Interface]"
    echo "Address = 10.66.66.1/24"
    echo "ListenPort = 51820"
    echo "PrivateKey = $srv_priv"
    if [[ -n "$iface" ]]; then
      echo "PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE; ip6tables -A FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o $iface -j MASQUERADE"
      echo "PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $iface -j MASQUERADE; ip6tables -D FORWARD -i wg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o $iface -j MASQUERADE"
    else
      warn "Interface default tidak ditemukan; NAT WireGuard dilewati."
    fi
  } > "$WG_CONF"
  chmod 600 "$WG_CONF"
  umask 022

  if systemctl restart wg-quick@wg0 2>/dev/null; then
    ok "WireGuard server berjalan (port 51820/udp)."
    add_wg_client "$WG_CLIENT_DEFAULT"
  else
    warn "Gagal menjalankan wg-quick@wg0 — cek dukungan kernel (modprobe wireguard)."
  fi
}

install_wireguard_flow() {
  if [[ "${VPN_INSTALL_WIREGUARD:-yes}" == "no" ]]; then
    warn "WireGuard dilewati (VPN_INSTALL_WIREGUARD=no)."
    return 0
  fi
  if [[ -t 0 ]]; then
    read -rp "Install WireGuard juga? [Y/n] (default Y): " wg_choice
    if [[ "$wg_choice" =~ ^[nN] ]]; then
      warn "WireGuard dilewati."
      return 0
    fi
  fi
  install_wireguard
}

# --- Management WireGuard ---
add_wg_client() {
  local name="$1"
  [[ -f "$WG_CONF" ]] || fail "WireGuard belum diinstall. Jalankan dulu: bash install-vpn.sh"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama client hanya boleh huruf/angka, tanda '-' atau '_'"
  mkdir -p "$WG_DIR"
  [[ -f "$WG_DIR/$name.conf" ]] && fail "Client '$name' sudah ada!"
  grep -q "^# wg-client $name " "$WG_CONF" && fail "Client '$name' sudah ada di konfigurasi!"

  local ip
  ip="$(wg_next_ip)" || fail "Subnet WireGuard penuh (10.66.66.2-254)."

  local cli_priv cli_pub psk srv_pub pk
  cli_priv="$(wg genkey)"
  cli_pub="$(printf '%s' "$cli_priv" | wg pubkey)"
  psk="$(wg genpsk)"
  srv_pub="$(wg show wg0 public-key 2>/dev/null || true)"
  if [[ -z "$srv_pub" ]]; then
    pk="$(awk '/^PrivateKey/{print $3; exit}' "$WG_CONF")"
    [[ -n "$pk" ]] && srv_pub="$(printf '%s' "$pk" | wg pubkey)"
  fi
  [[ -z "$srv_pub" ]] && fail "Tidak bisa membaca public key server WireGuard."

  [[ -z "$SERVER_IP" ]] && SERVER_IP="$(detect_ip)"

  # tambah peer ke konfigurasi server
  {
    echo
    echo "# wg-client $name pub=$cli_pub"
    echo "[Peer]"
    echo "PublicKey = $cli_pub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = $ip/32"
  } >> "$WG_CONF"
  wg_sync

  # file konfigurasi client
  cat > "$WG_DIR/$name.conf" <<EOF
[Interface]
Address = $ip/24
PrivateKey = $cli_priv
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = $srv_pub
PresharedKey = $psk
Endpoint = $SERVER_IP:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 600 "$WG_DIR/$name.conf"

  qrencode -r "$WG_DIR/$name.conf" -o "$WG_DIR/$name.png" 2>/dev/null && chmod 600 "$WG_DIR/$name.png" || true

  ok "Client WireGuard '$name' dibuat: $WG_DIR/$name.conf (+ QR: $WG_DIR/$name.png)"
}

remove_wg_client() {
  local name="$1"
  [[ -f "$WG_CONF" ]] || fail "WireGuard belum diinstall."
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama client hanya boleh huruf/angka, tanda '-' atau '_'"
  grep -q "^# wg-client $name " "$WG_CONF" || fail "Client WireGuard '$name' tidak ditemukan."

  cp "$WG_CONF" "$WG_CONF.bak"
  awk -v n="$name" '
    BEGIN { skip=0 }
    /^# wg-client / { skip = ($0 ~ "^# wg-client " n " ") ? 1 : 0 }
    skip { next }
    { print }
  ' "$WG_CONF" > "$WG_CONF.tmp" && mv "$WG_CONF.tmp" "$WG_CONF"
  chmod 600 "$WG_CONF"
  wg_sync

  rm -f "$WG_DIR/$name.conf" "$WG_DIR/$name.png"
  ok "Client WireGuard '$name' dihapus (backup: $WG_CONF.bak)."
}

wg_list() {
  [[ -f "$WG_CONF" ]] || fail "WireGuard belum diinstall."
  local dump
  dump="$(wg show wg0 dump 2>/dev/null || true)"

  echo "Client WireGuard (wg0):"
  local found=0 name pub ip hand rx tx ep
  while IFS= read -r line; do
    case "$line" in
      "# wg-client "*)
        found=1
        name="${line#\# wg-client }"; name="${name%% pub=*}"
        pub="${line##*pub=}"
        ip="$(printf '%s\n' "$dump" | awk -v p="$pub" '$1==p {print $4; exit}')"
        hand="$(printf '%s\n' "$dump" | awk -v p="$pub" '$1==p {print $5; exit}')"
        rx="$(printf '%s\n' "$dump" | awk -v p="$pub" '$1==p {print $6; exit}')"
        tx="$(printf '%s\n' "$dump" | awk -v p="$pub" '$1==p {print $7; exit}')"
        if [[ -n "$hand" && "$hand" != "0" ]]; then
          hand="$(date -d "@$hand" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$hand")"
        else
          hand="belum pernah"
        fi
        printf '  %-14s IP: %-15s Handshake: %-18s Rx: %-10s Tx: %s\n' \
          "$name" "${ip:-?}" "$hand" "$(human_bytes "${rx:-0}")" "$(human_bytes "${tx:-0}")"
        ;;
    esac
  done < "$WG_CONF"
  [[ $found -eq 0 ]] && echo "  (belum ada client)"
}

# ---------------------------------------------------------------------------
# 8. IKEv2/IPsec (strongSwan)
# ---------------------------------------------------------------------------
install_ikev2() {
  section "7b. Install IKEv2/IPsec (strongSwan)"

  if [[ -f /etc/swanctl/conf.d/ikev2.conf ]]; then
    warn "IKEv2/IPsec sudah terinstall, dilewati."
    return 0
  fi

  info "Menginstall strongSwan (IKEv2 server)..."
  apt-get install -y strongswan strongswan-pki libcharon-extra-plugins libcharon-extauth plugins-vici >/dev/null 2>&1 || \
    apt-get install -y strongswan strongswan-pki >/dev/null 2>&1

  mkdir -p "$IKEV2_DIR" "$IKEV2_CA_DIR" "$IKEV2_CLIENT_DIR" /etc/swanctl/conf.d /etc/swanctl/private /etc/swanctl/certs /etc/swanctl/x509ca

  # --- Generate CA (Certificate Authority) ---
  info "Membuat Certificate Authority (CA)..."
  local ca_key ca_cert
  ca_key="$IKEV2_CA_DIR/ca-key.pem"
  ca_cert="$IKEV2_CA_DIR/ca-cert.pem"

  # Generate CA private key
  openssl genrsa -out "$ca_key" 4096 2>/dev/null
  chmod 600 "$ca_key"

  # Generate CA certificate
  openssl req -x509 -new -nodes -key "$ca_key" -sha256 -days 3650 \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=VPN/CN=IKEv2-CA" \
    -out "$ca_cert" 2>/dev/null
  chmod 644 "$ca_cert"

  # Copy CA to strongSwan x509ca directory
  cp "$ca_cert" /etc/swanctl/x509ca/

  # --- Generate server certificate ---
  info "Membuat sertifikat server..."
  local srv_key srv_csr srv_cert
  srv_key="/etc/swanctl/private/server-key.pem"
  srv_csr="/etc/swanctl/certs/server-csr.pem"
  srv_cert="/etc/swanctl/certs/server-cert.pem"

  openssl genrsa -out "$srv_key" 4096 2>/dev/null
  chmod 600 "$srv_key"

  openssl req -new -key "$srv_key" \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=VPN/CN=$SERVER_IP" \
    -out "$srv_csr" 2>/dev/null

  openssl x509 -req -in "$srv_csr" -CA "$ca_cert" -CAkey "$ca_key" \
    -CAcreateserial -out "$srv_cert" -days 1825 -sha256 \
    -extfile <(echo -e "subjectAltName=IP:$SERVER_IP") 2>/dev/null
  chmod 644 "$srv_cert"

  # --- Server config ---
  info "Mengkonfigurasi strongSwan server..."
  cat > /etc/swanctl/conf.d/ikev2.conf <<EOF
connections {
  ikev2-vpn {
    local_addrs  = $SERVER_IP
    remote_addrs = 0.0.0.0/0

    local {
      auth = pubkey
      certs = server-cert.pem
      id = $SERVER_IP
    }
    remote {
      auth = pubkey
    }
    children {
      ikev2-net {
        local_ts  = 0.0.0.0/0
        remote_ts = 0.0.0.0/0
        esp_proposals = aes256-sha256
        rekey_time = 0s
        dpd_action = restart
        start_action = trap
      }
    }
    version = 2
    proposals = aes256-sha256-modp2048
    reauth_time = 0s
    rekey_time = 0s
    dpd_delay = 30s
  }
}

pools {
  ikev2-pool {
    addrs = $IKEV2_POOL
    dns = 1.1.1.1, 8.8.8.8
  }
}

secrets {
  private-default {
    file = server-key.pem
  }
}
EOF

  # --- Enable IP forwarding ---
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-ikev2-forward.conf
  sysctl -w net.ipv4.ip_forward=1 >/dev/null

  # --- NAT rule for IKEv2 clients ---
  local iface
  iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
  if [[ -n "$iface" ]]; then
    iptables -t nat -C POSTROUTING -s "$IKEV2_POOL" -o "$iface" -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s "$IKEV2_POOL" -o "$iface" -j MASQUERADE
    persist_nat_rule "-A POSTROUTING -s $IKEV2_POOL -o $iface -j MASQUERADE"
  fi

  # --- Start strongSwan ---
  systemctl enable strongswan-starter >/dev/null 2>&1 || true
  systemctl restart strongswan-starter
  # Also start VICI-based service if available
  systemctl enable strongswan-ikki >/dev/null 2>&1 || systemctl enable strongswan-vici >/dev/null 2>&1 || true
  systemctl restart strongswan-ikki 2>/dev/null || systemctl restart strongswan-vici 2>/dev/null || true

  ok "IKEv2/IPsec server berjalan (port 500/4500/udp)."

  # --- Create first client ---
  info "Membuat client IKEv2 pertama ($IKEV2_CLIENT_DEFAULT)..."
  add_ikev2_client "$IKEV2_CLIENT_DEFAULT"
}

add_ikev2_client() {
  local name="$1"
  [[ -f /etc/swanctl/conf.d/ikev2.conf ]] || fail "IKEv2 belum diinstall. Jalankan dulu: bash install-vpn.sh"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama client hanya boleh huruf/angka, tanda '-' atau '_'"
  [[ -f "$IKEV2_CLIENT_DIR/$name.p12" ]] && fail "Client IKEv2 '$name' sudah ada!"

  local ca_key="$IKEV2_CA_DIR/ca-key.pem"
  local ca_cert="$IKEV2_CA_DIR/ca-cert.pem"
  local client_key client_csr client_cert client_p12
  client_key="$IKEV2_CLIENT_DIR/$name-key.pem"
  client_csr="$IKEV2_CLIENT_DIR/$name-csr.pem"
  client_cert="$IKEV2_CLIENT_DIR/$name-cert.pem"
  client_p12="$IKEV2_CLIENT_DIR/$name.p12"
  local client_mobileconfig="$IKEV2_CLIENT_DIR/$name.mobileconfig"

  # Generate client private key
  openssl genrsa -out "$client_key" 2048 2>/dev/null
  chmod 600 "$client_key"

  # Generate client CSR
  openssl req -new -key "$client_key" \
    -subj "/C=ID/ST=Jakarta/L=Jakarta/O=VPN/CN=$name" \
    -out "$client_csr" 2>/dev/null

  # Sign client certificate with CA
  openssl x509 -req -in "$client_csr" -CA "$ca_cert" -CAkey "$ca_key" \
    -CAcreateserial -out "$client_cert" -days 1825 -sha256 2>/dev/null

  # Create .p12 bundle (password: vpn)
  openssl pkcs12 -export -in "$client_cert" -inkey "$client_key" \
    -certfile "$ca_cert" -out "$client_p12" -passout pass:vpn 2>/dev/null
  chmod 600 "$client_p12"

  # Generate .mobileconfig for iOS/macOS
  local server_cert_b64
  server_cert_b64=$(base64 -w0 /etc/swanctl/certs/server-cert.pem 2>/dev/null || true)
  local ca_cert_b64
  ca_cert_b64=$(base64 -w0 "$ca_cert" 2>/dev/null || true)

  cat > "$client_mobileconfig" <<MCEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadDisplayName</key>
	<string>IKEv2 VPN - $name</string>
	<key>PayloadIdentifier</key>
	<string>com.vpn.ikev2.$name</string>
	<key>PayloadType</key>
	<string>com.apple.configuration.vpn</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadUUID</key>
	<string>$(uuidgen 2>/dev/null || openssl rand -hex 16)</string>
	<key>PayloadContent</key>
	<dict>
		<key>VPNType</key>
		<string>IKEv2</string>
		<key>VPNSubType</key>
		<string>com.apple.networkExtension.ikev2</string>
		<key>UserDefinedName</key>
		<string>IKEv2 VPN - $SERVER_IP</string>
		<key>VPNRemote</key>
		<string>$SERVER_IP</string>
		<key>VPNServerAddress</key>
		<string>$SERVER_IP</string>
		<key>AuthenticationMethod</key>
		<string>Certificate</string>
		<key>ServerCertificateIssuerCommonName</key>
		<string>IKEv2-CA</string>
		<key>ServerCertificateCommonName</key>
		<string>$SERVER_IP</string>
		<key>RemoteIdentifier</key>
		<string>$SERVER_IP</string>
		<key>LocalIdentifier</key>
		<string>$name</string>
		<key>IKESecurityAssociationParameters</key>
		<dict>
			<key>EncryptionAlgorithm</key>
			<string>AES-256</string>
			<key>IntegrityAlgorithm</key>
			<string>SHA-256</string>
			<key>DiffieHellmanGroup</key>
			<integer>14</integer>
		</dict>
		<key>IPSecSecurityAssociationParameters</key>
		<dict>
			<key>EncryptionAlgorithm</key>
			<string>AES-256</string>
			<key>IntegrityAlgorithm</key>
			<string>SHA-256</string>
			<key>DiffieHellmanGroup</key>
			<integer>14</integer>
		</dict>
		<key>OnDemandEnabled</key>
		<integer>1</integer>
		<key>OnDemandRules</key>
		<array>
			<dict>
				<key>InterfaceType</key>
				<string>Any</string>
				<key>UseDNSServers</key>
				<true/>
			</dict>
		</array>
	</dict>
</dict>
</plist>
MCEOF
  chmod 644 "$client_mobileconfig"

  # Copy client files to client directory
  cp "$client_cert" "$IKEV2_CLIENT_DIR/$name"
  cp "$client_key" "$IKEV2_CLIENT_DIR/$name.key"
  cp "$ca_cert" "$IKEV2_CLIENT_DIR/ca.pem"

  # Load client certificate into strongSwan
  cp "$client_cert" /etc/swanctl/certs/ 2>/dev/null || true

  ok "Client IKEv2 '$name' dibuat:"
  echo "  - Sertifikat : $client_p12 (password: vpn)"
  echo "  - MobileConfig: $client_mobileconfig (iOS/macOS)"
  echo "  - File certs  : $IKEV2_CLIENT_DIR/$name* + ca.pem"
  echo "  - Untuk Android/Windows: gunakan file .p12 + ca.pem"
}

ikev2_list() {
  [[ -f /etc/swanctl/conf.d/ikev2.conf ]] || fail "IKEv2 belum diinstall."
  echo "Client IKEv2/IPsec:"
  local found=0 name
  for f in "$IKEV2_CLIENT_DIR"/*.p12; do
    [[ -e "$f" ]] || continue
    found=1
    name="$(basename "$f" .p12)"
    local mc=""
    [[ -f "$IKEV2_CLIENT_DIR/$name.mobileconfig" ]] && mc=" (.mobileconfig tersedia)"
    echo "  - $name$mc"
  done
  [[ $found -eq 0 ]] && echo "  (belum ada client)"
}

ikev2_remove() {
  local name="$1"
  [[ -f /etc/swanctl/conf.d/ikev2.conf ]] || fail "IKEv2 belum diinstall."
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama client hanya boleh huruf/angka, tanda '-' atau '_'"
  [[ -f "$IKEV2_CLIENT_DIR/$name.p12" ]] || fail "Client IKEv2 '$name' tidak ditemukan."

  # hapus file spesifik (bukan glob) supaya client1 tidak ikut menghapus client10
  rm -f \
    "$IKEV2_CLIENT_DIR/$name" \
    "$IKEV2_CLIENT_DIR/$name.p12" \
    "$IKEV2_CLIENT_DIR/$name-key.pem" \
    "$IKEV2_CLIENT_DIR/$name-csr.pem" \
    "$IKEV2_CLIENT_DIR/$name-cert.pem" \
    "$IKEV2_CLIENT_DIR/$name.mobileconfig" \
    "/etc/swanctl/certs/$name-cert.pem" 2>/dev/null || true
  ok "Client IKEv2 '$name' dihapus."
}

install_ikev2_flow() {
  install_ikev2
}

# ---------------------------------------------------------------------------
# 9. Shadowsocks (shadowsocks-libev)
# ---------------------------------------------------------------------------
ss_free_port() {
  local port i
  for i in $(seq 1 50); do
    port=$(( (RANDOM % 50000) + 10000 ))
    if ! ss -ltnup 2>/dev/null | grep -qP ":$port([^0-9]|$)"; then
      printf '%d' "$port"
      return 0
    fi
  done
  printf '%d' $(( (RANDOM % 50000) + 10000 ))
}

ss_add() {
  local name="$1" port="${2:-}" pass="${3:-}"
  [[ -d "$SS_DIR" ]] || fail "Shadowsocks belum diinstall. Jalankan dulu: bash install-vpn.sh"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama user hanya boleh huruf/angka, tanda '-' atau '_'"
  [[ -f "$SS_DIR/$name.json" ]] && fail "User Shadowsocks '$name' sudah ada!"

  if [[ -z "$port" ]]; then
    port="$(ss_free_port)"
  else
    [[ "$port" =~ ^[1-9][0-9]*$ ]] || fail "Port harus angka (tanpa nol di depan)."
    (( port >= 1024 && port <= 65535 )) || fail "Port harus antara 1024-65535."
    if ss -ltnup 2>/dev/null | grep -qP ":$port([^0-9]|$)"; then
      fail "Port $port sudah dipakai layanan lain."
    fi
  fi

  [[ -z "$pass" ]] && pass="$(gen_rand 16)"
  [[ -n "$pass" ]] && case "$pass" in *[\"\\]*) fail "Password Shadowsocks tidak boleh mengandung karakter kutip (\") atau backslash (\\)." ;; esac
  SS_LAST_PORT="$port"

  cat > "$SS_DIR/$name.json" <<EOF
{
    "server": "0.0.0.0",
    "server_port": $port,
    "password": "$pass",
    "method": "aes-256-gcm",
    "mode": "tcp_and_udp"
}
EOF
  # 644, karena unit systemd pakai DynamicUser (user dynamic tidak bisa baca mode 600)
  chmod 644 "$SS_DIR/$name.json"

  if ! systemctl enable --now "shadowsocks-libev-server@$name" >/dev/null 2>&1; then
    warn "Gagal menjalankan service Shadowsocks '$name' — cek dengan: systemctl status shadowsocks-libev-server@$name"
  fi

  ok "Shadowsocks '$name' aktif — port: $port | password: $pass | method: aes-256-gcm"
  warn "Jangan lupa buka port $port (tcp & udp) di firewall & panel VPS provider."
}

ss_list() {
  [[ -d "$SS_DIR" ]] || fail "Shadowsocks belum diinstall."
  echo "Server Shadowsocks:"
  local f found=0
  for f in "$SS_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    found=1
    local name port method status
    name="$(basename "$f" .json)"
    port="$(grep -oP '"server_port":\s*\K[0-9]+' "$f" 2>/dev/null || echo '?')"
    method="$(grep -oP '"method":\s*"\K[^"]+' "$f" 2>/dev/null || echo '?')"
    if systemctl is-active --quiet "shadowsocks-libev-server@$name"; then
      status="aktif"
    else
      status="mati"
    fi
    echo "  - $name | port: $port | method: $method | status: $status"
  done
  [[ $found -eq 0 ]] && echo "  (belum ada user)"
}

ss_remove() {
  local name="$1"
  [[ -f "$SS_DIR/$name.json" ]] || fail "User Shadowsocks '$name' tidak ditemukan."
  systemctl disable --now "shadowsocks-libev-server@$name" >/dev/null 2>&1 || true
  rm -f "$SS_DIR/$name.json"
  ok "User Shadowsocks '$name' dihapus."
}

install_shadowsocks() {
  section "8. Install Shadowsocks (standalone)"

  if ! command -v ss-server >/dev/null 2>&1; then
    info "Menginstall shadowsocks-libev..."
    apt-get install -y shadowsocks-libev
  else
    warn "shadowsocks-libev sudah terinstall, dilewati."
  fi

  # matikan config bawaan paket (password default lemah)
  systemctl disable --now shadowsocks-libev.service >/dev/null 2>&1 || true
  systemctl disable --now shadowsocks-libev-server@config >/dev/null 2>&1 || true
  rm -f /etc/shadowsocks-libev/config.json

  if [[ -f "$SS_DIR/ss1.json" ]]; then
    warn "User Shadowsocks 'ss1' sudah ada, dilewati."
  else
    info "Membuat user Shadowsocks default (ss1)..."
    ss_add ss1
  fi
  ok "Shadowsocks siap. Kelola user: bash install-vpn.sh user shadowsocks add|list|remove NAMA"
}

install_shadowsocks_flow() {
  if [[ "${VPN_INSTALL_SHADOWSOCKS:-yes}" == "no" ]]; then
    warn "Shadowsocks dilewati (VPN_INSTALL_SHADOWSOCKS=no)."
    return 0
  fi
  if [[ -t 0 ]]; then
    read -rp "Install Shadowsocks juga? [Y/n] (default Y): " ss_choice
    if [[ "$ss_choice" =~ ^[nN] ]]; then
      warn "Shadowsocks dilewati."
      return 0
    fi
  fi
  install_shadowsocks
}

# ---------------------------------------------------------------------------
# 9. SSH
# ---------------------------------------------------------------------------
ensure_ssh() {
  section "9. Cek SSH"
  if ! command -v sshd >/dev/null 2>&1; then
    info "openssh-server belum ada, menginstall..."
    apt-get install -y openssh-server
  fi
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || true
  ok "SSH aktif di port 22."
}

# ---------------------------------------------------------------------------
# 9b. Dropbear — port SSH tunnel tambahan (tidak bentrok OpenSSH :22)
# ---------------------------------------------------------------------------
install_dropbear() {
  section "9b. Dropbear (SSH tunnel)"
  if ! command -v dropbear >/dev/null 2>&1; then
    info "Menginstall dropbear..."
    apt-get install -y dropbear
  fi

  # Cari port dropbear: default 443, jika terpakai cari port terdekat
  # Urutan: 443 → 442 → 444 → 441 → 445 → 440 → 446 → ...
  local base=443 port="" i=0
  while (( i <= 100 )); do
    local candidate
    if (( i == 0 )); then
      candidate=$base
    elif (( i % 2 == 1 )); then
      candidate=$(( base - (i+1)/2 ))
    else
      candidate=$(( base + i/2 ))
    fi
    (( candidate < 1 || candidate > 65535 )) && { i=$((i+1)); continue; }
    if ! ss -ltn 2>/dev/null | grep -qP ":$candidate([^0-9]|$)"; then
      port=$candidate
      break
    fi
    i=$((i+1))
  done
  [[ -z "$port" ]] && fail "Tidak ada port SSH tunnel yang tersedia di sekitar port $base"
  ok "Port dropbear dipilih: $port"
  DB_PORT="$port"

  cat > "$DB_CONF" <<EOF
NO_START=0
DROPBEAR_PORT=$port
DROPBEAR_EXTRA_ARGS=""
DROPBEAR_BANNER=""
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable dropbear >/dev/null 2>&1 || true
  systemctl restart dropbear >/dev/null 2>&1 || true
  if systemctl is-active dropbear >/dev/null 2>&1; then
    ok "Dropbear aktif di port $port (SSH tunnel)."
  else
    warn "Dropbear gagal start — cek: journalctl -u dropbear -n 20"
  fi
}

# ---------------------------------------------------------------------------
# Kelola akun SSH tunnel: user ssh add NAMA [hari] [password] | list | remove
# ---------------------------------------------------------------------------
ssh_add() {
  local name="$1" days="${2:-30}" pass="${3:-}" expiry=""
  [[ -n "$name" ]] || fail "Nama user kosong."
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama user hanya boleh huruf/angka, tanda '-' atau '_'"
  id "$name" >/dev/null 2>&1 && fail "User '$name' sudah ada di sistem."
  if [[ -z "$days" ]] || ! [[ "$days" =~ ^[0-9]+$ ]] || (( days < 1 || days > 365 )); then
    fail "Masa aktif harus angka 1-365 (hari). Contoh: user ssh add $name 30"
  fi
  [[ -z "$pass" ]] && pass="$(gen_rand 16)"
  case "$pass" in *[\"\\]*) fail "Password tidak boleh mengandung karakter kutip (\") atau backslash (\\)." ;; esac

  expiry="$(date -d "+$days days" +%Y-%m-%d)"
  useradd -m -s /bin/bash -e "$expiry" "$name" 2>/dev/null \
    || fail "Gagal membuat user '$name'."
  echo "$name:$pass" | chpasswd

  # ambil port dropbear dari config kalau script dijalankan terpisah (bukan install)
  if [[ -z "$DB_PORT" ]] && [[ -f "$DB_CONF" ]]; then
    DB_PORT="$(grep -oP 'DROPBEAR_PORT=\s*\K[0-9]+' "$DB_CONF" 2>/dev/null || true)"
  fi

  # simpan tracking + info akun (mode 600)
  echo "$name|$expiry|$pass" >> "$SSH_USERS_FILE"
  [[ -z "$SERVER_IP" ]] && SERVER_IP="$(detect_ip)"
  umask 077
  {
    echo "=== SSH TUNNEL: $name ==="
    echo "Server   : $SERVER_IP (port 22 / dropbear ${DB_PORT:-443})"
    echo "User     : $name"
    echo "Password : $pass"
    echo "Aktif s/d: $expiry"
    echo "Koneksi  : ssh $name@$SERVER_IP"
    echo "Dropbear : ssh $name@$SERVER_IP -p ${DB_PORT:-443}"
    echo "Proxy    : ssh -D 1080 $name@$SERVER_IP   (SOCKS5 127.0.0.1:1080 di browser)"
    echo
  } >> "$SSH_TUNNEL_INFO"
  chmod 600 "$SSH_TUNNEL_INFO"

  ok "Akun SSH tunnel '$name' dibuat — aktif s/d $expiry."
  echo -e "  Koneksi : ${cyan}ssh $name@$SERVER_IP${plain}"
  echo -e "  Dropbear: ${cyan}ssh $name@$SERVER_IP -p ${DB_PORT:-443}${plain}"
  echo -e "  Password: ${cyan}$pass${plain}"
  echo -e "  Proxy   : ${cyan}ssh -D 1080 $name@$SERVER_IP${plain}  (SOCKS5 127.0.0.1:1080 di browser)"
  warn "Buka port ${DB_PORT:-443}/tcp di firewall & panel VPS provider untuk Dropbear."
  warn "Detail akun tersimpan di $SSH_TUNNEL_INFO"
}

ssh_list() {
  if [[ ! -f "$SSH_USERS_FILE" ]]; then
    echo "Belum ada akun SSH tunnel."
    return 0
  fi
  echo "Akun SSH tunnel (masa aktif otomatis):"
  local line name expiry pass today status
  today="$(date +%Y-%m-%d)"
  while IFS='|' read -r name expiry pass; do
    [[ -z "$name" ]] && continue
    if [[ "$expiry" < "$today" ]]; then
      status="KADALUARSA"
    else
      status="aktif"
    fi
    echo "  - $name | aktif s/d $expiry | $status"
  done < "$SSH_USERS_FILE"
}

ssh_remove() {
  local name="$1"
  [[ -n "$name" ]] || fail "Nama user kosong."
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Nama user tidak valid."
  id "$name" >/dev/null 2>&1 || fail "User '$name' tidak ada di sistem."
  userdel -r "$name" 2>/dev/null || fail "Gagal menghapus user '$name'."
  if [[ -f "$SSH_USERS_FILE" ]]; then
    grep -v "^$name|" "$SSH_USERS_FILE" > "$SSH_USERS_FILE.tmp" 2>/dev/null || true
    mv "$SSH_USERS_FILE.tmp" "$SSH_USERS_FILE"
  fi
  if [[ -f "$SSH_TUNNEL_INFO" ]]; then
    grep -v "SSH TUNNEL: $name" "$SSH_TUNNEL_INFO" > "$SSH_TUNNEL_INFO.tmp" 2>/dev/null || true
    mv "$SSH_TUNNEL_INFO.tmp" "$SSH_TUNNEL_INFO"
  fi
  ok "Akun SSH tunnel '$name' dihapus."
}

# ---------------------------------------------------------------------------
# 9. Firewall (jika aktif)
# ---------------------------------------------------------------------------
setup_firewall() {
  section "10. Firewall"

  FW_OPENED=0  # Daftar port yang perlu dibuka
  local fw_ports=(22/tcp 80/tcp "$PANEL_PORT"/tcp 1194/udp 500/udp 4500/udp 1701/udp 51820/udp)
  [[ -n "$DB_PORT" ]] && fw_ports+=("$DB_PORT"/tcp)  # Dropbear SSH tunnel
  # IKEv2 pakai port 500/4500 yang sama dengan L2TP, jadi sudah tercakup
  if [[ -f /etc/swanctl/conf.d/ikev2.conf ]] && ! command -v xl2tpd >/dev/null 2>&1; then
    fw_ports+=(500/udp 4500/udp)  # Tambah jika IKEv2 ada tapi L2TP tidak
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "${fw_ports[@]}"; do
      ufw allow "$p" >/dev/null 2>&1 || true
    done
    if [[ -n "$SS_LAST_PORT" ]]; then
      ufw allow "$SS_LAST_PORT"/tcp >/dev/null 2>&1 || true
      ufw allow "$SS_LAST_PORT"/udp >/dev/null 2>&1 || true
    fi

    FW_OPENED=1
    ok "ufw aktif: port 22, 80, panel, OpenVPN, L2TP/IKEv2, WireGuard diizinkan."
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
    for p in "${fw_ports[@]}"; do
      firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 || true
    done
    if [[ -n "$SS_LAST_PORT" ]]; then
      firewall-cmd --permanent --add-port="$SS_LAST_PORT"/tcp >/dev/null 2>&1 || true
      firewall-cmd --permanent --add-port="$SS_LAST_PORT"/udp >/dev/null 2>&1 || true
    fi
    firewall-cmd --reload >/dev/null 2>&1 || true
    FW_OPENED=1
    ok "firewalld aktif: port 22, 80, $PANEL_PORT/tcp, 1194/udp, 500/4500/1701/udp, 51820/udp diizinkan."
  else
    warn "ufw/firewalld tidak aktif — pastikan port dibuka di panel VPS provider."
  fi

  if [[ $FW_OPENED -eq 1 ]]; then
    warn "CATATAN: port inbound Xray (VMess/VLESS/Trojan/SS) yang nanti dibuat di panel ZET UI juga harus diizinkan di firewall & panel VPS provider."
  fi
}

# ---------------------------------------------------------------------------
# 10. Simpan kredensial & ringkasan
# ---------------------------------------------------------------------------
save_credentials() {
  local f="/root/vpn-credentials.txt"
  umask 077
  {
    echo "=== ZET UI (XRAY PANEL) ==="
    echo "Panel URL  : $ACCESS_URL"
    echo "Username   : $PANEL_USER"
    echo "Password   : $PANEL_PASS"
    echo
    echo "=== OPENVPN ==="
    echo "Server     : $SERVER_IP:1194/udp"
    echo "File client: /root/client1.ovpn"
    echo
    if [[ -n "$L2TP_PSK" ]]; then
      echo "=== L2TP/IPSEC ==="
      echo "Server     : $SERVER_IP"
      echo "IPsec PSK  : $L2TP_PSK"
      echo "Username   : $L2TP_USER"
      echo "Password   : $L2TP_PASS"
      echo
    fi
    if [[ -f /etc/swanctl/conf.d/ikev2.conf ]]; then
      echo "=== IKEV2/IPSEC ==="
      echo "Server     : $SERVER_IP (port 500/4500/udp)"
      echo "File client: $IKEV2_CLIENT_DIR/ (client1.p12, client1.mobileconfig)"
      echo "Password   : vpn (untuk file .p12)"
      echo
    fi
    if [[ -f "$WG_CONF" ]]; then
      echo "=== WIREGUARD ==="
      echo "Server     : $SERVER_IP:51820/udp"
      if [[ -f "$WG_DIR/$WG_CLIENT_DEFAULT.conf" ]]; then
        echo "File client: $WG_DIR/$WG_CLIENT_DEFAULT.conf (+ .png QR)"
      fi
      echo
    fi
    if [[ -f "$SS_DIR/ss1.json" ]]; then
      echo "=== SHADOWSOCKS ==="
      echo "Server     : $SERVER_IP:$(grep -oP '"server_port":\s*\K[0-9]+' "$SS_DIR/ss1.json") (tcp & udp)"
      echo "Password   : $(grep -oP '"password":\s*"\K[^"]+' "$SS_DIR/ss1.json")"
      echo "Method     : $(grep -oP '"method":\s*"\K[^"]+' "$SS_DIR/ss1.json")"
      echo
    fi
    echo "=== SSH ==="
    echo "Koneksi    : ssh root@$SERVER_IP"
    if [[ -n "$DB_PORT" ]]; then
      echo
      echo "=== SSH TUNNEL (DROPBEAR) ==="
      echo "Port       : $DB_PORT/tcp"
      echo "Akun       : lihat $SSH_TUNNEL_INFO"
      echo "Kelola     : bash install-vpn.sh user ssh add|list|remove NAMA"
    fi
  } > "$f"
  chmod 600 "$f"
  ok "Semua kredensial disimpan di: $f (mode 600)"
}

print_summary() {
  echo
  echo -e "${green}=========================== ZET UI (XRAY) ===========================${plain}"
  echo -e "  Panel        : ${cyan}$ACCESS_URL${plain}"
  echo -e "  Username     : ${cyan}$PANEL_USER${plain}"
  echo -e "  Password     : ${cyan}$PANEL_PASS${plain}"
  echo
  echo -e "  Protocol: VMess, VLESS, Trojan, Shadowsocks, Reality, WireGuard,"
  echo -e "  Hysteria2, dll. Buat user: Panel -> Inbound -> Tambah Inbound ->"
  echo -e "  pilih protocol -> isi port -> Create -> copy link/QR ke client."
  echo -e "  Jangan lupa buka port inbound-nya di panel VPS provider!"
  echo
  echo -e "${green}============================= OPENVPN ==============================${plain}"
  echo -e "  Server : port ${cyan}1194/udp${plain} (sudah running)"
  echo -e "  Client : ${cyan}/root/client1.ovpn${plain}"
  echo -e "  Kelola : ${cyan}bash install-vpn.sh user openvpn add|list|remove NAMA${plain}"
  echo
  if [[ -n "$L2TP_PSK" ]]; then
    echo -e "${green}=========================== L2TP/IPSEC =============================${plain}"
    echo -e "  Server     : ${cyan}$SERVER_IP${plain} (port 500/4500/1701 udp)"
    echo -e "  IPsec PSK  : ${cyan}$L2TP_PSK${plain}"
    echo -e "  Username   : ${cyan}$L2TP_USER${plain}"
    echo -e "  Password   : ${cyan}$L2TP_PASS${plain}"
    echo -e "  Kelola     : ${cyan}bash install-vpn.sh user l2tp add|list|remove NAMA${plain}"
    echo
  fi
  if [[ -f /etc/swanctl/conf.d/ikev2.conf ]]; then
    echo -e "${green}=========================== IKEV2/IPSEC ============================${plain}"
    echo -e "  Server : ${cyan}$SERVER_IP${plain} (port 500/4500/udp)"
    echo -e "  Client : ${cyan}$IKEV2_CLIENT_DIR/client1.p12${plain} (password: vpn)"
    echo -e "  Mobile : ${cyan}$IKEV2_CLIENT_DIR/client1.mobileconfig${plain} (iOS/macOS)"
    echo -e "  Kelola : ${cyan}bash install-vpn.sh user ikev2 add|list|remove NAMA${plain}"
    echo
  fi
  if [[ -f "$WG_CONF" ]]; then
    echo -e "${green}============================ WIREGUARD =============================${plain}"
    echo -e "  Server : port ${cyan}51820/udp${plain} (sudah running)"
    if [[ -f "$WG_DIR/$WG_CLIENT_DEFAULT.conf" ]]; then
      echo -e "  Client : ${cyan}$WG_DIR/$WG_CLIENT_DEFAULT.conf${plain} (+ QR .png)"
    fi
    echo -e "  Kelola : ${cyan}bash install-vpn.sh user wireguard add|list|remove NAMA${plain}"
    echo
  fi
  if [[ -f "$SS_DIR/ss1.json" ]]; then
    echo -e "${green}=========================== SHADOWSOCKS ============================${plain}"
    echo -e "  Server     : ${cyan}$SERVER_IP:$(grep -oP '"server_port":\s*\K[0-9]+' "$SS_DIR/ss1.json")${plain} (tcp & udp)"
    echo -e "  Password   : ${cyan}$(grep -oP '"password":\s*"\K[^"]+' "$SS_DIR/ss1.json")${plain}"
    echo -e "  Method     : ${cyan}$(grep -oP '"method":\s*"\K[^"]+' "$SS_DIR/ss1.json")${plain}"
    echo -e "  Kelola     : ${cyan}bash install-vpn.sh user shadowsocks add|list|remove NAMA${plain}"
    echo
  fi
  echo -e "${green}=============================== SSH ================================${plain}"
  echo -e "  Koneksi: ${cyan}ssh root@$SERVER_IP${plain}"
  echo
  if [[ -n "$DB_PORT" ]]; then
    echo -e "${green}======================== SSH TUNNEL (DROPBEAR) ========================${plain}"
    echo -e "  Server : port ${cyan}$DB_PORT/tcp${plain} (dropbear) & 22/tcp (openssh)"
    echo -e "  Kelola : ${cyan}bash install-vpn.sh user ssh add|list|remove NAMA${plain}"
    echo
  fi
  echo -e "${yellow}Semua selesai! Kredensial lengkap ada di /root/vpn-credentials.txt${plain}"
}

# ---------------------------------------------------------------------------
# Cek panel ZET UI: status layanan + konflik port inbound vs layanan sistem.
# Mencegah bug: inbound panel yang memakai port layanan VPN/web (mis. 51820)
# membuat xray crash-loop dan mematikan SEMUA layanan VPN.
# ---------------------------------------------------------------------------
panel_check_conflicts() {
  section "CEK PANEL 3x-UI & KONFLIK PORT INBOUND"
  [[ -d /usr/local/x-ui ]] || { warn "ZET UI belum terinstall."; return 1; }

  # status layanan
  if systemctl is-active x-ui >/dev/null 2>&1; then
    ok "Panel ZET UI    : aktif"
  else
    warn "Panel ZET UI    : TIDAK aktif!"
  fi
  if pgrep -f "xray-linux" >/dev/null 2>&1; then
    ok "Xray (core)      : berjalan"
  else
    warn "Xray (core)      : TIDAK berjalan — cek log: journalctl -u x-ui -n 50"
  fi

  # muat konfigurasi panel dari hasil install (token + base path + port)
  local token="" base="" port=""
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shellcheck disable=SC1091
    . /etc/x-ui/install-result.env
    token="${XUI_API_TOKEN:-}"
    base="${XUI_WEB_BASE_PATH:-}"
    port="${XUI_PANEL_PORT:-}"
  fi
  [[ -z "$port" ]] && port="${PANEL_PORT:-6871}"
  local pport="$port"   # simpan port panel (dipakai lagi setelah loop parsing)
  base="${base#/}"; base="${base%/}"
  [[ -z "$token" ]] && { warn "API token panel tidak ditemukan — lewati cek inbound."; return 0; }

  local url="http://127.0.0.1:${port}/${base:+$base/}panel/api/inbounds/list"
  local data
  data="$(curl -s --max-time 10 -H "Authorization: Bearer $token" "$url" 2>/dev/null || true)"
  if [[ -z "$data" ]] || ! printf '%s' "$data" | grep -q '"success": *true'; then
    warn "Tidak bisa membaca daftar inbound dari panel (token/port salah?)."
    return 0
  fi

  # port yang dipakai layanan sistem — inbound panel TIDAK BOLEH memakainya
  local reserved="22:80:443:$pport:1194:500:4500:1701:51820"
  local ssport="" dbport=""
  if [[ -f "$SS_DIR/ss1.json" ]]; then
    ssport="$(grep -oP '"server_port":\s*\K[0-9]+' "$SS_DIR/ss1.json" 2>/dev/null || true)"
    [[ -n "$ssport" ]] && reserved="$reserved:$ssport"
  fi
  if [[ -f "$DB_CONF" ]]; then
    dbport="$(grep -oP 'DROPBEAR_PORT=\s*\K[0-9]+' "$DB_CONF" 2>/dev/null || true)"
    [[ -n "$dbport" ]] && reserved="$reserved:$dbport"
  fi

  # parsing daftar inbound: port|protocol|remark
  local list=""
  if command -v python3 >/dev/null 2>&1; then
    list="$(printf '%s' "$data" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for i in d.get("obj") or []:
    print("{}|{}|{}".format(i.get("port", ""), i.get("protocol", ""), i.get("remark", "")))
')"
  else
    # fallback: ambil port saja (format JSON sederhana) -> baris "port||"
    list="$(printf '%s' "$data" | grep -oP '"port":\s*\K[0-9]+' | sed 's/$/||/')"
  fi

  local line port proto remark conflicts=0
  while IFS='|' read -r port proto remark; do
    [[ -z "$port" ]] && continue
    if [[ ":$reserved:" == *":$port:"* ]]; then
      warn "KONFLIK PORT: inbound '$remark' ($proto) memakai port $port — dipakai layanan sistem!"
      conflicts=$((conflicts+1))
    fi
  done <<< "$list"

  if (( conflicts == 0 )); then
    ok "Semua port inbound panel aman (tidak bentrok dengan layanan sistem)."
  else
    warn "$conflicts inbound bentrok. Ubah port-nya: panel -> Daftar Inbound -> Edit."
    warn "Port yang dipakai sistem: 22, 80, 443, $pport (panel), 1194 (OpenVPN), 500/4500/1701 (IPsec/L2TP), 51820 (WireGuard)${ssport:+, $ssport (Shadowsocks)}${dbport:+, $dbport (Dropbear)}."
  fi
}

# ---------------------------------------------------------------------------
# Kelola panel: panel check
# ---------------------------------------------------------------------------
manage_panel() {
  # args: $1=panel  $2=aksi
  local aksi="${2:-check}"
  [[ $EUID -ne 0 ]] && fail "Jalankan sebagai root."
  case "$aksi" in
    check|status)
      panel_check_conflicts
      ;;
    *)
      warn "Aksi tidak dikenal: $aksi (pilihan: check)"
      usage
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Dispatch kelola user: user <svc> <aksi> [nama] [password]
# ---------------------------------------------------------------------------
manage_users() {
  # args: $1=user  $2=svc  $3=aksi  $4=nama  $5=password
  local svc="${2:-}" aksi="${3:-}" name="${4:-}" pass="${5:-}"
  [[ $EUID -ne 0 ]] && fail "Jalankan sebagai root."
  [[ -z "$svc" || -z "$aksi" ]] && { usage; exit 1; }

  case "$svc" in
    openvpn|ovpn)
      case "$aksi" in
        add)    [[ -z "$name" ]] && { usage; exit 1; }; add_openvpn_client "$name" ;;
        list)   ovpn_list ;;
        remove|del) [[ -z "$name" ]] && { usage; exit 1; }; ovpn_remove "$name" ;;
        *) warn "Aksi tidak dikenal: $aksi"; usage; exit 1 ;;
      esac
      ;;
    l2tp)
      case "$aksi" in
        add)    [[ -z "$name" ]] && { usage; exit 1; }; l2tp_add "$name" "$pass" ;;
        list)   l2tp_list ;;
        remove|del) [[ -z "$name" ]] && { usage; exit 1; }; l2tp_remove "$name" ;;
        *) warn "Aksi tidak dikenal: $aksi"; usage; exit 1 ;;
      esac
      ;;
    wireguard|wg)
      case "$aksi" in
        add)    [[ -z "$name" ]] && { usage; exit 1; }; add_wg_client "$name" ;;
        list)   wg_list ;;
        remove|del) [[ -z "$name" ]] && { usage; exit 1; }; remove_wg_client "$name" ;;
        *) warn "Aksi tidak dikenal: $aksi"; usage; exit 1 ;;
      esac
      ;;
    ikev2|ike)
      case "$aksi" in
        add)    [[ -z "$name" ]] && { usage; exit 1; }; add_ikev2_client "$name" ;;
        list)   ikev2_list ;;
        remove|del) [[ -z "$name" ]] && { usage; exit 1; }; ikev2_remove "$name" ;;
        *) warn "Aksi tidak dikenal: $aksi"; usage; exit 1 ;;
      esac
      ;;
    shadowsocks|ss)
      case "$aksi" in
        add)    [[ -z "$name" ]] && { usage; exit 1; }; ss_add "$name" "${5:-}" "${6:-}" ;;
        list)   ss_list ;;
        remove|del) [[ -z "$name" ]] && { usage; exit 1; }; ss_remove "$name" ;;
        *) warn "Aksi tidak dikenal: $aksi"; usage; exit 1 ;;
      esac
      ;;
    ssh)
      case "$aksi" in
        add)    [[ -z "$name" ]] && { usage; exit 1; }; ssh_add "$name" "${5:-}" "${6:-}" ;;
        list)   ssh_list ;;
        remove|del) [[ -z "$name" ]] && { usage; exit 1; }; ssh_remove "$name" ;;
        *) warn "Aksi tidak dikenal: $aksi"; usage; exit 1 ;;
      esac
      ;;
    *)
      warn "Layanan tidak dikenal: $svc (openvpn | l2tp | ikev2 | wireguard | shadowsocks | ssh)"
      usage
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Uninstall semua layanan VPN (SSH tetap aktif)
# ---------------------------------------------------------------------------
uninstall_vpn() {
  section "UNINSTALL VPN ALL-IN-ONE"
  warn "Ini akan MENGHAPUS SEMUA layanan VPN: ZET UI, OpenVPN, L2TP/IPsec, IKEv2/IPsec, WireGuard, Shadowsocks."
  warn "Paket yang ikut dihapus: openvpn, easy-rsa, libreswan, xl2tpd, strongswan, wireguard, shadowsocks-libev, qrencode."
  warn "SSH TIDAK akan dihapus."

  if [[ "${VPN_UNINSTALL_YES:-no}" != "yes" ]]; then
    if [[ -t 0 ]]; then
      read -rp "Ketik 'y' untuk melanjutkan uninstall: " ans
      [[ "$ans" =~ ^[yY] ]] || { ok "Uninstall dibatalkan."; exit 0; }
    else
      fail "Mode non-interaktif: set VPN_UNINSTALL_YES=yes untuk uninstall tanpa konfirmasi."
    fi
  fi

  # ambil port panel dulu (untuk hapus aturan firewall) sebelum folder dihapus
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shellcheck disable=SC1091
    . /etc/x-ui/install-result.env
    PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
  fi

  local iface=""
  iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

  # 1) Hentikan semua service
  info "Menghentikan semua service VPN..."
  for s in x-ui openvpn-server@server ipsec xl2tpd strongswan-starter strongswan-ikki strongswan-vici wg-quick@wg0; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
  done
  # semua instance Shadowsocks
  for f in "$SS_DIR"/*.json; do
    [[ -e "$f" ]] || continue
    systemctl disable --now "shadowsocks-libev-server@$(basename "$f" .json)" >/dev/null 2>&1 || true
  done

  # 2) ZET UI (Xray)
  if [[ -d /usr/local/x-ui ]]; then
    info "Menghapus ZET UI (Xray)..."
    rm -f /etc/systemd/system/x-ui.service /usr/bin/x-ui /etc/default/x-ui
    rm -rf /usr/local/x-ui /etc/x-ui /root/cert
    systemctl daemon-reload
    ok "ZET UI dihapus."
  fi

  # 3) OpenVPN
  if [[ -d "$OVPN_DIR" ]]; then
    info "Menghapus OpenVPN..."
    [[ -n "$iface" ]] && iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o "$iface" -j MASQUERADE 2>/dev/null || true
    rm -rf "$OVPN_DIR"
    rm -f /etc/sysctl.d/99-openvpn-forward.conf
    rm -f /root/*.ovpn 2>/dev/null || true
    ok "OpenVPN dihapus."
  fi

  # 4) L2TP/IPsec — pakai script uninstall resmi hwdsl2
  if command -v xl2tpd >/dev/null 2>&1 || [[ -f /etc/ipsec.conf ]]; then
    info "Menghapus L2TP/IPsec (script uninstall resmi)..."
    if curl -fsSL https://get.vpnsetup.net/unst -o /tmp/vpnunst.sh && bash /tmp/vpnunst.sh; then
      ok "L2TP/IPsec dihapus."
    else
      warn "Script uninstall L2TP/IPsec bermasalah — lanjut pembersihan manual."
    fi
    rm -f /tmp/vpnunst.sh
    systemctl disable ipsec xl2tpd >/dev/null 2>&1 || true
    rm -rf /etc/xl2tpd /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d
    if [[ -f /etc/ppp/chap-secrets ]]; then
      mv /etc/ppp/chap-secrets /etc/ppp/chap-secrets.bak-uninstall
      ok "User L2TP dibackup ke /etc/ppp/chap-secrets.bak-uninstall"
    fi
  fi

  # 5) IKEv2/IPsec (strongSwan)
  if [[ -d "$IKEV2_DIR" ]]; then
    info "Menghapus IKEv2/IPsec (strongSwan)..."
    [[ -n "$iface" ]] && iptables -t nat -D POSTROUTING -s "$IKEV2_POOL" -o "$iface" -j MASQUERADE 2>/dev/null || true
    rm -rf "$IKEV2_DIR" /etc/swanctl /etc/ikev2
    rm -f /etc/sysctl.d/99-ikev2-forward.conf
    rm -rf "$IKEV2_CLIENT_DIR"
    ok "IKEv2/IPsec dihapus."
  fi

  # 6) WireGuard
  if [[ -d /etc/wireguard ]] || command -v wg >/dev/null 2>&1; then
    info "Menghapus WireGuard..."
    systemctl stop wg-quick@wg0 >/dev/null 2>&1 || true   # PostDown membersihkan aturan iptables
    rm -rf /etc/wireguard "$WG_DIR"
    ok "WireGuard dihapus."
  fi

  # 7) Shadowsocks
  if [[ -d "$SS_DIR" ]] || command -v ss-server >/dev/null 2>&1; then
    info "Menghapus Shadowsocks..."
    rm -rf "$SS_DIR"
    ok "Shadowsocks dihapus."
  fi

  # 6) Hapus paket VPN
  info "Menghapus paket VPN..."
  apt-get purge -y openvpn easy-rsa xl2tpd libreswan strongswan strongswan-pki wireguard wireguard-tools shadowsocks-libev qrencode >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true

  # 7) Hapus aturan firewall untuk port VPN
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "Menghapus aturan ufw untuk port VPN..."
    for p in "$PANEL_PORT"/tcp 1194/udp 500/udp 4500/udp 1701/udp 51820/udp; do
      ufw delete allow "$p" >/dev/null 2>&1 || true
    done
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    info "Menghapus aturan firewalld untuk port VPN..."
    for p in "$PANEL_PORT"/tcp 1194/udp 500/udp 4500/udp 1701/udp 51820/udp; do
      firewall-cmd --permanent --remove-port="$p" >/dev/null 2>&1 || true
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  # 8) Bersihkan NAT L2TP & simpan iptables
  [[ -n "$iface" ]] && iptables -t nat -D POSTROUTING -s 192.168.42.0/24 -o "$iface" -j MASQUERADE 2>/dev/null || true
  # hapus aturan NAT dari ufw before.rules jika ada
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local bf="/etc/ufw/before.rules"
    if [[ -f "$bf" ]]; then
      grep -vE "-A POSTROUTING -s (10\.8\.0\.0/24|$IKEV2_POOL|192\.168\.42\.0/24) " "$bf" > "$bf.tmp" 2>/dev/null && mv "$bf.tmp" "$bf" || rm -f "$bf.tmp"
      ufw reload >/dev/null 2>&1 || true
    fi
  else
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true

  # 9) Hapus file kredensial
  rm -f /root/vpn-credentials.txt

  echo
  ok "Uninstall selesai! SSH tetap aktif."
  warn "Tutup juga port VPN (54321, 1194, 500, 4500, 1701, 51820) di panel VPS provider."
}

# ---------------------------------------------------------------------------
# Pilih IPsec mode: L2TP atau IKEv2 (satu saja, tidak keduanya)
# ---------------------------------------------------------------------------
install_ipsec_flow() {
  # Mode dari env (untuk otomasi)
  local mode="${VPN_IPSEC_MODE:-}"

  if [[ -n "$mode" ]]; then
    case "$mode" in
      l2tp|L2TP)
        ok "IPsec mode: L2TP/IPsec (dari env)"
        install_l2tp_flow
        return
        ;;
      ikev2|IKEV2|ike)
        ok "IPsec mode: IKEv2/IPsec (dari env)"
        install_ikev2_flow
        return
        ;;
      none|skip)
        warn "IPsec dilewati (VPN_IPSEC_MODE=none)."
        return
        ;;
      *)
        warn "VPN_IPSEC_MODE tidak dikenal: $mode (pilih l2tp/ikev2/none)"
        ;;
    esac
  fi

  # Prompt interaktif
  if [[ -t 0 ]]; then
    echo
    echo -e "${cyan}==================================================${plain}"
    echo -e "  ${cyan}Pilih IPsec mode:${plain}"
    echo -e "${cyan}==================================================${plain}"
    echo
    echo -e "  1) L2TP/IPsec   — universal, support semua device, pakai username+password"
    echo -e "  2) IKEv2/IPsec  — lebih cepat, stabil, pakai sertifikat (recommended untuk MikroTik)"
    echo -e "  3) Lewati       — tidak install IPsec"
    echo
    read -rp "  Pilihan [1/2/3] (default 2): " ipsec_choice
    ipsec_choice="${ipsec_choice:-2}"

    case "$ipsec_choice" in
      1)
        install_l2tp_flow
        ;;
      2)
        install_ikev2_flow
        ;;
      3|0)
        warn "IPsec dilewati."
        ;;
      *)
        warn "Pilihan tidak valid ($ipsec_choice), IPsec dilewati."
        ;;
    esac
  else
    # Non-interactive: default IKEv2
    install_ikev2_flow
  fi
}

# ---------------------------------------------------------------------------
# Alur utama install
# ---------------------------------------------------------------------------
main() {
  check_root_os

  section "Deteksi IP publik"
  SERVER_IP="$(detect_ip)"
  ok "IP server: $SERVER_IP"

  install_base
  prompt_ssl
  install_xui
  setup_openvpn
  install_ipsec_flow
  install_wireguard_flow
  install_shadowsocks_flow
  ensure_ssh
  install_dropbear
  setup_firewall

  ACCESS_URL="${XUI_ACCESS_URL:-http://$SERVER_IP:$PANEL_PORT$PANEL_PATH}"
  save_credentials

  # cek otomatis: pastikan inbound panel tidak bentrok dengan port layanan sistem
  panel_check_conflicts

  section "RINGKASAN INSTALL"
  print_summary

  # Opsional: tambah client OpenVPN lain
  if [[ -t 0 ]]; then
    echo
    while true; do
      read -rp "Buat client OpenVPN tambahan? (ketik nama, kosong untuk selesai): " cname || break
      [[ -z "$cname" ]] && break
      if [[ "$cname" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        add_openvpn_client "$cname"
      else
        warn "Nama tidak valid (hanya huruf/angka/-/_)."
      fi
    done
  fi
}

# ---------------------------------------------------------------------------
# Dispatch argumen
# ---------------------------------------------------------------------------
case "${1:-install}" in
  install)
    main
    ;;
  add-client)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    [[ $EUID -ne 0 ]] && fail "Jalankan sebagai root."
    add_openvpn_client "$2"
    ;;
  user)
    manage_users "$@"
    ;;
  panel)
    manage_panel "$@"
    ;;
  uninstall|uninstall-vpn)
    uninstall_vpn
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    warn "Argumen tidak dikenal: $1"
    usage
    exit 1
    ;;
esac
