#!/bin/bash
set -euo pipefail
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
cd "$OPENWRT_PATH"

# ============================================
# Roc OpenWrt Build Script v7.0
# 目标: OpenWrt 24.x + Kernel 6.12
# 设备: 小米 AX5 / Redmi AX5 (IPQ6018 512M)
# 特性: NSS全加速 + PPPoE不断网 + 高吞吐量
# ============================================

# 6.12 内核版本检查
KERNEL_VER=$(grep -oP 'LINUX_VERSION-\d+\.\d+=\K.*' include/kernel-version.mk 2>/dev/null || echo "unknown")
green "Detected kernel version: $KERNEL_VER"
echo "$KERNEL_VER" | grep -q "6\.12" || {
    yellow "WARNING: Not Linux 6.12! Some patches may not apply."
}

PKG_LIST=(argon-config frpc frps argon)

#1 feed更新（带重试）
green "====1 Feed Update===="
for i in 1 2 3; do
    ./scripts/feeds update -a && break
    yellow "Feed update retry $i/3..."
    sleep 5
done
./scripts/feeds install -a
./scripts/feeds install coreutils ca-bundle jq curl libopenssl-legacy

#2 LAN 192.168.10.1 hostname=Roc
green "====2 Modify LAN&Hostname===="
[ -f package/base-files/files/bin/config_generate ] && {
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
}

#3 NSS DTS 固定64MB专属预留内存
green "====3 NSS DDR 64M Reserve===="
DTS_FILE=""
for path in target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/{ipq6018-512m.dtsi,ipq60xx/ipq6018-512m.dtsi};do
[ -f "$path" ] && DTS_FILE="$path" && break
done
[ -n "$DTS_FILE" ] && sed -i '/nss\|reserved/{s/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/}' "$DTS_FILE"

#4 清理旧源码
green "====4 Clean Old Feed Source===="
rm -rf feeds/luci/applications/luci-app-{argon-config,frpc,frps} feeds/luci/themes/luci-theme-argon
for NAME in "${PKG_LIST[@]}";do
DIRS=$(find feeds/luci feeds/packages -maxdepth 3 -iname "*$NAME*" 2>/dev/null||true)
[ -n "$DIRS" ] && rm -rf $DIRS
done

#5 拉FRP（带容错）
green "====5 Pull FRP===="
if git clone --depth=1 https://github.com/laipeng668/luci feeds/_tmpfrp 2>/dev/null; then
    mv feeds/_tmpfrp/applications/luci-app-frpc feeds/luci/applications/
    mv feeds/_tmpfrp/applications/luci-app-frps feeds/luci/applications/
    rm -rf feeds/_tmpfrp
    green "FRP cloned successfully"
else
    yellow "FRP clone failed, skipping..."
fi

#6 全量拉取所有主题+插件
green "====6 Pull Theme & Plugins===="
clone_repo() {
    local url="$1" dest="$2" name="$3"
    if git clone --depth=1 "$url" "$dest" 2>/dev/null; then
        green "  ✓ $name"
    else
        yellow "  ✗ $name clone failed, skipping..."
    fi
}

clone_repo "https://github.com/jerrykuku/luci-theme-argon" "feeds/luci/themes/luci-theme-argon" "argon-theme"
clone_repo "https://github.com/jerrykuku/luci-app-argon-config" "feeds/luci/applications/luci-app-argon-config" "argon-config"
clone_repo "https://github.com/eamonxg/luci-theme-aurora" "feeds/luci/themes/luci-theme-aurora" "aurora-theme"
clone_repo "https://github.com/eamonxg/luci-app-aurora-config" "feeds/luci/applications/luci-app-aurora-config" "aurora-config"
clone_repo "https://github.com/gdy666/luci-app-lucky" "package/luci-app-lucky" "lucky"
clone_repo "https://github.com/destan19/OpenAppFilter.git" "package/OpenAppFilter" "OAF"
clone_repo "https://github.com/NONGFAH/luci-app-athena-led" "package/luci-app-athena-led" "athena-led"

