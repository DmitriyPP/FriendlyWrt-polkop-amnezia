#!/bin/bash
# Выполняется через `source` из каталога project/ на шаге "Apply customizations" (джоб build_friendlywrt).
# Здесь собирается только userspace (rootfs). Ядра на этом этапе нет, поэтому
# модуль AmneziaWG собирается отдельно на втором этапе: scripts/3rd/add_amneziawg.sh.
# Не используем set -e/-u: файл source'ится в оболочку шага.

# --- исходные правки FriendlyElec ---
sed -i -e '/CONFIG_MAKE_TOOLCHAIN=y/d' configs/rockchip/01-nanopi
sed -i -e 's/CONFIG_IB=y/# CONFIG_IB is not set/g' configs/rockchip/01-nanopi
sed -i -e 's/CONFIG_SDK=y/# CONFIG_SDK is not set/g' configs/rockchip/01-nanopi

# --- источники ---
# Официальный amnezia-vpn/amneziawg-openwrt не обновлялся с 2024 года (tools 1.0, без AWG 2.0/3.x).
# Берём поддерживаемый форк с AmneziaWG 3.1: amneziawg-tools 3.1.20260812 + LuCI с параметрами AWG 2.0/3.x.
AWG_OPENWRT_REPO=https://github.com/Slava-Shchipunov/awg-openwrt.git
AWG_OPENWRT_COMMIT=03b62269e2edc168504f057cffaafda11b25ed92   # "feat: add awg v3.1 support"
AWG_TOOLS_EXPECTED=3.1.20260812
PODKOP_REPO=https://github.com/itdoginfo/podkop.git
PODKOP_REF=0.7.24   # релиз (тег) itdoginfo/podkop; это же значение станет версией пакета

custom_pkg_dir=friendlywrt/package/custom
rm -rf "${custom_pkg_dir}" /tmp/podkop-src /tmp/awg-openwrt-src
mkdir -p "${custom_pkg_dir}"

# --- AmneziaWG: tools + LuCI (модуль ядра собирается на этапе build_img) ---
git init -q /tmp/awg-openwrt-src
git -C /tmp/awg-openwrt-src fetch -q --depth 1 "${AWG_OPENWRT_REPO}" "${AWG_OPENWRT_COMMIT}" || exit 1
git -C /tmp/awg-openwrt-src checkout -q FETCH_HEAD || exit 1
mkdir -p "${custom_pkg_dir}/amneziawg"
for p in amneziawg-tools luci-proto-amneziawg; do
	[ -f "/tmp/awg-openwrt-src/${p}/Makefile" ] || { echo "::error::awg-openwrt: нет ${p}/Makefile"; exit 1; }
	cp -a "/tmp/awg-openwrt-src/${p}" "${custom_pkg_dir}/amneziawg/"
done
# kmod из дерева OpenWrt (ядро 6.12) не подходит к вендорскому ядру 6.1 — убираем зависимость на него
sed -i -z -e 's/[[:space:]]*\\\n[[:space:]]*+kmod-amneziawg//g' -e 's/[[:space:]]*+kmod-amneziawg//g' \
	"${custom_pkg_dir}"/amneziawg/*/Makefile
grep -q "^PKG_VERSION:=${AWG_TOOLS_EXPECTED}$" "${custom_pkg_dir}/amneziawg/amneziawg-tools/Makefile" || {
	echo "::error::amneziawg-tools: ожидалась версия ${AWG_TOOLS_EXPECTED}"
	grep '^PKG_VERSION' "${custom_pkg_dir}/amneziawg/amneziawg-tools/Makefile"
	exit 1
}

# --- Podkop: собираем из исходников (25.12 = apk, готовые .ipk не подходят) ---
git clone --depth 1 -b "${PODKOP_REF}" "${PODKOP_REPO}" /tmp/podkop-src || exit 1
for p in podkop luci-app-podkop; do
	[ -f "/tmp/podkop-src/${p}/Makefile" ] || { echo "::error::podkop: нет ${p}/Makefile — структура репозитория изменилась"; exit 1; }
	cp -a "/tmp/podkop-src/${p}" "${custom_pkg_dir}/"
done
# Без PODKOP_VERSION Makefile подставляет дату сборки (0.DDMMYYYY) — задаём версию релиза явно.
# Она же попадает в constants.sh (podkop show_version) и в LuCI (main.js).
sed -i -E "s/^PKG_VERSION[[:space:]]*:?=.*/PKG_VERSION:=${PODKOP_REF}/" \
	"${custom_pkg_dir}/podkop/Makefile" "${custom_pkg_dir}/luci-app-podkop/Makefile"
