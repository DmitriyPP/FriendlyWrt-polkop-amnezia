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

# build module
rm -rf awg-km
git clone --depth 1 -b "${AWG_KM_REF}" "${AWG_KM_REPO}" awg-km
(cd awg-km/src && {
	export PATH=/opt/FriendlyARM/toolchain/11.3-aarch64:$PATH
	# для ядер 5.6+ модулю нужен полный исходник ядра по симлинку kernel
	ln -sfn "${top_path}/kernel" kernel
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