LED_INIT="package/luci-app-athena-led/root/etc/init.d/athena_led"
LED_BIN="package/luci-app-athena-led/root/usr/sbin/athena-led"
[ -f "$LED_INIT" ] && chmod +x "$LED_INIT"
[ -f "$LED_BIN" ] && chmod +x "$LED_BIN"

#7 跳过代理源码
green "====7 Skip All Proxy Source===="

#8 NSS 6.12 兼容修复 + 启动优化
green "====8 NSS 6.12 Compatibility & Startup Order===="

# 8.0 NSS 驱动 6.12 API 适配
if echo "$KERNEL_VER" | grep -q "^6\.12"; then
    green "  Applying NSS 6.12 kernel API patches..."
    
    # 查找并修复 NSS 驱动中的 timer API
    for nss_c in $(find feeds/nss_packages -name "*.c" -path "*/qca-nss-drv/*" 2>/dev/null); do
        # setup_timer -> timer_setup (6.12 移除 setup_timer)
        if grep -q "setup_timer" "$nss_c" 2>/dev/null; then
            sed -i 's/setup_timer(\(&[^,]*\), \([^,]*\), \([^)]*\))/timer_setup(\1, \2, 0)/g' "$nss_c"
            yellow "    Fixed timer API in $(basename $nss_c)"
        fi
    done
    
    # 查找并修复 SSDK 中的内核版本检查
    for ssdk_mk in $(find feeds/nss_packages -name "Makefile" -path "*/qca-ssdk/*" 2>/dev/null); do
        grep -q "KERNEL_PATCHVER" "$ssdk_mk" 2>/dev/null && {
            sed -i 's/KERNEL_PATCHVER:=6\.6/KERNEL_PATCHVER:=6.12/g' "$ssdk_mk"
            green "    Fixed SSDK kernel version check"
        }
    done
    
    # NSS ECM 6.12 netif_napi_add 参数变化
    for ecm_c in $(find feeds/nss_packages -name "*.c" -path "*/qca-nss-ecm/*" 2>/dev/null); do
        if grep -q "netif_napi_add" "$ecm_c" 2>/dev/null; then
            sed -i 's/netif_napi_add(\([^,]*\), \([^,]*\), \([^,]*\), [0-9]*)/netif_napi_add(\1, \2, \3)/g' "$ecm_c"
            yellow "    Fixed NAPI API in $(basename $ecm_c)"
        fi
    done
fi

# 8.1 清理 6.12 废弃的 kmod 依赖
green "  Cleaning deprecated kmod dependencies..."
for mk_file in $(find package feeds -name "Makefile" 2>/dev/null); do
    # 移除 kmod-iptunnel4/kmode-iptunnel6（6.12 合并进内核）
    sed -i 's/\+kmod-iptunnel4//g; s/\+kmod-iptunnel6//g; s/\+kmod-iptunnel //g' "$mk_file" 2>/dev/null || true
done

# 8.2 启动顺序优化
optimize_start(){
local f="$1" s="$2"
[ ! -f "$f" ] && return 0
sed -i "s/START=.*/START=$s/" "$f"
sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$f"
}

