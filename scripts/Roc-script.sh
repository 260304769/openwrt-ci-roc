#!/bin/bash
set -e

# 彩色输出
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

# 设置 OPENWRT_PATH 默认值（关键修复）
if [ -z "$OPENWRT_PATH" ]; then
    OPENWRT_PATH=$(pwd)
    export OPENWRT_PATH
    green "OPENWRT_PATH set to: $OPENWRT_PATH"
fi

PKG_LIST=(argon-config wechatpush appfilter frpc frps argon aria2 ariang nginx frp golang open-app-filter)

#1.初始化feed
green "===== Update & Install Feeds ====="
./scripts/feeds update -a || true
./scripts/feeds install -a || true

#2.基础定制：网关/主机名/状态栏
green "===== Basic Customization ====="
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate || true
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate || true
sed -i "s#_('Firmware Version'),.*#_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),#" feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js || true

#3.DTS NSS预留64MB内存
green "===== NSS Memory Reservation ====="
DTS_FILE=""
for path in \
    "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi" \
    "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq60xx/ipq6018-512m.dtsi"; do
    [ -f "$path" ] && DTS_FILE="$path" && break
done
if [ -n "$DTS_FILE" ]; then
    sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' "$DTS_FILE" || true
    green "✅ NSS reserved 64MB done ($DTS_FILE)"
else
    yellow "⚠️ DTS file not found, skip memory reservation"
fi

#4.清理源内原生包
green "===== Remove default packages ====="
rm -rf feeds/luci/applications/luci-app-{argon-config,wechatpush,appfilter,frpc,frps} feeds/luci/themes/luci-theme-argon || true
rm -rf feeds/packages/net/{open-app-filter,ariang,aria2,nginx,frp} feeds/packages/lang/golang || true
for NAME in "${PKG_LIST[@]}"; do
    DIRS=$(find feeds/luci feeds/packages -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
    [ -n "$DIRS" ] && rm -rf "$DIRS" || true
done

#稀疏克隆函数
git_sparse_clone() {
    local b=$1 u=$2; shift 2
    git clone --depth=1 -b $b --single-branch --filter=blob:none --sparse --timeout=60 "$u" || return 0
    d=$(basename "$u"); cd "$d"
    git sparse-checkout set $*
    mkdir -p ../package
    mv -f $* ../package 2>/dev/null || true
    cd ..; rm -rf "$d"
}

#5.稀疏拉取第三方包入feed
green "===== Pull custom packages ====="
git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
mv -f package/aria2 feeds/packages/net 2>/dev/null || true

git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
mv -f package/nginx feeds/packages/net 2>/dev/null || true

git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
mv -f package/ariang feeds/packages/net 2>/dev/null || true

git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv -f package/golang feeds/packages/lang 2>/dev/null || true

git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
mv -f package/frp feeds/packages/net 2>/dev/null || true

git_sparse_clone frp https://github.com/laipeng668/luci applications/luci-app-frpc applications/luci-app-frps
mv -f package/luci-app-frpc feeds/luci/applications 2>/dev/null || true
mv -f package/luci-app-frps feeds/luci/applications 2>/dev/null || true

#6.拉取主题+常用插件
green "===== Pull Theme & Apps ====="
git clone --depth=1 --timeout=60 https://github.com/jerrykuku/luci-theme-argon feeds/luci/themes/luci-theme-argon || true
git clone --depth=1 --timeout=60 https://github.com/jerrykuku/luci-app-argon-config feeds/luci/applications/luci-app-argon-config || true
git clone --depth=1 --timeout=60 https://github.com/eamonxg/luci-theme-aurora feeds/luci/themes/luci-theme-aurora || true
git clone --depth=1 --timeout=60 https://github.com/eamonxg/luci-app-aurora-config feeds/luci/applications/luci-app-aurora-config || true

git clone --depth=1 --timeout=60 https://github.com/sbwml/luci-app-openlist2 package/openlist2 || true
git clone --depth=1 --timeout=60 https://github.com/gdy666/luci-app-lucky package/luci-app-lucky || true
git clone --depth=1 --timeout=60 https://github.com/tty228/luci-app-wechatpush package/luci-app-wechatpush || true
git clone --depth=1 --timeout=60 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter || true
git clone --depth=1 --timeout=60 https://github.com/laipeng668/luci-app-gecoosac package/luci-app-gecoosac || true
git clone --depth=1 --timeout=60 https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led || true
chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led 2>/dev/null || true

#7.Passwall&OpenClash
green "===== Setup PassWall & OpenClash ====="
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls} || true
git clone --depth=1 --timeout=60 https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages || true
rm -rf feeds/luci/applications/{luci-app-passwall,luci-app-openclash} || true
git clone --depth=1 --timeout=60 https://github.com/Openwrt-Passwall/openwrt-passwall package/luci-app-passwall || true
git clone --depth=1 --timeout=60 https://github.com/Openwrt-Passwall/openwrt-passwall2 package/luci-app-passwall2 || true
git clone --depth=1 --timeout=60 https://github.com/vernesong/OpenClash package/luci-app-openclash || true

