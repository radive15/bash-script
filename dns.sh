#!/bin/bash

set -euo pipefail

domain="k8s.local"
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

zone="${ROUTE53_ZONE_ID:-$($binAWS ssm get-parameter --region "$REGION" --name "/dns/zone-id" --query 'Parameter.Value' --output text)}"
subDomain="$(echo "$getMetadataName" | cut -d '.' -f 1)"
hostname=$getMetadataName

#Set Hostname
hostnamectl set-hostname --static "$hostname"
echo $hostname > /etc/hostname
sed -i 's/ - set_hostname/\#- set_hostname/' /etc/cloud/cloud.cfg
sed -i 's/ - update_hostname/\#- update_hostname/' /etc/cloud/cloud.cfg
echo "127.0.0.1 localhost localhost.localdomain localhost4 localhost4.localdomain4 localhost.$domain
::1       localhost localhost.localdomain localhost6 localhost6.localdomain6

$privateIP $hostname $subDomain" > /etc/hosts

#Set DNS

aws route53 change-resource-record-sets \
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
