#!/bin/bash
set -euo pipefail
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
cd "$OPENWRT_PATH"

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
    yellow "FRP clone failed, check network or repo - skipping..."
fi

#6 全量拉取所有主题+插件（全部保留不精简，带容错）
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

#8 启动优化容错
green "====8 Startup Order Optimize Enable ===="
optimize_start(){
local f="$1" s="$2"
[ ! -f "$f" ] && return 0
sed -i "s/START=.*/START=$s/" "$f"
sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$f"
}

#仅删除PPE（唯一不稳定驱动，其余NSS组件全保留）
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

#9 编译小补丁
TS=$(find feeds/packages -maxdepth3 -name tailscale/Makefile 2>/dev/null|head -1||true)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS"
RU=$(find feeds/packages -maxdepth3 -name rust/Makefile 2>/dev/null|head -1||true)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU"

#首页NSS状态栏｜自适应：内容短单行、超长自动两行
green "==== Inject NSS Status To Argon & Aurora Homepage ===="
ARGON_PATH="feeds/luci/themes/luci-theme-argon/luasrc/view/themes/argon/status.htm"
[ -f "$ARGON_PATH" ] && sed -i '/<div class="system-info">/a\<div style="margin:4px 0;color:#666;font-size:14px;word-wrap:break-word;white-space:normal">NSS:<%=luci.sys.exec("grep -o \047CPU.*HWE.*\047 /sys/kernel/debug/nss/stats")%> ECM:<%=luci.sys.exec("awk \047/tcp|udp|total/{printf $0}\047 /sys/kernel/debug/ecm/preload_stats")%></div>' "$ARGON_PATH"

AURORA_PATH="feeds/luci/themes/luci-theme-aurora/luasrc/view/themes/aurora/status.htm"
[ -f "$AURORA_PATH" ] && sed -i '/system-info/a\<div style="margin:5px 0;font-size:13px;color:#555;word-wrap:break-word;white-space:normal">NSS:<%=luci.sys.exec("grep CPU /sys/kernel/debug/nss/stats")%> ECM:<%=luci.sys.exec("awk \047/tcp|udp|total/{print $0}\047 /sys/kernel/debug/ecm/preload_stats")%></div>' "$AURORA_PATH"

#10 预埋系统配置｜全插件保留，仅优化稳定参数
mkdir -p package/base-files/files/etc/uci-defaults

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

#②内存+NSS稳定参数（性能优化版）
cat > package/base-files/files/etc/uci-defaults/90-memoptimize <<'EOF'
#!/bin/sh
# 脏页控制
echo 60 >/proc/sys/vm/swappiness
echo 10 >/proc/sys/vm/dirty_ratio
echo 5 >/proc/sys/vm/dirty_background_ratio

# 按内存自适应 min_free_kbytes
total_mem=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 524288)
if [ "$total_mem" -gt 1048576 ]; then
    echo 8192 >/proc/sys/vm/min_free_kbytes
elif [ "$total_mem" -gt 524288 ]; then
    echo 4096 >/proc/sys/vm/min_free_kbytes
else
    echo 2048 >/proc/sys/vm/min_free_kbytes
fi

# TCP Fast Open + 连接跟踪早期卸载
grep -q "tcp_fastopen" /etc/sysctl.conf || echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
grep -q "nf_conntrack_early_offload" /etc/sysctl.conf || echo "net.netfilter.nf_conntrack_early_offload=1" >> /etc/sysctl.conf

# BBR 拥塞控制（内核支持时自动生效）
grep -q "tcp_congestion_control" /etc/sysctl.conf || {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
}

# NSS 稳速参数
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable
[ -d /sys/module/qca_nss_drv/parameters ] && echo 5 >/sys/module/qca_nss_drv/parameters/pbuf_high_watermark

# 定时缓存回收（每6小时释放pagecache，不释放dentry/inode）
grep -q drop_caches /etc/crontabs/root || echo "0 */6 * * * sync;echo 1 >/proc/sys/vm/drop_caches" >> /etc/crontabs/root
/etc/init.d/cron enable
EOF
chmod +x package/base-files/files/etc/uci-defaults/90-memoptimize

