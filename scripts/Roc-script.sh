#!/bin/bash
set -e

# 彩色输出
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

# 设置 OPENWRT_PATH 默认值
if [ -z "$OPENWRT_PATH" ]; then
    OPENWRT_PATH=$(pwd)
    export OPENWRT_PATH
    green "OPENWRT_PATH set to: $OPENWRT_PATH"
fi

PKG_LIST=(argon-config wechatpush appfilter frpc frps argon aria2 ariang nginx frp golang open-app-filter)

# ==================== 1. 初始化feed ====================
green "===== 1/14 Update & Install Feeds ====="
./scripts/feeds update -a || true
./scripts/feeds install -a || true

# ==================== 2. 基础定制 ====================
green "===== 2/14 Basic Customization ====="
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate || true
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate || true

# ==================== 3. DTS NSS预留64MB内存 ====================
green "===== 3/14 NSS Memory Reservation ====="
DTS_FILE=""
for path in \
    "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi" \
    "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq60xx/ipq6018-512m.dtsi"; do
    [ -f "$path" ] && DTS_FILE="$path" && break
done
if [ -n "$DTS_FILE" ]; then
    sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' "$DTS_FILE" || true
    green "   NSS reserved 64MB done ($DTS_FILE)"
else
    yellow "   DTS file not found, skip memory reservation"
fi

# ==================== 4. 清理源内原生包 ====================
green "===== 4/14 Remove default packages ====="
rm -rf feeds/luci/applications/luci-app-{argon-config,wechatpush,appfilter,frpc,frps} feeds/luci/themes/luci-theme-argon || true
rm -rf feeds/packages/net/{open-app-filter,ariang,aria2,nginx,frp} feeds/packages/lang/golang || true
for NAME in "${PKG_LIST[@]}"; do
    DIRS=$(find feeds/luci feeds/packages -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
    [ -n "$DIRS" ] && rm -rf "$DIRS" || true
done

# ==================== 稀疏克隆函数 ====================
git_sparse_clone() {
    local b=$1 u=$2; shift 2
    git clone --depth=1 -b $b --single-branch --filter=blob:none --sparse --timeout=60 "$u" || return 0
    d=$(basename "$u"); cd "$d"
    git sparse-checkout set $*
    mkdir -p ../package
    mv -f $* ../package 2>/dev/null || true
    cd ..; rm -rf "$d"
}

# ==================== 5. 拉取自定义包 ====================
green "===== 5/14 Pull custom packages ====="
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

# ==================== 6. 拉取主题和插件 ====================
green "===== 6/14 Pull Theme & Apps ====="
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

# ==================== 7. Passwall & OpenClash ====================
green "===== 7/14 Setup PassWall & OpenClash ====="
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls} || true
git clone --depth=1 --timeout=60 https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages || true
rm -rf feeds/luci/applications/{luci-app-passwall,luci-app-openclash} || true
git clone --depth=1 --timeout=60 https://github.com/Openwrt-Passwall/openwrt-passwall package/luci-app-passwall || true
git clone --depth=1 --timeout=60 https://github.com/Openwrt-Passwall/openwrt-passwall2 package/luci-app-passwall2 || true
git clone --depth=1 --timeout=60 https://github.com/vernesong/OpenClash package/luci-app-openclash || true

# ==================== 8. 优化所有启动顺序 ====================
green "===== 8/14 Optimize ALL startup order ====="

optimize_start() {
    local file=$1 start=$2 name=$3
    if [ -f "$file" ]; then
        sed -i "s/START=.*/START=$start/" "$file" 2>/dev/null || true
        sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$file" 2>/dev/null || true
        green "   ✓ $name: START=$start"
    fi
}