grep -q "^PKG_VERSION:=${PODKOP_REF}$" "${custom_pkg_dir}/podkop/Makefile" || { echo "::error::podkop: не удалось задать версию"; exit 1; }

# apk (OpenWrt 25.x) не принимает дефис внутри версии: обрезаем всё после дефиса в PKG_VERSION
find "${custom_pkg_dir}" -name Makefile -exec \
	sed -i -E 's/^(PKG_VERSION[:?]?=[^-[:space:]]*)-[^[:space:]]*/\1/' {} +

# --- первичная настройка при первой загрузке ---
# Podkop работает через сервис sing-box и читает /etc/config/sing-box (секция main).
# Гарантируем, что UCI-конфиг и рабочий config.json существуют, sing-box работает от root,
# а запуском sing-box управляет podkop (автостарт самого sing-box выключен).
mkdir -p friendlywrt/files/etc/uci-defaults
cat > friendlywrt/files/etc/uci-defaults/99-podkop-singbox <<'EOF'
#!/bin/sh
[ -f /etc/config/sing-box ] || touch /etc/config/sing-box
uci -q get sing-box.main >/dev/null || uci -q set sing-box.main=sing-box
uci -q get sing-box.main.conffile >/dev/null || uci -q set sing-box.main.conffile='/etc/sing-box/config.json'
uci -q get sing-box.main.workdir  >/dev/null || uci -q set sing-box.main.workdir='/usr/share/sing-box'
uci -q set sing-box.main.enabled='1'
uci -q set sing-box.main.user='root'
uci -q commit sing-box

conf="$(uci -q get sing-box.main.conffile)"
mkdir -p "$(dirname "${conf:-/etc/sing-box/config.json}")" /usr/share/sing-box
[ -s "${conf:-/etc/sing-box/config.json}" ] || echo '{"log":{"level":"warn"}}' > "${conf:-/etc/sing-box/config.json}"

[ -x /etc/init.d/sing-box ] && /etc/init.d/sing-box disable
[ -x /etc/init.d/podkop ] && /etc/init.d/podkop enable
exit 0
EOF

# Wi-Fi: код страны. Без него ядро работает в домене 00, где 5-ГГц каналы помечены NO-IR:
# точка доступа держится только пока подключён клиент-аплинк и гаснет при его обрыве.
# Если /etc/config/wireless ещё не создан, скрипт возвращает 1 и выполнится при следующей загрузке.
cat > friendlywrt/files/etc/uci-defaults/99-wifi-country <<'EOF'
#!/bin/sh
radios=$(uci -q show wireless | sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p")
[ -n "$radios" ] || exit 1
for r in $radios; do
	uci -q get wireless."$r".country >/dev/null || uci -q set wireless."$r".country='RU'
done
uci -q commit wireless
exit 0
EOF
chmod 0755 friendlywrt/files/etc/uci-defaults/99-wifi-country
chmod 0755 friendlywrt/files/etc/uci-defaults/99-podkop-singbox

# --- выбор пакетов ---
sed -i -e '/^CONFIG_PACKAGE_dnsmasq=/d' -e '/CONFIG_PACKAGE_dnsmasq is not set/d' configs/rockchip/01-nanopi
cat >> configs/rockchip/01-nanopi <<'EOF'
# --- custom: Podkop ---
# CONFIG_PACKAGE_dnsmasq is not set
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_sing-box=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_coreutils-base64=y
CONFIG_PACKAGE_bind-dig=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
CONFIG_PACKAGE_podkop=y
CONFIG_PACKAGE_luci-app-podkop=y
CONFIG_PACKAGE_luci-i18n-podkop-ru=y
# --- custom: AmneziaWG 3.1 (userspace; модуль ядра — на этапе build_img) ---
CONFIG_PACKAGE_amneziawg-tools=y
CONFIG_PACKAGE_luci-proto-amneziawg=y
EOF
