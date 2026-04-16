# DNS Setup Script — Pre-Deploy Checklist

Script `dns.sh` digunakan sebagai **bootstrap (user-data)** saat EC2 instance pertama kali dibuat. Script otomatis mengkonfigurasi hostname dan mendaftarkan DNS record di Route 53 tanpa perlu login ke instance.

---

## Cara Kerja Bootstrap

```
Instance launch → user-data dijalankan oleh cloud-init (sebagai root)
    → Tunggu IMDS ready
    → Ambil instance-id, private IP, region dari IMDS
    → Ambil tag Name dari EC2 → dijadikan hostname
    → Set hostname via hostnamectl
    → Disable cloud-init hostname override
    → Tulis /etc/hosts
    → Register/update A record di Route 53
```

---

## Prasyarat

- EC2 instance berbasis **Amazon Linux 2** atau **Amazon Linux 2023**
- AWS CLI tersedia di `/usr/bin/aws` (pre-installed di AL2/AL2023)
- Instance berjalan di dalam **VPC** dengan akses internet atau VPC Endpoint ke SSM dan Route 53

---

## Step-by-Step Checklist

### Step 1 — Buat IAM Role untuk EC2

Buat IAM Role dengan trust policy untuk EC2, lalu attach policy berikut:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeTags"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["ssm:GetParameter"],
      "Resource": "arn:aws:ssm:*:*:parameter/dns/zone-id"
    },
    {
      "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets"],
      "Resource": "arn:aws:route53:::hostedzone/*"
    }
  ]
}
```

- [ ] IAM Role sudah dibuat
- [ ] Policy `ec2:DescribeTags` sudah di-attach
- [ ] Policy `ssm:GetParameter` sudah di-attach
- [ ] Policy `route53:ChangeResourceRecordSets` sudah di-attach

---

### Step 2 — Simpan Zone ID di SSM Parameter Store

Lakukan ini **sebelum** instance dibuat, dari mesin lokal atau CI/CD:

```bash
aws ssm put-parameter \
  --name "/dns/zone-id" \
  --value "Z0027769AL6VVCOQ6GCX" \
  --type "String" \
  --region ap-southeast-1
```

- [ ] Zone ID Route 53 sudah diketahui (cek di AWS Console → Route 53 → Hosted Zones)
- [ ] Parameter `/dns/zone-id` sudah dibuat di SSM

---

### Step 3 — Verifikasi Hosted Zone di Route 53

```bash
aws route53 get-hosted-zone --id Z0027769AL6VVCOQ6GCX
```

- [ ] Hosted Zone dengan domain `k8s.local` sudah ada
- [ ] Zone ID sesuai dengan yang disimpan di SSM
- [ ] Hosted Zone berjenis **Private** dan sudah di-associate ke VPC yang akan digunakan instance

---

### Step 4 — Siapkan Tag `Name` untuk Instance

Script mengambil hostname dari tag `Name`. Tag **wajib diset saat launch**, bukan setelah instance jalan.

Format tag yang diharapkan:
```
Name = node1.k8s.local
```

Contoh launch via AWS CLI dengan tag:
```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxx \
  --instance-type t3.medium \
  --iam-instance-profile Name=<nama-iam-role> \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=node1.k8s.local}]' \
  --user-data file://dns.sh
```

- [ ] Format tag mengikuti pola `<subdomain>.<domain>` (contoh: `node1.k8s.local`)
- [ ] Tag `Name` sudah di-set di resource spec saat launch (bukan setelah instance jalan)
- [ ] Nilai tag tidak mengandung spasi atau karakter khusus

---

### Step 5 — Pastikan IMDSv2 Aktif

Script menggunakan IMDSv2. Pastikan saat launch instance **tidak menonaktifkan** IMDS endpoint:

```bash
# Cek di instance yang sudah berjalan
aws ec2 describe-instances \
  --instance-ids <instance-id> \
  --query 'Reservations[*].Instances[*].MetadataOptions'
