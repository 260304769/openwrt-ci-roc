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

#3 NSS DTS 64MB DDR 0x40000000~0x41000000
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

[ -f package/luci-app-athena-led/root/etc/init.d/athena_led ] && chmod +x $_
[ -f package/luci-app-athena-led/root/usr/sbin/athena-led ] && chmod +x $_

#7 跳过代理源码
green "====7 Skip All Proxy Source===="

#8 NSS+系统启动优先级
green "====8 Startup Order Optimize===="
optimize_start(){
local f="$1" s="$2" n="$3"
[ -f "$f" ] && {
sed -i "s/START=.*/START=$s/" "$f"
sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$f"
}
}
optimize_start feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init 10 qca-nss-drv
[ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe
optimize_start feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init 11 qca-nss-ecm
optimize_start feeds/nss_packages/qca-nss-dp/files/qca-nss-dp.init 12 qca-nss-dp
optimize_start feeds/nss_packages/qca-ssdk/files/qca-ssdk.init 13 qca-ssdk

optimize_start package/base-files/files/etc/init.d/boot 15 boot
optimize_start package/system/zram-swap/files/zram-swap.init 16 zram-swap
optimize_start package/utils/irqbalance/files/irqbalance.init 17 irqbalance

optimize_start package/base-files/files/etc/init.d/network 20 network
optimize_start package/network/services/dnsmasq/files/dnsmasq.init 21 dnsmasq
optimize_start package/network/services/odhcpd/files/odhcpd.init 22 odhcpd
optimize_start package/network/config/firewall4/files/firewall.init 23 firewall4

optimize_start feeds/packages/net/miniupnpd/files/miniupnpd.init 30 miniupnpd
optimize_start feeds/packages/net/zerotier/files/zerotier.init 32 zerotier

optimize_start package/network/services/uhttpd/files/uhttpd.init 40 uhttpd
optimize_start package/system/rpcd/files/rpcd.init 41 rpcd

optimize_start feeds/packages/net/vlmcsd/files/vlmcsd.init 50 vlmcsd
optimize_start feeds/packages/utils/ttyd/files/ttyd.init 51 ttyd
optimize_start feeds/luci/applications/luci-app-autoreboot/root/etc/init.d/autoreboot 60 autoreboot
optimize_start feeds/luci/applications/luci-app-watchcat/root/etc/init.d/watchcat 61 watchcat

optimize_start package/luci-app-athena-led/root/etc/init.d/athena_led 95 athena-led

#9 编译小补丁
TS=$(find feeds/packages -maxdepth3 -name tailscale/Makefile 2>/dev/null|head -1||true)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS"
RU=$(find feeds/packages -maxdepth3 -name rust/Makefile 2>/dev/null|head -1||true)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU"

#10 【修复版预埋配置：fstab/OAF/hostapd/时区/内存】
mkdir -p package/base-files/files/etc/uci-defaults

#时区简体中文
cat > package/base-files/files/etc/uci-defaults/95-set-lang <<'EOF'
#!/bin/sh
uci set luci.main.lang=zh_cn
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit luci;uci commit system
EOF
chmod +x $_

#内存参数+2h缓存自动释放
cat > package/base-files/files/etc/uci-defaults/90-memoptimize <<'EOF'
#!/bin/sh
echo 60 >/proc/sys/vm/swappiness
echo 10 >/proc/sys/vm/dirty_ratio
echo 5 >/proc/sys/vm/dirty_background_ratio
echo 1024 >/proc/sys/vm/min_free_kbytes
grep -q drop_caches /etc/crontabs/root || echo "0 */2 * * * sync;echo 3 >/proc/sys/vm/drop_caches">>/etc/crontabs/root
/etc/init.d/cron enable
EOF
chmod +x $_

#====核心修复脚本：容错fstab、容错OAF、wireless脚本内置hostapd目录授权====
cat > package/base-files/files/etc/uci-defaults/92-fix-all <<'EOF'
#!/bin/sh
#fstab容错创建全局，关闭extroot
if ! uci -q get fstab.@global[0];then
    uci add fstab global
fi
uci set fstab.@global[0].extroot='0'
uci commit fstab

#OAF容错创建配置，消除Entry not found
if ! uci -q get oaf.@global[0];then
    uci add oaf global
fi
uci set oaf.@global[0].enable='0'
uci commit oaf

#无线启动脚本内置自动创建+授权hostapd目录，根治权限拒绝
sed -i '/mkdir -p \/var\/run\/hostapd/d' /etc/init.d/wireless
sed -i 's/start_service() {/start_service() {\nmkdir -p \/var\/run\/hostapd\nchmod 777 \/var\/run\/hostapd/' /etc/init.d/wireless
exit 0
EOF
chmod +x $_

#收尾刷新feed
./scripts/feeds update -a
./scripts/feeds install -a
green "==== Prebuild Finish ===="