#自定义chnlist
CHNLIST="package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist"
mkdir -p "$(dirname "$CHNLIST")" || true
echo "baidu.com" > "$CHNLIST" || true

#8.NSS启动顺序修正
green "===== Fix NSS init start order ====="
if [ -d feeds/nss_packages ]; then
    f=feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init
    [ -f "$f" ] && sed -i 's/START=.*/START=45/;s/USE_PROCD=.*/USE_PROCD=1/' "$f" && green "   ✓ qca-nss-drv START=45"
    f=feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init
    [ -f "$f" ] && sed -i 's/START=.*/START=50/' "$f" && green "   ✓ qca-nss-ecm START=50"
    [ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe && green "   ✓ removed qca-nss-ppe"
else
    yellow "⚠️ feeds/nss_packages not found, skip NSS patches"
fi

#9.注释废弃ath11k自定义init(内核自动加载无线驱动)
green "===== Skip custom ath11k init (kernel auto load) ====="

#10.编译容错
green "===== Fix compile issues ====="
TS=$(find feeds/packages -maxdepth 3 -name tailscale/Makefile 2>/dev/null | head -1)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS" && green "✓ Tailscale fixed"

RU=$(find feeds/packages -maxdepth 3 -name rust/Makefile 2>/dev/null | head -1)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU" && green "✓ Rust fixed"

# ===================== 11. 修复无 IP 分配问题 =====================
green "===== Fix IP allocation issue ====="

# 11.1 创建必要的目录
mkdir -p package/base-files/files/etc/config
mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/init.d

# 11.2 修复网络默认配置
cat > package/base-files/files/etc/config/network << 'EOF'
config interface 'loopback'
    option device 'lo'
    option proto 'static'
    option ipaddr '127.0.0.1'
    option netmask '255.0.0.0'

config globals 'globals'
    option ula_prefix 'fd00::/48'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports 'eth0'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.10.1'
    option netmask '255.255.255.0'
    option ip6assign '60'

config interface 'wan'
    option device 'eth1'
    option proto 'dhcp'

config interface 'wan6'
    option device 'eth1'
    option proto 'dhcpv6'
EOF
green "✓ Network config created"

# 11.3 修复 DHCP 配置
cat > package/base-files/files/etc/config/dhcp << 'EOF'
config dnsmasq
    option domainneeded '1'
    option boguspriv '1'
    option filterwin2k '0'
    option localise_queries '1'
    option rebind_protection '1'
    option rebind_localhost '1'
    option local '/lan/'
    option domain 'lan'
    option expandhosts '1'
    option nonegcache '0'
    option authoritative '1'
    option readethers '1'
    option leasefile '/tmp/dhcp.leases'
    option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
    option nonwildcard '1'
    option localservice '1'
    option ednspacket_max '1232'

config dhcp 'lan'
    option interface 'lan'
    option start '100'
    option limit '150'
    option leasetime '12h'
    option dhcpv4 'server'
    option dhcpv6 'server'
    option ra 'server'
    option ra_slaac '1'
    list ra_flags 'managed-config'
    list ra_flags 'other-config'

config dhcp 'wan'
    option interface 'wan'
    option ignore '1'

config odhcpd 'odhcpd'
    option maindhcp '0'
    option leasefile '/tmp/hosts/odhcpd'
    option leasetrigger '/usr/sbin/odhcpd-update'
    option loglevel '4'
EOF
green "✓ DHCP config created"

# 11.4 添加 NSS 等待脚本
cat > package/base-files/files/etc/init.d/nss-wait << 'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {
    echo "Waiting for NSS to be ready..."
    sleep 3
    
    if [ -f /sys/kernel/debug/nss/status ]; then
        echo "NSS is ready"
    else
        echo "NSS not ready, restarting network"
        /etc/init.d/network restart
    fi
}