```

Pastikan output:
```json
"HttpTokens": "optional" atau "required",
"HttpEndpoint": "enabled"
```

- [ ] IMDS endpoint aktif (`HttpEndpoint: enabled`)
- [ ] IMDSv2 tidak diblokir oleh security policy

---

### Step 6 — Upload Script ke S3

Karena digunakan sebagai bootstrap, script harus accessible saat launch. Simpan di S3:

```bash
aws s3 cp dns.sh s3://<bucket-name>/scripts/dns.sh
```

Lalu di user-data, unduh dan jalankan:

```bash
#!/bin/bash
aws s3 cp s3://<bucket-name>/scripts/dns.sh /tmp/dns.sh
bash /tmp/dns.sh
```

Atau langsung embed script `dns.sh` sebagai isi user-data saat launch.

- [ ] Script sudah di-upload ke S3 **atau** siap di-embed sebagai user-data
- [ ] Bucket S3 accessible dari instance (via IAM Role atau public)

---

### Step 7 — Launch Instance dengan IAM Role dan User-data

```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxx \
  --instance-type t3.medium \
  --iam-instance-profile Name=<nama-iam-role> \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=node1.k8s.local}]' \
  --user-data file://dns.sh
```

- [ ] IAM Role di-attach saat launch (`--iam-instance-profile`)
- [ ] IMDSv2 di-enforce saat launch (`HttpTokens=required`)
- [ ] Tag `Name` di-set saat launch (`--tag-specifications`)
- [ ] User-data berisi atau menjalankan script `dns.sh`

---

### Step 8 — Verifikasi Hasil Setelah Instance Boot

Tunggu instance selesai boot (~2-3 menit), lalu verifikasi:

**Cek log bootstrap:**
```bash
cat /var/log/dns-bootstrap.log
```

**Cek hostname:**
```bash
hostname
hostnamectl status
```

**Cek `/etc/hosts`:**
```bash
cat /etc/hosts
```

**Cek DNS record di Route 53:**
```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id Z0027769AL6VVCOQ6GCX \
  --query "ResourceRecordSets[?Name=='node1.k8s.local.']"
```

**Cek resolusi DNS dari instance lain di VPC yang sama:**
```bash
nslookup node1.k8s.local
```

- [ ] `/var/log/dns-bootstrap.log` tidak mengandung error
- [ ] `hostname` menampilkan nama yang benar
- [ ] `/etc/hosts` berisi entry yang sesuai
- [ ] A record muncul di Route 53 dengan IP yang benar
- [ ] DNS resolve dari instance lain di VPC yang sama

---

## Troubleshooting

| Error | Kemungkinan Penyebab | Solusi |
|---|---|---|
| `ERROR: Gagal ambil metadata dari EC2` | IMDSv2 diblokir atau tag Name tidak ada | Cek IMDS setting dan tag EC2 |
| `An error occurred (AccessDenied)` | IAM Role kurang permission atau belum di-attach saat launch | Tambahkan permission (Step 1), pastikan di-attach saat launch (Step 7) |
| `ParameterNotFound` | SSM parameter `/dns/zone-id` belum dibuat | Jalankan Step 2 |
| `getMetadataName = None` | Tag `Name` di-set setelah instance launch | Tag wajib ada saat launch (Step 4) |
| DNS tidak resolve | Hosted Zone tidak di-associate ke VPC | Associate Private Hosted Zone ke VPC (Step 3) |
| Hostname kembali ke default setelah reboot | cloud-init override tidak berhasil di-disable | Cek `/etc/cloud/cloud.cfg` secara manual |
| Bootstrap tidak jalan sama sekali | Script error sebelum logging aktif | Cek `/var/log/cloud-init-output.log` |

---

## Catatan

- Script ini **idempotent** — aman dijalankan lebih dari satu kali karena menggunakan `UPSERT` untuk DNS record
- Log bootstrap tersimpan di `/var/log/dns-bootstrap.log` dan `/var/log/cloud-init-output.log`
- Domain `k8s.local` dan zone ID di script perlu disesuaikan dengan environment masing-masing
- Script berjalan sebagai **root** via cloud-init, tidak perlu `sudo`
