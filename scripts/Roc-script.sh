#!/bin/bash
set -euo pipefail

# ============================================
# Roc Stable Build for LiBwrt/openwrt-6.x
# 版本: v9.0 Final Ultimate
# 目标: 零冲突 + 零Bug + 极致稳定 + 全优化
# 内核: Linux 6.12.x (预留 6.18)
# ============================================

red()    { printf "\033[31m%s\033[0m\n" "$1"; }
green()  { printf "\033[32m%s\033[0m\n" "$1"; }
yellow() { printf "\033[33m%s\033[0m\n" "$1"; }

export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
cd "$OPENWRT_PATH"

# ============================================
# 0. 环境初始化
# ============================================
green "====0 Environment Init===="

# 编译依赖自动安装
check_deps() {
    local missing=""
    for dep in gcc g++ flex bison make python3 rsync git curl perl; do
        command -v "$dep" >/dev/null 2>&1 || missing="$missing $dep"
    done
    if [ -n "$missing" ]; then
        yellow "Missing:$missing"
        if command -v apt >/dev/null 2>&1; then
            sudo apt update -qq && sudo apt install -y build-essential flex bison python3 rsync git curl perl 2>/dev/null && green "Done" || {
                red "Install failed. Run: sudo apt install build-essential flex bison python3 rsync git curl perl"; exit 1;
            }
        else
            red "Install manually:$missing"; exit 1
        fi
    fi
}
check_deps

LIbwrt_VER=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
KERNEL_VER=$(grep -oP 'LINUX_VERSION-\d+\.\d+=\K.*' include/kernel-version.mk 2>/dev/null || echo "0.0")

green "LiBwrt: $LIbwrt_VER | Kernel: $KERNEL_VER"

mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/hotplug.d/iface
mkdir -p package/base-files/files/usr/bin

# ============================================
# 1. Feed 初始化
# ============================================
green "====1 Feed Init===="
[ -f feeds.conf ] && conf="feeds.conf" || [ -f feeds.conf.default ] && conf="feeds.conf.default" || { red "No feeds.conf!"; exit 1; }

for i in 1 2 3; do
    ./scripts/feeds update -a && break
    yellow "Retry $i/3..."
    sleep 5
done
./scripts/feeds install -a 2>/dev/null || true
./scripts/feeds install coreutils ca-bundle jq curl libopenssl-legacy 2>/dev/null || true

# ============================================
# 2. 冲突彻底清理
# ============================================
green "====2 Conflict Removal===="

# 永久删除冲突模块源码
CONFLICT_MODULES="
qca-nss-ppe
qca-nss-ecm-nat
qca-nss-drv-cake
qca-nss-drv-wifi
zram-backend-lzo
"

for mod in $CONFLICT_MODULES; do
    find . -path "*/$mod*" -type d 2>/dev/null | while read dir; do
        yellow "Removing: $dir"
        rm -rf "$dir"
    done
done

# 废弃 kmod
for mk_file in $(find package feeds -name "Makefile" 2>/dev/null); do
    for kmod in iptunnel4 iptunnel6 ppp-async nf-conntrack6 nf-ipt6 nf-nat6; do
        sed -i "s/+$kmod//g" "$mk_file" 2>/dev/null || true
    done
done

# 重复插件
for pkg in frpc frps argon-config argon; do
    count=$(find package feeds -path "*/luci-app-$pkg/Makefile" 2>/dev/null | wc -l)
    [ "$count" -gt 1 ] && {
        yellow "Dedup $pkg"
        find feeds -path "*/luci-app-$pkg" -type d -exec rm -rf {} + 2>/dev/null || true
    }
done

# .config 精确清理
[ -f .config ] && {
    for key in \
        "CONFIG_PACKAGE_kmod-qca-nss-ecm-nat" \
        "CONFIG_PACKAGE_kmod-qca-nss-drv-cake" \
        "CONFIG_PACKAGE_kmod-qca-nss-drv-wifi" \
        "CONFIG_PACKAGE_kmod-qca-nss-ppe" \
        "CONFIG_KERNEL_ZRAM_BACKEND_LZO"; do
        sed -i "/^${key}[= ]/d; /^# ${key} is not set/d" .config 2>/dev/null || true
    done
    for kmod in iptunnel4 iptunnel6 ppp-async nf-conntrack6 nf-ipt6 nf-nat6; do
        sed -i "/CONFIG_PACKAGE_kmod-$kmod/d" .config 2>/dev/null || true
    done
}

