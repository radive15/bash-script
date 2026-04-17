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

1. Buka **IAM** → **Roles** → **Create role**
2. Pilih **AWS service** → Use case: **EC2** → **Next**
3. Skip bagian "Add permissions" → **Next**
4. Beri nama role, contoh: `ec2-dns-bootstrap-role` → **Create role**
5. Buka role yang baru dibuat → tab **Permissions** → **Add permissions** → **Create inline policy**
6. Pilih tab **JSON**, paste policy berikut:

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
    },
    {
      "Effect": "Allow",
      "Action": ["route53:GetChange"],
      "Resource": "arn:aws:route53:::change/*"
    }
  ]
}
```

7. **Next** → beri nama policy, contoh: `ec2-dns-bootstrap-policy` → **Create policy**

- [ ] IAM Role sudah dibuat
- [ ] Policy `ec2:DescribeTags` sudah di-attach
- [ ] Policy `ssm:GetParameter` sudah di-attach
- [ ] Policy `route53:ChangeResourceRecordSets` sudah di-attach

---

### Step 2 — Simpan Zone ID di SSM Parameter Store

1. Buka **AWS Console** → **Systems Manager** → **Parameter Store** → **Create parameter**
2. Isi form:
   - **Name**: `/dns/zone-id`
   - **Type**: `String`
   - **Value**: Zone ID dari hosted zone `radifan.local` (format: `ZXXXXXXXXXXXXXXXXX`)
3. Klik **Create parameter**

Zone ID bisa dilihat di **Route 53** → **Hosted zones** → klik `radifan.local` → kolom **Hosted zone ID**.

- [ ] Zone ID Route 53 sudah diketahui
- [ ] Parameter `/dns/zone-id` sudah dibuat di SSM

---

### Step 3 — Verifikasi Hosted Zone di Route 53

1. Buka **Route 53** → **Hosted zones**
2. Pastikan `radifan.local` sudah ada di daftar
3. Klik hosted zone tersebut → tab **Details**, pastikan:
   - **Type**: `Private`
   - **VPCs**: sudah di-associate ke VPC yang akan digunakan instance

- [ ] Hosted Zone dengan domain `radifan.local` sudah ada
- [ ] Zone ID sesuai dengan yang disimpan di SSM
- [ ] Hosted Zone berjenis **Private** dan sudah di-associate ke VPC yang akan digunakan instance

---

### Step 4 — Set Tag `Name` saat Launch via Console

Script mengambil hostname dari tag `Name`. Tag **wajib diset saat launch**, bukan setelah instance jalan.

Saat membuat instance di AWS Console, pada bagian **"Add tags"**:
- Key: `Name`
- Value: nama instance sesuai format `<subdomain>.<domain>`, contoh: `server1.radifan.local`

> **Perhatian:** Jika tag baru ditambahkan setelah instance running, script bootstrap sudah selesai dijalankan dan DNS **tidak akan terdaftar otomatis**.

- [ ] Format tag mengikuti pola `<subdomain>.<domain>` (contoh: `server1.radifan.local`)
- [ ] Tag `Name` sudah diisi di form "Add tags" **sebelum** klik Launch Instance
- [ ] Nilai tag tidak mengandung spasi atau karakter khusus

---

### Step 5 — Launch Instance via Console

Saat membuat instance di AWS Console, pastikan bagian berikut diisi di **"Advanced details"**:

- **IAM instance profile**: pilih role `ec2-dns-bootstrap-role` yang dibuat di Step 1
- **Metadata accessible**: `Enabled`
- **Metadata version**: `V1 and V2 (token optional)` atau `V2 only (token required)`
- **User data**: paste seluruh isi file `dns.sh`

- [ ] IAM Role `ec2-dns-bootstrap-role` dipilih di field "IAM instance profile"
- [ ] Metadata accessible di-set `Enabled`
- [ ] Metadata version tidak di-set ke `Disabled`
- [ ] User data diisi dengan isi script `dns.sh`

---

### Step 6 — Verifikasi Hasil Setelah Instance Boot

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
  --hosted-zone-id XXXXXXXXXXXXXXXXXXXX \
  --query "ResourceRecordSets[?Name=='server1.radifan.local.']"
```

**Cek resolusi DNS dari instance lain di VPC yang sama:**
```bash
nslookup server1.radifan.local
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
| `An error occurred (AccessDenied)` | IAM Role kurang permission atau belum di-attach saat launch | Tambahkan permission (Step 1), pastikan di-attach saat launch (Step 5) |
| `ParameterNotFound` | SSM parameter `/dns/zone-id` belum dibuat | Jalankan Step 2 |
| `getMetadataName = None` | Tag `Name` di-set setelah instance launch | Tag wajib ada saat launch (Step 4) |
| DNS tidak resolve | Hosted Zone tidak di-associate ke VPC | Associate Private Hosted Zone ke VPC (Step 3) |
| Hostname kembali ke default setelah reboot | cloud-init override tidak berhasil di-disable | Cek `/etc/cloud/cloud.cfg` secara manual |
| Bootstrap tidak jalan sama sekali | Script error sebelum logging aktif | Cek `/var/log/cloud-init-output.log` |

---

## Catatan

- Script ini **idempotent** — aman dijalankan lebih dari satu kali karena menggunakan `UPSERT` untuk DNS record
- Log bootstrap tersimpan di `/var/log/dns-bootstrap.log` dan `/var/log/cloud-init-output.log`
- Domain `radifan.local` dan zone ID di script perlu disesuaikan dengan environment masing-masing
- Script berjalan sebagai **root** via cloud-init, tidak perlu `sudo`
