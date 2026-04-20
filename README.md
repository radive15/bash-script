# bash-script

Kumpulan bash script untuk kebutuhan operasional server Linux, khususnya di lingkungan AWS EC2. Setiap folder berisi satu script beserta dokumentasinya.

---

## Struktur Folder

```
bash-script/
├── check-folder/       # Analisis penggunaan disk
├── cleaner/            # Rotasi dan pembersihan log otomatis
├── dns/                # Bootstrap hostname & DNS saat EC2 pertama kali jalan
├── hardening/          # Hardening keamanan server Linux
└── sftp-generator/     # Provisioning akun SFTP untuk merchant
```

---

## check-folder

**Script:** `check-folder-size.sh`

Menganalisis penggunaan disk pada folder tertentu. Menampilkan ukuran total, rincian per subfolder (diurutkan dari terbesar), dan daftar file terbesar.

**Kapan dipakai:** Saat disk hampir penuh dan perlu tahu folder/file mana yang paling banyak memakan ruang.

**Contoh penggunaan:**
```bash
./check-folder-size.sh /var/log           # Cek folder /var/log
./check-folder-size.sh -t 20 /home        # Tampilkan 20 file terbesar
./check-folder-size.sh -f /data           # Tampilkan semua file tanpa batas
```

---

## cleaner

**Script:** `cleaner.sh` (konfigurasi logrotate)

File konfigurasi logrotate untuk rotasi log harian otomatis. Log dikompresi dan disimpan selama 14 hari. Jika penggunaan disk melewati 80%, file `.gz` terlama dihapus otomatis sampai disk kembali di bawah ambang batas.

**Kapan dipakai:** Di-deploy ke `/etc/logrotate.d/cleaner` pada server produksi yang perlu manajemen log otomatis.

**Cara deploy:**
```bash
sudo cp cleaner.sh /etc/logrotate.d/cleaner
sudo logrotate -d /etc/logrotate.d/cleaner   # Test (dry-run)
sudo logrotate -f /etc/logrotate.d/cleaner   # Paksa jalankan
```

---

## dns

**Script:** `dns.sh` (EC2 user-data / cloud-init)

Script bootstrap yang dijalankan sekali saat EC2 pertama kali dinyalakan. Mengambil metadata instance (instance-id, IP, tag Name) via IMDSv2, mengatur hostname, lalu mendaftarkan A record ke Route 53 secara otomatis.

**Kapan dipakai:** Paste sebagai user-data saat launch EC2, agar instance langsung punya hostname dan DNS yang terdaftar tanpa konfigurasi manual.

**Prasyarat:**
- IAM Role dengan izin `ec2:DescribeTags`, `ssm:GetParameter`, `route53:ChangeResourceRecordSets`
- Zone ID Route 53 disimpan di SSM Parameter `/dns/zone-id`
- Instance diberi tag `Name` sebelum diluncurkan

---

## hardening

**Script:** `hardening.sh`

Script hardening keamanan komprehensif untuk server Linux di AWS EC2. Menerapkan 11 lapisan keamanan sekaligus dalam satu kali jalan.

**Kapan dipakai:** Dijalankan dengan `sudo` setelah server baru dibuat, sebelum digunakan untuk produksi. SSH key harus sudah terpasang sebelum menjalankan script ini karena login via password akan dinonaktifkan.

**Yang dilakukan script ini:**

| # | Langkah | Keterangan |
|---|---------|------------|
| 1 | Update sistem | Upgrade semua paket ke versi terbaru |
| 2 | SSH hardening | Nonaktifkan root login & password auth, cipher kuat |
| 3 | Kernel hardening | SYN flood protection, ASLR, anti-spoofing, dsb |
| 4 | Performance tuning | TCP BBR, shared memory, file descriptor, swappiness |
| 5 | Filesystem | `/tmp` noexec, `/proc` hidepid, core dump dinonaktifkan |
| 6 | Password policy | Minimal 14 karakter, expired 90 hari, 4 jenis karakter |
| 7 | Nonaktifkan service | Matikan bluetooth, cups, telnet, rpcbind, dsb |
| 8 | Firewall | Auto-detect firewalld/ufw/iptables, default DROP |
| 9 | Auditd | Pantau perubahan di `/etc/passwd`, `/etc/sudoers`, dsb |
| 10 | AIDE | Deteksi perubahan file tidak sah (integrity check harian) |
| 11 | AWS hardening | Enforce IMDSv2, install SSM Agent |

**Cara menjalankan:**
```bash
sudo bash hardening.sh           # Server standar (HDD)
sudo bash hardening.sh --ssd     # Server dengan SSD
```

---

## sftp-generator

**Script:** `sftpgenerator.sh`

Membuat akun SFTP terisolasi untuk merchant secara otomatis. Setiap merchant mendapat user Linux tersendiri dengan shell dibatasi (`rssh`), direktori home khusus, dan password acak yang di-generate otomatis.

**Kapan dipakai:** Dijalankan oleh tim ops saat ada merchant baru yang membutuhkan akses SFTP untuk pengiriman file settlement.

**Cara menjalankan:**
```bash
./sftpgenerator.sh <merchant_id>
# Contoh:
./sftpgenerator.sh merchant_abc
```

**Yang dibuat otomatis:**
- Direktori: `/metadata/sftp/settle/<merchant_id>/download/settlement`
- User Linux dengan shell terbatas (`rssh`)
- Entry konfigurasi di `/etc/rssh.conf`
- Password acak (tidak disimpan permanen)
- Konfigurasi sync di `/metadata/sftp/bin/sync.conf`
