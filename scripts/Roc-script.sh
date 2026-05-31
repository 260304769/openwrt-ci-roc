#!/bin/bash
set -euo pipefail

# 彩色输出
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
green "OPENWRT_PATH set to: $OPENWRT_PATH"
cd "$OPENWRT_PATH" || exit 1

PKG_LIST=(argon-config wechatpush appfilter frpc frps argon aria2 ariang nginx frp golang open-app-filter)

# ==================== 1. Feed更新+补全依赖 ====================
green "===== 1/15 Update & Install Feeds ====="
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install shadow-newuidmap shadow-newgidmap python3-pysocks python3-unidecode
./scripts/feeds install coreutils ca-bundle jq curl libopenssl-legacy

# ==================== 2. 修改网关与主机名 ====================
green "===== 2/15 Basic Customization ====="
[ -f package/base-files/files/bin/config_generate ] && {
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
}

# ==================== 3. NSS内存预留 ====================
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

# ==================== 4. 清理源内原有包 ====================
green "===== 4/15 Remove default packages ====="
rm -rf feeds/luci/applications/luci-app-{argon-config,wechatpush,appfilter,frpc,frps} feeds/luci/themes/luci-theme-argon
rm -rf feeds/packages/net/{open-app-filter,ariang,aria2,nginx,frp} feeds/packages/lang/golang
for NAME in "${PKG_LIST[@]}"; do
    DIRS=$(find feeds/luci feeds/packages -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
    [ -n "$DIRS" ] && rm -rf "$DIRS"
done

# ==================== 稀疏克隆 ====================
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

# ==================== 5. 拉取软件包 ====================
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

# ==================== 6. 主题+插件 +依赖 ====================
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

LED_INIT="package/luci-app-athena-led/root/etc/init.d/athena_led"
LED_BIN="package/luci-app-athena-led/root/usr/sbin/athena-led"
[ -f "${LED_INIT}" ] && chmod +x "${LED_INIT}"
[ -f "${LED_BIN}" ] && chmod +x "${LED_BIN}"

./scripts/feeds install aria2 nginx python3 libustream-wolfssl

# ==================== 7. Passwall+OpenClash ====================
green "===== 7/15 Setup PassWall & OpenClash ====="
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages
rm -rf feeds/luci/applications/{luci-app-passwall,luci-app-openclash}
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall package/luci-app-passwall
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2 package/luci-app-passwall2
git clone --depth=1 https://github.com/vernesong/OpenClash package/luci-app-openclash
./scripts/feeds install coreutils ca-bundle curl jq libopenssl-legacy

# ==================== 8. 调整启动优先级 ====================
green "===== 8/15 Optimize ALL startup order ====="
optimize_start() {
    local file=$1 start=$2 name=$3
    if [ -f "$file" ]; then
        sed -i "s/START=.*/START=$start/" "$file"
        sed -i "s/USE_PROCD=.*/USE_PROCD=1/" "$file"
        green "   ✓ $name: START=$start"
    else
        yellow "   ⚠ $name init not exist skip"
    fi
}
optimize_start "feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init" 10 "qca-nss-drv"
[ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe && green "   ✓ removed qca-nss-ppe"
optimize_start "feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init" 12 "qca-nss-ecm"
optimize_start "feeds/nss_packages/qca-nss-dp/files/qca-nss-dp.init" 13 "qca-nss-dp"
optimize_start "feeds/nss_packages/qca-ssdk/files/qca-ssdk.init" 14 "qca-ssdk"
optimize_start "package/base-files/files/etc/init.d/boot" 15 "boot"
optimize_start "package/system/zram-swap/files/zram-swap.init" 16 "zram-swap"
optimize_start "package/utils/irqbalance/files/irqbalance.init" 17 "irqbalance"
optimize_start "package/base-files/files/etc/init.d/network" 20 "network"
optimize_start "package/network/services/dnsmasq/files/dnsmasq.init" 21 "dnsmasq"
optimize_start "package/network/services/odhcpd/files/odhcpd.init" 22 "odhcpd"
optimize_start "package/network/config/firewall4/files/firewall.init" 23 "firewall4"
optimize_start "feeds/packages/net/miniupnpd/files/miniupnpd.init" 30 "miniupnpd"
optimize_start "feeds/packages/net/zerotier/files/zerotier.init" 32 "zerotier"
optimize_start "package/network/services/uhttpd/files/uhttpd.init" 40 "uhttpd"
optimize_start "package/system/rpcd/files/rpcd.init" 41 "rpcd"
optimize_start "feeds/packages/net/vlmcsd/files/vlmcsd.init" 50 "vlmcsd"
optimize_start "feeds/packages/utils/ttyd/files/ttyd.init" 51 "ttyd"
optimize_start "feeds/luci/applications/luci-app-autoreboot/root/etc/init.d/autoreboot" 60 "autoreboot"
optimize_start "feeds/luci/applications/luci-app-watchcat/root/etc/init.d/watchcat" 61 "watchcat"
optimize_start "feeds/packages/net/ddns-scripts/files/ddns.init" 75 "ddns"
optimize_start "package/luci-app-openclash/root/etc/init.d/openclash" 80 "openclash"
optimize_start "package/luci-app-passwall/root/etc/init.d/passwall" 81 "passwall"
optimize_start "package/luci-app-passwall2/root/etc/init.d/passwall2" 82 "passwall2"
optimize_start "feeds/packages/net/nginx/files/nginx.init" 85 "nginx"
optimize_start "feeds/packages/net/aria2/files/aria2.init" 88 "aria2"
optimize_start "package/luci-app-athena-led/root/etc/init.d/athena_led" 95 "athena-led"

# ====================9. 编译错误修复 ====================
green "===== 9/15 Fix compile issues ====="
TS=$(find feeds/packages -maxdepth 3 -name tailscale/Makefile 2>/dev/null | head -1)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS" && green "   Tailscale fixed"
RU=$(find feeds/packages -maxdepth 3 -name rust/Makefile 2>/dev/null | head -1)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU" && green "   Rust fixed"

# =========【核心修复：全部预埋配置注释，不再写入固件导致opkg报错】=========
: '
#10 网络固化
#11 MSS脚本
#12 nss-wait
#13 nss-fix
#14 wifi默认参数
#15 cpufreq调频预设
整段配置全部屏蔽，开机后手动配置，彻底消除install 2errors
'

# 最终刷新feed
./scripts/feeds update -a
./scripts/feeds install -a

green "✅ 配置预埋已屏蔽，解决安装阶段2errors，直接编译"