# 删除 PPE 不稳定驱动
if [ -d feeds/nss_packages ];then
[ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe
optimize_start feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init 10
optimize_start feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init 11
optimize_start feeds/nss_packages/qca-nss-dp/files/qca-nss-dp.init 12
optimize_start feeds/nss_packages/qca-ssdk/files/qca-ssdk.init 13
fi

optimize_start package/base-files/files/etc/init.d/boot 15
optimize_start package/system/zram-swap/files/zram-swap.init 16
optimize_start package/utils/irqbalance/files/irqbalance.init 17
optimize_start package/base-files/files/etc/init.d/network 20
optimize_start package/network/services/dnsmasq/files/dnsmasq.init 21
optimize_start package/network/services/odhcpd/files/odhcpd.init 22
optimize_start package/network/config/firewall4/files/firewall.init 23
optimize_start feeds/packages/net/miniupnpd/files/miniupnpd.init 30
optimize_start feeds/packages/net/zerotier/files/zerotier.init 32
optimize_start package/network/services/uhttpd/files/uhttpd.init 40
optimize_start package/system/rpcd/files/rpcd.init 41
optimize_start feeds/packages/net/vlmcsd/files/vlmcsd.init 50
optimize_start feeds/packages/utils/ttyd/files/ttyd.init 51
optimize_start feeds/luci/applications/luci-app-autoreboot/root/etc/init.d/autoreboot 60
optimize_start feeds/luci/applications/luci-app-watchcat/root/etc/init.d/watchcat 61
optimize_start package/luci-app-athena-led/root/etc/init.d/athena_led 95

#9 编译补丁（6.12 适配）
green "====9 Compile Patches for 6.12===="

# Tailscale 兼容
TS=$(find feeds/packages -maxdepth3 -name tailscale/Makefile 2>/dev/null|head -1||true)
[ -f "$TS" ] && {
    sed -i '/\/files/d' "$TS"
    grep -q "kmod-tun" "$TS" 2>/dev/null && sed -i 's/kmod-tun/kmod-tun/g' "$TS"
}

# Rust LLVM 兼容（6.12 需要 LLVM>=15）
RU=$(find feeds/packages -maxdepth3 -name rust/Makefile 2>/dev/null|head -1||true)
[ -f "$RU" ] && {
    sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU"
}

#10 预埋系统配置
green "====10 System Configuration===="
mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/hotplug.d/iface
mkdir -p package/base-files/files/usr/bin

#①时区+中文
cat > package/base-files/files/etc/uci-defaults/95-set-lang <<'EOF'
#!/bin/sh
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci set luci.main.lang='zh_cn'
uci commit system
uci commit luci
echo "export LANG=zh_CN.UTF-8" >> /etc/profile
EOF
chmod +x package/base-files/files/etc/uci-defaults/95-set-lang

#②文件系统稳定（6.12 适配）
cat > package/base-files/files/etc/uci-defaults/88-fs-stable <<'EOF'
#!/bin/sh
mount -o remount,noatime / 2>/dev/null || true
[ -w /proc/sys/kernel/printk ] && echo "3 4 1 3" > /proc/sys/kernel/printk 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true

grep -q "fs.file-max" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'FSTUNE'
fs.file-max=65536
fs.nr_open=65536
vm.dirty_writeback_centisecs=1500
vm.dirty_expire_centisecs=3000
FSTUNE
EOF
chmod +x package/base-files/files/etc/uci-defaults/88-fs-stable

#③高吞吐量+TCP优化（6.12 BBRv3适配）
cat > package/base-files/files/etc/uci-defaults/90-memoptimize <<'THROUGHPUT'
#!/bin/sh
echo 10 >/proc/sys/vm/dirty_ratio
echo 5 >/proc/sys/vm/dirty_background_ratio

total_mem=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 524288)
if [ "$total_mem" -gt 1048576 ]; then
    echo 8192 >/proc/sys/vm/min_free_kbytes
elif [ "$total_mem" -gt 524288 ]; then
    echo 4096 >/proc/sys/vm/min_free_kbytes
else
    echo 2048 >/proc/sys/vm/min_free_kbytes
fi

# TCP Fast Open + BBR（6.12 支持 BBRv3）
grep -q "tcp_fastopen" /etc/sysctl.conf || echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
grep -q "tcp_congestion_control" /etc/sysctl.conf || {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
}

# TCP 缓冲区（高吞吐量）
grep -q "tcp_rmem" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'TCPBUF'
net.ipv4.tcp_rmem=4096 131072 6291456
net.ipv4.tcp_wmem=4096 65536 4194304
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_mem=98304 131072 196608
TCPBUF

