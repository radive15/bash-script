#!/bin/bash
set -euo pipefail

# ─── Konfigurasi ─────────────────────────────────────────────────────────────
SOURCE_DIR="/var/www/myapp"
BUCKET="s3://my-bucket/backup"
RETENTION_DAYS=30
ENCRYPT=false
SNS_TOPIC_ARN=""
LOG_FILE="/var/log/backup-s3.log"
TMPDIR="/tmp/backup-s3"

# ─── Variabel internal ────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
DATE=$(date +%Y-%m-%d)
FILENAME="backup_${TIMESTAMP}.tar.gz"
FILEPATH="${TMPDIR}/${FILENAME}"
DRY_RUN=false

# ─── Parse argumen ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Fungsi logging ──────────────────────────────────────────────────────────
log() {
    local level="$1"
    local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${msg}" | tee -a "$LOG_FILE"
}

# ─── Fungsi notifikasi SNS ───────────────────────────────────────────────────
notify_failure() {
    local msg="$1"
    log "ERROR" "$msg"
    if [[ -n "$SNS_TOPIC_ARN" ]]; then
        aws sns publish \
            --topic-arn "$SNS_TOPIC_ARN" \
            --subject "Backup S3 GAGAL - $(hostname)" \
            --message "$msg" || true
    fi
}

# ─── Fungsi cleanup ──────────────────────────────────────────────────────────
cleanup() {
    if [[ -f "$FILEPATH" ]]; then
        rm -f "$FILEPATH" "${FILEPATH}.gpg" 2>/dev/null || true
        log "INFO" "File temp dihapus"
    fi
}
trap cleanup EXIT

# ─── Step 2: Validasi prasyarat ──────────────────────────────────────────────
log "INFO" "==== Mulai backup: $FILENAME ===="

if ! command -v aws &>/dev/null; then
    notify_failure "aws cli tidak ditemukan. Install terlebih dahulu."
    exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    notify_failure "Source dir tidak ditemukan: $SOURCE_DIR"
    exit 1
fi

if [[ -z "$(ls -A "$SOURCE_DIR")" ]]; then
    notify_failure "Source dir kosong: $SOURCE_DIR"
    exit 1
fi

if ! aws s3 ls "$BUCKET" &>/dev/null; then
    notify_failure "Tidak bisa akses S3 bucket: $BUCKET"
    exit 1
fi

mkdir -p "$TMPDIR"
log "INFO" "Validasi prasyarat OK"

# ─── Step 3: Kompresi ────────────────────────────────────────────────────────
log "INFO" "Mengompresi $SOURCE_DIR ..."
if ! tar -czf "$FILEPATH" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"; then
    notify_failure "Gagal mengompresi $SOURCE_DIR"
    exit 1
fi
log "INFO" "Kompresi selesai: $(du -sh "$FILEPATH" | cut -f1)"

# ─── Step 4: Enkripsi (opsional) ─────────────────────────────────────────────
UPLOAD_FILE="$FILEPATH"
if [[ "$ENCRYPT" == true ]]; then
    if ! command -v gpg &>/dev/null; then
        notify_failure "gpg tidak ditemukan tapi ENCRYPT=true"
        exit 1
    fi
    log "INFO" "Mengenkripsi file ..."
    gpg --batch --yes --symmetric --cipher-algo AES256 --output "${FILEPATH}.gpg" "$FILEPATH"
    rm -f "$FILEPATH"
    UPLOAD_FILE="${FILEPATH}.gpg"
    FILENAME="${FILENAME}.gpg"
    log "INFO" "Enkripsi selesai"
fi

# ─── Step 5: Upload ke S3 ────────────────────────────────────────────────────
S3_PATH="${BUCKET}/${DATE}/${FILENAME}"

if [[ "$DRY_RUN" == true ]]; then
    log "INFO" "[DRY-RUN] Akan upload: $UPLOAD_FILE -> $S3_PATH"
    log "INFO" "[DRY-RUN] Selesai, tidak ada perubahan."
    exit 0
fi

log "INFO" "Upload ke $S3_PATH ..."
for attempt in 1 2; do
    if aws s3 cp "$UPLOAD_FILE" "$S3_PATH"; then
        log "INFO" "Upload berhasil (percobaan ke-${attempt})"
        break
    fi
    if [[ $attempt -eq 2 ]]; then
        notify_failure "Upload ke S3 gagal setelah 2 percobaan: $S3_PATH"
        exit 1
    fi
    log "INFO" "Upload gagal, mencoba lagi ..."
    sleep 5
done

# ─── Step 6: Verifikasi upload ───────────────────────────────────────────────
log "INFO" "Memverifikasi upload ..."
LOCAL_SIZE=$(stat -c%s "$UPLOAD_FILE")
S3_SIZE=$(aws s3 ls "$S3_PATH" | awk '{print $3}')

if [[ "$LOCAL_SIZE" != "$S3_SIZE" ]]; then
    notify_failure "Ukuran file tidak cocok. Lokal: ${LOCAL_SIZE}B, S3: ${S3_SIZE}B"
    exit 1
fi
log "INFO" "Verifikasi OK (${LOCAL_SIZE} bytes)"

# ─── Step 7: Retensi otomatis ────────────────────────────────────────────────
log "INFO" "Menerapkan retensi ${RETENTION_DAYS} hari ..."
CUTOFF_DATE=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d)

aws s3 ls "${BUCKET}/" | while read -r line; do
    FILE_DATE=$(echo "$line" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1)
    FILE_NAME=$(echo "$line" | awk '{print $NF}')
    if [[ -n "$FILE_DATE" && "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
        log "INFO" "Menghapus backup lama: $FILE_NAME"
        aws s3 rm "${BUCKET}/${FILE_NAME}" || true
    fi
done
log "INFO" "Retensi selesai"

# ─── Step 8 & 9: Cleanup + log akhir ─────────────────────────────────────────
log "INFO" "==== Backup selesai: $S3_PATH ===="
