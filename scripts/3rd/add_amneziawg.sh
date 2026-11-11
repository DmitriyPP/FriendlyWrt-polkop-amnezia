#!/bin/bash
# scripts/3rd/add_amneziawg.sh
# Запускается из project/ ПОСЛЕ `./build.sh kernel` (джоб build_img).
# Собирает модуль AmneziaWG out-of-tree против вендорского ядра FriendlyElec
# и кладёт его в rootfs вместе с автозагрузкой. Сделано по образцу add_rtl8852be.sh.
set -eu
top_path=$(pwd)

AWG_KM_REPO=https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
AWG_KM_REF=master   # зафиксируйте коммит, совместимый с amneziawg-tools из custome_config.sh

pushd kernel
kernel_ver=`make CROSS_COMPILE=aarch64-linux-gnu- ARCH=arm64 kernelrelease`
popd
modules_dir=$(readlink -f ./out/output_*_kmodules/lib/modules/${kernel_ver})
[ -d "${modules_dir}" ] || {
	echo "please build kernel first."
	exit 1
}

# Зависимости WireGuard/AWG должны быть в ядре (y или m), иначе модуль не загрузится
for opt in CONFIG_NET_UDP_TUNNEL CONFIG_DST_CACHE CONFIG_CRYPTO_LIB_CURVE25519 CONFIG_CRYPTO_LIB_CHACHA20POLY1305; do
	grep -Eq "^${opt}=(y|m)" kernel/.config || {
		echo "::error::${opt} не включён в ядре. Добавьте CONFIG_WIREGUARD=m через scripts/custome_kernel_config.sh"
		exit 1
	}
done

# Тот же тулчейн, которым FriendlyElec собрал ядро (gcc 11.3, лежит в .../bin)
TOOLCHAIN_BIN=/opt/FriendlyARM/toolchain/11.3-aarch64/bin
if [ ! -x "${TOOLCHAIN_BIN}/aarch64-linux-gnu-gcc" ]; then
	found=$(find /opt/FriendlyARM/toolchain -name aarch64-linux-gnu-gcc -type f 2>/dev/null | head -n1)
	[ -n "${found}" ] || { echo "::error::aarch64-linux-gnu-gcc не найден в /opt/FriendlyARM/toolchain"; exit 1; }
	TOOLCHAIN_BIN=$(dirname "${found}")
fi
export PATH="${TOOLCHAIN_BIN}:${PATH}"
echo "Using compiler: $(command -v aarch64-linux-gnu-gcc)"
aarch64-linux-gnu-gcc --version | head -n1

# build module
rm -rf awg-km
git clone --depth 1 -b "${AWG_KM_REF}" "${AWG_KM_REPO}" awg-km

# Совместимость нового кода AmneziaWG со старым ядром 6.1:
# функции таймеров переименованы в 6.2+ (timer_delete*), в 6.16+ (timer_container_of).
# Заголовок подключается в каждый файл модуля через -include и не трогает само ядро.
compat_h="${top_path}/awg-km/awg_compat_old_kernel.h"
cat > "${compat_h}" <<'EOF'
#ifndef AWG_COMPAT_OLD_KERNEL_H
#define AWG_COMPAT_OLD_KERNEL_H
#include <linux/version.h>
#include <linux/timer.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 2, 0)
#ifndef timer_delete
#define timer_delete(t) del_timer(t)
#endif
#ifndef timer_delete_sync
#define timer_delete_sync(t) del_timer_sync(t)
#endif
#endif
#ifndef timer_container_of
#define timer_container_of(var, t, field) from_timer(var, t, field)
#endif
#endif
EOF

(cd awg-km/src && {
	# для ядер 5.6+ модулю нужен полный исходник ядра по симлинку kernel
	ln -sfn "${top_path}/kernel" kernel
	export KCFLAGS="-include ${compat_h}"
	make CROSS_COMPILE=aarch64-linux-gnu- ARCH=arm64 KERNELDIR="${top_path}/kernel" -j"$(nproc)"
	cp -afv amneziawg.ko "${modules_dir}/"
})

# load module on boot
files_dir="${top_path}/amneziawg"
mkdir -p "${files_dir}/etc/modules.d"
echo "amneziawg" > "${files_dir}/etc/modules.d/50-amneziawg"

# add files to rootfs
if ! grep -q 'FRIENDLYWRT_FILES+=(amneziawg)' .current_config.mk; then
	echo "FRIENDLYWRT_FILES+=(amneziawg)" >> .current_config.mk
fi
