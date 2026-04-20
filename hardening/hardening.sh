#!/usr/bin/env bash
# Linux Server Hardening Script for AWS EC2
# Tested on: Amazon Linux 2023, Ubuntu 22.04 LTS, RHEL 8/9
# Run as root: sudo bash hardening.sh
# Untuk server SSD/highmem: sudo bash hardening.sh --ssd

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# log=info, warn=peringatan, err=error — dipakai di seluruh script
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  err "Script harus dijalankan sebagai root"
  exit 1
fi

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
  else
    err "OS tidak dikenali"
    exit 1
  fi
  log "Detected OS: $OS $OS_VERSION"
}

# wrapper install paket agar fungsi lain tidak perlu tahu distro apa yang dipakai
pkg_install() {
  case $OS in
    amzn|rhel|centos|fedora)
      dnf install -y "$@" 2>/dev/null || yum install -y "$@"
      ;;
    ubuntu|debian)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    *)
      warn "Package manager tidak dikenali, skip install: $*"
      ;;
  esac
}

# ─────────────────────────────────────────────
# 1. UPDATE SYSTEM
# ─────────────────────────────────────────────
update_system() {
  log "=== [1/11] Update System Packages ==="
  case $OS in
    amzn|rhel|centos|fedora)
      dnf update -y 2>/dev/null || yum update -y
      ;;
    ubuntu|debian)
      apt-get update -y && apt-get upgrade -y
      ;;
  esac
  log "System updated"
}

# ─────────────────────────────────────────────
# 2. SSH HARDENING
# ─────────────────────────────────────────────
harden_ssh() {
  log "=== [2/11] SSH Hardening ==="
  local sshd_config="/etc/ssh/sshd_config"
  # backup dulu sebelum modifikasi, format: sshd_config.bak.YYYY-MM-DD
  cp "$sshd_config" "${sshd_config}.bak.$(date +%F)"

  declare -A ssh_settings=(
    ["Protocol"]="2"
    ["PermitRootLogin"]="no"
    ["PasswordAuthentication"]="no"
    ["PubkeyAuthentication"]="yes"
    ["PermitEmptyPasswords"]="no"
    ["MaxAuthTries"]="3"
    ["MaxSessions"]="5"
    ["ClientAliveInterval"]="300"
    ["ClientAliveCountMax"]="2"
    ["LoginGraceTime"]="30"
    ["X11Forwarding"]="no"
    ["AllowTcpForwarding"]="no"
    ["AllowAgentForwarding"]="no"
    ["PermitUserEnvironment"]="no"
    ["Banner"]="/etc/ssh/banner"
    ["LogLevel"]="VERBOSE"
    ["Ciphers"]="aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-gcm@openssh.com"
    ["MACs"]="hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"
  )

  # update nilai jika sudah ada (termasuk yang di-comment), append jika belum ada
  for key in "${!ssh_settings[@]}"; do
    if grep -qE "^#?${key}" "$sshd_config"; then
      sed -i "s|^#\?${key}.*|${key} ${ssh_settings[$key]}|" "$sshd_config"
    else
      echo "${key} ${ssh_settings[$key]}" >> "$sshd_config"
    fi
  done

  cat > /etc/ssh/banner << 'EOF'
***************************************************************************
  AUTHORIZED ACCESS ONLY. All activities are monitored and logged.
  Unauthorized access will be reported to law enforcement.
***************************************************************************
EOF

  sshd -t && systemctl restart sshd
  log "SSH hardened"
}

# ─────────────────────────────────────────────
# 3. KERNEL HARDENING (sysctl)
# ─────────────────────────────────────────────
harden_kernel() {
  log "=== [3/11] Kernel Hardening (sysctl) ==="
  cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# Network: disable IP forwarding (unless this is a router/NAT)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Network: disable ICMP redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0

# Network: enable SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Network: source validation (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Network: ignore broadcast pings
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Network: log suspicious packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Memory: ASLR (Address Space Layout Randomization)
kernel.randomize_va_space = 2

# Kernel: restrict dmesg to root
kernel.dmesg_restrict = 1

# Kernel: restrict ptrace
kernel.yama.ptrace_scope = 1

# Kernel: disable magic sysrq
kernel.sysrq = 0

# Kernel: restrict core dumps
fs.suid_dumpable = 0
kernel.core_uses_pid = 1

# Disable IPv6 if not needed (comment out if you use IPv6)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

  sysctl -p /etc/sysctl.d/99-hardening.conf
  log "Kernel hardened"
}

