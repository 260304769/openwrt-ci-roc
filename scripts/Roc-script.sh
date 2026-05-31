#!/bin/bash
set -euo pipefail

# 彩色输出
red()    { echo -e "\033[31m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }

export OPENWRT_PATH="${OPENWRT_PATH:-$(pwd)}"
green "OPENWRT_PATH set to: $OPENWRT_PATH"
cd "$OPENWRT_PATH" || exit 1

# 精简PKG_LIST，只保留当前配置勾选包
PKG_LIST=(argon-config appfilter frpc frps argon)

# ==================== 1. Feed更新+补全依赖 ====================
green "===== 1/15 Update & Install Feeds ====="
./scripts/feeds update -a
./scripts/feeds install -a
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
rm -rf feeds/luci/applications/luci-app-{argon-config,appfilter,frpc,frps} feeds/luci/themes/luci-theme-argon
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

# ==================== 5. 【关键注释】删除下载/frp/golang拉取（config未启用） ====================
green "===== 5/15 Skip download/frp/nginx/aria2 pull (not selected in .config) ====="

# ==================== 6. 主题+需要的插件 ====================
green "===== 6/15 Pull Theme & Apps ====="
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon feeds/luci/themes/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config feeds/luci/applications/luci-app-argon-config
git clone --depth=1 https://github.com/eamonxg/luci-theme-aurora feeds/luci/themes/luci-theme-aurora
git clone --depth=1 https://github.com/eamonxg/luci-app-aurora-config feeds/luci/applications/luci-app-aurora-config

git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/luci-app-lucky
git clone --depth=1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
git clone --depth=1 https://github.com/NONGFAH/luci-app-athena-led package/luci-app-athena-led

LED_INIT="package/luci-app-athena-led/root/etc/init.d/athena_led"
LED_BIN="package/luci-app-athena-led/root/usr/sbin/athena-led"
[ -f "${LED_INIT}" ] && chmod +x "${LED_INIT}"
[ -f "${LED_BIN}" ] && chmod +x "${LED_BIN}"

# ==================== 7. 【全注释】Passwall+OpenClash 全部屏蔽（.config禁用代理） ====================
green "===== 7/15 Skip Passwall & OpenClash pull (all proxy disabled in config) ====="

# ==================== 8. NSS最优启动时序【核心优化】 ====================
green "===== 8/15 Optimize NSS&System startup order ====="
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

# NSS标准固定启动链：drv→ecm→dp→ssdk
optimize_start "feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init" 10 "qca-nss-drv"
[ -d feeds/nss_packages/qca-nss-ppe ] && rm -rf feeds/nss_packages/qca-nss-ppe && green "   ✓ removed qca-nss-ppe"
optimize_start "feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init" 11 "qca-nss-ecm"
optimize_start "feeds/nss_packages/qca-nss-dp/files/qca-nss-dp.init" 12 "qca-nss-dp"
optimize_start "feeds/nss_packages/qca-ssdk/files/qca-ssdk.init" 13 "qca-ssdk"

# 系统底层
optimize_start "package/base-files/files/etc/init.d/boot" 15 "boot"
optimize_start "package/system/zram-swap/files/zram-swap.init" 16 "zram-swap"
optimize_start "package/utils/irqbalance/files/irqbalance.init" 17 "irqbalance"

# 网络栈
optimize_start "package/base-files/files/etc/init.d/network" 20 "network"
optimize_start "package/network/services/dnsmasq/files/dnsmasq.init" 21 "dnsmasq"
optimize_start "package/network/services/odhcpd/files/odhcpd.init" 22 "odhcpd"
optimize_start "package/network/config/firewall4/files/firewall.init" 23 "firewall4"

# 内网辅助
optimize_start "feeds/packages/net/miniupnpd/files/miniupnpd.init" 30 "miniupnpd"
optimize_start "feeds/packages/net/zerotier/files/zerotier.init" 32 "zerotier"

# WEB面板
optimize_start "package/network/services/uhttpd/files/uhttpd.init" 40 "uhttpd"
optimize_start "package/system/rpcd/files/rpcd.init" 41 "rpcd"

# 系统工具
optimize_start "feeds/packages/net/vlmcsd/files/vlmcsd.init" 50 "vlmcsd"
optimize_start "feeds/packages/utils/ttyd/files/ttyd.init" 51 "ttyd"
optimize_start "feeds/luci/applications/luci-app-autoreboot/root/etc/init.d/autoreboot" 60 "autoreboot"
optimize_start "feeds/luci/applications/luci-app-watchcat/root/etc/init.d/watchcat" 61 "watchcat"

# DDNS
optimize_start "feeds/packages/net/ddns-scripts/files/ddns.init" 75 "ddns"

# 代理全部取消延后（无代理）

# LED末尾
optimize_start "package/luci-app-athena-led/root/etc/init.d/athena_led" 95 "athena-led"

# ====================9. 编译错误修复 ====================
green "===== 9/15 Fix compile issues ====="
TS=$(find feeds/packages -maxdepth 3 -name tailscale/Makefile 2>/dev/null | head -1)
[ -f "$TS" ] && sed -i '/\/files/d' "$TS" && green "   Tailscale fixed"
RU=$(find feeds/packages -maxdepth 3 -name rust/Makefile 2>/dev/null | head -1)
[ -f "$RU" ] && sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU" && green "   Rust fixed"

#====================【1.默认简体中文+上海时区预埋】====================
green "===== Add Default Chinese UI + Shanghai Timezone ====="
mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/95-set-lang <<'EOF'
#!/bin/sh
uci set luci.main.lang=zh_cn
uci set system.@system[0].zonename='Asia/Shanghai'
uci set system.@system[0].timezone='CST-8'
uci commit luci
uci commit system
EOF
chmod +x package/base-files/files/etc/uci-defaults/95-set-lang

#====================【2.内存自动优化+定时释放缓存】====================
green "===== Add Auto Memory Optimize & Auto Free RAM ====="
cat > package/base-files/files/etc/uci-defaults/90-memoptimize <<'EOF'
#!/bin/sh
echo 60 > /proc/sys/vm/swappiness
echo 10 > /proc/sys/vm/dirty_ratio
echo 5 > /proc/sys/vm/dirty_background_ratio
echo 1024 > /proc/sys/vm/min_free_kbytes
grep -q "drop_caches" /etc/crontabs/root || echo "0 */2 * * * sync;echo 3 > /proc/sys/vm/drop_caches" >>/etc/crontabs/root
/etc/init.d/cron enable
EOF
chmod +x package/base-files/files/etc/uci-defaults/90-memoptimize

#====================【3.关键新增：OAF默认配置+hostapd权限 根治开机报错】====================
green "===== Fix OAF & hostapd permission error ====="
cat > package/base-files/files/etc/uci-defaults/92-fix-oaf-hostapd <<'EOF'
#!/bin/sh
#OAF缺配置修复
uci add oaf global
uci set oaf.@global[0].enable='0'
uci commit oaf
#hostapd目录权限
mkdir -p /var/run/hostapd
chmod 755 /var/run/hostapd
#关闭extroot，消除block fstab ubi0_1报错
uci set fstab.@global[0].extroot='0'
uci commit fstab
EOF
chmod +x package/base-files/files/etc/uci-defaults/92-fix-oaf-hostapd

# 最终刷新feed
./scripts/feeds update -a
./scripts/feeds install -a

green "==== Prebuild Script Finished All Fix Done ===="
