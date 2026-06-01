#!/bin/bash
set -euo pipefail
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
cd "$OPENWRT_PATH"

PKG_LIST=(argon-config frpc frps argon)

#1 feed更新
green "====1 Feed Update===="
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install coreutils ca-bundle jq curl libopenssl-legacy

#2 LAN 192.168.10.1 hostname=Roc
green "====2 Modify LAN&Hostname===="
[ -f package/base-files/files/bin/config_generate ] && {
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
}

#3 NSS DTS 固定64MB专属预留内存（硬件级冗余）
green "====3 NSS DDR 64M Reserve===="
DTS_FILE=""
for path in target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/{ipq6018-512m.dtsi,ipq60xx/ipq6018-512m.dtsi};do
[ -f "$path" ] && DTS_FILE="$path" && break
done
[ -n "$DTS_FILE" ] && sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' "$DTS_FILE"

#4 清理旧源码
green "====4 Clean Old Feed Source===="
rm -rf feeds/luci/applications/luci-app-{argon-config,frpc,frps} feeds/luci/themes/luci-theme-argon
for NAME in "${PKG_LIST[@]}";do
DIRS=$(find feeds/luci feeds/packages -maxdepth 3 -iname "*$NAME*" 2>/dev/null||true)
[ -n "$DIRS" ] && rm -rf $DIRS
done

#5 拉FRP
green "====5 Pull FRP===="
git clone --depth=1 https://github.com/laipeng668/luci feeds/_tmpfrp
mv feeds/_tmpfrp/applications/luci-app-frpc feeds/luci/applications/
mv feeds/_tmpfrp/applications/luci-app-frps feeds/luci/applications/
rm -rf feeds/_tmpfrp

#6 拉主题+lucky+OAF+led
green "====6 Pull Theme & Plugins===="
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon feeds/luci/themes/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config feeds/luci/applications/luci-app-argon-config
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora feeds/luci/themes/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config feeds/luci/applications/luci-app-aurora-config

git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/luci-app-lucky
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
git clone --depth=1 https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led

LED_INIT="package/luci-app-athena-led/root/etc/init.d/athena_led"
LED_BIN="package/luci-app-athena-led/root/usr/sbin/athena-led"
[ -f "$LED_INIT" ] && chmod +x "$LED_INIT"
[ -f "$LED_BIN" ] && chmod +x "$LED_BIN"

#7 跳过代理源码
green "====7 Skip All Proxy Source===="