# ─────────────────────────────────────────────
# 4. PERFORMANCE TUNING (sysctl)
# ─────────────────────────────────────────────
tune_performance() {
  # gunakan flag --ssd untuk server dengan SSD atau RAM besar (dirty ratio lebih agresif)
  local ssd_mode=0
  [[ "${1:-}" == "--ssd" ]] && ssd_mode=1

  log "=== [4/11] Performance Tuning (ssd_mode=$ssd_mode) ==="

  # semua nilai dihitung dari RAM aktual agar sesuai spesifikasi instance
  local mem_bytes shmmax shmall file_max max_tw max_orphan min_free ulimit_max
  mem_bytes=$(awk '/MemTotal:/ { printf "%0.f", $2*1024 }' /proc/meminfo)
  shmmax=$(echo "$mem_bytes * 0.90" | bc | cut -f1 -d'.')
  shmall=$(( mem_bytes / $(getconf PAGE_SIZE) ))
  file_max=$(echo "$mem_bytes / 4194304 * 256" | bc | cut -f1 -d'.')
  max_tw=$(( file_max * 2 ))
  max_orphan=$(echo "$mem_bytes * 0.10 / 65536" | bc | cut -f1 -d'.')
  min_free=$(echo "($mem_bytes / 1024) * 0.01" | bc | cut -f1 -d'.')
  ulimit_max=$(echo "$file_max - ($file_max * 10 / 100)" | bc | cut -f1 -d'.')

  local dirty_ratio dirty_bg_ratio
  if [[ $ssd_mode -eq 1 ]]; then
    dirty_ratio=5
    dirty_bg_ratio=3
  else
    dirty_ratio=15
    dirty_bg_ratio=5
  fi

  cat > /etc/sysctl.d/99-performance.conf << EOF
# ── Kernel / Shared Memory ────────────────────────────────────────────────────
kernel.shmmax = $shmmax
kernel.shmall = $shmall
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.panic = 10

# ── TCP: connection backlog ───────────────────────────────────────────────────
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 20000
net.core.netdev_max_backlog = 2500
net.core.optmem_max = 25165824

# ── TCP: congestion control (BBR) ────────────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── TCP: keep-alive & timeouts ───────────────────────────────────────────────
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = $max_tw
net.ipv4.tcp_max_orphans = $max_orphan
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0

# ── TCP: reliability & features ──────────────────────────────────────────────
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_no_metrics_save = 1

# ── TCP/UDP: buffer sizes ─────────────────────────────────────────────────────
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 212992
net.core.wmem_default = 212992
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# ── Ports & routing ──────────────────────────────────────────────────────────
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.route.flush = 1

# ── Neighbor cache (high-traffic) ────────────────────────────────────────────
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_interval = 5
net.ipv4.neigh.default.gc_stale_time = 120

# ── Conntrack ─────────────────────────────────────────────────────────────────
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_loose = 0
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_close = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 20
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 20
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 10

# ── Memory ────────────────────────────────────────────────────────────────────
vm.swappiness = 1
vm.dirty_ratio = $dirty_ratio
vm.dirty_background_ratio = $dirty_bg_ratio
vm.dirty_expire_centisecs = 12000
vm.min_free_kbytes = $min_free

# ── File descriptors ──────────────────────────────────────────────────────────
fs.file-max = $file_max
EOF

  sysctl -p /etc/sysctl.d/99-performance.conf

  # Load conntrack modules
  modprobe nf_conntrack 2>/dev/null || true
  modprobe nf_log_ipv4  2>/dev/null || true

  # ulimits
  cat > /etc/security/limits.d/99-performance.conf << EOF
* soft nofile $ulimit_max
* hard nofile $ulimit_max
* soft nproc  $ulimit_max
* hard nproc  $ulimit_max
* soft core   0
* hard core   0
root soft nofile $ulimit_max
root hard nofile $ulimit_max
EOF

  log "Performance tuning applied (RAM-based, ssd_mode=$ssd_mode)"
}

# ─────────────────────────────────────────────
# 5. FILESYSTEM HARDENING
# ─────────────────────────────────────────────
harden_filesystem() {
  log "=== [5/11] Filesystem Hardening ==="
  # cek dulu sebelum append fstab agar tidak duplikat saat script dijalankan ulang

  # Secure /tmp with noexec, nosuid, nodev
  if ! grep -q "tmpfs.*/tmp" /etc/fstab; then
    echo "tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev,size=1G 0 0" >> /etc/fstab
    mount -o remount /tmp 2>/dev/null || true
  fi

  # Bind /var/tmp to /tmp
  if ! grep -q "/var/tmp" /etc/fstab; then
    echo "/tmp /var/tmp none bind 0 0" >> /etc/fstab
    mount --bind /tmp /var/tmp 2>/dev/null || true
  fi

  # Restrict /proc mount
  if ! grep -q "proc.*hidepid" /etc/fstab; then
    echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab
  fi

  # Core dump restriction
  echo "* hard core 0" >> /etc/security/limits.d/99-performance.conf
  echo "ulimit -S -c 0 > /dev/null 2>&1" >> /etc/profile

  # sticky bit mencegah user lain menghapus file milik orang lain di dir yang sama
  find / -xdev -type d -perm -0002 -exec chmod +t {} \; 2>/dev/null

  log "Filesystem hardened"
}

