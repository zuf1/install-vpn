# Install VPN All-in-One (VPS Debian/Ubuntu)

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)
![OS](https://img.shields.io/badge/OS-Debian%2011%2F12%20%7C%20Ubuntu%2020.04--24.04-D70A53)
![Services](https://img.shields.io/badge/Layanan-7%20VPN-1f6feb)
![Non-interactive](https://img.shields.io/badge/Otomasi-Cloud--init%20ready-green)

Satu script untuk install & kelola server VPN di VPS:

| # | Layanan | Protocol | Port |
|---|---------|----------|------|
| 1 | **ZET UI** (panel Xray — fork 3x-ui) | VMess, VLESS, Trojan, Shadowsocks, Reality, WireGuard, Hysteria2, dll. | acak, lihat file kredensial |
| 2 | **OpenVPN** | OpenVPN | `1194/udp` |
| 3 | **L2TP/IPsec** (Libreswan + xl2tpd) | L2TP over IPsec | `500/udp`, `4500/udp`, `1701/udp` |
| 4 | **IKEv2/IPsec** (strongSwan) | IKEv2 | `500/udp`, `4500/udp` |
| 5 | **WireGuard** | WireGuard | `51820/udp` |
| 6 | **Shadowsocks** (shadowsocks-libev) | Shadowsocks | per-user (acak, tcp & udp) |
| 7 | **SSH** | SSH (tidak dihapus saat uninstall) | `22/tcp` |
| 8 | **SSH Tunnel** (Dropbear) | akun SSH tunnel: proxy SOCKS5 / port forwarding | `443/tcp` |

## Fitur

- **8 layanan dalam satu script** — ZET UI (panel Xray: VMess, VLESS, Trojan, Shadowsocks, Reality, WireGuard, Hysteria2), OpenVPN, L2TP/IPsec, IKEv2/IPsec, WireGuard, Shadowsocks, SSH, dan SSH Tunnel (Dropbear).
- **Kredensial otomatis & tersimpan** — semua user, password, PSK, port & file client dihasilkan otomatis dan disimpan di `/root/vpn-credentials.txt` (mode 600, hanya root yang bisa baca).
- **File client siap pakai** — `.ovpn`, WireGuard `.conf` + QR code (PNG), IKEv2 `.p12` + `.mobileconfig`; tinggal unduh & import di HP/PC.
- **Kelola user via CLI** — tambah/daftar/hapus user untuk semua layanan tanpa edit config manual (`user openvpn|wireguard|l2tp|ikev2|shadowsocks add/list/remove`).
- **SSL Let's Encrypt otomatis** — panel ZET UI bisa diamankan dengan SSL (domain atau IP) tanpa setup manual.
- **Firewall otomatis** — semua port VPN dibuka di ufw/firewalld jika aktif.
- **Otomasi / tanpa prompt** — semua pilihan install bisa lewat env (`VPN_SSL_MODE`, `VPN_IPSEC_MODE`, dll) untuk cloud-init.
- **Uninstall bersih** — hapus semua layanan VPN + file kredensial (SSH tetap aman).

## Contoh Output

```text
$ bash install-vpn.sh panel check

==================================================
  CEK PANEL 3x-UI & KONFLIK PORT INBOUND
==================================================
[OK] Panel ZET UI      : aktif
[OK] Xray (core)      : berjalan
[OK] Semua port inbound panel aman (tidak bentrok dengan layanan sistem).

$ bash install-vpn.sh user wireguard list
Client WireGuard (wg0):
  wgclient1      IP: 10.66.66.2/32   Handshake: belum pernah       Rx: 0 B        Tx: 0 B
  budi           IP: 10.66.66.3/32   Handshake: belum pernah       Rx: 0 B        Tx: 0 B
```

---

## Daftar Isi

1. [Persiapan](#1-persiapan)
2. [Instalasi](#2-instalasi)
3. [Port yang harus dibuka](#3-port-yang-harus-dibuka)
4. [Kelola user VPN](#4-kelola-user-vpn)
5. [Panduan Client](#5-panduan-client)
   - [ZET UI / Xray (VMess, VLESS, Trojan, Shadowsocks)](#51-zet-ui--xray-vmess-vless-trojan-shadowsocks)
   - [OpenVPN](#52-openvpn)
   - [L2TP/IPsec](#53-l2tpipsec)
   - [IKEv2/IPsec](#54-ikevipsec)
   - [WireGuard](#55-wireguard)
   - [Shadowsocks](#56-shadowsocks)
   - [SSH](#57-ssh)
6. [Uninstall](#6-uninstall)
7. [Otomasi / Tanpa Prompt](#7-otomasi--tanpa-prompt)
8. [FAQ & Troubleshooting](#8-faq--troubleshooting)
9. [Tips Keamanan](#9-tips-keamanan)

---

## 1. Persiapan

- VPS dengan **Debian 11/12** atau **Ubuntu 20.04/22.04/24.04** (x86_64/arm64).
- Akses **root** (`sudo -i`).
- OS harus fresh atau setidaknya tidak ada layanan yang memakai port yang sama.

```bash
apt-get update && apt-get upgrade -y && reboot
```

---

## 2. Instalasi

Upload `install-vpn.sh` ke VPS
```bash
wget -O install-vpn.sh https://raw.githubusercontent.com/zuf1/install-vpn/main/install-vpn.sh
```
lalu:

```bash
bash install-vpn.sh
```

**Contoh pemilihan IPsec (pilihan 2 = IKEv2):**
```
==================================================
  Pilih IPsec mode:
==================================================

  1) L2TP/IPsec   — universal, support semua device, pakai username+password
  2) IKEv2/IPsec  — lebih cepat, stabil, pakai sertifikat (recommended untuk MikroTik)
  3) Lewati       — tidak install IPsec

  Pilihan [1/2/3] (default 2): 2
```

Selama proses install akan ada beberapa pertanyaan:

| Prompt | Pilihan | Keterangan |
|--------|---------|------------|
| **SSL panel ZET UI** | `1` Domain / `2` IP / `3` Lewati | SSL Let's Encrypt. Butuh port 80 terbuka. Domain butuh DNS A record ke IP VPS. |
| **IPsec mode** | `1` L2TP / `2` IKEv2 / `3` Lewati | **Pilih salah satu.** L2TP universal tapi lambat. IKEv2 lebih cepat & recommended. Tidak bisa keduanya (berbagi port 500/4500). |
| **Install WireGuard?** | `Y/n` | Otomatis dibuat client `wgclient1`. |
| **Install Shadowsocks?** | `Y/n` | Otomatis dibuat user `ss1` (port & password acak). |
| **Client OpenVPN tambahan** | ketik nama / kosong | Ulang sampai kosong untuk selesai. |

Setelah selesai, semua kredensial ditampilkan di layar **dan** disimpan di:

```
/root/vpn-credentials.txt
```

> ⚠️ Simpan file itu baik-baik (mode 600, hanya root yang bisa baca). Hapus dari server jika sudah tidak diperlukan.

---

## 3. Port yang harus dibuka

Di **panel VPS provider** (dan firewall server jika aktif), buka port berikut:

| Port | Protocol | Untuk |
|------|----------|-------|
| `22` | tcp | SSH |
| `80` | tcp | Validasi SSL Let's Encrypt (hanya jika pakai SSL) |
| *port panel* | tcp | Panel ZET UI (acak — lihat `/root/vpn-credentials.txt`) |
| `1194` | udp | OpenVPN |
| `500`, `4500`, `1701` | udp | L2TP/IPsec |
| `51820` | udp | WireGuard |
| `443` | tcp | SSH Tunnel (Dropbear — lihat `/etc/default/dropbear`) |
| *port Shadowsocks* | tcp & udp | Per-user (acak saat dibuat) — buka juga |
| *port inbound Xray* | tcp | Dibuat per-inbound dari panel ZET UI — buka juga |

> Jika `ufw`/`firewalld` aktif di server, script otomatis membuka port di atas. Kalau tidak aktif, cukup buka di panel VPS provider.

---

## 4. Kelola user VPN

Semua perintah dijalankan sebagai root.

```bash
# OpenVPN
bash install-vpn.sh user openvpn add budi          # buat client baru
bash install-vpn.sh user openvpn list              # daftar client
bash install-vpn.sh user openvpn remove budi       # revoke sertifikat (langsung tidak bisa connect)

# L2TP/IPsec
bash install-vpn.sh user l2tp add budi rahasia123  # tambah user (password opsional)
bash install-vpn.sh user l2tp list
bash install-vpn.sh user l2tp remove budi

# IKEv2/IPsec
bash install-vpn.sh user ikev2 add budi           # buat client + sertifikat
bash install-vpn.sh user ikev2 list               # daftar client
bash install-vpn.sh user ikev2 remove budi        # hapus client

# WireGuard
bash install-vpn.sh user wireguard add budi        # buat peer + file .conf & QR
bash install-vpn.sh user wireguard list            # status handshake & traffic
bash install-vpn.sh user wireguard remove budi

# Shadowsocks
bash install-vpn.sh user shadowsocks add budi               # port & password otomatis
bash install-vpn.sh user shadowsocks add budi 18443 rahasia # atau tentukan port & password
bash install-vpn.sh user shadowsocks list
bash install-vpn.sh user shadowsocks remove budi
```

Alias singkat: `add-client NAMA` = `user openvpn add NAMA`.

File client yang dihasilkan:

| Layanan | Lokasi file |
|---------|-------------|
| OpenVPN | `/root/<nama>.ovpn` |
| WireGuard | `/root/wireguard/<nama>.conf` + `<nama>.png` (QR) |
| L2TP | cukup catat username & password |
| IKEv2 | `/root/ikev2-clients/<nama>.p12` (password: vpn) + `.mobileconfig` |
| Shadowsocks | cukup catat port, password & method (ditampilkan saat `add`) |

### Dua lapis layanan: sistem vs panel ZET UI

`install-vpn.sh` memasang **dua lapis yang independen** untuk protokol yang sama:

| Protokol | Lapisan sistem (daemon mandiri) | Lapisan panel (inbound ZET UI) |
|----------|-------------------------------|-------------------------------|
| Shadowsocks | `ss1` (shadowsocks-libev) — port `11153` tcp+udp | inbound SS — port tinggi bebas, misal `20003` |
| WireGuard | `wg0` (kernel, wg-quick) — port `51820/udp` | inbound WG (userspace xray) — port tinggi bebas, misal `20002` |

**Kenapa dua-duanya?**

- **Lapisan sistem** dipasang sebagai daemon mandiri — **tidak bergantung panel**. Kalau ZET UI mati/error, layanan ini tetap jalan. Dikelola via CLI (`bash install-vpn.sh user shadowsocks/wireguard add ...`).
- **Lapisan panel** adalah inbound di dalam Xray/ZET UI — punya fitur lebih (multi-user, pencatatan traffic, subscription link, UI panel). Dikelola dari panel/API.

**Apakah bentrok? Tidak** — selama **port-nya berbeda**. Kedua lapisan bisa berjalan bersamaan karena masing-masing mendengarkan di port sendiri (contoh nyata: `ss-server` di `11153` + inbound SS xray di `20003`; `wg0` di `51820` + inbound WG xray di `20002`).

### Cek panel ZET UI & konflik port inbound

`install-vpn.sh` memasang **ZET UI (panel Xray)** dan layanan VPN sistem di server yang sama. Inbound yang dibuat di panel **tidak boleh memakai port layanan sistem** — kalau bentrok, xray crash-loop dan semua VPN ikut mati (pernah terjadi: inbound WireGuard di port `51820` dibuat di panel, padahal port itu dipakai WireGuard sistem).

Jalankan kapan saja untuk memastikan aman:

```bash
bash install-vpn.sh panel check
```

Cek ini juga otomatis dijalankan di akhir install. Port yang dipakai sistem — **jangan dipakai untuk inbound panel**:

| Port | Dipakai untuk |
|------|---------------|
| `22/tcp` | SSH |
| `80/tcp`, `443/tcp` | Web/nginx (website) |
| `6871/tcp` | Panel ZET UI |
| `1194/udp` | OpenVPN |
| `500/udp`, `4500/udp`, `1701/udp` | IPsec (IKEv2/L2TP) |
| `51820/udp` | WireGuard |
| `443/tcp` | Dropbear SSH tunnel (lihat `/etc/default/dropbear`) |
| port Shadowsocks | layanan Shadowsocks sistem (lihat `/etc/shadowsocks-libev/ss1.json`) |

Saran: pakai port tinggi yang bebas untuk inbound panel, misal `20000`–`29999`.

---

## 5. Panduan Client

### 5.1 ZET UI / Xray (VMess, VLESS, Trojan, Shadowsocks)

**1. Buat inbound di panel**

1. Buka panel: `http://IP_VPS:<port_panel>/<path>` (lihat `/root/vpn-credentials.txt`).
2. Login dengan username & password dari file tersebut.
3. Menu **Inbound → Tambah Inbound**.
4. Pilih protocol (**VMess / VLESS / Trojan / Shadowsocks / Reality / dll**), isi **port**, lalu **Create**.
5. Klik ikon **QR / link** pada inbound untuk menyalin konfigurasi.

**2. Import di aplikasi client**

| Platform | Aplikasi |
|----------|----------|
| Android | [v2rayNG](https://play.google.com/store/apps/details?id=com.v2ray.ang), NekoBox |
| Windows | [v2rayN](https://github.com/2dust/v2rayN) |
| iOS | Shadowrocket, Streisand, sing-box |
| macOS | V2rayU, sing-box |

Cara umum: salin link konfigurasi → buka aplikasi → **import dari clipboard** (atau scan QR).

> **Tips tanpa domain:** pakai `TCP` (tanpa TLS) langsung ke IP. Kalau mau TLS/Reality, siapkan domain yang diarahkan ke IP VPS lalu atur di panel (menu SSL / inbound Reality).

---

### 5.2 OpenVPN

File client: `/root/client1.ovpn` (atau `/root/<nama>.ovpn`).

Unduh file ke perangkat, lalu import:

| Platform | Aplikasi | Cara |
|----------|----------|------|
| Android | [OpenVPN for Android](https://play.google.com/store/apps/details?id=de.blinkt.openvpn) | Import profil → pilih file `.ovpn` |
| iOS | [OpenVPN Connect](https://apps.apple.com/app/openvpn-connect/id590379981) | Import file `.ovpn` (via Files/AirDrop) |
| Windows | [OpenVPN Connect](https://openvpn.net/client/) | Import profil → pilih file |
| macOS | Tunnelblick / OpenVPN Connect | Drag file `.ovpn` ke aplikasi |

> Tidak bisa download langsung dari VPS? Pakai `scp` dari PC:
> ```bash
> scp root@IP_VPS:/root/client1.ovpn .
> ```

---

### 5.3 L2TP/IPsec

Data yang dibutuhkan:

```
Server IP   : IP_VPS
IPsec PSK   : (lihat /root/vpn-credentials.txt)
Username    : vpnuser (atau user yang dibuat via `user l2tp add`)
Password    : (lihat file kredensial / yang dibuat saat add)
```

| Platform | Cara |
|----------|------|
| **Android** | Settings → Network & Internet → VPN → Tambah VPN → tipe **L2TP/IPsec PSK** → isi server, PSK, user, password |
| **iOS** | Settings → General → VPN & Device Management → VPN → Tambah Konfigurasi → **L2TP/IPsec** → isi server, account, password, secret (PSK) |
| **Windows 10/11** | Settings → Network & Internet → VPN → Tambah VPN → Provider: Windows (bawaan), tipe **L2TP/IPsec** dengan PSK. Jika di belakang NAT, perlu [registry fix sekali](https://github.com/hwdsl2/setup-ipsec-vpn/blob/master/docs/clients.md) (kunci `AssumeUDPEncapsulationContextOnSendRule`) |
| **macOS** | System Settings → Network → `+` → VPN → tipe **L2TP over IPsec** → isi server, account, password, Shared Secret (PSK) |

---

### 5.4 IKEv2/IPsec

IKEv2 menggunakan **sertifikat** (bukan password) untuk autentikasi. Cepat, stabil, dan built-in di semua OS modern.

**File client yang dihasilkan:**

| File | Untuk |
|------|-------|
| `/root/ikev2-clients/<nama>.p12` | Android, Windows, Linux (password: `vpn`) |
| `/root/ikev2-clients/<nama>.mobileconfig` | iOS, macOS (import langsung) |
| `/root/ikev2-clients/ca.pem` | CA certificate (import ke semua platform) |

**Cara pakai:**

| Platform | Cara |
|----------|------|
| **iOS** | Download `.mobileconfig` dari VPS → buka di Safari → **Allow** → Settings → VPN → pilih profile yang muncul → aktifkan |
| **macOS** | Buka `.mobileconfig` → install di System Settings → Network → VPN → aktifkan |
| **Android** | Install app [strongSwan](https://play.google.com/store/apps/details?id=org.strongswan.android) → Import certificate → tambah profile: server=`IP_VPS`, type=`IKEv2 Certificate`, select `.p12` certificate, CA cert=`ca.pem`, identity=`nama` |
| **Windows 10/11** | Settings → Network & Internet → VPN → Add VPN → Server=`IP_VPS`, VPN type=`IKEv2`, Authentication=`Certificate`. Import `.p12` ke Personal store + `ca.pem` ke Trusted Root store via certlm.msc |
| **Linux** | `swanctl --load-all` lalu `swanctl --initiate --child ikev2-net` atau pakai NetworkManager IKEv2 plugin |

> **Catatan:** Jika L2TP/IPsec juga aktif, IKEv2 tidak bisa diinstall (berbagi port 500/4500). Pilih salah satu.

---

### 5.5 WireGuard

File client: `/root/wireguard/wgclient1.conf` (+ QR di `wgclient1.png`).

Unduh file `.conf`, lalu import:

| Platform | Aplikasi | Cara |
|----------|----------|------|
| Android | [WireGuard](https://play.google.com/store/apps/details?id=com.wireguard.android) | `+` → Import dari file **atau scan QR** |
| iOS | [WireGuard](https://apps.apple.com/app/wireguard/id1441195209) | Scan QR / import file |
| Windows | [WireGuard](https://www.wireguard.com/install/) | Import tunnel dari file |
| macOS | [WireGuard](https://apps.apple.com/app/wireguard/id1451689525) | Import dari file |
| Linux | `wg-quick up ./nama.conf` | CLI |

> QR bisa ditampilkan di layar terminal dengan `qrencode -t ansiutf8 < /root/wireguard/wgclient1.conf` (instal `qrencode` dulu jika belum ada).

---

### 5.6 Shadowsocks

Data yang dibutuhkan (ditampilkan saat `user shadowsocks add`):

```
Server IP : IP_VPS
Port      : <port acak, tcp & udp>
Password  : <password acak>
Method    : aes-256-gcm
```

| Platform | Aplikasi | Cara |
|----------|----------|------|
| Android | [v2rayNG](https://play.google.com/store/apps/details?id=com.v2ray.ang) | `+` → tipe **Shadowsocks** → isi server, port, password, method → simpan |
| iOS | Shadowrocket / Streisand | Import dari clipboard (format `ss://`) atau isi manual |
| Windows | [Shadowsocks-Windows](https://github.com/shadowsocks/shadowsocks-windows) | Tambah server → isi server, port, password, method |
| macOS | ShadowsocksX-NG | Tambah server → isi manual |
| Linux | `sslocal -c config.json` | shadowsocks-libev / shadowsocks-rust client |

> Format link `ss://` bisa dibuat manual: `ss://<base64(method:password)>@IP:port`. Contoh:
> `ss://$(printf 'aes-256-gcm:RAHASIA' | base64)@IP_VPS:18443`

---

### 5.7 SSH

```bash
ssh root@IP_VPS
```

Saran: ganti password SSH dan/atau gunakan **kunci SSH** (`ssh-keygen` → `ssh-copy-id`). SSH tidak ikut dihapus saat uninstall.

---

### 5.8 SSH Tunnel (Dropbear)

Installer memasang **Dropbear** di port `443/tcp` (otomatis cari port terdekat jika 443 terpakai: 443 → 442 → 444 → 441 → ...) sebagai jalur SSH tunnel tambahan — berguna kalau port 22 diblokir ISP/provider. Buat akun SSH tunnel:

```bash
bash install-vpn.sh user ssh add NAMA [hari] [password]
bash install-vpn.sh user ssh list
bash install-vpn.sh user ssh remove NAMA
```

Contoh: buat akun `budi` aktif 30 hari dengan password acak:

```bash
bash install-vpn.sh user ssh add budi 30
```

Output:

```text
[OK] Akun SSH tunnel 'budi' dibuat — aktif s/d 2026-09-23.
  Koneksi : ssh budi@IP_VPS
  Dropbear: ssh budi@IP_VPS -p 443
  Password: R4nd0mPa55w0rd
  Proxy   : ssh -D 1080 budi@IP_VPS  (SOCKS5 127.0.0.1:1080 di browser)
```

Cara pakai di HP/PC:

1. **Proxy SOCKS5** (paling umum): jalankan `ssh -D 1080 budi@IP_VPS`, lalu set proxy SOCKS5 `127.0.0.1:1080` di browser/aplikasi. Semua trafik lewat server.
2. **Port forwarding**: `ssh -L 8080:target.com:80 budi@IP_VPS` — terowongan ke situs yang diblokir.
3. Aplikasi Android/iOS: **Termux** atau **JuiceSSH** → buat koneksi SSH → aktifkan dynamic forwarding.

Akun otomatis **kadaluarsa** sesuai masa aktif (`[hari]`, default 30, maks 365). Detail akun tersimpan di `/root/ssh-tunnel-users.txt` (mode 600).

> ⚠️ Jangan lupa buka port `443/tcp` di firewall & panel VPS provider (dan port 22 kalau mau dipakai juga).

---

## 6. Uninstall

Hapus **semua** layanan VPN (SSH tetap aktif):

```bash
bash install-vpn.sh uninstall
# atau tanpa konfirmasi:
VPN_UNINSTALL_YES=yes bash install-vpn.sh uninstall
```

Yang dihapus: ZET UI, OpenVPN (+ file `.ovpn`), L2TP/IPsec (user dibackup ke `/etc/ppp/chap-secrets.bak-uninstall`), IKEv2/IPsec (sertifikat + config strongSwan), WireGuard, Shadowsocks, paket-paket terkait, aturan firewall, dan `/root/vpn-credentials.txt`.

---

## 7. Otomasi / Tanpa Prompt

Untuk cloud-init / provisioning, semua prompt bisa dilewati lewat env:

```bash
VPN_SSL_MODE=none \
VPN_INSTALL_L2TP=yes \
VPN_INSTALL_WIREGUARD=yes \
bash install-vpn.sh
```

| Variabel | Nilai | Default |
|----------|-------|---------|
| `VPN_SSL_MODE` | `domain` \| `ip` \| `none` | `none` |
| `VPN_SSL_DOMAIN` | `vpn.example.com` | — |
| `VPN_IPSEC_MODE` | `l2tp` \| `ikev2` \| `none` | `ikev2` |
| `VPN_INSTALL_WIREGUARD` | `yes` \| `no` | `yes` |
| `VPN_INSTALL_SHADOWSOCKS` | `yes` \| `no` | `yes` |
| `VPN_UNINSTALL_YES` | `yes` | `no` |

---

## 8. FAQ & Troubleshooting

**Q: Port panel ZET UI berapa?**
Panel memakai port **acak** (1024–62000) saat install. Lihat `XUI_PANEL_PORT` di `/root/vpn-credentials.txt` (atau `/etc/x-ui/install-result.env`).

**Q: Client tidak bisa connect ke OpenVPN/WireGuard/L2TP?**
1. Pastikan port terbuka di panel VPS provider (lihat tabel port di atas).
2. Pastikan ufw/firewalld tidak memblokir (`sudo ufw status`).
3. Cek service berjalan: `systemctl status openvpn-server@server`, `wg show`, `ipsec status`.

**Q: Ingin ganti port panel / password panel?**
Jalankan `x-ui` di terminal VPS → pilih menu pengaturan, atau edit langsung lewat menu panel (Panel Settings).

**Q: Server tidak punya IPv6 / hanya IPv4?**
Script dan konfigurasi client default aman untuk IPv4-only. Koneksi WireGuard/OpenVPN tetap jalan.

**Q: OpenVPN lambat?**
Coba ganti cipher di `/etc/openvpn/server/server.conf` ke `AES-128-GCM` (lebih ringan), lalu `systemctl restart openvpn-server@server`.

**Q: L2TP tidak bisa connect dari HP ke jaringan WiFi rumah yang sama?**
Limitasi L2TP: dua perangkat di belakang NAT yang sama tidak bisa connect bersamaan. Gunakan **WireGuard** atau **IKEv2** untuk kasus itu.

---

## 9. Tips Keamanan

- **SSH**: gunakan kunci SSH, nonaktifkan `PermitRootLogin` jika memungkinkan, atau minimal ganti password.
- **Panel ZET UI**: tanpa SSL, akses panel lewat **SSH tunnel** saja:
  ```bash
  ssh -L 2222:127.0.0.1:<port_panel> root@IP_VPS
  # lalu buka http://localhost:2222 di browser
  ```
- Batasi user VPN hanya untuk kebutuhan sendiri; hapus user yang tidak dipakai (`user ... remove`).
- Rutin `apt-get update && apt-get upgrade` untuk patch keamanan.
- Jangan sebarkan file kredensial (`.ovpn`, `.conf`, `vpn-credentials.txt`).

---

## Script terkait

- **Proxy server (3proxy)** — HTTP + SOCKS5, script `install-proxy.sh`: dokumentasi terpisah di [README-proxy.md](README-proxy.md).