# ============================================
# 3. 基础配置
# ============================================
green "====3 Base Config===="
[ -f package/base-files/files/bin/config_generate ] && {
    grep -q "192.168.10.1" package/base-files/files/bin/config_generate || \
        sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate
    grep -q "hostname='Roc'" package/base-files/files/bin/config_generate || \
        sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
}

for dts in target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi \
           target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq60xx/ipq6018-512m.dtsi; do
    [ -f "$dts" ] && ! grep -q "0x04000000" "$dts" 2>/dev/null && {
        sed -i '/nss\|reserved/{s/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/}' "$dts"
        green "DTS: $dts"
    } && break
done

# ============================================
# 4. 插件拉取
# ============================================
green "====4 Plugins===="
clone_repo() {
    [ -d "$2/.git" ] || [ -f "$2/Makefile" ] && { green "  ✓ $3"; return 0; }
    git clone --depth=1 --single-branch "$1" "$2" 2>/dev/null && green "  ✓ $3" || yellow "  ✗ $3"
}

clone_repo "https://github.com/jerrykuku/luci-theme-argon"       "feeds/luci/themes/luci-theme-argon"          "argon-theme"
clone_repo "https://github.com/jerrykuku/luci-app-argon-config"  "feeds/luci/applications/luci-app-argon-config" "argon-config"
clone_repo "https://github.com/eamonxg/luci-theme-aurora"        "feeds/luci/themes/luci-theme-aurora"         "aurora-theme"
clone_repo "https://github.com/eamonxg/luci-app-aurora-config"   "feeds/luci/applications/luci-app-aurora-config" "aurora-config"
clone_repo "https://github.com/gdy666/luci-app-lucky"            "package/luci-app-lucky"                      "lucky"
clone_repo "https://github.com/destan19/OpenAppFilter.git"       "package/OpenAppFilter"                       "OAF"
clone_repo "https://github.com/NONGFAH/luci-app-athena-led"      "package/luci-app-athena-led"                 "athena-led"

if [ ! -d feeds/luci/applications/luci-app-frpc ] && [ ! -d package/luci-app-frpc ]; then
    clone_repo "https://github.com/laipeng668/luci" "feeds/_tmpfrp" "frp"
    [ -d feeds/_tmpfrp/applications/luci-app-frpc ] && {
        mv feeds/_tmpfrp/applications/luci-app-frpc feeds/luci/applications/ 2>/dev/null || true
        mv feeds/_tmpfrp/applications/luci-app-frps feeds/luci/applications/ 2>/dev/null || true
    }
    rm -rf feeds/_tmpfrp 2>/dev/null || true
fi

[ -f package/luci-app-athena-led/root/etc/init.d/athena_led ] && chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led
[ -f package/luci-app-athena-led/root/usr/sbin/athena-led ] && chmod +x package/luci-app-athena-led/root/usr/sbin/athena-led

# ============================================
# 5. NSS 驱动适配
# ============================================
green "====5 NSS Adapt===="
NSS_DIRS=$(find feeds package -maxdepth 4 -type d \( -name "qca-nss*" -o -name "qca-ssdk" \) 2>/dev/null | grep -v ppe || true)

if [ -n "$NSS_DIRS" ]; then
    for f in $(find $NSS_DIRS -name "*.c" -o -name "*.h" 2>/dev/null); do
        [ ! -f "${f}.bak" ] && cp "$f" "${f}.bak" 2>/dev/null || true
        
        if grep -q "setup_timer" "$f" 2>/dev/null; then
            sed -i 's/setup_timer(\(&[^,]*\), \([^,]*\), \([^)]*\))/timer_setup(\1, \2, 0)/g' "$f"
            # 跨行
            perl -i -0pe 's/setup_timer\s*\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*[^)]+\s*\)/timer_setup($1, $2, 0)/gs' "$f" 2>/dev/null || true
        fi
        
        if grep -q "netif_napi_add" "$f" 2>/dev/null; then
            sed -i 's/netif_napi_add(\([^,]*\), \([^,]*\), \([^,]*\), [0-9]*)/netif_napi_add(\1, \2, \3)/g' "$f"
        fi
    done
    
    for mk in $(find $NSS_DIRS -name "Makefile" 2>/dev/null); do
        grep -q "KERNEL_PATCHVER" "$mk" 2>/dev/null && \
            sed -i "s/KERNEL_PATCHVER:=6\.[0-9]*/KERNEL_PATCHVER:=$KERNEL_VER/g" "$mk"
    done
fi