# ─────────────────────────────────────────────
# 6. USER & PASSWORD POLICY
# ─────────────────────────────────────────────
harden_users() {
  log "=== [6/11] User & Password Policy ==="

  # Password quality
  if command -v pwquality-tool &>/dev/null || [[ -f /etc/security/pwquality.conf ]]; then
    cat > /etc/security/pwquality.conf << 'EOF'
minlen = 14
minclass = 4
maxrepeat = 3
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
EOF
  fi

  # Login defs
  sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
  sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   7/'  /etc/login.defs
  sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' /etc/login.defs

  # Lock inactive accounts after 30 days
  useradd -D -f 30

  # Remove empty password entries
  awk -F: '($2 == "") {print $1}' /etc/shadow | while read -r user; do
    warn "User dengan empty password: $user — locking"
    passwd -l "$user"
  done

  # set shell ke nologin untuk akun sistem (uid < 1000) yang masih punya shell aktif
  while IFS=: read -r username _ uid _ _ _ shell; do
    if [[ $uid -lt 1000 && $uid -ne 0 && $shell != "/sbin/nologin" && $shell != "/bin/false" ]]; do
      usermod -s /sbin/nologin "$username" 2>/dev/null || true
    fi
  done < /etc/passwd

  log "User policy hardened"
}

# ─────────────────────────────────────────────
# 7. DISABLE UNNECESSARY SERVICES
# ─────────────────────────────────────────────
disable_services() {
  log "=== [7/11] Disable Unnecessary Services ==="
  local services=(
    bluetooth avahi-daemon cups postfix
    rpcbind nfs-server ypbind telnet vsftpd
    xinetd rsh rlogin rexec
  )
  for svc in "${services[@]}"; do
    if systemctl list-units --full --all | grep -q "${svc}.service"; then
      systemctl disable --now "$svc" 2>/dev/null && log "Disabled: $svc" || true
    fi
  done
}

# ─────────────────────────────────────────────
# 8. FIREWALL
# ─────────────────────────────────────────────
configure_firewall() {
  log "=== [8/11] Firewall Configuration ==="
  # deteksi otomatis: firewalld (RHEL/Amazon) → ufw (Ubuntu) → iptables (fallback)

  if command -v firewall-cmd &>/dev/null; then
    systemctl enable --now firewalld
    firewall-cmd --set-default-zone=drop
    firewall-cmd --zone=drop --add-service=ssh --permanent
    firewall-cmd --reload
    log "firewalld configured"

  elif command -v ufw &>/dev/null; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw --force enable
    log "ufw configured"

  else
    warn "Tidak ada firewall terdeteksi, menggunakan iptables dasar"
    pkg_install iptables-services 2>/dev/null || true
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
  fi
}

# ─────────────────────────────────────────────
# 9. AUDITING (auditd)
# ─────────────────────────────────────────────
configure_auditd() {
  log "=== [9/11] Audit Daemon ==="
  pkg_install audit audispd-plugins 2>/dev/null || true
  systemctl enable --now auditd

  cat > /etc/audit/rules.d/hardening.rules << 'EOF'
# Delete all existing rules
-D

# Buffer size
-b 8192

# Failure mode: 1=print warning, 2=panic
-f 1

# Identity changes
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group  -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d -p wa -k sudoers

# Auth & login
-w /var/log/auth.log -p wa -k auth_log
-w /var/log/secure   -p wa -k auth_log
-w /var/log/faillog  -p wa -k login
-w /var/log/lastlog  -p wa -k login

# SSH config
-w /etc/ssh/sshd_config -p wa -k sshd

# Cron
-w /etc/cron.d     -p wa -k cron
-w /etc/crontab    -p wa -k cron
-w /var/spool/cron -p wa -k cron

# Kernel modules
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod  -p x -k modules
-w /sbin/modprobe -p x -k modules

# Privilege escalation
-a always,exit -F arch=b64 -S setuid -S setgid -k privilege_escalation
-w /usr/bin/sudo -p x -k sudo_usage
-w /usr/bin/su   -p x -k su_usage

# Network config changes
-w /etc/hosts     -p wa -k network
-w /etc/resolv.conf -p wa -k network

# Unauthorized file access (EPERM, EACCES)
-a always,exit -F arch=b64 -S open  -F exit=-EPERM  -k access
-a always,exit -F arch=b64 -S open  -F exit=-EACCES -k access
-a always,exit -F arch=b64 -S creat -F exit=-EPERM  -k access

# Make rules immutable (reboot required to change)
# -e 2
EOF

  augenrules --load 2>/dev/null || service auditd restart
  log "auditd configured"
}

