# Cleaner — Auto-Bersih Log Server

## Apa ini?

Cleaner adalah konfigurasi otomatis yang menjaga folder log server kamu tetap bersih dan tidak memenuhi disk.

Bayangkan folder `/home/admin/logs` seperti tong sampah digital. Setiap hari server menulis catatan aktivitas (log) ke sana. Jika tidak pernah dibersihkan, lama-lama disk akan penuh dan server bisa mati.

Cleaner bekerja di balik layar setiap hari secara otomatis untuk:
- Mengarsipkan log lama
- Menghapus log yang sudah terlalu tua
- Memastikan disk tidak sampai penuh

---

## Cara Kerja (Singkat)

```
Setiap hari (tengah malam)
  └─ Logrotate membaca konfigurasi cleaner
       ├─ File log aktif → diarsipkan dan dikompres
       ├─ Arsip lebih dari 14 hari → dihapus otomatis
       └─ Disk masih > 80%? → hapus arsip tertua sampai aman
```

---

## Fitur

| Fitur | Keterangan |
|---|---|
| Rotate harian | Log diarsipkan setiap hari |
| Simpan 14 hari | Arsip lebih dari 14 hari dihapus otomatis |
| Kompresi otomatis | File lama dikompres (.gz) untuk hemat ruang |
| Aman untuk aplikasi aktif | File yang sedang ditulis aplikasi tidak dirusak |
| Penjaga disk 80% | Jika disk masih penuh setelah rotate, arsip tertua ikut dihapus |
| Format nama jelas | Nama file arsip menyertakan tanggal, contoh: `app.log-2026-04-18.gz` |

---

## Cara Pasang

### 1. Salin file ke logrotate

```bash
sudo cp cleaner.sh /etc/logrotate.d/cleaner
```

### 2. Pastikan hak akses benar

```bash
sudo chmod 644 /etc/logrotate.d/cleaner
sudo chown root:root /etc/logrotate.d/cleaner
```

### 3. Selesai

Logrotate akan menjalankannya otomatis setiap hari. Tidak perlu konfigurasi tambahan.

---

## Cara Uji Coba (Tanpa Eksekusi Nyata)

Gunakan perintah ini untuk melihat apa yang *akan* dilakukan cleaner, tanpa benar-benar mengubah file:

```bash
sudo logrotate -d /etc/logrotate.d/cleaner
```

Jika tidak ada pesan error, konfigurasi sudah benar.

---

## Cara Jalankan Manual

Jika ingin menjalankan pembersihan sekarang tanpa menunggu jadwal:

```bash
sudo logrotate -f /etc/logrotate.d/cleaner
```

---

## Cara Cek Log Aktivitas Cleaner

Cleaner mencatat setiap tindakan pembersihan ke file:

```
/home/admin/logs/cleaner.log
```

Contoh isi log:
```
2026-04-18 03:00:12 [WARN] disk usage 85%, cleaning old rotated logs...
2026-04-18 03:00:13 [INFO] force deleted /home/admin/logs/app.log-2026-04-01.gz
```

---

## Kompatibilitas

| Sistem Operasi | Status |
|---|---|
| Amazon Linux 2023 | Penuh |
| Ubuntu 20.04 / 22.04 | Penuh |
| Debian 10 / 11 / 12 | Penuh |
| RHEL / CentOS 8+ | Penuh |
| Alpine Linux | Penuh |
| Amazon Linux 2 | Hampir penuh — fitur `maxsize` tidak aktif* |

> **Amazon Linux 2:** Jika muncul error saat pasang, hapus baris `maxsize 30G` dari file `cleaner.sh` menggunakan teks editor, lalu ulangi langkah pemasangan.

---

## Struktur Folder yang Dipantau

```
/home/admin/logs/
├── app.log                        ← file aktif (tidak disentuh saat sedang ditulis)
├── app.log-2026-04-17.gz          ← arsip kemarin
├── app.log-2026-04-16.gz          ← arsip 2 hari lalu
├── ...
└── cleaner.log                    ← log aktivitas cleaner sendiri
```

---

## Pertanyaan Umum

**Q: Apakah data log yang masih dibutuhkan bisa terhapus?**
A: Tidak. Cleaner hanya menghapus arsip yang sudah dikompres (file `.gz`), bukan file log yang sedang aktif digunakan aplikasi.

**Q: Apakah bisa mengubah batas 14 hari atau 80%?**
A: Bisa. Buka file `cleaner.sh` dengan teks editor, ubah angka `14` di baris `rotate 14` atau angka `80` di baris `TARGET=80`.

**Q: Apakah cleaner jalan sendiri atau harus dijalankan manual?**
A: Jalan sendiri. Setelah dipasang, logrotate menjalankannya otomatis setiap hari (biasanya tengah malam).