# TCP 连接优化
grep -q "tcp_tw_reuse" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'TCPCONN'
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_keepalive_time=60
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=6
net.ipv4.tcp_max_orphans=16384
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=4096
net.ipv4.route.gc_timeout=100
net.ipv4.tcp_backlog=8192
net.ipv4.tcp_window_scaling=1
TCPCONN

# 连接跟踪（6.12 优化）
grep -q "nf_conntrack_timestamp" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'CONNTRACK'
net.netfilter.nf_conntrack_max=65535
net.nf_conntrack_max=65535
net.netfilter.nf_conntrack_timestamp=0
net.netfilter.nf_conntrack_early_offload=1
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=15
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
CONNTRACK

# 网络核心（6.12 新增参数）
grep -q "netdev_max_backlog" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'NETCORE'
net.core.netdev_max_backlog=5000
net.core.dev_weight=128
net.core.netdev_budget=600
net.core.netdev_budget_usecs=8000
NETCORE

# UDP 优化（6.12）
grep -q "udp_mem" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<'UDP'
net.ipv4.udp_mem=65536 131072 262144
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
UDP

# NSS 稳速
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable

# 定时缓存回收
grep -q drop_caches /etc/crontabs/root || echo "0 */6 * * * sync;echo 1 >/proc/sys/vm/drop_caches" >> /etc/crontabs/root
/etc/init.d/cron enable
THROUGHPUT
chmod +x package/base-files/files/etc/uci-defaults/90-memoptimize

#④ OOM 调优
cat > package/base-files/files/etc/uci-defaults/91-oom-tune <<'EOF'
#!/bin/sh
grep -q "vm.panic_on_oom" /etc/sysctl.conf || echo "vm.panic_on_oom=0" >> /etc/sysctl.conf
grep -q "vm.oom_kill_allocating_task" /etc/sysctl.conf || echo "vm.oom_kill_allocating_task=0" >> /etc/sysctl.conf
grep -q "kernel.panic_on_oops" /etc/sysctl.conf || echo "kernel.panic_on_oops=10" >> /etc/sysctl.conf
EOF
chmod +x package/base-files/files/etc/uci-defaults/91-oom-tune

#⑤防火墙+ZT+dnsmasq
cat > package/base-files/files/etc/uci-defaults/92-fix-all <<'EOF'
#!/bin/sh
if ! uci -q get fstab.@global[0] >/dev/null; then
    uci add fstab global
fi
uci set fstab.@global[0].extroot='0'
uci commit fstab

if ! uci -q get oaf.@global[0] >/dev/null; then
    uci add oaf global
fi
uci set oaf.@global[0].enable='0'
uci commit oaf

sed -i '/mkdir -p \/var\/run\/hostapd/d' /etc/init.d/wireless
sed -i 's/start_service() {/start_service() {\nmkdir -p \/var\/run\/hostapd\nchmod 777 \/var\/run\/hostapd/' /etc/init.d/wireless

uci set firewall.@defaults[0].fullcone='1'

# 清理旧 ZT 配置
for section in $(uci show firewall 2>/dev/null | grep "\.name='zerotier'" | cut -d= -f1); do
    uci delete "$section" 2>/dev/null || true
done
for section in $(uci show firewall 2>/dev/null | grep -E "\.(src|dest)='(lan|zerotier)'" | cut -d. -f1-2 | sort -u); do
    s=$(uci -q get "$section.src" 2>/dev/null || true)
    d=$(uci -q get "$section.dest" 2>/dev/null || true)
    if { [ "$s" = "lan" ] && [ "$d" = "zerotier" ]; } || { [ "$s" = "zerotier" ] && [ "$d" = "lan" ]; }; then
        uci delete "$section" 2>/dev/null || true
    fi
