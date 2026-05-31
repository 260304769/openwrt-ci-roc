#!/bin/bash
set -euo pipefail

# 彩色输出
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

# 设置 OPENWRT_PATH 默认值
export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
green "OPENWRT_PATH set to: $OPENWRT_PATH"
cd "$OPENWRT_PATH" || exit 1

PKG_LIST=(argon-config wechatpush appfilter frpc frps argon aria2 ariang nginx frp golang open-app-filter)

# ==================== 1. 初始化feed ====================
green "===== 1/15 Update & Install Feeds ====="
./scripts/feeds update -a
./scripts/feeds install -a

# ==================== 2. 基础定制 ====================
green "===== 2/15 Basic Customization ====="
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate

# ==================== 3. DTS NSS预留64MB内存 ====================
green "===== 3/15 NSS Memory Reservation ====="
DTS_FILE=""
for path in \
    "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi" \
    "target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq60xx/ipq6018-512m.dtsi"; do
    [ -f "$path" ] && DTS_FILE="$path" && break
done
if [ -n "$DTS_FILE" ]; then
    sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' "$DTS_FILE"
    green "   NSS reserved 64MB done ($DTS_FILE)"
else
    yellow "   DTS file not found, skip memory reservation"
fi

# ==================== 4. 清理源内原生包 ====================
green "===== 4/15 Remove default packages ====="
rm -rf feeds/luci/applications/luci-app-{argon-config,wechatpush,appfilter,frpc,frps} feeds/luci/themes/luci-theme-argon
rm -rf feeds/packages/net/{open-app-filter,ariang,aria2,nginx,frp} feeds/packages/lang/golang
for NAME in "${PKG_LIST[@]}"; do
    DIRS=$(find feeds/luci feeds/packages -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
    [ -n "$DIRS" ] && rm -rf "$DIRS"
done

# ==================== 稀疏克隆函数【删除--timeout=60】 ====================
git_sparse_clone() {
    local BRANCH="$1" REPO="$2"; shift 2
    local CHECKOUT=("$@")
    git clone --depth=1 -b "$BRANCH" --single-branch --filter=blob:none --sparse "$REPO"
    local DIR_NAME=$(basename "$REPO" .git)
    cd "$DIR_NAME"
    git sparse-checkout set "${CHECKOUT[@]}"
    mkdir -p ../package
    for item in "${CHECKOUT[@]}"; do
        [ -e "$item" ] && mv "$item" ../package/
    done
    cd ..
    rm -rf "$DIR_NAME"
}

# ==================== 5. 拉取自定义包 ====================
green "===== 5/15 Pull custom packages ====="
git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
mv -f package/aria2 feeds/packages/net

git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
mv -f package/nginx feeds/packages/net

git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
mv -f package/ariang feeds/packages/net

git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv -f package/golang feeds/packages/lang

git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
mv -f package/frp feeds/packages/net

git_sparse_clone frp https://github.com/laipeng668/luci applications/luci-app-frpc applications/luci-app-frps
mv -f package/luci-app-frpc feeds/luci/applications
mv -f package/luci-app-frps feeds/luci/applications

# ==================== 6. 拉取主题和插件【全删--timeout=60】 ====================
green "===== 6/15 Pull Theme & Apps ====="
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon feeds/luci/themes/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config feeds/luci/applications/luci-app-argon-config
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora feeds/luci/themes/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config feeds/luci/applications/luci-app-aurora-config

git clone --depth=1 https://github.com/sbwml/luci-app-openlist2 package/openlist2
git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/luci-app-lucky
git clone --depth=1 https://github.com/tty228/luci-app-wechatpush package/luci-app-wechatpush
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
git clone --depth=1 https://github.com/laipeng668/luci-app-gecoosac package/luci-app-gecoosac
git clone --depth=1 https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led

# 文件存在才chmod容错
[ -f package/luci-app-athena-led/root/etc/init.d/athena_led ] && chmod +x "$_"
[ -f package/luci-app-athena-led/root/usr/sbin/athena-led ] && chmod +x "$_"

# ==================== 7. Passwall & OpenClash ====================
green "===== 7/15 Setup PassWall & OpenClash ====="
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages
rm -rf feeds/luci/applications/{luci-app-passwall,luci-app-openclash}
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall package/luci-app-passwall
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2 package/luci-app-passwall2
git clone --depth=1 https://github.com/vernesong/OpenClash package/luci-app-openclash

# ==================== 8. 优化所有启动顺序 ====================
green "===== 8/15 Optimize ALL startup order ====="

optimize_start() {
    local file=$1 start=$2 name=$3
    if [ -f "$file" ]; then
        sed -i "s/START=.*/START=$start/" "$file"
        sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$file"
        green "   ✓ $name: START=$start"
    fi
}

green "   --- NSS 硬件加速 ---"
optimize_start "feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init" 10 "qca-nss-drv"
[ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe && green "   ✓ removed qca-nss-ppe"
optimize_start "feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init" 12 "qca-nss-ecm"
optimize_start "feeds/nss_packages/qca-nss-dp/files/qca-nss-dp.init" 13 "qca-nss-dp"
optimize_start "feeds/nss_packages/qca-ssdk/files/qca-ssdk.init" 14 "qca-ssdk"

green "   --- 系统基础 ---"
optimize_start "package/base-files/files/etc/init.d/boot" 15 "boot"
optimize_start "package/system/zram-swap/files/zram-swap.init" 16 "zram-swap"
optimize_start "package/utils/irqbalance/files/irqbalance.init" 17 "irqbalance"

green "   --- 网络基础 ---"
optimize_start "package/base-files/files/etc/init.d/network" 20 "network"
optimize_start "package/network/services/dnsmasq/files/dnsmasq.init" 21 "dnsmasq"
optimize_start "package/network/services/odhcpd/files/odhcpd.init" 22 "odhcpd"
optimize_start "package/network/config/firewall4/files/firewall.init" 23 "firewall4"

green "   --- 网络服务 ---"
optimize_start "feeds/packages/net/miniupnpd/files/miniupnpd.init" 30 "miniupnpd"
optimize_start "feeds/packages/net/zerotier/files/zerotier.init" 32 "zerotier"

green "   --- Web 管理 ---"
optimize_start "package/network/services/uhttpd/files/uhttpd.init" 40 "uhttpd"
optimize_start "package/system/rpcd/files/rpcd.init" 41 "rpcd"

green "   --- 应用服务 ---"
optimize_start "feeds/packages/net/vlmcsd/files/vlmcsd.init" 50 "vlmcsd"
optimize_start "feeds/packages/utils/ttyd/files/ttyd.init" 51 "ttyd"

green "   --- 监控服务 ---"
optimize_start "feeds/luci/applications/luci-app-autoreboot/root/etc/init.d/autoreboot" 60 "autoreboot"
optimize_start "feeds/luci/applications/luci-app-watchcat/root/etc/init.d/watchcat" 61 "watchcat"

green "   --- 高级网络 ---"
optimize_start "feeds/packages/net/ddns-scripts/files/ddns.init" 75 "ddns"
optimize_start "package/luci-app-openclash/root/etc/init.d/openclash" 80 "openclash"
optimize_start "package/luci-app-passwall/root/etc/init.d/passwall" 81 "passwall"
optimize_start "package/luci-app-passwall2/root/etc/init.d/passwall2" 82 "passwall2"

green "   --- 高级应用 ---"
optimize_start "feeds/packages/net/nginx/files/nginx.init" 85 "nginx"
optimize_start "feeds/packages/net/aria2/files/aria2.init" 88 "aria2"
optimize_start "package/luci-app-athena-led/root/etc/init.d/athena_led" 95 "athena-led"

green "   ✅ 所有启动顺序优化完成"

# ==================== 9. 编译容错 ====================
green "===== 9/15 Fix compile issues ====="
TS=$(find feeds/packages -maxdepth 3 -name tailscale/Makefile 2>/dev/null | head -1)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS" && green "   Tailscale fixed"

RU=$(find feeds/packages -maxdepth 3 -name rust/Makefile 2>/dev/null | head -1)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU" && green "   Rust fixed"

# ==================== 10. 固化网络+DHCP+PPPoE+防火墙NAT ====================
green "===== 10/15 Preconfig Network+DHCP+PPPoE+Full NAT Forward ====="
mkdir -p package/base-files/files/etc/config package/base-files/files/etc/uci-defaults package/base-files/files/etc/init.d

cat > package/base-files/files/etc/config/network << 'NETEOF'
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
    option proto 'pppoe'
    option username '你的宽带账号'
    option password '你的宽带密码'
    option keepalive '6 10'
    option peerdns '0'
    option dns '223.5.5.5 119.29.29.29'
    option mtu '1492'

config interface 'wan6'
    option device '@wan'
    option proto 'dhcpv6'
NETEOF

cat > package/base-files/files/etc/config/dhcp << 'DHCPEOF'
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
DHCPEOF

cat > package/base-files/files/etc/config/firewall << 'FWEOF'
config defaults
    option syn_flood '1'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'REJECT'

config zone
    option name 'lan'
    option network 'lan'
    option input 'ACCEPT'
    option output 'ACCEPT'
    option forward 'ACCEPT'

config zone
    option name 'wan'
    option network 'wan wan6'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
    option masq '1'
    option mtu_fix '1'

config forwarding
    option src 'lan'
    option dest 'wan'

# 常用端口转发模板（按需取消注释）
# config redirect
#     option src 'wan'
#     option src_dport '80'
#     option dest 'lan'
#     option dest_ip '192.168.10.100'
#     option dest_port '80'
#     option target 'DNAT'

# config redirect
#     option src 'wan'
#     option src_dport '443'
#     option dest 'lan'
#     option dest_ip '192.168.10.100'
#     option dest_port '443'
#     option target 'DNAT'
FWEOF

green "   ✓ 网络/DHCP/防火墙/PPPoE NAT转发全部固化完成"

# ==================== 11. PPPoE TCP MSS 优化【set +e容错】 ====================
green "===== 11/15 PPPoE TCP MSS Fix ====="
cat > package/base-files/files/etc/uci-defaults/97-pppoe-mss-fix << 'MSSFIXEOF'
#!/bin/sh
set +e
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1452
ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1432
exit 0
MSSFIXEOF
chmod +x package/base-files/files/etc/uci-defaults/97-pppoe-mss-fix
green "   ✓ PPPoE MSS优化完成"

# ==================== 12. NSS等待脚本 ====================
green "===== 12/15 Create NSS wait script ====="
cat > package/base-files/files/etc/init.d/nss-wait << 'EOF'
#!/bin/sh /etc/rc.common
START=98
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c "set +e;sleep 5;[ -f /sys/kernel/debug/nss/stats ]||/etc/init.d/network restart"
    procd_close_instance
}
EOF
chmod +x package/base-files/files/etc/init.d/nss-wait
green "   ✓ nss-wait START=98"

# ==================== 13. NSS uci-defaults修复【set +e】 ====================
green "===== 13/15 Create NSS firstboot fix ====="
cat > package/base-files/files/etc/uci-defaults/99-nss-fix << 'EOF'
#!/bin/sh
set +e
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

# ==================== 14. WiFi预设【set +e】 ====================
green "===== 14/15 WiFi preset ====="
cat > package/base-files/files/etc/uci-defaults/99-set-wifi << 'EOF'
#!/bin/sh
set +e
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

# ==================== 15. CPU ondemand 极致性能【set +e】 + 最终刷新 ====================
green "===== 15/15 CPU ondemand Configuration & Final Feeds Update ====="
cat > package/base-files/files/etc/uci-defaults/98-cpufreq << 'EOF'
#!/bin/sh
set +e
sleep 2

for cpu in /sys/devices/system/cpu/cpu[1-9]*/online; do
    echo 1 > "$cpu" 2>/dev/null
done

if [ -d /sys/devices/system/cpu/cpufreq ]; then
    for policy in /sys/devices/system/cpu/cpufreq/policy*; do
        echo "ondemand" > "$policy/scaling_governor" 2>/dev/null
        echo 800000  > "$policy/scaling_min_freq" 2>/dev/null
        echo 1800000 > "$policy/scaling_max_freq" 2>/dev/null
    done
    
    echo 15     > /sys/devices/system/cpu/cpufreq/ondemand/up_threshold 2>/dev/null
    echo 5000   > /sys/devices/system/cpu/cpufreq/ondemand/sampling_rate 2>/dev/null
    echo 0      > /sys/devices/system/cpu/cpufreq/ondemand/ignore_nice_load 2>/dev/null
    echo 1000   > /sys/devices/system/cpu/cpufreq/ondemand/sampling_down_factor 2>/dev/null
fi

exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/98-cpufreq
green "   ✓ CPU 极致性能: 800-1800MHz | 15%升频 | 5ms采样"

./scripts/feeds update -a
./scripts/feeds install -a

echo ""
green "====================编译配置修复完毕===================="
