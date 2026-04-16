#!/bin/bash

usage() {
  echo "Usage: $0 [OPTIONS] [PATH]"
  echo ""
  echo "Options:"
  echo "  -f        Tampilkan ukuran semua file"
  echo "  -t <n>    Tampilkan top N file terbesar (default: 10)"
  echo "  -h        Tampilkan bantuan ini"
  echo ""
  echo "Contoh:"
  echo "  $0                    # cek folder saat ini"
  echo "  $0 /var/log           # cek folder tertentu"
  echo "  $0 -f /var/log        # tampilkan semua file"
  echo "  $0 -t 20 /var/log     # tampilkan top 20 file terbesar"
  exit 0
}

SHOW_FILES=false
TOP_N=10

while getopts "ft:h" opt; do
  case $opt in
    f) SHOW_FILES=true ;;
    t) TOP_N="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

TARGET="${1:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: '$TARGET' bukan direktori atau tidak ditemukan"
  exit 1
fi

echo "======================================"
echo " Cek Ukuran: $TARGET"
echo "======================================"

echo ""
echo "[ Total Ukuran ]"
du -sh "$TARGET"

echo ""
echo "[ Ukuran per Sub-Folder (diurutkan terbesar) ]"
du -h --max-depth=1 "$TARGET" | sort -rh | grep -v "^$(du -sh "$TARGET" | cut -f1)"

echo ""
echo "[ Top $TOP_N File Terbesar ]"
find "$TARGET" -type f -exec du -h {} + 2>/dev/null | sort -rh | head -"$TOP_N"

if [ "$SHOW_FILES" = true ]; then
  echo ""
  echo "[ Semua File ]"
  find "$TARGET" -type f -exec du -h {} + 2>/dev/null | sort -rh
fi

echo ""
echo "======================================"