done
for section in $(uci show firewall 2>/dev/null | grep "\.name='ZT-9993-UDP'" | cut -d= -f1); do
    uci delete "$section" 2>/dev/null || true
done

# 重建 ZT
uci add firewall zone
uci set firewall.@zone[-1].name='zerotier'
uci set firewall.@zone[-1].device='zt+'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='zerotier'
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='zerotier'
uci set firewall.@forwarding[-1].dest='lan'
uci add firewall rule
uci set firewall.@rule[-1].name='ZT-9993-UDP'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='9993'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall

# dnsmasq 高并发
uci set dhcp.@dnsmasq[0].cachesize='2000'
uci set dhcp.@dnsmasq[0].dnsforwardmax='512'
uci set dhcp.@dnsmasq[0].mincachettl='600'
uci set dhcp.@dnsmasq[0].maxcachettl='3600'
uci set dhcp.@dnsmasq[0].localise_queries='1'
uci set dhcp.@dnsmasq[0].rebind_protection='0'
uci commit dhcp

grep -q "ZTIF=" /etc/rc.local || echo 'sleep 8;ZTIF=$(ip link|grep zt|awk "{print \$2}"|sed s/://);[ -n "$ZTIF" ]&&ip link set $ZTIF mtu 1400' >> /etc/rc.local
/etc/init.d/zerotier enable
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/92-fix-all

#⑥ECM 连接数
cat > package/base-files/files/etc/uci-defaults/93-nss-ecm <<'EOF'
#!/bin/sh
uci -q get ecm.@global[0] >/dev/null || uci add ecm global
uci set ecm.@global[0].acceleration_engine='nss'
uci set ecm.@global[0].preload_mode='full'
uci set ecm.@global[0].conn_limit='65535'
uci commit ecm
EOF
chmod +x package/base-files/files/etc/uci-defaults/93-nss-ecm

#⑦ Zram（6.12 LZ4/ZSTD）
cat > package/base-files/files/etc/uci-defaults/94-zram-tune <<'EOF'
#!/bin/sh
if [ -d /sys/block/zram0 ]; then
    # 6.12 支持多压缩流
    [ -f /sys/block/zram0/max_comp_streams ] && echo 4 > /sys/block/zram0/max_comp_streams 2>/dev/null || true
    echo 40 > /proc/sys/vm/swappiness 2>/dev/null || true
    # 6.12 新增：写回限制
    [ -d /sys/block/zram0/bdi ] && echo 0 > /sys/block/zram0/bdi/max_ratio 2>/dev/null || true
    # 6.12 支持 recompression
    [ -f /sys/block/zram0/recomp_algorithm ] && echo "zstd" > /sys/block/zram0/recomp_algorithm 2>/dev/null || true
else
    echo 60 > /proc/sys/vm/swappiness 2>/dev/null || true
fi
EOF
chmod +x package/base-files/files/etc/uci-defaults/94-zram-tune

#⑧ PPPoE 优化（6.12 ppp_generic）
cat > package/base-files/files/etc/uci-defaults/96-pppoe-optimize <<'EOF'
#!/bin/sh
uci -q get network.wan >/dev/null || exit 0
proto=$(uci -q get network.wan.proto 2>/dev/null || true)

if [ "$proto" = "pppoe" ]; then
    uci set network.wan.keepalive='30 6'
    uci set network.wan.peerdns='1'
    uci set network.wan.mtu='1492'
    uci set network.wan.demand='0'
    uci set network.wan.ipv6='1'
    uci commit network
    ip link set pppoe-wan mtu 1492 2>/dev/null || true
fi

# 6.12 ppp_generic 替代 ppp_async
lsmod | grep -q ppp_generic || modprobe ppp_generic 2>/dev/null || true
grep -q "pppd-watchdog" /etc/crontabs/root || \
    echo "*/5 * * * * pgrep pppd >/dev/null 2>&1 || ifup wan 2>/dev/null" >> /etc/crontabs/root
