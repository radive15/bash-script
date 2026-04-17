# check-folder-size.sh

Script bash untuk mengecek ukuran folder dan file secara ringkas di terminal.

## Fungsi

- Menampilkan **total ukuran** folder target
- Menampilkan **ukuran per sub-folder**, diurutkan dari terbesar
- Menampilkan **top N file terbesar** (default: 10)
- Opsional: menampilkan **semua file** beserta ukurannya

## Cara Pakai

```bash
./check-folder-size.sh [OPTIONS] [PATH]
```

### Options

| Flag | Keterangan |
|------|-----------|
| `-f` | Tampilkan semua file |
| `-t <n>` | Tampilkan top N file terbesar (default: 10) |
| `-h` | Tampilkan bantuan |

### Contoh

```bash
# Cek folder saat ini
./check-folder-size.sh

# Cek folder tertentu
./check-folder-size.sh /var/log

# Tampilkan semua file di /var/log
./check-folder-size.sh -f /var/log

# Tampilkan top 20 file terbesar
./check-folder-size.sh -t 20 /var/log
```

## Cara Kerja

1. Parse argumen dengan `getopts` — baca flag `-f`, `-t`, `-h`
2. Validasi path target — pastikan direktori ada
3. Jalankan `du -sh` untuk total ukuran
4. Jalankan `du -h --max-depth=1` + `sort -rh` untuk ukuran per sub-folder
5. Jalankan `find -type f` + `du -h` + `sort -rh | head` untuk top N file
6. Jika flag `-f` aktif, tampilkan semua file tanpa batas