#③ECM连接数改为标准65535，兼顾满载稳定不溢出
cat > package/base-files/files/etc/uci-defaults/93-nss-ecm <<'EOF'
#!/bin/sh
uci -q get ecm.@global[0] >/dev/null || uci add ecm global
uci set ecm.@global[0].acceleration_engine='nss'
uci set ecm.@global[0].preload_mode='full'
uci set ecm.@global[0].conn_limit='65535'
uci commit ecm
EOF
chmod +x package/base-files/files/etc/uci-defaults/93-nss-ecm

#④防火墙+ZT原生配置（全量匹配精确清理版）
cat > package/base-files/files/etc/uci-defaults/92-fix-all <<'EOF'
#!/bin/sh
# fstab 初始化
if ! uci -q get fstab.@global[0] >/dev/null; then
    uci add fstab global
fi
uci set fstab.@global[0].extroot='0'
uci commit fstab

# OAF 默认关闭
if ! uci -q get oaf.@global[0] >/dev/null; then
    uci add oaf global
fi
uci set oaf.@global[0].enable='0'
uci commit oaf

# hostapd 目录修复
sed -i '/mkdir -p \/var\/run\/hostapd/d' /etc/init.d/wireless
sed -i 's/start_service() {/start_service() {\nmkdir -p \/var\/run\/hostapd\nchmod 777 \/var\/run\/hostapd/' /etc/init.d/wireless

# FullCone NAT
uci set firewall.@defaults[0].fullcone='1'

# === 精确清理已存在的 zerotier 配置 ===
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

# === 重建 zerotier 配置 ===
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

# ZT MTU 优化（幂等保护）
grep -q "ZTIF=" /etc/rc.local || echo 'sleep 8;ZTIF=$(ip link|grep zt|awk "{print \$2}"|sed s/://);[ -n "$ZTIF" ]&&ip link set $ZTIF mtu 1400' >> /etc/rc.local
/etc/init.d/zerotier enable

exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/92-fix-all

#⑤ OOM 调优 + 内核参数
cat > package/base-files/files/etc/uci-defaults/91-oom-tune <<'EOF'
#!/bin/sh
grep -q "vm.panic_on_oom" /etc/sysctl.conf || echo "vm.panic_on_oom=0" >> /etc/sysctl.conf
grep -q "vm.oom_kill_allocating_task" /etc/sysctl.conf || echo "vm.oom_kill_allocating_task=0" >> /etc/sysctl.conf
grep -q "kernel.panic_on_oops" /etc/sysctl.conf || echo "kernel.panic_on_oops=10" >> /etc/sysctl.conf
[ -w /sys/kernel/debug/kmemleak ] && echo "scan=0" > /sys/kernel/debug/kmemleak 2>/dev/null || true
EOF
chmod +x package/base-files/files/etc/uci-defaults/91-oom-tune

#⑥ Zram 防泄漏参数
cat > package/base-files/files/etc/uci-defaults/94-zram-tune <<'EOF'
#!/bin/sh
if [ -d /sys/block/zram0 ]; then
    echo 4 > /sys/block/zram0/max_comp_streams 2>/dev/null || true
    echo 40 > /proc/sys/vm/swappiness 2>/dev/null || true
fi
EOF
chmod +x package/base-files/files/etc/uci-defaults/94-zram-tune

#11 长期运行守护｜防内存泄漏 + 关键服务自动恢复
green "====11 Long-Run Guardian ===="
mkdir -p package/base-files/files/etc/hotplug.d/iface
mkdir -p package/base-files/files/usr/bin

#① 守护进程主程序
cat > package/base-files/files/usr/bin/roc-guardian <<'GUARDIAN'
#!/bin/sh
# Roc Guardian v1.0 - 长期运行守护
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
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        /etc/init.d/uhttpd restart 2>/dev/null || true
        /etc/init.d/rpcd restart 2>/dev/null || true
    elif [ "$mem_used" -gt "$MEM_THRESHOLD" ]; then
        log "WARNING: memory ${mem_used}%, releasing pagecache"
        sync
        echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
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