EOF
chmod +x package/base-files/files/etc/uci-defaults/96-pppoe-optimize

#⑨ 中断亲和（6.12 NAPI threaded）
cat > package/base-files/files/etc/uci-defaults/97-irq-affinity <<'IRQ612'
#!/bin/sh
cpu_count=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)

set_affinity() {
    local irq_name="$1" cpu="$2"
    local irq_num=$(grep -E "$irq_name" /proc/interrupts | awk -F: '{print $1}' | tr -d ' ' | head -1)
    [ -n "$irq_num" ] && [ -f "/proc/irq/$irq_num/smp_affinity" ] && {
        echo "$cpu" > "/proc/irq/$irq_num/smp_affinity" 2>/dev/null || true
    }
}

if [ "$cpu_count" -ge 4 ]; then
    set_affinity "eth1" "04"
    set_affinity "eth0" "08"
    set_affinity "nss" "01"
    set_affinity "ath11k" "02"
elif [ "$cpu_count" -ge 2 ]; then
    set_affinity "eth1" "02"
    set_affinity "eth0" "02"
    set_affinity "nss" "01"
fi

# RPS/XPS
for iface in eth0 eth1 pppoe-wan br-lan; do
    [ -d "/sys/class/net/$iface" ] || continue
    mask=$(printf "%x" $(( (1 << cpu_count) - 1 )))
    for q in /sys/class/net/$iface/queues/rx-* 2>/dev/null; do
        echo "$mask" > "$q/rps_cpus" 2>/dev/null || true
    done
    for q in /sys/class/net/$iface/queues/tx-* 2>/dev/null; do
        echo "$mask" > "$q/xps_cpus" 2>/dev/null || true
    done
    ip link set dev "$iface" txqueuelen 2000 2>/dev/null || true
done

# 6.12 NAPI 线程化
[ -f /proc/sys/net/core/napi_threaded ] && echo 1 > /proc/sys/net/core/napi_threaded 2>/dev/null || true
IRQ612
chmod +x package/base-files/files/etc/uci-defaults/97-irq-affinity

#⑩ NSS 吞吐量最大化
cat > package/base-files/files/etc/uci-defaults/98-nss-throughput <<'NSSTUNE'
#!/bin/sh
[ -d /sys/module/qca_nss_drv ] && {
    [ -f /sys/module/qca_nss_drv/parameters/nss_watchdog ] && echo 0 > /sys/module/qca_nss_drv/parameters/nss_watchdog 2>/dev/null || true
    [ -f /sys/module/qca_nss_drv/parameters/pbuf_high_watermark ] && echo 10 > /sys/module/qca_nss_drv/parameters/pbuf_high_watermark 2>/dev/null || true
    [ -f /sys/module/qca_nss_drv/parameters/multi_queue ] && echo 1 > /sys/module/qca_nss_drv/parameters/multi_queue 2>/dev/null || true
}
[ -d /sys/module/xt_FULLCONENAT ] && echo 1 > /sys/module/xt_FULLCONENAT/parameters/enable 2>/dev/null || true
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 > /sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
NSSTUNE
chmod +x package/base-files/files/etc/uci-defaults/98-nss-throughput

#11 长期运行守护
green "====11 Long-Run Guardian===="

cat > package/base-files/files/usr/bin/roc-guardian <<'GUARDIAN'
#!/bin/sh
LOG_TAG="roc-guardian"
MEM_THRESHOLD=85
PROC_THRESHOLD=300

PROTECT_PROCS="
  /usr/sbin/dnsmasq:-500
  /usr/sbin/uhttpd:-500
  /usr/sbin/dropbear:-500
  /usr/sbin/rpcd:-400
  /usr/sbin/zerotier-one:-300
  /usr/sbin/frpc:-300
  /usr/sbin/frps:-300
"

log() { logger -t "$LOG_TAG" -p daemon.info "$1"; }

