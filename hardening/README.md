# hardening.sh — Penjelasan Detail untuk Pemula

Script ini digunakan untuk **mengamankan dan mengoptimalkan server Linux di AWS EC2** secara otomatis.
Cukup jalankan satu kali, dan script akan mengurus 11 langkah hardening sekaligus.

---

## Cara Menjalankan

```bash
# Server HDD biasa
sudo bash hardening.sh

# Server SSD atau RAM besar
sudo bash hardening.sh --ssd
```

> **Penting:** Pastikan SSH key sudah terpasang sebelum reboot. Script akan menonaktifkan login dengan password.

---

## Alur Kerja Script (Dari Atas ke Bawah)

### Baris 1–5 — Header
```bash
#!/usr/bin/env bash
```
Baris pertama disebut **shebang** — memberitahu sistem bahwa file ini harus dijalankan menggunakan program `bash`.
Baris berikutnya adalah komentar (diawali `#`) yang menjelaskan script ini untuk apa dan cara pakainya.

---

### Baris 7 — Pengaman Script
```bash
set -euo pipefail
```
Tiga pengaman sekaligus:
- `-e` → script **berhenti otomatis** jika ada perintah yang gagal
- `-u` → **error** jika ada variabel yang belum didefinisikan
- `-o pipefail` → **error** jika ada bagian dari pipeline (`|`) yang gagal

Tanpa ini, script akan terus jalan meski ada yang salah dan bisa berbahaya.

---

### Baris 9–17 — Warna & Fungsi Log
```bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { ... }   # [+] teks hijau — informasi normal
warn() { ... }   # [!] teks kuning — peringatan
err()  { ... }   # [-] teks merah — error
```
Mendefinisikan warna terminal dan tiga fungsi pesan agar output mudah dibaca.
`NC` adalah **No Color** — mereset warna kembali ke default setelah teks berwarna.

---

### Baris 19–22 — Cek Root
```bash
if [[ $EUID -ne 0 ]]; then
  err "Script harus dijalankan sebagai root"
  exit 1
fi
```
`$EUID` adalah ID user yang sedang menjalankan script. Root selalu bernilai `0`.
Jika bukan root, script langsung berhenti — karena semua perintah hardening butuh akses root.

---

### Baris 24–34 — `detect_os()` — Deteksi Sistem Operasi
```bash
. /etc/os-release
OS=$ID
OS_VERSION=$VERSION_ID
```
File `/etc/os-release` berisi informasi distro Linux yang terinstall.
Script membaca file ini untuk tahu apakah server pakai Amazon Linux, Ubuntu, atau RHEL,
sehingga perintah yang dijalankan bisa disesuaikan per distro.

---

### Baris 36–49 — `pkg_install()` — Install Paket
```bash
pkg_install() {
  case $OS in
    amzn|rhel|...) dnf install -y "$@" ;;
    ubuntu|debian) apt-get install -y "$@" ;;
  esac
}
```
Fungsi pembantu agar fungsi lain cukup memanggil `pkg_install nama-paket` tanpa peduli distro apa.
Di belakang layar, script otomatis memilih `dnf`/`yum` (Red Hat) atau `apt-get` (Debian/Ubuntu).

---

## 11 Langkah Hardening

---

### [1/11] `update_system()` — Update Sistem
Mengupdate semua paket ke versi terbaru.
Patch keamanan terbaru ikut terinstall di sini, menutup celah yang sudah diketahui publik.

---

### [2/11] `harden_ssh()` — Amankan SSH

SSH adalah pintu masuk utama ke server. Fungsi ini memperketat konfigurasinya:

| Pengaturan | Nilai | Artinya |
|---|---|---|
| `PermitRootLogin` | no | Root tidak boleh login langsung lewat SSH |
| `PasswordAuthentication` | no | Login hanya boleh pakai SSH key, bukan password |
| `MaxAuthTries` | 3 | Maksimal 3x percobaan login, lalu diblokir |
| `LoginGraceTime` | 30 | Koneksi yang tidak login dalam 30 detik diputus |
| `X11Forwarding` | no | Menonaktifkan tampilan grafis lewat SSH (tidak dibutuhkan server) |
| `AllowTcpForwarding` | no | Mencegah SSH dipakai sebagai tunnel/proxy |
| `LogLevel` | VERBOSE | Mencatat detail aktivitas SSH untuk investigasi |
| `Ciphers` | aes256-gcm, chacha20 | Hanya izinkan enkripsi yang kuat |

Script juga membuat file **banner peringatan** yang muncul saat seseorang mencoba login,
lalu memvalidasi konfigurasi (`sshd -t`) sebelum me-restart SSH agar tidak terkunci.

---

### [3/11] `harden_kernel()` — Amankan Kernel Linux

Menulis pengaturan ke `/etc/sysctl.d/99-hardening.conf`. Kernel adalah inti OS — mengaturnya bisa mencegah berbagai serangan jaringan:

| Pengaturan | Artinya |
|---|---|
| `ip_forward = 0` | Server tidak meneruskan paket antar jaringan (bukan router) |
| `accept_redirects = 0` | Menolak perintah "redirect" dari router lain (mencegah pembajakan rute) |
| `tcp_syncookies = 1` | Perlindungan terhadap serangan SYN flood (membanjiri server dengan koneksi palsu) |
| `rp_filter = 1` | Memvalidasi sumber paket masuk (anti-spoofing/pemalsuan IP) |
| `log_martians = 1` | Mencatat paket dengan alamat sumber yang tidak masuk akal |
| `randomize_va_space = 2` | **ASLR** — mengacak lokasi memori program agar sulit dieksploitasi |
| `dmesg_restrict = 1` | Hanya root yang bisa membaca log kernel (menyembunyikan info sistem) |
| `yama.ptrace_scope = 1` | Membatasi kemampuan proses untuk "mengintip" proses lain |
| `sysrq = 0` | Menonaktifkan tombol magic SysRq yang bisa dipakai untuk bypass keamanan |
| `suid_dumpable = 0` | Program dengan hak istimewa tidak bisa membuat core dump (file debug yang bisa berisi data sensitif) |
| `disable_ipv6 = 1` | Matikan IPv6 jika tidak dipakai (kurangi attack surface) |

---

### [4/11] `tune_performance()` — Optimasi Performa

Mengoptimalkan parameter kernel untuk throughput jaringan tinggi. Semua nilai **dihitung otomatis** dari RAM server.

**Cara kerja perhitungan RAM:**
```bash
mem_bytes = total RAM dalam bytes (baca dari /proc/meminfo)
shmmax    = 90% RAM  → batas shared memory satu segmen
shmall    = RAM / page size  → total halaman shared memory
file_max  = RAM / 4MB * 256  → jumlah maksimum file terbuka
ulimit    = file_max - 10%   → batas per user/proses
```

**Pengaturan penting:**

| Pengaturan | Artinya |
|---|---|
| `tcp_congestion_control = bbr` | Algoritma BBR dari Google — meningkatkan kecepatan transfer secara signifikan |
| `default_qdisc = fq` | Antrian paket yang adil, diperlukan BBR agar bekerja optimal |
| `somaxconn = 65535` | Maksimum antrean koneksi yang menunggu di server |
| `tcp_tw_reuse = 1` | Reuse koneksi TCP yang sudah selesai (hemat port) |
| `swappiness = 1` | Hampir tidak pakai swap — utamakan RAM (lebih cepat) |
| `tcp_sack = 1` | Selective ACK — pengiriman ulang hanya paket yang hilang, bukan semuanya |
| `nf_conntrack_max = 524288` | Bisa melacak hingga ~500rb koneksi aktif sekaligus |

**Mode SSD (`--ssd`):** `dirty_ratio` diturunkan dari 15% ke 5%, artinya data lebih cepat ditulis ke disk
karena SSD tidak butuh batching sebesar HDD.

---

### [5/11] `harden_filesystem()` — Amankan Filesystem

| Tindakan | Artinya |
|---|---|
| `/tmp` dengan `noexec,nosuid,nodev` | File di `/tmp` tidak bisa dieksekusi — mencegah attacker upload dan jalankan malware di sana |
| `/var/tmp` → bind ke `/tmp` | Sama dengan `/tmp`, agar tidak ada celah lewat `/var/tmp` |
| `/proc` dengan `hidepid=2` | User biasa tidak bisa melihat proses milik user lain di `/proc` |
| Core dump dinonaktifkan | Program yang crash tidak membuat file dump yang bisa berisi password/data sensitif |
| Sticky bit di direktori writable | Mencegah user menghapus file milik orang lain di direktori yang bisa ditulis semua orang (seperti `/tmp`) |

---

### [6/11] `harden_users()` — Kebijakan User & Password

| Pengaturan | Artinya |
|---|---|
| `minlen = 14` | Password minimal 14 karakter |
| `minclass = 4` | Wajib ada huruf besar, kecil, angka, dan simbol |
| `PASS_MAX_DAYS 90` | Password harus diganti setiap 90 hari |
| `PASS_MIN_DAYS 7` | Tidak boleh ganti password lagi dalam 7 hari (mencegah balik ke password lama) |
| `PASS_WARN_AGE 14` | Peringatan 14 hari sebelum password expired |
| `useradd -D -f 30` | Akun yang tidak aktif 30 hari otomatis dikunci |
| Empty password → lock | Akun tanpa password langsung dikunci |
| Akun sistem → nologin | Akun sistem (seperti `daemon`, `bin`) tidak boleh punya shell login |

---

### [7/11] `disable_services()` — Matikan Layanan Tidak Perlu

