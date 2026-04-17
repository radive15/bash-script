#!/bin/bash

set -euo pipefail

# Redirect semua output ke log untuk debugging bootstrap
exec > >(tee /var/log/dns-bootstrap.log) 2>&1
echo "=== DNS Bootstrap dimulai: $(date) ==="

# Tunggu network dan IMDS ready sebelum lanjut
echo "Menunggu IMDS ready..."
until curl -s -o /dev/null -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"; do
    echo "IMDS belum siap, coba lagi dalam 2 detik..."
    sleep 2
done
echo "IMDS ready."

domain="radifan.local"
binAWS="/usr/bin/aws"

# IMDSv2 - ambil token dulu
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Ambil metadata menggunakan token IMDSv2
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
privateIP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

# Ambil hostname dari tag Name EC2
getMetadataName=$($binAWS ec2 describe-tags --region "$REGION" \
  --filters "Name=resource-id,Values=$INSTANCE_ID" \
  --query 'Tags[?Key==`Name`].Value | [0]' --output text)

# Validasi variabel kritis
if [ -z "$privateIP" ] || [ -z "$getMetadataName" ] || [ "$getMetadataName" = "None" ]; then
    echo "ERROR: Gagal ambil metadata dari EC2"
    exit 1
fi

# Ambil zone ID dari env var atau SSM
zone="${ROUTE53_ZONE_ID:-}"
if [ -z "$zone" ]; then
    zone=$($binAWS ssm get-parameter --region "$REGION" \
      --name "/dns/zone-id" --query 'Parameter.Value' --output text)
fi

subDomain="$(echo "$getMetadataName" | cut -d '.' -f 1)"
hostname=$getMetadataName

#Set Hostname
hostnamectl set-hostname --static "$hostname"
echo "$hostname" > /etc/hostname

# Disable cloud-init hostname override jika ada
if grep -q "set_hostname" /etc/cloud/cloud.cfg 2>/dev/null; then
    sed -i 's/ - set_hostname/#- set_hostname/' /etc/cloud/cloud.cfg
    sed -i 's/ - update_hostname/#- update_hostname/' /etc/cloud/cloud.cfg
fi

printf "127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4 localhost.%s\n::1       localhost localhost.localdomain localhost6 localhost6.localdomain6\n\n%s %s %s\n" \
  "$domain" "$privateIP" "$hostname" "$subDomain" > /etc/hosts

#Set DNS

$binAWS route53 change-resource-record-sets \
  --hosted-zone-id "$zone" \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"$subDomain.$domain\",
        \"Type\": \"A\",
        \"TTL\": 60,
        \"ResourceRecords\": [{\"Value\": \"$privateIP\"}]
      }
    }]
  }"