#8 【启用启动时序优化｜NSS优先启动+删除PPE根治冲突】
green "====8 Startup Order Optimize Enable ===="
optimize_start(){
local f="$1" s="$2"
[ -f "$f" ] && {
sed -i "s/START=.*/START=$s/" "$f"
sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$f"
}
}
#永久删除PPE目录，根除PPE与NSS冲突
if [ -d feeds/nss_packages ];then
[ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe
#NSS硬件驱动优先启动(10~13，网络栈之前初始化)
optimize_start feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init 10
optimize_start feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init 11
optimize_start feeds/nss_packages/qca-nss-dp/files/qca-nss-dp.init 12
optimize_start feeds/nss_packages/qca-ssdk/files/qca-ssdk.init 13
fi
#系统服务逐级顺延
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

#10 预埋默认配置
mkdir -p package/base-files/files/etc/uci-defaults

#①时区+中文
cat > package/base-files/files/etc/uci-defaults/95-set-lang <<'EOF'
#!/bin/sh
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci set luci.main.lang='zh_cn'
uci set luci.main.autolang='0'
uci commit system
uci commit luci
echo "export LANG=zh_CN.UTF-8" >> /etc/profile
EOF
chmod +x package/base-files/files/etc/uci-defaults/95-set-lang

#②内存优化+NSS预加载sysctl参数+定时缓存回收
cat > package/base-files/files/etc/uci-defaults/90-memoptimize <<'EOF'
#!/bin/sh
echo 60 >/proc/sys/vm/swappiness
echo 10 >/proc/sys/vm/dirty_ratio
echo 5 >/proc/sys/vm/dirty_background_ratio
echo 1024 >/proc/sys/vm/min_free_kbytes
#TCP快速打开+连接早期硬件卸载
echo "net.ipv4.tcp_fastopen=3">>/etc/sysctl.conf
echo "net.netfilter.nf_conntrack_early_offload=1">>/etc/sysctl.conf
#NSS流表预加载全模式
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 3 >/sys/kernel/debug/nss/flow_preload/enable
[ -d /sys/module/qca_nss_drv/parameters ] && echo 1 >/sys/module/qca_nss_drv/parameters/pbuf_high_watermark
#定时释放内存
grep -q drop_caches /etc/crontabs/root || echo "0 */2 * * * sync;echo 3 >/proc/sys/vm/drop_caches">>/etc/crontabs/root
/etc/init.d/cron enable
EOF
chmod +x package/base-files/files/etc/uci-defaults/90-memoptimize

#③ECM全局配置（全预加载+连接上限8万，流表冗余）
cat > package/base-files/files/etc/uci-defaults/93-nss-ecm <<'EOF'
#!/bin/sh
uci -q get ecm.@global[0] >/dev/null || uci add ecm global
uci set ecm.@global[0].acceleration_engine='nss'
uci set ecm.@global[0].preload_mode='full'
uci set ecm.@global[0].conn_limit='80000'
uci commit ecm
EOF
chmod +x package/base-files/files/etc/uci-defaults/93-nss-ecm

#④防火墙/Zerotier/hostapd固化配置
cat > package/base-files/files/etc/uci-defaults/92-fix-all <<'EOF'
#!/bin/sh
if ! uci -q get fstab.@global[0];then
    uci add fstab global
fi
uci set fstab.@global[0].extroot='0'
uci commit fstab

if ! uci -q get oaf.@global[0];then
    uci add oaf global
fi
uci set oaf.@global[0].enable='0'
uci commit oaf

sed -i '/mkdir -p \/var\/run\/hostapd/d' /etc/init.d/wireless
sed -i 's/start_service() {/start_service() {\nmkdir -p \/var\/run\/hostapd\nchmod 777 \/var\/run\/hostapd/' /etc/init.d/wireless

uci set firewall.@defaults[0].fullcone='1'
uci add firewall zone
uci set firewall.zone[-1].name='zerotier'
uci set firewall.zone[-1].device='zt+'
uci set firewall.zone[-1].input='ACCEPT'
uci set firewall.zone[-1].output='ACCEPT'
uci set firewall.zone[-1].forward='ACCEPT'
uci set firewall.zone[-1].masq='1'
uci set firewall.zone[-1].mtu_fix='1'

uci add firewall forwarding
uci set firewall.forwarding[-1].src='lan'
uci set firewall.forwarding[-1].dest='zerotier'
uci add firewall forwarding
uci set firewall.forwarding[-1].src='zerotier'
uci set firewall.forwarding[-1].dest='lan'

uci add firewall rule
uci set firewall.rule[-1].name='ZT-9993-UDP'
uci set firewall.rule[-1].src='wan'
uci set firewall.rule[-1].proto='udp'
uci set firewall.rule[-1].dest_port='9993'
uci set firewall.rule[-1].target='ACCEPT'
uci commit firewall

mkdir -p /var/lib/zerotier-one
cat > /var/lib/zerotier-one/local.conf <<'ZTCFG'
{
"settings":{
"defaultPhysicalMTU":1400,
"allowTcpFallbackRelay":false,
"enableActiveProbes":false,
"disableBroadcast":true,
"disableMulticast":true,
"bind":["0.0.0.0"]
}
}
ZTCFG
echo 'sleep 8;ZTIF=$(ip link|grep zt|awk "{print $2}"|sed s/://);[ -n "$ZTIF" ]&&ip link set $ZTIF mtu 1400' >>/etc/rc.local
/etc/init.d/zerotier enable
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/92-fix-all

#收尾刷新feed
./scripts/feeds update -a
./scripts/feeds install -a
green "==== Prebuild All Done ===="

#================NSS全冗余.config自动写入｜去冲突完整版================
CFG=".config"
#清理冲突配置项
sed -i '/CONFIG_PACKAGE_kmod-qca-nss-ecm-nat/d' $CFG
sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-cake/d' $CFG
sed -i '/CONFIG_PACKAGE_kmod-qca-nss-drv-wifi/d' $CFG
sed -i '/CONFIG_PACKAGE_kmod-qca-nss-ppe/d' $CFG

#写入全套无冲突NSS冗余+流量预加载
cat >>$CFG <<'NSS_ALL_CONF'
#NSS内存规格适配AX5 512MB
CONFIG_NSS_MEM_PROFILE_MEDIUM=y
#全锥NAT，匹配防火墙fullcone=1
CONFIG_PACKAGE_kmod-qca-nss-drv-fullcone=y
#PPPOE全套硬件冗余
CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe-tap=y
CONFIG_PACKAGE_kmod-qca-nss-drv-pppoe-relay=y
#隧道全硬件卸载 ZT/GRE/IPSEC/UDP-LITE/MACSEC
CONFIG_PACKAGE_kmod-qca-nss-drv-tun=y
CONFIG_PACKAGE_kmod-qca-nss-drv-gre=y
CONFIG_PACKAGE_kmod-qca-nss-drv-ipsec=y
CONFIG_PACKAGE_kmod-qca-nss-drv-udp-lite=y
CONFIG_PACKAGE_kmod-qca-nss-drv-macsec=y
#二层链路硬件
CONFIG_PACKAGE_kmod-qca-nss-drv-vlan=y
CONFIG_PACKAGE_kmod-qca-nss-drv-policer=y
#NSS队列对接内核fq_codel，双共存无冲突
CONFIG_PACKAGE_kmod-qca-nss-drv-qdisc=y

#流量预加载+小包硬件预热核心
CONFIG_PACKAGE_kmod-qca-nss-drv-flow-preload=y
CONFIG_NSS_DRV_FLOW_PRELOAD_ENABLE=y
CONFIG_NSS_DRV_FLOW_CACHE=y
CONFIG_NSS_ECM_PRELOAD_CONN=y
CONFIG_NSS_ECM_FLOW_CACHE=y
CONFIG_PACKAGE_kmod-qca-nss-drv-reassemble=y
CONFIG_NSS_DRV_REASSEMBLE_ENABLE=y

#NSS状态监控面板
CONFIG_PACKAGE_nssinfo=y
CONFIG_PACKAGE_nssstats=y
CONFIG_PACKAGE_luci-app-nssinfo=y
CONFIG_PACKAGE_luci-i18n-nssinfo-zh-cn=y

#内核流表卸载&早期offload冗余
CONFIG_KERNEL_NF_FLOW_OFFLOAD=y
CONFIG_PACKAGE_kmod-nft-flow=y
CONFIG_KERNEL_NF_CONNTRACK_MARK=y
CONFIG_KERNEL_NF_CONNTRACK_ZONES=y
CONFIG_KERNEL_NF_CONNTRACK_EARLY_OFFLOAD=y

#冲突模块强制关闭
# CONFIG_PACKAGE_kmod-qca-nss-ecm-nat is not set
# CONFIG_PACKAGE_kmod-qca-nss-drv-cake is not set
# CONFIG_PACKAGE_kmod-qca-nss-drv-wifi is not set
# CONFIG_PACKAGE_kmod-qca-nss-ppe is not set
# CONFIG_PACKAGE_kmod-qca-nss-ppe-ipv4 is not set
# CONFIG_PACKAGE_kmod-qca-nss-ppe-nat is not set
NSS_ALL_CONF

green "==== NSS全冗余+ECM预加载+启动时序+内存优化全部配置完成 ===="