Setiap layanan yang berjalan adalah potensi celah keamanan. Script mematikan:

| Layanan | Kenapa dimatikan |
|---|---|
| `bluetooth` | Server tidak butuh Bluetooth |
| `avahi-daemon` | Protokol network discovery — tidak dibutuhkan di server |
| `cups` | Layanan printer |
| `postfix` | Mail server — matikan jika server bukan mail server |
| `rpcbind`, `nfs-server` | NFS untuk sharing file — sering disalahgunakan |
| `telnet`, `rsh`, `rlogin` | Protokol lama tanpa enkripsi — berbahaya |
| `vsftpd`, `xinetd` | FTP dan super-server lama |

---

### [8/11] `configure_firewall()` — Konfigurasi Firewall

Script mendeteksi otomatis firewall yang tersedia:

1. **firewalld** (RHEL/Amazon Linux) → set zone ke `drop` (tolak semua), izinkan hanya SSH
2. **ufw** (Ubuntu) → `deny incoming`, `allow outgoing`, izinkan hanya SSH
3. **iptables** (fallback) → aturan manual: drop semua input kecuali SSH dan koneksi yang sudah established

Prinsipnya sama: **tolak semua koneksi masuk, kecuali yang eksplisit diizinkan.**

---

### [9/11] `configure_auditd()` — Audit Log

`auditd` mencatat aktivitas penting di server ke log. Script mengatur agar hal-hal berikut tercatat:

| Yang dipantau | Kenapa penting |
|---|---|
| `/etc/passwd`, `/etc/shadow` | Perubahan data user/password |
| `/etc/sudoers` | Perubahan hak akses sudo |
| `/var/log/auth.log` | Log autentikasi |
| `/etc/ssh/sshd_config` | Perubahan konfigurasi SSH |
| `/etc/crontab`, `/etc/cron.d` | Perubahan jadwal cron (sering dipakai persistence malware) |
| `insmod`, `rmmod`, `modprobe` | Load/unload kernel module |
| `sudo`, `su` | Penggunaan privilege escalation |
| `/etc/hosts`, `/etc/resolv.conf` | Perubahan konfigurasi jaringan |
| Akses file ditolak (EPERM/EACCES) | Percobaan akses file yang tidak diizinkan |

---

### [10/11] `configure_aide()` — File Integrity Monitoring

**AIDE (Advanced Intrusion Detection Environment)** adalah seperti "foto" kondisi file sistem.

Cara kerjanya:
1. Saat script jalan → AIDE membuat **database baseline** (foto awal semua file penting)
2. Setiap malam pukul 03:00 → AIDE membandingkan kondisi file sekarang dengan foto awal
3. Jika ada file yang berubah (hash berbeda) → laporan dikirim via email ke root

Berguna untuk deteksi jika ada file sistem yang dimodifikasi oleh attacker.

---

### [11/11] `harden_aws()` — Hardening Khusus AWS

**IMDSv2 (Instance Metadata Service v2):**
- Setiap EC2 instance punya endpoint metadata di `http://169.254.169.254`
- IMDSv1 bisa diakses langsung — berbahaya jika ada celah SSRF (attacker bisa curi IAM credentials)
- IMDSv2 menambahkan token yang harus di-request dulu — jauh lebih aman
- Script mengambil instance ID dan region dari metadata, lalu enforce IMDSv2 via AWS CLI

**SSM Agent:**
- Memungkinkan akses ke server lewat AWS Systems Manager tanpa perlu membuka port SSH ke publik
- Berguna sebagai fallback jika SSH bermasalah

---

## File yang Dimodifikasi Script

| File | Apa yang diubah |
|---|---|
| `/etc/ssh/sshd_config` | Konfigurasi SSH |
| `/etc/sysctl.d/99-hardening.conf` | Parameter keamanan kernel |
| `/etc/sysctl.d/99-performance.conf` | Parameter performa kernel |
| `/etc/security/limits.d/99-performance.conf` | Batas resource per user |
| `/etc/fstab` | Opsi mount filesystem |
| `/etc/security/pwquality.conf` | Kebijakan kualitas password |
| `/etc/login.defs` | Kebijakan masa berlaku password |
| `/etc/audit/rules.d/hardening.rules` | Aturan audit log |
| `/etc/cron.d/aide-check` | Jadwal cek AIDE harian |
| `/etc/ssh/banner` | Pesan peringatan saat login SSH |

---

## Setelah Script Selesai

Script akan meminta **REBOOT** agar semua perubahan kernel dan mount aktif.

```
[+] Hardening selesai!
[+] REBOOT diperlukan agar semua perubahan kernel & mount aktif.
[!] Pastikan SSH key kamu sudah terpasang sebelum reboot!
```

Urutan yang aman:
1. Pastikan SSH key sudah ada di `~/.ssh/authorized_keys`
2. Reboot server
3. Coba login ulang dengan SSH key