protect_oom() {
    for entry in $PROTECT_PROCS; do
        proc_path="${entry%%:*}"
        score="${entry##*:}"
        pid=$(pgrep -f "$proc_path" 2>/dev/null | head -1)
        [ -n "$pid" ] && [ -d "/proc/$pid" ] && {
            echo "$score" > "/proc/$pid/oom_score_adj" 2>/dev/null || true
        }
    done
}

check_memory() {
    mem_used=$(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{printf "%.0f",(t-a)*100/t}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "$mem_used" -gt 95 ]; then
        log "CRITICAL: memory ${mem_used}%, emergency recovery"
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        /etc/init.d/uhttpd restart 2>/dev/null || true
    elif [ "$mem_used" -gt "$MEM_THRESHOLD" ]; then
        log "WARNING: memory ${mem_used}%, releasing pagecache"
        sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi
}

check_processes() {
    for entry in $PROTECT_PROCS; do
        proc_path="${entry%%:*}"
        proc_name=$(basename "$proc_path")
        if ! pgrep -f "$proc_path" >/dev/null 2>&1; then
            log "Process $proc_name dead, restarting..."
            case "$proc_name" in
                dnsmasq)   /etc/init.d/dnsmasq restart 2>/dev/null ;;
                uhttpd)    /etc/init.d/uhttpd restart 2>/dev/null ;;
                dropbear)  /etc/init.d/dropbear restart 2>/dev/null ;;
                rpcd)      /etc/init.d/rpcd restart 2>/dev/null ;;
                zerotier*) /etc/init.d/zerotier restart 2>/dev/null ;;
                frpc|frps) /etc/init.d/$proc_name restart 2>/dev/null ;;
            esac
            log "Process $proc_name restart attempted"
        fi
    done
}

check_nss() {
    if [ -d /sys/kernel/debug/nss ]; then
        nss_stats=$(cat /sys/kernel/debug/nss/stats 2>/dev/null | head -5)
        if echo "$nss_stats" | grep -q "NSS HANG\|firmware crash"; then
            log "NSS hang detected, reloading drivers..."
            /etc/init.d/qca-nss-drv restart 2>/dev/null || true
            /etc/init.d/qca-nss-ecm restart 2>/dev/null || true
        fi
    fi
}

check_conntrack() {
    if [ -f /proc/sys/net/netfilter/nf_conntrack_count ]; then
        count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
        max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 65535)
        if [ "$count" -gt $((max * 80 / 100)) ]; then
            log "WARNING: conntrack ${count}/${max} > 80%"
            echo 600 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || true
        fi
    fi
}

check_pppoe() {
    proto=$(uci -q get network.wan.proto 2>/dev/null || true)
    [ "$proto" != "pppoe" ] && return 0
    
    if ! pgrep -f "pppd.*wan" >/dev/null 2>&1; then
        log "PPPoE pppd dead, reconnecting..."
        ifup wan 2>/dev/null || true
        return
    fi
    
    wan_ip=$(ifconfig pppoe-wan 2>/dev/null | awk '/inet /{print $2}' | cut -d: -f2)
    if [ -z "$wan_ip" ] || [ "$wan_ip" = "0.0.0.0" ]; then
        log "PPPoE no IP, restarting wan..."
        ifdown wan 2>/dev/null || true; sleep 3
        ifup wan 2>/dev/null || true
        return
    fi
    
    gateway=$(ip route | awk '/default via/{print $3; exit}')
    if [ -n "$gateway" ]; then
        fail_count=0
        for i in 1 2 3; do
            ping -c1 -W2 "$gateway" >/dev/null 2>&1 || fail_count=$((fail_count + 1))
            sleep 1
        done
        if [ "$fail_count" -ge 3 ]; then
            log "PPPoE gateway $gateway unreachable, reconnecting..."
            ifdown wan 2>/dev/null || true; sleep 5
            ifup wan 2>/dev/null || true
            [ -x /etc/init.d/qca-nss-ecm ] && /etc/init.d/qca-nss-ecm restart 2>/dev/null || true
            [ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
        fi
    fi
    
    err_count=$(ifconfig pppoe-wan 2>/dev/null | grep -o 'errors:[0-9]*' | cut -d: -f2 || echo 0)
    if [ "$err_count" -gt 1000 ]; then
        log "PPPoE errors $err_count > 1000, resetting..."
        ifdown wan 2>/dev/null || true; sleep 3
        ifup wan 2>/dev/null || true
    fi
}

log "Guardian v3.0 started (6.12 kernel), PID=$$"
while true; do
    protect_oom
    check_memory
    check_processes
    check_nss
    check_conntrack
    check_pppoe
    sleep 300
done
GUARDIAN
chmod +x package/base-files/files/usr/bin/roc-guardian

# 守护进程 init
cat > package/base-files/files/etc/init.d/roc-guardian <<'INIT'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
NAME=roc-guardian

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/roc-guardian
    procd_set_param respawn 3600 1 3600
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall roc-guardian 2>/dev/null || true
}
INIT
chmod +x package/base-files/files/etc/init.d/roc-guardian

