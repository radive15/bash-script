# /etc/logrotate.d/cleaner
#
#
# Target: bersihkan /home/admin/logs, simpan log 14 hari, target disk <= 80%
#
# Cara pasang:
#   cp cleaner /etc/logrotate.d/cleaner
#
# Cara test tanpa eksekusi:
#   logrotate -d /etc/logrotate.d/cleaner
#
# Cara jalankan manual:
#   logrotate -f /etc/logrotate.d/cleaner
#
# Kompatibilitas:
#   - Amazon Linux 2023, Ubuntu 20+, Debian 10+, RHEL/CentOS 8+ : penuh
#   - Amazon Linux 2 (logrotate 3.8.6)                          : maxsize tidak didukung, sisanya berfungsi
#   - Alpine Linux                                               : penuh (menggunakan POSIX find)

/home/admin/logs/*.log {

    # ── Jadwal & Retensi ──────────────────────────────────────────────────────

    # Rotate setiap hari
    daily

    # Simpan maksimal 14 hari (setara RESERVE=14 di zclean.sh)
    rotate 14

    # ── Keamanan File yang Sedang Dibuka ──────────────────────────────────────

    # Salin file lalu kosongkan aslinya — TIDAK menghapus file yang sedang
    # ditulis aplikasi. Setara dengan fungsi crush_files() di zclean.sh.
    copytruncate

    # ── Kondisi Khusus ────────────────────────────────────────────────────────

    # Tidak error jika file log tidak ada
    missingok

    # Tidak rotate jika file kosong
    notifempty

    # Rotate juga jika ukuran file melebihi 10GB meski belum sehari
    # Setara dengan clean_huge() di zclean.sh
    # CATATAN: butuh logrotate >= 3.9.0 (Amazon Linux 2 tidak mendukung)
    maxsize 10G

    # ── Kompresi ──────────────────────────────────────────────────────────────

    # Kompres file lama dengan gzip untuk hemat disk
    compress

    # Tunda kompresi 1 hari (jaga-jaga file masih dibaca proses lain)
    delaycompress

    # ── Format Nama File ──────────────────────────────────────────────────────

    # Tambahkan tanggal pada nama file hasil rotate
    # Contoh: app.log → app.log-2026-04-18.gz
    dateext
    dateformat -%Y-%m-%d

    # ── Disk Usage Check (post-rotate) ────────────────────────────────────────
    # Jalankan setelah semua file dirotate.
    # Jika disk masih > 80%, hapus file rotate tertua sampai di bawah 80%.
    # Setara dengan logika clean_until() di zclean.sh.
    postrotate
        LOGS_DIR="/home/admin/logs"
        TARGET=80

        usage=$(df "$LOGS_DIR" | awk 'END {print $5}' | tr -d '%')

        if [ -n "$usage" ] && [ "$usage" -gt "$TARGET" ]; then
            echo "$(date '+%F %T') [WARN] disk usage ${usage}%, cleaning old rotated logs..." \
                >> "$LOGS_DIR/cleaner.log"

            # Hapus file rotate (.gz) dari yang tertua sampai disk <= TARGET
            # Menggunakan sort berbasis nama file (ISO date = urutan kronologis)
            # Kompatibel dengan GNU find, BusyBox (Alpine), dan Amazon Linux
            find "$LOGS_DIR" -type f -name "*.gz" | sort \
                | while IFS= read -r fpath; do
                    usage=$(df "$LOGS_DIR" | awk 'END {print $5}' | tr -d '%')
                    [ "$usage" -le "$TARGET" ] && break
                    rm -f "$fpath"
                    echo "$(date '+%F %T') [INFO] force deleted $fpath" \
                        >> "$LOGS_DIR/cleaner.log"
                done
        fi
    endscript
}