check_proc_count() {
    count=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
    [ "$count" -gt "$PROC_THRESHOLD" ] && log "WARNING: process count $count > $PROC_THRESHOLD"
}

log "Guardian started, PID=$$"
while true; do
    protect_oom
    check_memory
    check_processes
    check_nss
    check_conntrack
    check_proc_count
    sleep 300
done
GUARDIAN
chmod +x package/base-files/files/usr/bin/roc-guardian

#② 守护进程 init 脚本
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

#③ WAN重连NSS加速恢复
cat > package/base-files/files/etc/hotplug.d/iface/99-nss-recover <<'HOTPLUG'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || [ "$INTERFACE" = "wan6" ] || exit 0

logger -t nss-recover "WAN up, recovering NSS acceleration..."
sleep 3

[ -x /etc/init.d/qca-nss-ecm ] && /etc/init.d/qca-nss-ecm restart 2>/dev/null || true
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable 2>/dev/null || true
[ -d /sys/module/xt_FULLCONENAT ] && echo 1 >/sys/module/xt_FULLCONENAT/parameters/enable 2>/dev/null || true
HOTPLUG
chmod +x package/base-files/files/etc/hotplug.d/iface/99-nss-recover

#收尾刷新feed（带重试）
green "==== Final Feed Refresh ===="
for i in 1 2 3; do
    ./scripts/feeds update -a && break
    yellow "Feed update retry $i/3..."
    sleep 5
done
./scripts/feeds install -a
green "==== Prebuild All Done ===="

#NSS配置全保留原有硬件加速项，仅关闭4个高危模块，其余全开启
CFG=".config"
[ -f "$CFG" ] || touch "$CFG"

sed -i '/CONFIG_PACKAGE_kmod-qca-nss-ecm-nat/d' $CFG
sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-cake/d' $CFG
sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi/d' $CFG
sed -i '/CONFIG_PACKAGE_kmod-qca-nss-ppe/d' $CFG

cat >>$CFG <<'NSS_ALL_CONF'
CONFIG_NSS_MEM_PROFILE_MEDIUM=y
CONFIG_PACKAGE_kmod-qca-nss-drv-fullcone=y
CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe-tap=y
CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe-relay=y
CONFIG_PACKAGE_kmod-qca-nss-drv-tun=y
CONFIG_PACKAGE_kmod-qca-nss-drv-gre=y
CONFIG_PACKAGE_kmod-qca-nss-drv-ipsec=y
CONFIG_PACKAGE_kmod-qca-nss-drv-udp-lite=y
CONFIG_PACKAGE_kmod-qca-nss-drv-vlan=y
CONFIG_PACKAGE_kmod-qca-nss-drv-policer=y
CONFIG_PACKAGE_kmod-qca-nss-drv-qdisc=y

CONFIG_PACKAGE_kmod-qca-nss-drv-flow-preload=y
CONFIG_NSS_DRV_FLOW_PRELOAD_ENABLE=y
CONFIG_NSS_DRV_FLOW_CACHE=y
CONFIG_NSS_ECM_PRELOAD_CONN=y
CONFIG_NSS_ECM_FLOW_CACHE=y
CONFIG_PACKAGE_kmod-qca-nss-drv-reassemble=y
CONFIG_NSS_DRV_REASSEMBLE_ENABLE=y

CONFIG_PACKAGE_nssinfo=y
CONFIG_PACKAGE_nssstats=y
CONFIG_PACKAGE_luci-app-nssinfo=y
CONFIG_PACKAGE_luci-i18n-nssinfo-zh-cn=y

CONFIG_KERNEL_NF_FLOW_OFFLOAD=y
CONFIG_PACKAGE_kmod-nft-flow=y
CONFIG_KERNEL_NF_CONNTRACK_MARK=y
CONFIG_KERNEL_NF_CONNTRACK_ZONES=y
CONFIG_KERNEL_NF_CONNTRACK_EARLY_OFFLOAD=y
NSS_ALL_CONF

green "==== 全插件保留+稳速优化完成 ===="
