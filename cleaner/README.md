# cleaner-amazon-linux.sh

Script Bash untuk membersihkan file log secara otomatis di Amazon Linux EC2. Script ini menjaga partisi `/home` agar tidak penuh dengan menghapus log lama secara bertahap dan aman.

---

## Tujuan

- Mencegah disk `/home/ec2-user/logs` penuh akibat akumulasi file log
- Menghapus file log kadaluarsa (default: lebih dari 14 hari)
- Menjaga performa I/O server tetap stabil dengan mode *slow delete* (truncate bertahap)
- Aman dijalankan di lingkungan produksi: tidak menghapus file yang masih dibuka proses lain

---

## Cara Penggunaan

### 1. Persiapan

```bash
# Buat direktori log jika belum ada
mkdir -p /home/ec2-user/logs

# Set permission script
chmod 700 /home/ec2-user/cleaner-amazon-linux.sh
```

### 2. Menjalankan Manual

```bash
# Jalankan dengan pengaturan default (threshold 90%)
/home/ec2-user/cleaner-amazon-linux.sh

# Mulai bersih saat disk mencapai 80%, bersihkan sampai 70%
/home/ec2-user/cleaner-amazon-linux.sh -t 80 -r 70

# Fast delete (rm -rf langsung, tanpa throttle)
/home/ec2-user/cleaner-amazon-linux.sh -n

# Force hapus file terbesar jika masih penuh
/home/ec2-user/cleaner-amazon-linux.sh -f

# Debug mode (catat detail ke log)
/home/ec2-user/cleaner-amazon-linux.sh -d
```

### 3. Opsi CLI

| Flag | Deskripsi | Default |
|------|-----------|---------|
| `-r <angka>` | Target penggunaan disk setelah bersih (%) | `90` |
| `-t <angka>` | Mulai bersih saat disk mencapai nilai ini (%) | `90` |
| `-b <ukuran>` | Ukuran chunk saat slow delete (contoh: `50m`, `1g`) | `20m` |
| `-n` | Fast delete — pakai `rm -rf` langsung | - |
| `-s` | Random sleep sebelum mulai (untuk cluster) | - |
| `-f` | Force hapus file terbesar jika disk masih penuh | - |
| `-d` | Aktifkan debug logging | - |
| `-i` | Mode interaktif — kill instance lain yang berjalan | - |

### 4. File Konfigurasi (opsional)

Buat file `/home/ec2-user/cleaner.conf` dengan permission `600`:

```bash
chmod 600 /home/ec2-user/cleaner.conf
```

Contoh isi config:

```ini
# Target penggunaan disk setelah bersih (%)
to=75

# Mulai bersih saat disk mencapai (%)
from=85

# Ukuran chunk slow delete dalam MB
block=50

# Aktifkan fast delete (tidak bisa dipakai bersamaan dengan block)
# fast

# Random sleep untuk cluster
# sleep

# Debug logging
# debug

# Force hapus file terbesar
# force
```

> Config file akan diabaikan jika menjalankan dengan flag `--noconf`.

### 5. Jadwal Otomatis dengan Cron

```bash
crontab -e
```

Tambahkan baris berikut untuk menjalankan setiap jam:

```cron
0 * * * * /bin/bash /home/ec2-user/cleaner-amazon-linux.sh >> /home/ec2-user/logs/cron.log 2>&1
```

### 6. Jadwal dengan systemd Timer (direkomendasikan)

Buat `/etc/systemd/system/cleaner.service`:

```ini
[Unit]
Description=Log Cleaner

[Service]
Type=oneshot
User=ec2-user
ExecStart=/bin/bash /home/ec2-user/cleaner-amazon-linux.sh
```

Buat `/etc/systemd/system/cleaner.timer`:

```ini
[Unit]
Description=Jalankan Log Cleaner setiap jam

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
```

Aktifkan:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cleaner.timer
sudo systemctl list-timers cleaner.timer
```

---

## Cara Kerja

Script membersihkan log secara berlapis, berhenti begitu disk sudah di bawah target:

```
1. Disk ≥ 97%?  → Hapus file log sangat besar (>30G atau >50G)
2. Hapus log kadaluarsa (lebih dari 14 hari)
3. Disk masih penuh? → Hapus per hari mundur (13 hari, 12 hari, dst.)
4. Disk masih penuh? → Hapus per jam mundur (24 jam, 23 jam, dst.)
5. Disk masih penuh + flag -f? → Hapus file terbesar (maks. 5x)
```

File yang masih terbuka oleh proses lain tidak dihapus melainkan dikosongkan isinya (*crush*), sehingga proses yang memakai file tersebut tidak crash.

---

## Log

Script mencatat semua aktivitas ke:

```
/home/ec2-user/logs/cleaner.log.YYYY-MM-DD
```

Contoh isi log:

```
2025-04-17 04:12:03 [INFO] deleted expired file /home/ec2-user/logs/app.log.2025-04-01 size 52428800
2025-04-17 04:12:05 [WARN] deleted huge file /home/ec2-user/logs/access.log size 34359738368
2025-04-17 04:12:10 [ERROR] give up deleting largest files
```

---

## Rekomendasi Produksi

| # | Rekomendasi | Alasan |
|---|-------------|--------|
| 1 | Jangan jalankan sebagai `root` | Script menghapus file; jalankan sebagai `ec2-user` dengan akses terbatas hanya ke `LOGS_DIR` |
| 2 | Permission script `700` | Mencegah user lain membaca atau memodifikasi script |
| 3 | Permission config `600` | Script akan memperingatkan jika permission config terlalu longgar |
| 4 | Gunakan systemd timer, bukan cron | Systemd menyediakan sandboxing, logging via journald, dan restart policy |
| 5 | Pantau log cleaner secara berkala | Pastikan tidak ada error berulang atau file yang tidak terhapus |
| 6 | Set `-t` dan `-r` dengan selisih minimal 5% | Contoh: `-t 85 -r 80` agar tidak terlalu agresif menghapus |
| 7 | Hindari flag `-n` (fast delete) di produksi | Fast delete menyebabkan spike I/O yang bisa mempengaruhi performa |
| 8 | Install `lsof` di server | `sudo dnf install lsof` — memastikan file yang masih dipakai tidak dihapus paksa |

---

## Dependensi

| Perintah | Paket (Amazon Linux) | Keterangan |
|----------|----------------------|------------|
| `lsof` | `sudo dnf install lsof` | Deteksi file yang sedang dibuka; ada fallback `/proc/*/fd` |
| `ionice` | Bawaan (`util-linux`) | Prioritas I/O idle agar tidak ganggu performa |
| `nice` | Bawaan (`coreutils`) | Prioritas CPU rendah |
| `truncate` | Bawaan (`coreutils`) | Slow delete bertahap |
| `find` | Bawaan (`findutils`) | Pencarian file log |
