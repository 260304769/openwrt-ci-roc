#!/bin/bash
set -e

# 彩色输出
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

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

#稀疏克隆函数（克隆失败直接返回不终止脚本）
git_sparse_clone() {
    local b=$1 u=$2; shift 2
    git clone --depth=1 -b $b --single-branch --filter=blob:none --sparse --timeout=60 "$u" || return 0
    d=$(basename "$u"); cd "$d"
    git sparse-checkout set $*
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

#6.拉取主题+常用插件（加超时+容错）
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

#7.Passwall&OpenClash(源码留存、配置不编译)
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
    yellow "   Add src-git nss_packages https://github.com/qosmio/nss-packages.git into feeds.conf.default"
fi

#9.ath11k启动优先级
green "===== Fix ath11k start order ====="
if [ -f "package/kernel/ath11k/files/ath11k.init" ]; then
    sed -i 's/START=.*/START=60/' package/kernel/ath11k/files/ath11k.init && green "✓ ath11k START=60"
elif [ -f "package/kernel/mac80211/files/ath11k.init" ]; then
    sed -i 's/START=.*/START=60/' package/kernel/mac80211/files/ath11k.init && green "✓ ath11k START=60 (mac80211 path)"
else
    yellow "⚠️ ath11k.init not found, skip"
fi

#10.编译容错(rust/tailscale)
green "===== Fix compile issues ====="
TS=$(find feeds/packages -maxdepth 3 -name tailscale/Makefile 2>/dev/null | head -1)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS" && green "✓ Tailscale fixed"

RU=$(find feeds/packages -maxdepth 3 -name rust/Makefile 2>/dev/null | head -1)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU" && green "✓ Rust fixed"

#最终刷新源
green "===== Final feeds update ====="
./scripts/feeds update -a || true
./scripts/feeds install -a || true

echo ""
green "===== AX5 IPQ6018 512M 补丁全部完成 ====="
echo ""
echo "📌 编译步骤："
echo "   1. rm -f .config"
echo "   2. cat > .config <<'EOF' 粘贴纯英文配置 EOF"
echo "   3. make defconfig"
echo "   4. make download -j8"
echo "   5. make -j\$(nproc)"