# WAN 热插拔恢复
cat > package/base-files/files/etc/hotplug.d/iface/99-nss-recover <<'HOTPLUG'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || [ "$INTERFACE" = "wan6" ] || exit 0

logger -t nss-recover "WAN up, recovering NSS..."
sleep 5

[ -x /etc/init.d/qca-nss-ecm ] && /etc/init.d/qca-nss-ecm restart 2>/dev/null || true
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
[ -d /sys/module/xt_FULLCONENAT ] && echo 1 >/sys/module/xt_FULLCONENAT/parameters/enable 2>/dev/null || true

proto=$(uci -q get network.wan.proto 2>/dev/null || true)
if [ "$proto" = "pppoe" ]; then
    uci set network.wan.keepalive='30 6'
    uci commit network
    ip link set pppoe-wan mtu 1492 2>/dev/null || true
fi

[ -f /tmp/resolv.conf.auto ] && /etc/init.d/dnsmasq reload 2>/dev/null || true

if pgrep zerotier-one >/dev/null 2>&1; then
    sleep 10
    /etc/init.d/zerotier restart 2>/dev/null || true
fi
HOTPLUG
chmod +x package/base-files/files/etc/hotplug.d/iface/99-nss-recover

#收尾刷新feed
green "==== Final Feed Refresh===="
for i in 1 2 3; do
    ./scripts/feeds update -a && break
    yellow "Feed update retry $i/3..."
    sleep 5
done
./scripts/feeds install -a

# .config 冲突清理
CFG=".config"
[ -f "$CFG" ] || touch "$CFG"

# 清理 6.12 不兼容项
sed -i '/^CONFIG_PACKAGE_kmod-qca-nss-ecm-nat=/d' $CFG
sed -i '/^CONFIG_PACKAGE_kmod-qca-nss-drv-cake=/d' $CFG
sed -i '/^CONFIG_PACKAGE_kmod-qca-nss-drv-wifi=/d' $CFG
sed -i '/^CONFIG_PACKAGE_kmod-qca-nss-ppe/d' $CFG
sed -i '/^CONFIG_KERNEL_ZRAM_BACKEND_LZO/d' $CFG

# 确保 6.12 关键项
grep -q "CONFIG_PACKAGE_kmod-qca-nss-drv-flow-preload=y" "$CFG" || \
    echo "CONFIG_PACKAGE_kmod-qca-nss-drv-flow-preload=y" >> "$CFG"
grep -q "CONFIG_NSS_DRV_FLOW_PRELOAD_ENABLE=y" "$CFG" || \
    echo "CONFIG_NSS_DRV_FLOW_PRELOAD_ENABLE=y" >> "$CFG"

green "==== Roc v7.0 Build Ready (Kernel 6.12) ===="
