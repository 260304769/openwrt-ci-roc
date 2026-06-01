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

#3 NSS DTS 固定64MB专属预留内存
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

#6 全量拉取所有主题+插件（全部保留不精简）
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
uci set luci.main.autolang='0'
uci commit system
uci commit luci
echo "export LANG=zh_CN.UTF-8" >> /etc/profile
EOF
chmod +x package/base-files/files/etc/uci-defaults/95-set-lang

#②内存+NSS稳定参数 flow_preload=2（breeze稳速参数）
cat > package/base-files/files/etc/uci-defaults/90-memoptimize <<'EOF'
#!/bin/sh
echo 60 >/proc/sys/vm/swappiness
echo 10 >/proc/sys/vm/dirty_ratio
echo 5 >/proc/sys/vm/dirty_background_ratio
echo 1024 >/proc/sys/vm/min_free_kbytes
echo "net.ipv4.tcp_fastopen=3">>/etc/sysctl.conf
echo "net.netfilter.nf_conntrack_early_offload=1">>/etc/sysctl.conf
[ -d /sys/kernel/debug/nss/flow_preload ] && echo 2 >/sys/kernel/debug/nss/flow_preload/enable
[ -d /sys/module/qca_nss_drv/parameters ] && echo 1 >/sys/module/qca_nss_drv/parameters/pbuf_high_watermark
grep -q drop_caches /etc/crontabs/root || echo "0 */2 * * * sync;echo 3 >/proc/sys/vm/drop_caches">>/etc/crontabs/root
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

#④防火墙+ZT原生配置，删除自定义local.conf杜绝ZT反复重启
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

#彻底注释自定义ZT配置，原生运行防崩溃
echo 'sleep 8;ZTIF=$(ip link|grep zt|awk "{print $2}"|sed s/://);[ -n "$ZTIF" ]&&ip link set $ZTIF mtu 1400' >>/etc/rc.local
/etc/init.d/zerotier enable
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/92-fix-all

#收尾刷新feed
./scripts/feeds update -a
./scripts/feeds install -a
green "==== Prebuild All Done ===="

#NSS配置全保留原有硬件加速项，仅关闭4个高危模块，其余全开启
CFG=".config"
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

#仅关闭故障源模块
# CONFIG_PACKAGE_kmod-qca-nss-ecm-nat is not set
# CONFIG_PACKAGE_kmod-qca-nss-drv-cake is not set
# CONFIG_PACKAGE_kmod-qca-nss-drv-wifi is not set
# CONFIG_PACKAGE_kmod-qca-nss-ppe is not set
# CONFIG_PACKAGE_kmod-qca-nss-ppe-ipv4 is not set
# CONFIG_PACKAGE_kmod-qca-nss-ppe-nat is not set
NSS_ALL_CONF

green "==== 全插件保留+稳速优化完成 ===="
