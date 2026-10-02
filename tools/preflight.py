#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Read-only compatibility gate; this does not prove exclusive memory ownership."""
import hashlib
import ctypes as C
import fcntl
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

KERNEL = '7.0.0-1019-nvidia-64k'
DRIVER = '580.178.04'
CONFIG_SHA256 = '66839f60bdf36d6f970cf2b35d34e4a0893d16b7a732803d80a83eb1afbca7bc'
IMAGE_SHA256 = 'ee0285b1ac2d6d1fdf3b7cd928b47ceebbe5ce354eec154dc1f14eba1c67fea6'
DISPLAY = dict(base=0x280200000, size=0x7fe00000, type=0)
UEFI = dict(base=0x300000000, size=0x3000000, type=2)


class Alloc(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ('root', 'parent', 'new', 'cls')] + [
        ('params', C.c_void_p), ('size', C.c_uint32), ('status', C.c_uint32)]


class Control(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ('client', 'object', 'cmd', 'flags')] + [
        ('params', C.c_void_p), ('size', C.c_uint32), ('status', C.c_uint32)]


class Device(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in
                ('id', 'share', 'targetclient', 'targetdevice', 'flags')] + [
        (name, C.c_uint64) for name in ('vasize', 'start', 'limit')] + [
        ('mode', C.c_uint32)]


class Region(C.Structure):
    _fields_ = [('base', C.c_uint64), ('size', C.c_uint64), ('kind', C.c_uint32)]


class Regions(C.Structure):
    _fields_ = [('count', C.c_uint32), ('regions', Region * 8)]


def rm_call(fd, number, argument):
    request = 0xc0000000 | (C.sizeof(argument) << 16) | (ord('F') << 8) | number
    fcntl.ioctl(fd, request, argument)
    if argument.status:
        raise RuntimeError(f'RM operation {number:#x}: status {argument.status:#x}')


def query_regions():
    if C.sizeof(C.c_void_p) != 8:
        raise RuntimeError('64-bit userspace required')
    with open('/dev/nvidiactl', 'rb+', buffering=0) as control:
        with open('/dev/nvidia0', 'rb+', buffering=0) as gpu:
            fcntl.ioctl(gpu.fileno(), 0xc00446c9, C.c_int(control.fileno()))
            allocation = Alloc(0, 0, 0, 0x41, None, 0, 0)
            rm_call(control.fileno(), 0x2b, allocation)
            root = allocation.new
            device = Device()
            rm_call(control.fileno(), 0x2b, Alloc(
                root, root, 0x80000001, 0x80, C.addressof(device),
                C.sizeof(device), 0,
            ))
            subdevice = C.c_uint32()
            rm_call(control.fileno(), 0x2b, Alloc(
                root, 0x80000001, 0x80000002, 0x2080,
                C.addressof(subdevice), C.sizeof(subdevice), 0,
            ))
            regions = Regions()
            rm_call(control.fileno(), 0x2a, Control(
                root, 0x80000002, 0x20801360, 0, C.addressof(regions),
                C.sizeof(regions), 0,
            ))
            if regions.count > len(regions.regions):
                raise RuntimeError('Invalid region count')
            return [
                dict(base=region.base, size=region.size, type=region.kind)
                for region in regions.regions[:regions.count]
            ]


def validate(info):
    expected = dict(arch='aarch64', page_size=65536, kernel=KERNEL,
                    driver=DRIVER, product='NVIDIA_DGX_Spark', vendor='NVIDIA',
                    bios='5.36_0ACUM018', config_sha256=CONFIG_SHA256,
                    image_sha256=IMAGE_SHA256)
    errors = [f'{key}: expected {value!r}, got {info.get(key)!r}'
              for key, value in expected.items() if info.get(key) != value]
    regions = info.get('regions', [])
    if len(regions) != 2 or DISPLAY not in regions or UEFI not in regions:
        errors.append('RM regions differ from the reviewed display + UEFI layout')
    if info.get('reclaim_loaded') is not False:
        errors.append('reclamation already loaded or state unknown; do not replay')
    return errors


def collect():
    kernel = platform.release()
    def dmi(name):
        return Path('/sys/class/dmi/id', name).read_text().strip()
    def sha(path):
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    # This also fails if GPU firmware cannot initialize. No raw host identifiers.
    driver = subprocess.check_output(['nvidia-smi', '--query-gpu=driver_version',
                                     '--format=csv,noheader'], text=True).strip()
    return dict(arch=platform.machine(), page_size=os.sysconf('SC_PAGE_SIZE'),
                kernel=kernel, driver=driver, product=dmi('product_name'),
                vendor=dmi('sys_vendor'), bios=dmi('bios_version'),
                config_sha256=sha(f'/boot/config-{kernel}'),
                image_sha256=sha(f'/boot/vmlinuz-{kernel}'), regions=query_regions(),
                reclaim_loaded=any(Path('/sys/module', m).exists() for m in
                                   ['gb10_reclaim_probe', 'gb10_reclaim_left', 'gb10_reclaim_right']))


def main():
    try:
        info = collect()
        errors = validate(info)
        print(json.dumps(dict(observed=info, compatible=not errors, errors=errors), indent=2))
        if errors:
            return 2
        print('Compatibility matches.', file=sys.stderr)
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Preflight refused: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
