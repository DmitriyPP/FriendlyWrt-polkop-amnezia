#!/bin/bash
# Выполняется через `source` из каталога project/ на шаге "Apply customizations" (джоб build_friendlywrt).
# Здесь собирается только userspace (rootfs). Ядра на этом этапе нет, поэтому
# модуль AmneziaWG собирается отдельно на втором этапе: scripts/3rd/add_amneziawg.sh.
# Не используем set -e/-u: файл source'ится в оболочку шага.

# --- исходные правки FriendlyElec ---
sed -i -e '/CONFIG_MAKE_TOOLCHAIN=y/d' configs/rockchip/01-nanopi
sed -i -e 's/CONFIG_IB=y/# CONFIG_IB is not set/g' configs/rockchip/01-nanopi
sed -i -e 's/CONFIG_SDK=y/# CONFIG_SDK is not set/g' configs/rockchip/01-nanopi

# --- источники (лучше зафиксировать на тегах/коммитах) ---
AWG_OPENWRT_REPO=https://github.com/amnezia-vpn/amneziawg-openwrt.git
AWG_OPENWRT_REF=master
PODKOP_REPO=https://github.com/itdoginfo/podkop.git
PODKOP_REF=main

custom_pkg_dir=friendlywrt/package/custom
rm -rf "${custom_pkg_dir}" /tmp/podkop-src
mkdir -p "${custom_pkg_dir}"

# --- AmneziaWG: только tools + LuCI ---
git clone --depth 1 -b "${AWG_OPENWRT_REF}" "${AWG_OPENWRT_REPO}" "${custom_pkg_dir}/amneziawg-openwrt" || exit 1
# kmod из дерева OpenWrt не совпадёт с вендорским ядром — убираем пакет и зависимость на него
rm -rf "${custom_pkg_dir}/amneziawg-openwrt/kmod-amneziawg"
sed -i -e 's/[[:space:]]*+kmod-amneziawg//g' "${custom_pkg_dir}"/amneziawg-openwrt/*/Makefile

# apk (OpenWrt 25.x) не принимает дефис внутри версии: "0.0.1-1" -> ошибка "package version is invalid".
# Для luci-proto-amneziawg задаём версию явно, до include luci.mk
luci_awg_mk="${custom_pkg_dir}/amneziawg-openwrt/luci-proto-amneziawg/Makefile"
sed -i -E '/^PKG_VERSION[:?]?=/d' "${luci_awg_mk}"
sed -i '1i PKG_VERSION:=0.0.1' "${luci_awg_mk}"

# --- Podkop: собираем из исходников (25.12 = apk, готовые .ipk не подходят) ---
git clone --depth 1 -b "${PODKOP_REF}" "${PODKOP_REPO}" /tmp/podkop-src || exit 1
for p in podkop luci-app-podkop; do
	[ -f "/tmp/podkop-src/${p}/Makefile" ] || { echo "::error::podkop: нет ${p}/Makefile — структура репозитория изменилась"; exit 1; }
	cp -a "/tmp/podkop-src/${p}" "${custom_pkg_dir}/"
done

# Та же защита для всех остальных своих пакетов: обрезаем всё после дефиса в PKG_VERSION
find "${custom_pkg_dir}" -name Makefile -exec \
	sed -i -E 's/^(PKG_VERSION[:?]?=[^-[:space:]]*)-[^[:space:]]*/\1/' {} +

# --- выбор пакетов ---
sed -i -e '/^CONFIG_PACKAGE_dnsmasq=/d' -e '/CONFIG_PACKAGE_dnsmasq is not set/d' configs/rockchip/01-nanopi
cat >> configs/rockchip/01-nanopi <<'EOF'
# --- custom: Podkop ---
# CONFIG_PACKAGE_dnsmasq is not set
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_podkop=y
CONFIG_PACKAGE_luci-app-podkop=y
CONFIG_PACKAGE_luci-i18n-podkop-ru=y
# --- custom: AmneziaWG (userspace, модуль ядра — на этапе build_img) ---
CONFIG_PACKAGE_amneziawg-tools=y
CONFIG_PACKAGE_luci-proto-amneziawg=y
EOF
