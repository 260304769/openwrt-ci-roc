#!/bin/bash
set -e

PKG_PATH=$(pwd)
PKG_LIST=(argon-config wechatpush appfilter frpc frps argon aria2 ariang nginx frp golang open-app-filter)

./scripts/feeds update -a
./scripts/feeds install -a

sed -i 's/192.168.1.1/192.168.10.1/g' package/base-files/files/bin/config_generate
sed -i "s/hostname='.*'/hostname='Roc'/g" package/base-files/files/bin/config_generate
sed -i "s#_('Firmware Version'),.*#_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),#" feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js

#NSS内存64M
DTS_FILE="target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/ipq6018-512m.dtsi"
[ -f "$DTS_FILE" ] && sed -i 's/reg = <0x0 0x4ab00000 0x0 0x[0-9a-f]\+>/reg = <0x0 0x4ab00000 0x0 0x04000000>/' "$DTS_FILE" && echo "NSS reserved 64MB"

#清理原生插件
rm -rf feeds/luci/applications/luci-app-{argon-config,wechatpush,appfilter,frpc,frps} feeds/luci/themes/luci-theme-argon
rm -rf feeds/packages/net/{open-app-filter,ariang,aria2,nginx,frp} feeds/packages/lang/golang
for NAME in "${PKG_LIST[@]}";do
  DIRS=$(find feeds/luci feeds/packages -maxdepth 3 -type d -iname "*$NAME*" 2>/dev/null)
  [ -n "$DIRS" ] && rm -rf $DIRS
done

#稀疏拉取
git_sparse_clone(){
  local b=$1 u=$2;shift 2
  git clone --depth=1 -b $b --single-branch --filter=blob:none --sparse $u
  d=$(basename $u);cd $d;git sparse-checkout set $*;mv $* ../package;cd ..;rm -rf $d
}
git_sparse_clone aria2 https://github.com/laipeng668/packages net/aria2;mv package/aria2 feeds/packages/net
git_sparse_clone nginx https://github.com/laipeng668/packages net/nginx;mv package/nginx feeds/packages/net
git_sparse_clone ariang https://github.com/laipeng668/packages net/ariang;mv package/ariang feeds/packages/net
git_sparse_clone master https://github.com/laipeng668/packages lang/golang;mv package/golang feeds/packages/lang
git_sparse_clone frp-binary https://github.com/laipeng668/packages net/frp;mv package/frp feeds/packages/net
git_sparse_clone frp https://github.com/laipeng668/luci applications/luci-app-frpc applications/luci-app-frps
mv package/luci-app-frpc feeds/luci/applications;mv package/luci-app-frps feeds/luci/applications

#主题&插件
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

#Passwall源码(不编译)
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages package/passwall-packages
rm -rf feeds/luci/applications/{luci-app-passwall,luci-app-openclash}
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall package/luci-app-passwall
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2 package/luci-app-passwall2
git clone --depth=1 https://github.com/vernesong/OpenClash package/luci-app-openclash
echo "baidu.com" > package/luci-app-passwall/luci-app-passwall/root/usr/share/passwall/rules/chnlist

#NSS补丁(关闭nss feed自动跳过)
if [ -d feeds/nss_packages ];then
  f=feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init;[ -f $f ]&&sed -i 's/START=.*/START=45/;s/USE_PROCD=.*/USE_PROCD=1/' $f
  f=feeds/nss_packages/qca-nss-ecm/files/qca-nss-ecm.init;[ -f $f ]&&sed -i 's/START=.*/START=50/' $f||echo "ecm missing skip"
  [ -d feeds/nss_packages/qca-nss-ppe ]&&rm -rf feeds/nss_packages/qca-nss-ppe
fi
f=package/kernel/ath11k/files/ath11k.init;[ -f $f ]&&sed -i 's/START=.*/START=60/' $f

#tailscale/rust容错
TS=$(find feeds/packages -maxdepth 3 -name tailscale/Makefile 2>/dev/null|head -1);[ -f "$TS" ]&&sed -i '/\/files/d' "$TS"
RU=$(find feeds/packages -maxdepth 3 -name rust/Makefile 2>/dev/null|head -1);[ -f "$RU" ]&&sed -i 's/ci-llvm=true/ci-llvm=false/' "$RU"

echo "All patch done!"