# ─────────────────────────────────────────────
# 10. AIDE (File Integrity Monitoring)
# ─────────────────────────────────────────────
configure_aide() {
  log "=== [10/11] AIDE File Integrity Monitoring ==="
  pkg_install aide 2>/dev/null || { warn "AIDE tidak tersedia di repo, skip"; return; }

  # buat database baseline — AIDE akan membandingkan kondisi file terhadap snapshot ini
  aide --init && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz 2>/dev/null || \
    aide -i  && mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz 2>/dev/null || true

  # Daily check via cron
  cat > /etc/cron.d/aide-check << 'EOF'
0 3 * * * root /usr/sbin/aide --check 2>&1 | mail -s "AIDE Integrity Report $(hostname)" root
EOF

  log "AIDE configured — daily check at 03:00"
}

# ─────────────────────────────────────────────
# 11. AWS-SPECIFIC HARDENING
# ─────────────────────────────────────────────
harden_aws() {
  log "=== [11/11] AWS-Specific Hardening ==="

  # IMDSv2 wajib — IMDSv1 rentan terhadap SSRF yang bisa bocorkan IAM credentials
  # Enforce IMDSv2 (disable IMDSv1)
  if command -v aws &>/dev/null; then
    INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token | \
      xargs -I{} curl -sf -H "X-aws-ec2-metadata-token: {}" \
      http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")

    REGION=$(curl -sf -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token | \
      xargs -I{} curl -sf -H "X-aws-ec2-metadata-token: {}" \
      http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")

    if [[ -n "$INSTANCE_ID" && -n "$REGION" ]]; then
      aws ec2 modify-instance-metadata-options \
        --instance-id "$INSTANCE_ID" \
        --region "$REGION" \
        --http-tokens required \
        --http-put-response-hop-limit 1 && log "IMDSv2 enforced" || warn "Gagal enforce IMDSv2 — pastikan IAM permission"
    else
      warn "Tidak bisa detect instance ID/region, skip IMDSv2 enforcement"
    fi
  else
    warn "AWS CLI tidak ditemukan — enforce IMDSv2 via console atau user-data"
  fi

  # Install SSM Agent jika belum ada
  if ! systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    case $OS in
      amzn) yum install -y amazon-ssm-agent && systemctl enable --now amazon-ssm-agent ;;
      ubuntu|debian)
        snap install amazon-ssm-agent --classic 2>/dev/null || \
        pkg_install amazon-ssm-agent
        systemctl enable --now amazon-ssm-agent 2>/dev/null || \
        snap start amazon-ssm-agent 2>/dev/null || true
        ;;
    esac
    log "SSM Agent installed"
  else
    log "SSM Agent already running"
  fi

  # CloudWatch Agent (opsional — uncomment jika mau)
  # pkg_install amazon-cloudwatch-agent
  # systemctl enable --now amazon-cloudwatch-agent

  log "AWS hardening done"
}

# ─────────────────────────────────────────────
# LYNIS AUDIT (opsional)
# ─────────────────────────────────────────────
run_lynis() {
  if ! command -v lynis &>/dev/null; then
    warn "Lynis tidak ditemukan, skip audit"
    return
  fi
  log "Menjalankan Lynis audit..."
  lynis audit system --quiet --report-file /var/log/lynis-report.dat
  log "Lynis report: /var/log/lynis-report.dat"
}

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
main() {
  log "======================================"
  log "  Linux Hardening Script - AWS EC2"
  log "  $(date)"
  log "======================================"

  detect_os
  update_system
  harden_ssh
  harden_kernel
  tune_performance "${1:-}"
  harden_filesystem
  harden_users
  disable_services
  configure_firewall
  configure_auditd
  configure_aide
  harden_aws
  run_lynis

  log "======================================"
  log "  Hardening selesai!"
  log "  REBOOT diperlukan agar semua"
  log "  perubahan kernel & mount aktif."
  log "======================================"
  warn "Pastikan SSH key kamu sudah terpasang sebelum reboot!"
}

main "$@"
