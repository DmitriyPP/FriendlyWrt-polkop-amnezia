#!/bin/bash
# scripts/3rd/prepare_aic8800.sh
# Запускается из project/ ПЕРЕД `./build.sh kernel`.
# build-kernel.sh FriendlyElec клонирует драйвер AIC8800 в scripts/sd-fuse/out/aic8800,
# только если этой папки ещё нет. Подкладываем туда свою копию с увеличенным пулом
# буферов переупорядочивания (MAX_REORD_RXFRAME): при его исчерпании драйвер в режиме
# клиента пишет "no pframe" и теряет все входящие пакеты до сброса чипа.
set -eu

AIC_REPO=https://github.com/friendlyarm/aic8800.git
AIC_COMMIT=17b18a83234641f792113ebe5ccbdfef9799d702   # main на 2026-10-12, RELEASE_DATE 2026_0509
AIC_REORD_FRAMES=${AIC_REORD_FRAMES:-2048}             # было 250

dst=scripts/sd-fuse/out/aic8800
rm -rf "$dst"
mkdir -p "$(dirname "$dst")"
git init -q "$dst"
git -C "$dst" fetch -q --depth 1 "$AIC_REPO" "$AIC_COMMIT"
git -C "$dst" checkout -q FETCH_HEAD

for h in aic8800_bsp/aicsdio_txrxif.h aic8800_fdrv/aicwf_txrxif.h; do
	f="$dst/$h"
	[ -f "$f" ] || { echo "::error::aic8800: нет $h — структура репозитория изменилась"; exit 1; }
	sed -i -E "s/^(#define[[:space:]]+MAX_REORD_RXFRAME[[:space:]]+)[0-9]+/\1${AIC_REORD_FRAMES}/" "$f"
	grep -qE "^#define[[:space:]]+MAX_REORD_RXFRAME[[:space:]]+${AIC_REORD_FRAMES}([[:space:]]|$)" "$f" || {
		echo "::error::aic8800: не удалось изменить MAX_REORD_RXFRAME в $h"; exit 1; }
done

# Метка в версии модуля (используется только в MODULE_VERSION) — чтобы на роутере
# `modinfo aic8800_fdrv` показывал, что стоит исправленный драйвер.
find "$dst" -name 'rwnx_version_gen.h' -exec \
	sed -i -E "s/^(#define RWNX_VERS_MOD \"[^\"]*)\"/\1-reord${AIC_REORD_FRAMES}\"/" {} +
grep -rq "reord${AIC_REORD_FRAMES}" "$dst"/aic8800_fdrv/ || { echo "::error::aic8800: метка версии не выставлена"; exit 1; }

echo "aic8800: commit ${AIC_COMMIT}, MAX_REORD_RXFRAME=${AIC_REORD_FRAMES}"
grep -rhE '^#define (MAX_REORD_RXFRAME|RWNX_VERS_MOD)' "$dst"/aic8800_fdrv/ "$dst"/aic8800_bsp/
