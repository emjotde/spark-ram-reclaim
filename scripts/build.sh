#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build="$repo/build"
kernel=7.0.0-1019-nvidia-64k
commit=c8e699821c23e4335bf23330a54a23d15cfb95e9
if [[ $(uname -m) != aarch64 || $(uname -r) != "$kernel" ]]; then
    echo "Build only on aarch64 running $kernel with matching headers." >&2; exit 2
fi
if [[ $EUID == 0 ]]; then echo 'Build as an ordinary user, not root.' >&2; exit 2; fi
[[ -d /lib/modules/$kernel/build ]]
for tool in git make gcc-13 python3; do command -v "$tool" >/dev/null; done
mkdir -p "$build/unsigned" "$build/modules/reclaim"
if [[ ! -d "$build/driver" ]]; then
    git clone --depth 1 --branch 580.178.04 https://github.com/NVIDIA/open-gpu-kernel-modules.git "$build/driver"
fi
[[ $(git -C "$build/driver" rev-parse HEAD) == "$commit" ]] || { echo 'Wrong driver source revision' >&2; exit 2; }
# Refuse modified sources; retain the build for inspection instead of overwriting it.
if git -C "$build/driver" diff --quiet; then
    git -C "$build/driver" apply --check "$repo/patches/nvidia-580.178.04-headless-guard.patch"
    git -C "$build/driver" apply "$repo/patches/nvidia-580.178.04-headless-guard.patch"
fi
git -C "$build/driver" diff --binary > "$build/driver.diff"
cmp "$build/driver.diff" "$repo/patches/nvidia-580.178.04-headless-guard.patch"
make -C "$build/driver" -j"${JOBS:-4}" modules CC=gcc-13
cp "$build/driver/kernel-open/nvidia.ko" "$build/unsigned/nvidia-guarded.ko"
cp "$repo/modules/reclaim/"* "$build/modules/reclaim/"
make -C "$build/modules/reclaim" CC=gcc-13
symbols=(init_mm fixmap_lock pgd_pgtable_alloc_init_mm __create_pgd_mapping_locked
         unmap_hotplug_range free_empty_tables memblock_clear_nomap memblock_mark_nomap)
for module in gb10_reclaim_probe gb10_reclaim_left gb10_reclaim_right; do
    rm -f -- "$build/unsigned/$module.ko"
    python3 "$repo/tools/klp_relocate.py" \
        "$build/modules/reclaim/$module.ko" "$build/unsigned/$module.ko" "${symbols[@]}"
done
gcc-13 -O2 -Wall -Wextra -I"$build/driver/src/common/sdk/nvidia/inc" \
    "$repo/tools/allocation_probe.c" -o "$build/allocation_probe"
nvcc=${NVCC:-/usr/local/cuda/bin/nvcc}
"$nvcc" -O2 -arch=sm_121 "$repo/tests/cuda_coverage.cu" -o "$build/cuda_coverage"
(cd "$build/unsigned" && sha256sum ./*.ko > SHA256SUMS)
echo 'Build complete. Nothing installed, signed, enrolled, or loaded.'