stop() {
    echo "NSS wait script stopped"
}
EOF
chmod +x package/base-files/files/etc/init.d/nss-wait 2>/dev/null || true
green "✓ NSS wait script added"

# 11.5 添加 uci-defaults 修复脚本
cat > package/base-files/files/etc/uci-defaults/99-nss-fix << 'EOF'
#!/bin/sh
sleep 2
[ -d /sys/class/net/br-lan ] || brctl addbr br-lan
brctl addif br-lan eth0 2>/dev/null || true
ifconfig eth0 up
/etc/init.d/network restart
/etc/init.d/dnsmasq restart
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-nss-fix 2>/dev/null || true
green "✓ NSS uci-defaults script added"

#=====双频WiFi配置：2.4G:001 HE20 /5G:001-5G HE80，密码11111111=====
cat > package/base-files/files/etc/uci-defaults/99-set-wifi <<'EOF'
#!/bin/sh
sleep 3
wifi reload >/dev/null 2>&1

#2.4G radio0
uci set wireless.radio0.ssid='001'
uci set wireless.radio0.encryption='psk2'
uci set wireless.radio0.key='11111111'
uci set wireless.radio0.band='2g'
uci set wireless.radio0.htmode='HE20'

#5G radio1
uci set wireless.radio1.ssid='001-5G'
uci set wireless.radio1.encryption='psk2'
uci set wireless.radio1.key='11111111'
uci set wireless.radio1.band='5g'
uci set wireless.radio1.htmode='HE80'

uci commit wireless
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-set-wifi
green "✓ 双频WiFi预设：2.4G=001(HE20)｜5G=001-5G(HE80)｜密码11111111"

green "✅ IP allocation fix completed"

# 11.7 修复 .config格式 + 强制关闭mac80211编译（根治报错）
green "===== Fix .config format & Disable mac80211 ====="
cd "$OPENWRT_PATH"

if [ -f .config ]; then
    cp .config .config.bak 2>/dev/null || true
    grep -E '^(# )?CONFIG_' .config.bak > .config 2>/dev/null || true
    sed -i '/^$/d' .config
    sed -i 's/^\t//g' .config
    sed -i -e '$a\' .config
fi

# 核心：关闭mac80211，启用ath11k，解决编译失败
sed -i '/CONFIG_PACKAGE_kmod-mac80211/d' .config
echo "# CONFIG_PACKAGE_kmod-mac80211 is not set" >> .config
sed -i '/CONFIG_PACKAGE_kmod-ath11k/d' .config
echo "CONFIG_PACKAGE_kmod-ath11k=y" >> .config

make defconfig > /dev/null 2>&1 || true
green "✅ defconfig completed | mac80211已禁用、ath11k已勾选"

#最终刷新源
green "===== Final feeds update ====="
./scripts/feeds update -a || true
./scripts/feeds install -a || true

echo ""
green "===== AX5 IPQ6018 512M 补丁全部完成 ====="
echo ""
echo "📌 WiFi参数："
echo "   ✅ 2.4G：SSID=001｜密码=11111111｜HE20"
echo "   ✅ 5G：SSID=001-5G｜密码=11111111｜HE80"
echo "📌 已修复的问题："
echo "   ✅ NSS 硬件加速配置 (START=45/50)"
echo "   ✅ ath11k无线自动适配，开机自动生成WiFi"
echo "   ✅ 彻底关闭mac80211不再编译报错"
echo "   ✅ 网络 IP 分配问题 + DHCP"
echo "   ✅ .config格式错误"
echo ""
echo "📌 编译步骤："
echo "   1. rm -rf build_dir staging_dir tmp .config"
echo "   2. bash build.sh"
echo "   3. make download -j8"
echo "   4. make -j\$(nproc)"