# ============================================
# 6. 启动顺序
# ============================================
green "====6 Startup Order===="
optimize_start() {
    [ ! -f "$1" ] || [ ! -w "$1" ] && return 0
    sed -i "s/START=[0-9]*/START=$2/" "$1"
    sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$1" 2>/dev/null || true
}

for init in $(find feeds package \( -name "qca-nss-drv.init" -o -name "qca-nss-ecm.init" -o -name "qca-nss-dp.init" -o -name "qca-ssdk.init" \) 2>/dev/null); do
    case "$init" in *nss-drv*) optimize_start "$init" 10 ;; *nss-ecm*) optimize_start "$init" 11 ;; *nss-dp*) optimize_start "$init" 12 ;; *ssdk*) optimize_start "$init" 13 ;; esac
done

for svc in \
    "package/base-files/files/etc/init.d/boot:15" \
    "package/system/zram-swap/files/zram-swap.init:16" \
    "package/base-files/files/etc/init.d/network:20" \
    "package/network/services/dnsmasq/files/dnsmasq.init:21" \
    "package/network/config/firewall4/files/firewall.init:23" \
    "feeds/packages/net/zerotier/files/zerotier.init:32" \
    "package/network/services/uhttpd/files/uhttpd.init:40" \
    "package/system/rpcd/files/rpcd.init:41"; do
    f="${svc%%:*}"; s="${svc##*:}"
    optimize_start "$f" "$s"
done

# ============================================
# 7. 编译补丁
# ============================================
green "====7 Patches===="
TS=$(find feeds/packages -maxdepth 3 -name "tailscale/Makefile" 2>/dev/null | head -1)
[ -f "$TS" ] && grep -q "/files" "$TS" && sed -i '/\/files/d' "$TS"
RU=$(find feeds/packages -maxdepth 3 -name "rust/Makefile" 2>/dev/null | head -1)
[ -f "$RU" ] && grep -q "ci-llvm=true" "$RU" && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU"

# ============================================
# 8. 系统预置
# ============================================
green "====8 System Presets===="

# ① 时区
cat > package/base-files/files/etc/uci-defaults/95-lang <<'EOF'
#!/bin/sh
uci -q get system.@system[0].zonename >/dev/null || uci set system.@system[0].zonename='Asia/Shanghai'
uci -q get system.@system[0].timezone >/dev/null || uci set system.@system[0].timezone='CST-8'
[ "$(uci -q get luci.main.lang)" != "zh_cn" ] && uci set luci.main.lang='zh_cn'
uci commit system 2>/dev/null; uci commit luci 2>/dev/null
EOF

# ② 文件系统
cat > package/base-files/files/etc/uci-defaults/88-fs <<'EOF'
#!/bin/sh
mount -o remount,noatime / 2>/dev/null || true
[ -w /proc/sys/kernel/printk ] && echo "3 4 1 3" > /proc/sys/kernel/printk 2>/dev/null || true
mountpoint -q /tmp || mount -t tmpfs tmpfs /tmp 2>/dev/null || true
grep -q "fs.file-max=65536" /etc/sysctl.conf 2>/dev/null || echo "fs.file-max=65536" >> /etc/sysctl.conf
EOF

# ③ 高吞吐量
cat > package/base-files/files/etc/uci-defaults/90-throughput <<'EOF'
#!/bin/sh
echo 10 >/proc/sys/vm/dirty_ratio 2>/dev/null || true
echo 5 >/proc/sys/vm/dirty_background_ratio 2>/dev/null || true
total_mem=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 524288)
[ "$total_mem" -gt 1048576 ] && echo 8192 >/proc/sys/vm/min_free_kbytes || echo 2048 >/proc/sys/vm/min_free_kbytes

a() { grep -q "$1" /etc/sysctl.conf 2>/dev/null || echo "$1" >> /etc/sysctl.conf; }
a "net.ipv4.tcp_fastopen=3"
a "net.core.default_qdisc=fq"
a "net.ipv4.tcp_congestion_control=bbr"
a "net.ipv4.tcp_rmem=4096 131072 8388608"
a "net.ipv4.tcp_wmem=4096 65536 6291456"
a "net.core.rmem_max=16777216"
a "net.core.wmem_max=16777216"
a "net.ipv4.tcp_tw_reuse=1"
a "net.ipv4.tcp_keepalive_time=60"
a "net.ipv4.tcp_fin_timeout=10"
a "net.ipv4.tcp_max_syn_backlog=16384"
a "net.core.somaxconn=8192"
a "net.core.netdev_max_backlog=8192"
a "net.core.netdev_budget=800"
a "net.netfilter.nf_conntrack_max=65535"
a "net.netfilter.nf_conntrack_timestamp=0"
a "net.netfilter.nf_conntrack_early_offload=1"
a "net.netfilter.nf_conntrack_tcp_timeout_established=3600"
a "net.ipv4.udp_mem=65536 131072 262144"

