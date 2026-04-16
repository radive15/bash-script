#!/bin/bash
#vim: set expandtab tabstop=4 shiftwidth=4 softtabstop=4:

# chkconfig: 2345 20 85

SYSCTL_RUN(){

host=$(hostname)
ARCH=$(uname -m)

which bc > /dev/null
if [ $? -ne 0 ]; then
    echo "This script require GNU bc, cf. http://www.gnu.org/software/bc/"
    echo "On Linux Debian/Ubuntu you can install it by doing : apt-get install bc"
    yum install -y bc
fi

mem_bytes=$(awk '/MemTotal:/ { printf "%0.f",$2 * 1024}' /proc/meminfo)
shmmax=$(echo "$mem_bytes * 0.90" | bc | cut -f 1 -d '.')
shmall=$(expr $mem_bytes / $(getconf PAGE_SIZE))
max_orphan=$(echo "$mem_bytes * 0.10 / 65536" | bc | cut -f 1 -d '.')
file_max=$(echo "$mem_bytes / 4194304 * 256" | bc | cut -f 1 -d '.')
max_tw=$(($file_max*2))
min_free=$(echo "($mem_bytes / 1024) * 0.01" | bc | cut -f 1 -d '.')
ulimitMax=$(echo "($file_max - ($file_max * 10 / 100))" | bc | cut -f 1 -d '.')

if [ "$1" != "ssd" ]; then
    vm_dirty_bg_ratio=5
    vm_dirty_ratio=15
else
    # This setup is generally ok for ssd and highmem servers
    vm_dirty_bg_ratio=3
    vm_dirty_ratio=5
fi

echo "Update ulimit for $host"
>/etc/security/limits.d/25-dana.conf cat << EOF

chatbot soft nofile $ulimitMax
chatbot soft nproc  $ulimitMax
chatbot hard nofile $ulimitMax
chatbot hard nproc  $ulimitMax

EOF

echo "Update sysctl for $host"
>/etc/sysctl.d/10-dana.conf cat << EOF
kernel.printk = 4 4 1 7
kernel.panic = 10
kernel.sysrq = 0
kernel.shmmax = $shmmax
kernel.shmall = $shmall
kernel.core_uses_pid = 1
kernel.msgmnb = 65536
kernel.msgmax = 65536
vm.swappiness = 1
vm.dirty_ratio = 80
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 12000
vm.min_free_kbytes = $min_free
fs.file-max = $file_max

net.core.netdev_max_backlog = 2500
net.core.rmem_default = 212992
net.core.rmem_max = 16777216
net.core.wmem_default = 212992
net.core.wmem_max = 16777216
net.core.somaxconn = 65000
net.core.optmem_max = 25165824
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_interval = 5
net.ipv4.neigh.default.gc_stale_time = 120
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
net.ipv4.conf.default.rp_filter = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.ip_no_pmtu_disc = 1
net.ipv4.route.flush = 1
net.ipv4.route.max_size = 8048576
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_congestion_control = htcp
net.ipv4.tcp_mem = 65536 131072 262144
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.udp_rmem_min = 16384
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_max_tw_buckets = $max_tw
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_orphans = $max_orphan
net.ipv4.tcp_orphan_retries = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_max_syn_backlog = 20000
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.inet_peer_gc_mintime = 5
EOF

sysctl --system
modprobe ip_conntrack
modprobe nf_log_ipv4
modprobe xt_NFLOG
modprobe nf_log_ipv6
exit $?
}

case $1 in
     start )
          SYSCTL_RUN
     ;;
     stop )
          echo "tidak ada stop HAHA"
     ;;
     * )
          SYSCTL_RUN
     ;;
esac
