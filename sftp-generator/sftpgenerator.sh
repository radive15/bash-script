#!/bin/bash

set -e

# Validasi input
if [[ -z "$1" ]]; then
    echo "Usage: $0 <merchant_id>"
    exit 1
fi

# Validasi karakter merchant_id
if [[ ! "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: merchant_id hanya boleh huruf, angka, underscore, atau dash"
    exit 1
fi

merchant_ID=$1

# Cek apakah user sudah ada
if id "$merchant_ID" &>/dev/null; then
    echo "Error: user $merchant_ID sudah ada"
    exit 1
fi

mkdir -p /metadata/sftp/settle/$merchant_ID/download/settlement
sudo useradd -d /metadata/sftp/settle/$merchant_ID/download/settlement -s /usr/bin/rssh $merchant_ID
sudo sh -c "echo \"user=$merchant_ID:011:00010:/metadata/sftp/settle/$merchant_ID/download/settlement\" >> /etc/rssh.conf"

/home/admin/users/randpwd.sh > ~/users/$merchant_ID
cat ~/users/$merchant_ID | sudo passwd $merchant_ID --stdin
sudo rm -f ~/users/$merchant_ID

sudo sh -c "echo \"$merchant_ID=/metadata/sftp/settle/$merchant_ID\" >> /metadata/sftp/bin/sync.conf"
sudo cp -r /home/admin/CHROOT/* /metadata/sftp/settle/$merchant_ID/download/settlement
sudo sh /metadata/sftp/bin/sync.sh

echo "done: user $merchant_ID berhasil dibuat"
