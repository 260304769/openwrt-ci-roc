#!/bin/bash
set -e

# ===================== 全局变量定义 =====================
PKG_PATH=$(pwd)

# 需要批量清理的包名列表
PKG_LIST=(
    argon-config wechatpush appfilter frpc frps argon aria2 ariang nginx frp golang open-app-filter
)

# ===================== 第一步：初始化 feeds =====================
echo "===== Update & Install Feeds ====="
./scripts/feeds update -a
./scripts/feeds install -a

# ===================== 基础定制 =====================
sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate

# 还原原版版本显示
sed -i "s#_('Firmware Version'),.*#_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),#" \
feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js

# ===================== AX5 512MB NSS 内存优化 =====================
echo "===== AX5 512MB NSS Memory Optimization ====="

# 修正 NSS 固件路径（qualcommax 目录结构）
DTS_FILE="target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi"
if [ -f "$DTS_FILE" ]; then
    # 为 NSS 预留 64MB 内存（512MB 版本推荐值）
    sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' "$DTS_FILE"
    echo "NSS memory reserved: 64MB"
fi

# ===================== 清理 feeds 原有包 =====================
echo "===== Remove default feeds packages ====="
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf feeds/luci/applications/luci-app-wechatpush
rm -rf feeds/luci/applications/luci-app-appfilter
rm -rf feeds/luci/applications/luci-app-frpc
rm -rf feeds/luci/applications/luci-app-frps
rm -rf feeds/luci/themes/luci-theme-argon
rm -rf feeds/packages/net/open-app-filter
rm -rf feeds/packages/net/ariang
rm -rf feeds/packages/net/aria2
rm -rf feeds/packages/net/nginx
rm -rf feeds/packages/net/frp
rm -rf feeds/packages/lang/golang

# 批量模糊删除匹配目录
for NAME in "${PKG_LIST[@]}"; do
    echo "Search directory: $NAME"
    FOUND_DIRS=$(find feeds/luci/ feeds/packages/ -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
    if [ -n "$FOUND_DIRS" ]; then
        while read -r DIR; do
            rm -rf "$DIR"
            echo "Delete directory: $DIR"
        done <<< "$FOUND_DIRS"
    else
        echo "Not found directory: $NAME"
    fi
done

# ===================== 稀疏克隆函数 =====================
git_sparse_clone() {
    local branch="$1" repourl="$2"
    shift 2
    git clone --depth=1 -b "$branch" --single-branch --filter=blob:none --sparse "$repourl"
    local repodir=$(basename "$repourl")
    cd "$repodir"
    git sparse-checkout set "$@"
    mv -f "$@" ../package/
    cd ..
    rm -rf "$repodir"
}

# ===================== 拉取替换包 =====================
echo "===== Pull custom packages ====="

# Aria2 / Nginx / AriaNG / Golang / Frp
git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2
mv -f package/aria2 feeds/packages/net/aria2

git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx
mv -f package/nginx feeds/packages/net/nginx

git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang
mv -f package/ariang feeds/packages/net/ariang

git_sparse_clone master https://github.com/laipeng668/packages lang/golang
mv -f package/golang feeds/packages/lang/golang

git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp
mv -f package/frp feeds/packages/net/frp

git_sparse_clone frp https://github.com/laipeng668/luci applications/luci-app-frpc applications/luci-app-frps
mv -f package/luci-app-frpc feeds/luci/applications/luci-app-frpc
mv -f package/luci-app-frps feeds/luci/applications/luci-app-frps

# 主题 & 插件
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

chmod +x package/luci-app-athena-led/root/etc/init.d/athena_led package/luci-app-athena-led/root/usr/sbin/athena-led

# ===================== PassWall & OpenClash =====================
echo "===== Setup PassWall & OpenClash ====="

rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages

rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/luci/applications/luci-app-openclash
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall package/luci-app-passwall
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2 package/luci-app-passwall2
git clone --depth=1 https://github.com/vernesong/OpenClash package/luci-app-openclash

# 清空 PassWall 国内列表
echo "baidu.com" > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

# ===================== NSS 服务启动顺序修正（AX5 关键） =====================
echo "===== Fix NSS init start order for AX5 ====="

# 修正 qca-nss-drv 启动顺序（必须在网络启动前）
NSS_DRV_INIT="feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
if [ -f "$NSS_DRV_INIT" ]; then
    sed -i 's/START=.*/START=45/' "$NSS_DRV_INIT"
    sed -i 's/USE_PROCD=.*/USE_PROCD=1/' "$NSS_DRV_INIT"
    echo "qca-nss-drv init fixed (START=45)"
fi

# 修正 qca-nss-ecm 连接管理器
NSS_ECM_INIT="feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init"
if [ -f "$NSS_ECM_INIT" ]; then
    sed -i 's/START=.*/START=50/' "$NSS_ECM_INIT"
    echo "qca-nss-ecm init fixed (START=50)"
fi

# 修正 ath11k 无线驱动启动顺序（必须在 NSS 之后）
ATH11K_INIT="package/kernel/ath11k/files/ath11k.init"
if [ -f "$ATH11K_INIT" ]; then
    sed -i 's/START=.*/START=60/' "$ATH11K_INIT"
    echo "ath11k init fixed (START=60)"
fi

# ===================== 修复 Tailscale 配置冲突 =====================
TS_FILE=$(find feeds/packages/ -maxdepth 3 -type f -wholename "*/tailscale/Makefile" 2>/dev/null | head -1)
if [ -f "$TS_FILE" ]; then
    sed -i '/\/files/d' "$TS_FILE"
    echo "Tailscale config fixed!"
fi

# ===================== 修复 Rust 编译失败 =====================
RUST_FILE=$(find feeds/packages/ -maxdepth 3 -type f -wholename "*/rust/Makefile" 2>/dev/null | head -1)
if [ -f "$RUST_FILE" ]; then
    sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"
    echo "Rust compile fixed!"
fi

# ===================== AX5 特定：禁用 ipq807x 不兼容的驱动 =====================
echo "===== AX5 specific fixes ====="

# 移除可能冲突的 qca-nss-ppe 驱动（AX5 不需要）
PPE_DRV="feeds/nss_packages/qca-nss-ppe"
if [ -d "$PPE_DRV" ]; then
    rm -rf "$PPE_DRV"
    echo "Removed qca-nss-ppe (not needed for AX5)"
fi

# ===================== 最后再执行一次 feeds 刷新 =====================
echo "===== Final feeds update ====="
./scripts/feeds update -a
./scripts/feeds install -a

echo "===== All patch done for AX5 512MB! ====="
