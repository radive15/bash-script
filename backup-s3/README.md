# backup-s3

**Script:** `backup-s3.sh`

Backup file/folder ke Amazon S3 dengan kompresi, enkripsi, dan retensi otomatis.

**Kapan dipakai:** Dijalankan via cron secara terjadwal (harian/mingguan) untuk memastikan data server tersimpan aman di S3 dengan pengelolaan retensi otomatis.

**Prasyarat:**
- `aws cli` terinstall dan terkonfigurasi
- IAM Role dengan izin `s3:PutObject`, `s3:GetObject`, `s3:ListBucket`, `s3:DeleteObject`
- (Opsional) GPG terinstall jika menggunakan enkripsi lokal

---

## Yang dilakukan script ini

| # | Langkah | Keterangan |
|---|---------|------------|
| 1 | Konfigurasi variabel | Set source dir, bucket, retensi, timestamp, dan tmpdir |
| 2 | Validasi prasyarat | Cek aws cli, source dir, dan akses ke S3 bucket |
| 3 | Kompresi | Compress file/folder target menjadi `.tar.gz` |
| 4 | Enkripsi | Enkripsi via GPG atau pakai AWS SSE-S3 saat upload |
| 5 | Upload ke S3 | Upload ke S3 dengan path terstruktur per tanggal |
| 6 | Verifikasi upload | Bandingkan ukuran file lokal vs S3 |
| 7 | Retensi otomatis | Hapus backup lama di S3 yang melewati batas retensi |
| 8 | Cleanup lokal | Hapus file temp setelah upload sukses |
| 9 | Logging | Catat hasil tiap step ke log file |
| 10 | Notifikasi | Alert via SNS jika backup gagal |

---

## Cara menjalankan

```bash
sudo bash backup-s3.sh                        # Backup dengan konfigurasi default
sudo bash backup-s3.sh --source /var/www/app  # Tentukan folder sumber
sudo bash backup-s3.sh --dry-run              # Simulasi tanpa upload ke S3
```

## Contoh cron (backup harian jam 02.00)

```bash
0 2 * * * /opt/scripts/backup-s3.sh >> /var/log/backup-s3.log 2>&1
```

---

## Struktur path di S3

```
s3://my-bucket/
└── backup/
    ├── 2026-05-06/
    │   └── backup_2026-05-06_02-00-00.tar.gz
    ├── 2026-05-07/
    │   └── backup_2026-05-07_02-00-00.tar.gz
    └── ...
```

---

## Konfigurasi

Edit variabel di bagian atas script sebelum dijalankan:

| Variabel | Default | Keterangan |
|----------|---------|------------|
| `SOURCE_DIR` | `/var/www/myapp` | Folder yang akan dibackup |
| `BUCKET` | `s3://my-bucket/backup` | S3 bucket tujuan |
| `RETENTION_DAYS` | `30` | Berapa hari backup disimpan |
| `ENCRYPT` | `false` | Aktifkan enkripsi GPG (`true`/`false`) |
| `SNS_TOPIC_ARN` | `` | ARN SNS untuk notifikasi gagal |
| `LOG_FILE` | `/var/log/backup-s3.log` | Path log file |
