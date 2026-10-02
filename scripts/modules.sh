#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
umask 077

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
command=${1:-}
keydir=${2:-/root/.local/share/gb10-ram-reclaim/keys}
stage=${3:-/root/.local/share/gb10-ram-reclaim/signed}

[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 2; }
[[ $keydir == /* ]] || { echo 'Use an absolute key directory.' >&2; exit 2; }
keydir=$(realpath -m -- "$keydir")
case "$keydir/" in "$repo/"*) echo 'Key directory must be outside the checkout.' >&2; exit 2;; esac

case "$command" in
key)
    [[ ! -e $keydir && ! -L $keydir ]] ||
        { echo 'Key directory exists; refusing overwrite.' >&2; exit 2; }
    install -d -m 0700 -- "$keydir"
    openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
        -subj '/CN=GB10 RAM Reclaim Local Module Key/' \
        -addext 'basicConstraints=critical,CA:FALSE' \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=1.3.6.1.4.1.2312.16.1.2' \
        -keyout "$keydir/module.key" -outform DER -out "$keydir/module.der"
    chmod 0600 "$keydir/module.key" "$keydir/module.der"
    openssl x509 -inform DER -in "$keydir/module.der" \
        -noout -subject -fingerprint -sha256
    echo "Created root-only key in $keydir."
    ;;
sign)
    [[ $stage == /* ]] || { echo 'Use an absolute output directory.' >&2; exit 2; }
    stage=$(realpath -m -- "$stage")
    case "$stage/" in "$repo/"*) echo 'Signed output must be outside the checkout.' >&2; exit 2;; esac
    [[ ! -e $stage && ! -L $stage ]] ||
        { echo 'Signing destination exists; refusing overwrite.' >&2; exit 2; }
    [[ $(stat -c '%u:%a' "$keydir/module.key") == 0:600 ]] ||
        { echo 'Key must be root-owned mode 0600.' >&2; exit 2; }
    sign_file=/lib/modules/7.0.0-1019-nvidia-64k/build/scripts/sign-file
    [[ -x $sign_file ]]
    (cd "$repo/build/unsigned" && sha256sum -c SHA256SUMS)
    install -d -m 0700 -- "$stage"
    for module in nvidia-guarded gb10_reclaim_probe gb10_reclaim_left \
                  gb10_reclaim_right; do
        install -m 0600 -- "$repo/build/unsigned/$module.ko" "$stage/$module.ko"
        "$sign_file" sha256 "$keydir/module.key" "$keydir/module.der" "$stage/$module.ko"
        modinfo -F signer "$stage/$module.ko"
    done
    (cd "$stage" && sha256sum ./*.ko > SHA256SUMS)
    echo "Signed modules in $stage. Nothing was loaded or installed."
    ;;
*)
    echo "Usage: $0 {key|sign} [key-directory] [signed-output-directory]" >&2
    exit 2
    ;;
esac