# --- NSS 硬件加速层 (10-18) ---
green "   --- NSS 硬件加速 ---"
optimize_start "feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init" 10 "qca-nss-drv"
[ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe && green "   ✓ removed qca-nss-ppe"
optimize_start "feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init" 12 "qca-nss-ecm"
optimize_start "feeds/nss_packages/qca-nss-dp/files/qca-nss-dp.init" 13 "qca-nss-dp"
optimize_start "feeds/nss_packages/qca-ssdk/files/qca-ssdk.init" 14 "qca-ssdk"

# --- 系统基础层 (15-19) ---
green "   --- 系统基础 ---"
optimize_start "package/base-files/files/etc/init.d/boot" 15 "boot"
optimize_start "package/system/zram-swap/files/zram-swap.init" 16 "zram-swap"
optimize_start "package/utils/irqbalance/files/irqbalance.init" 17 "irqbalance"

# --- 网络基础层 (20-29) ---
green "   --- 网络基础 ---"
optimize_start "package/base-files/files/etc/init.d/network" 20 "network"
optimize_start "package/network/services/dnsmasq/files/dnsmasq.init" 21 "dnsmasq"
optimize_start "package/network/services/odhcpd/files/odhcpd.init" 22 "odhcpd"
optimize_start "package/network/config/firewall4/files/firewall.init" 23 "firewall4"

# --- 网络服务层 (30-39) ---
green "   --- 网络服务 ---"
optimize_start "feeds/packages/net/miniupnpd/files/miniupnpd.init" 30 "miniupnpd"
optimize_start "feeds/packages/net/zerotier/files/zerotier.init" 32 "zerotier"

# --- Web 管理层 (40-49) ---
green "   --- Web 管理 ---"
optimize_start "package/network/services/uhttpd/files/uhttpd.init" 40 "uhttpd"
optimize_start "package/system/rpcd/files/rpcd.init" 41 "rpcd"

# --- 应用服务层 (50-59) ---
green "   --- 应用服务 ---"
optimize_start "feeds/packages/net/vlmcsd/files/vlmcsd.init" 50 "vlmcsd"
optimize_start "feeds/packages/utils/ttyd/files/ttyd.init" 51 "ttyd"

# --- 监控层 (60-69) ---
green "   --- 监控服务 ---"
optimize_start "feeds/luci/applications/luci-app-autoreboot/root/etc/init.d/autoreboot" 60 "autoreboot"
optimize_start "feeds/luci/applications/luci-app-watchcat/root/etc/init.d/watchcat" 61 "watchcat"

# --- 高级网络层 (80-89) ---
green "   --- 高级网络 ---"
optimize_start "feeds/packages/net/ddns-scripts/files/ddns.init" 75 "ddns"
optimize_start "package/luci-app-openclash/root/etc/init.d/openclash" 80 "openclash"
optimize_start "package/luci-app-passwall/root/etc/init.d/passwall" 81 "passwall"
optimize_start "package/luci-app-passwall2/root/etc/init.d/passwall2" 82 "passwall2"

# --- 应用层 (85-99) ---
green "   --- 高级应用 ---"
optimize_start "feeds/packages/net/nginx/files/nginx.init" 85 "nginx"
optimize_start "feeds/packages/net/aria2/files/aria2.init" 88 "aria2"
optimize_start "package/luci-app-athena-led/root/etc/init.d/athena_led" 95 "athena-led"

green "   ✅ 所有启动顺序优化完成"

# ==================== 9. 编译容错 ====================
green "===== 9/14 Fix compile issues ====="
TS=$(find feeds/packages -maxdepth 3 -name tailscale/Makefile 2>/dev/null | head -1)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS" && green "   Tailscale fixed"

RU=$(find feeds/packages -maxdepth 3 -name rust/Makefile 2>/dev/null | head -1)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU" && green "   Rust fixed"

# ==================== 10. 修复网络和DHCP配置 ====================
green "===== 10/14 Fix Network & DHCP ====="
mkdir -p package/base-files/files/etc/config
mkdir -p package/base-files/files/etc/uci-defaults
mkdir -p package/base-files/files/etc/init.d

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
green "   ✓ Network/DHCP config created"

# ==================== 11. NSS等待脚本 ====================
green "===== 11/14 Create NSS wait script ====="
cat > package/base-files/files/etc/init.d/nss-wait << 'EOF'
#!/bin/sh /etc/rc.common

START=98
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "
        sleep 5
        echo 'Checking NSS...'
        if [ -f /sys/kernel/debug/nss/stats ]; then
            echo 'NSS active'
        else
            echo 'NSS not ready, restarting network'
            /etc/init.d/network restart
        fi
    "
    procd_close_instance
}
EOF
chmod +x package/base-files/files/etc/init.d/nss-wait
green "   ✓ nss-wait START=98"

# ==================== 12. NSS uci-defaults修复 ====================
green "===== 12/14 Create NSS firstboot fix ====="
cat > package/base-files/files/etc/uci-defaults/99-nss-fix << 'EOF'
#!/bin/sh
sleep 2
[ -d /sys/class/net/br-lan ] || brctl addbr br-lan 2>/dev/null
brctl addif br-lan eth0 2>/dev/null || true
ip link set eth0 up 2>/dev/null
/etc/init.d/network restart 2>/dev/null
/etc/init.d/dnsmasq restart 2>/dev/null
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-nss-fix
green "   ✓ NSS firstboot fix created"

# ==================== 13. WiFi预设 ====================
green "===== 13/14 WiFi preset ====="
cat > package/base-files/files/etc/uci-defaults/99-set-wifi << 'EOF'
#!/bin/sh
sleep 5
wifi reload >/dev/null 2>&1

uci set wireless.radio0.ssid='001'
uci set wireless.radio0.encryption='psk2'
uci set wireless.radio0.key='11111111'
uci set wireless.radio0.band='2g'
uci set wireless.radio0.htmode='HE20'

uci set wireless.radio1.ssid='001_5G'
uci set wireless.radio1.encryption='psk2'
uci set wireless.radio1.key='11111111'
uci set wireless.radio1.band='5g'
uci set wireless.radio1.htmode='HE80'

uci commit wireless
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-set-wifi
green "   ✓ WiFi preset: 001 / 001_5G (密码: 11111111)"

# ==================== 14. 最终刷新源 ====================
green "===== 14/14 Final feeds update ====="
./scripts/feeds update -a || true
./scripts/feeds install -a || true