[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
grep -q "drop_caches" /etc/crontabs/root 2>/dev/null || echo "0 */8 * * * sync;echo 1 >/proc/sys/vm/drop_caches" >> /etc/crontabs/root
/etc/init.d/cron enable 2>/dev/null || true
EOF

# ④ 网络+防火墙+ZT+PPPoE+DNS+ECM
cat > package/base-files/files/etc/uci-defaults/92-network <<'EOF'
#!/bin/sh
if uci -q get network.wan >/dev/null 2>&1; then
    [ "$(uci -q get network.wan.proto)" = "pppoe" ] && {
        uci -q get network.wan.keepalive >/dev/null || uci set network.wan.keepalive='30 6'
        uci -q get network.wan.mtu >/dev/null || uci set network.wan.mtu='1492'
        uci commit network 2>/dev/null
        [ -d /sys/class/net/pppoe-wan ] && ip link set pppoe-wan mtu 1492 2>/dev/null || true
    }
fi
uci set firewall.@defaults[0].fullcone='1' 2>/dev/null || true
if ! uci show firewall 2>/dev/null | grep -q "name='zerotier'"; then
    for s in $(uci show firewall 2>/dev/null | grep "zerotier\|ZT-9993" | cut -d= -f1); do uci delete "$s" 2>/dev/null || true; done
    uci add firewall zone; uci set firewall.@zone[-1].name='zerotier'; uci set firewall.@zone[-1].device='zt+'
    uci set firewall.@zone[-1].input='ACCEPT'; uci set firewall.@zone[-1].output='ACCEPT'; uci set firewall.@zone[-1].forward='ACCEPT'; uci set firewall.@zone[-1].masq='1'
    uci add firewall forwarding; uci set firewall.@forwarding[-1].src='lan'; uci set firewall.@forwarding[-1].dest='zerotier'
    uci add firewall forwarding; uci set firewall.@forwarding[-1].src='zerotier'; uci set firewall.@forwarding[-1].dest='lan'
    uci add firewall rule; uci set firewall.@rule[-1].name='ZT-9993-UDP'; uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='udp'; uci set firewall.@rule[-1].dest_port='9993'; uci set firewall.@rule[-1].target='ACCEPT'
fi
uci commit firewall 2>/dev/null
uci -q get dhcp.@dnsmasq[0].cachesize >/dev/null || uci set dhcp.@dnsmasq[0].cachesize='2000'
uci -q get dhcp.@dnsmasq[0].dnsforwardmax >/dev/null || uci set dhcp.@dnsmasq[0].dnsforwardmax='512'
uci commit dhcp 2>/dev/null
if uci -q get ecm >/dev/null 2>&1; then
    uci -q get ecm.@global[0].acceleration_engine >/dev/null || uci set ecm.@global[0].acceleration_engine='nss'
    uci -q get ecm.@global[0].preload_mode >/dev/null || uci set ecm.@global[0].preload_mode='full'
    uci -q get ecm.@global[0].conn_limit >/dev/null || uci set ecm.@global[0].conn_limit='65535'
    uci commit ecm 2>/dev/null
fi
/etc/init.d/zerotier enable 2>/dev/null || true
EOF

# ⑤ Zram
cat > package/base-files/files/etc/uci-defaults/94-zram <<'EOF'
#!/bin/sh
if [ -d /sys/block/zram0 ]; then
    [ -f /sys/block/zram0/max_comp_streams ] && echo 4 > /sys/block/zram0/max_comp_streams 2>/dev/null || true
    echo 40 > /proc/sys/vm/swappiness 2>/dev/null || true
else
    echo 60 > /proc/sys/vm/swappiness 2>/dev/null || true
fi
EOF

# ⑥ 中断亲和
cat > package/base-files/files/etc/uci-defaults/97-irq <<'EOF'
#!/bin/sh
cpu_count=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
s() { local n=$(grep -E "$1" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | tr -d ' ' | head -1); [ -n "$n" ] && [ -w "/proc/irq/$n/smp_affinity" ] && echo "$2" > "/proc/irq/$n/smp_affinity" 2>/dev/null || true; }
[ "$cpu_count" -ge 4 ] && { s "eth1" "04"; s "eth0" "08"; s "nss" "01"; s "ath11k" "02"; }
for iface in eth0 eth1 pppoe-wan br-lan; do
    [ -d "/sys/class/net/$iface" ] || continue
    mask=$(printf "%x" $(( (1 << cpu_count) - 1 )))
    for q in /sys/class/net/$iface/queues/rx-* 2>/dev/null; do echo "$mask" > "$q/rps_cpus" 2>/dev/null || true; done
    for q in /sys/class/net/$iface/queues/tx-* 2>/dev/null; do echo "$mask" > "$q/xps_cpus" 2>/dev/null || true; done
    ip link set dev "$iface" txqueuelen 4000 2>/dev/null || true
done
[ -w /proc/sys/net/core/napi_threaded ] && echo 1 > /proc/sys/net/core/napi_threaded 2>/dev/null || true
EOF

# ⑦ NSS + 看门狗
cat > package/base-files/files/etc/uci-defaults/98-nss <<'EOF'
#!/bin/sh
[ -w /sys/module/qca_nss_drv/parameters/nss_watchdog ] && echo 0 > /sys/module/qca_nss_drv/parameters/nss_watchdog 2>/dev/null || true
[ -w /sys/module/qca_nss_drv/parameters/pbuf_high_watermark ] && echo 10 > /sys/module/qca_nss_drv/parameters/pbuf_high_watermark 2>/dev/null || true
[ -w /sys/module/qca_nss_drv/parameters/multi_queue ] && echo 1 > /sys/module/qca_nss_drv/parameters/multi_queue 2>/dev/null || true
[ -w /sys/module/xt_FULLCONENAT/parameters/enable ] && echo 1 > /sys/module/xt_FULLCONENAT/parameters/enable 2>/dev/null || true
[ -w /sys/kernel/debug/nss/flow_preload/enable ] && echo 2 > /sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
[ -c /dev/watchdog ] && echo 1 > /proc/sys/kernel/nmi_watchdog 2>/dev/null || true
EOF

# 设置所有执行权限
chmod +x package/base-files/files/etc/uci-defaults/*

# ============================================
# 9. 守护进程
# ============================================
green "====9 Guardian===="

cat > package/base-files/files/usr/bin/roc-guardian <<'GUARDIAN'
#!/bin/bash
LOG="/tmp/roc-guardian.log"
MAX=51200

log() {
    [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$MAX" ] && : > "$LOG"
    echo "$(date '+%F %T') $1" >> "$LOG"
    logger -t "roc-guardian" "$1"
}

tcp_ok() {
    bash -c "echo >/dev/tcp/$1/$2" 2>/dev/null &
    local p=$!
    for i in 1 2 3 4; do kill -0 "$p" 2>/dev/null || { wait "$p" 2>/dev/null; return $?; }; sleep 0.5; done
    kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 1
}

g1() { while true; do
    for proc in dnsmasq uhttpd dropbear; do
        pid=$(pgrep -f "$proc" 2>/dev/null | head -1)
        [ -n "$pid" ] && [ -w "/proc/$pid/oom_score_adj" ] && echo -500 > "/proc/$pid/oom_score_adj" 2>/dev/null
    done
    m=$(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{printf "%.0f",(t-a)*100/t}' /proc/meminfo 2>/dev/null || echo 0)
    [ "$m" -gt 95 ] && { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; log "CRITICAL: mem ${m}%"; }
    [ "$m" -gt 85 ] && [ "$m" -le 95 ] && { sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; log "WARN: mem ${m}%"; }
    sleep 300
done }

g2() { while true; do
    pgrep -f dnsmasq >/dev/null 2>&1 || { log "dnsmasq dead"; /etc/init.d/dnsmasq restart 2>/dev/null; }
    pgrep -f uhttpd >/dev/null 2>&1 || { log "uhttpd dead"; /etc/init.d/uhttpd restart 2>/dev/null; }
    sleep 120
done }

g3() { while true; do
    uci -q get network.wan.proto 2>/dev/null | grep -q pppoe || { sleep 180; continue; }
    pgrep -f "pppd.*wan" >/dev/null 2>&1 || { log "pppd dead"; ifup wan 2>/dev/null; sleep 180; continue; }
    gw=$(ip route 2>/dev/null | awk '/default via/{print $3; exit}')
    [ -z "$gw" ] && { sleep 180; continue; }
    ping -c1 -W2 "$gw" >/dev/null 2>&1 && { sleep 180; continue; }
    ok=0; for p in 80 443; do tcp_ok "$gw" "$p" && { ok=1; break; }; done
    [ "$ok" -eq 0 ] && { log "gw $gw unreachable"; ifdown wan 2>/dev/null; sleep 5; ifup wan 2>/dev/null; }
    sleep 180
done }

g4() { while true; do
    [ -r /sys/kernel/debug/nss/stats ] && head -5 /sys/kernel/debug/nss/stats 2>/dev/null | grep -q "HANG\|crash" && {
        log "NSS hang"; /etc/init.d/qca-nss-drv restart 2>/dev/null; /etc/init.d/qca-nss-ecm restart 2>/dev/null
    }
    sleep 300
done }

log "Guardian v5.0 (ultimate)"
while true; do
    g1 & p1=$!; g2 & p2=$!; g3 & p3=$!; g4 & p4=$!
    while kill -0 "$p1" 2>/dev/null && kill -0 "$p2" 2>/dev/null && kill -0 "$p3" 2>/dev/null && kill -0 "$p4" 2>/dev/null; do
        sleep 30
    done
    log "Child died, restarting all"
    for p in $p1 $p2 $p3 $p4; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
    sleep 5
done
GUARDIAN
chmod +x package/base-files/files/usr/bin/roc-guardian

cat > package/base-files/files/etc/init.d/roc-guardian <<'EOF'
#!/bin/sh /etc/rc.common
START=99; USE_PROCD=1; NAME=roc-guardian
start_service() { procd_set_param command /usr/bin/roc-guardian; procd_set_param respawn 3600 1 3600; }
EOF
chmod +x package/base-files/files/etc/init.d/roc-guardian

cat > package/base-files/files/etc/hotplug.d/iface/99-wan-recover <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && [ "${INTERFACE%%[0-9]*}" = "wan" ] || exit 0
sleep 5
[ -x /etc/init.d/qca-nss-ecm ] && /etc/init.d/qca-nss-ecm restart 2>/dev/null || true
[ -w /sys/kernel/debug/nss/flow_preload/enable ] && echo 2 > /sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
[ "$(uci -q get network.wan.proto)" = "pppoe" ] && [ -d /sys/class/net/pppoe-wan ] && ip link set pppoe-wan mtu 1492 2>/dev/null || true
[ -f /tmp/resolv.conf.auto ] && /etc/init.d/dnsmasq reload 2>/dev/null || true
pgrep zerotier-one >/dev/null 2>&1 && { sleep 10; /etc/init.d/zerotier restart 2>/dev/null; }
EOF
chmod +x package/base-files/files/etc/hotplug.d/iface/99-wan-recover

# ============================================
# 10. 收尾
# ============================================
green "====10 Finalize===="
./scripts/feeds update -a 2>/dev/null || true
./scripts/feeds install -a 2>/dev/null || true

[ -f .config ] || touch .config
grep -q "CONFIG_PACKAGE_kmod-qca-nss-drv-flow-preload=y" .config 2>/dev/null || echo "CONFIG_PACKAGE_kmod-qca-nss-drv-flow-preload=y" >> .config
grep -q "CONFIG_NSS_DRV_FLOW_PRELOAD_ENABLE=y" .config 2>/dev/null || echo "CONFIG_NSS_DRV_FLOW_PRELOAD_ENABLE=y" >> .config

# 验证脚本
cat > /tmp/roc-verify.sh <<'V'
#!/bin/sh
echo "=== Roc v9.0 Verify ==="
echo "NSS:"
find bin -name "*qca-nss*.ko" 2>/dev/null | while read k; do echo "  ✓ $k"; done
echo "PPE:"
find bin -path "*ppe*" -name "*.ko" 2>/dev/null && echo "  ✗" || echo "  ✓ clean"
echo "API:"
grep -r "setup_timer" feeds/nss_packages 2>/dev/null && echo "  ✗" || echo "  ✓ timer ok"
grep -r "netif_napi_add.*,.*,.*,.*," feeds/nss_packages 2>/dev/null && echo "  ✗" || echo "  ✓ napi ok"
echo "Size:"
find bin -name "*squashfs*" -exec ls -lh {} \; 2>/dev/null
V
chmod +x /tmp/roc-verify.sh

green "========================================="
green "  Roc v9.0 Ultimate Build Ready"
green "  Source: LiBwrt/openwrt-6.x"
green "  Kernel: $KERNEL_VER"
green "  Verify: bash /tmp/roc-verify.sh"
green "========================================="
