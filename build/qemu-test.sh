#!/bin/bash
# Boot-check an AnanasOS ISO. Content checks must pass. Screenshots are saved for review.
set -euo pipefail

ISO="${1:-/mnt/c/Users/miski/AnanasOS-iso/AnanasOS-1.1-amd64.iso}"
OUT="${2:-/mnt/c/Users/miski/AnanasOS-iso/test}"
WORK="${WORK:-$HOME/ananas-build}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Uruchom jako root." >&2
    exit 1
fi
if [ ! -f "$ISO" ]; then
    echo "Brak ISO: $ISO" >&2
    exit 1
fi

mkdir -p "$OUT"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y qemu-system-x86 ovmf squashfs-tools python3-pil sshpass xorriso

fail=0
note() { printf '%s\n' "$*" | tee -a "$OUT/report.txt"; }
bad() { note "BRAK: $*"; fail=1; }

note "ISO: $ISO"
note "Rozmiar: $(du -h "$ISO" | cut -f1)"
xorriso -indev "$ISO" -report_el_torito plain > "$OUT/eltorito.txt"
if ! grep -q 'El Torito' "$OUT/eltorito.txt"; then
    bad "brak nagłówka El Torito"
fi

rm -rf "$WORK/iso-check"
mkdir -p "$WORK/iso-check"
xorriso -osirrox on -indev "$ISO" \
    -extract /casper/filesystem.squashfs "$WORK/iso-check/filesystem.squashfs" \
    -extract /casper/vmlinuz "$WORK/iso-check/vmlinuz" \
    -extract /casper/initrd "$WORK/iso-check/initrd" \
    -extract /boot/grub/grub.cfg "$WORK/iso-check/grub.cfg" \
    -extract /.disk/info "$WORK/iso-check/disk-info"

for needle in "Uruchom AnanasOS" "boot=casper" "quiet splash"; do
    if ! grep -q "$needle" "$WORK/iso-check/grub.cfg"; then
        bad "grub.cfg nie zawiera: $needle"
    fi
done
note "Dysk: $(cat "$WORK/iso-check/disk-info")"

unsquashfs -l "$WORK/iso-check/filesystem.squashfs" > "$WORK/iso-check/files.txt"
need_path() {
    if ! grep -q "$1" "$WORK/iso-check/files.txt"; then
        bad "squashfs nie zawiera $1"
    else
        note "jest $1"
    fi
}
need_path "usr/bin/thunar"
need_path "usr/bin/xfce4-terminal"
need_path "usr/sbin/lightdm"
need_path "usr/bin/calamares"
need_path "usr/local/bin/ananas-appimage"
need_path "usr/share/plymouth/themes/ananas/wordmark.png"
need_path "usr/share/ananas/wallpaper.png"
need_path "usr/share/ananas/login.png"
if grep -q "usr/bin/firefox" "$WORK/iso-check/files.txt"; then
    note "jest firefox"
elif grep -q "usr/bin/falkon" "$WORK/iso-check/files.txt"; then
    note "jest falkon"
else
    bad "brak przeglądarki"
fi
if grep -q "libfuse.so.2" "$WORK/iso-check/files.txt"; then
    note "jest libfuse.so.2"
else
    bad "brak libfuse.so.2 (AppImage)"
fi

screendump() {
    local mon="$1" dest="$2"
    python3 - "$mon" "$dest" << 'PY'
import socket, sys, time
mon, dest = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(20)
s.connect(mon)
time.sleep(0.2)
try:
    s.recv(4096)
except socket.timeout:
    pass
s.sendall(("screendump %s\n" % dest).encode())
time.sleep(1.5)
s.close()
PY
}

boot_qemu() {
    local mode="$1"
    local shotdir="$OUT/$mode"
    mkdir -p "$shotdir"
    local mon="$shotdir/monitor.sock"
    local serial="$shotdir/serial.log"
    rm -f "$mon"
    local -a args=(
        qemu-system-x86_64
        -m 4096 -smp 2
        -cdrom "$ISO" -boot d
        -vga std -display none
        -serial "file:$serial"
        -monitor "unix:$mon,server,nowait"
        -netdev user,id=n0,hostfwd=tcp::2222-:22
        -device virtio-net-pci,netdev=n0
        -name "ananas-$mode"
    )
    if [ -e /dev/kvm ]; then
        args+=(-enable-kvm -cpu host)
    else
        args+=(-cpu qemu64)
    fi
    if [ "$mode" = "uefi" ]; then
        local code="/usr/share/OVMF/OVMF_CODE_4M.fd"
        local vars_src="/usr/share/OVMF/OVMF_VARS_4M.fd"
        if [ ! -f "$code" ]; then
            code="/usr/share/OVMF/OVMF_CODE.fd"
            vars_src="/usr/share/OVMF/OVMF_VARS.fd"
        fi
        cp -f "$vars_src" "$shotdir/vars.fd"
        args+=(-drive "if=pflash,format=raw,readonly=on,file=$code" -drive "if=pflash,format=raw,file=$shotdir/vars.fd")
    fi
    "${args[@]}" > "$shotdir/qemu.log" 2>&1 &
    local qpid=$!
    local i
    for i in 20 45 80 120 180; do
        sleep 25
        if ! kill -0 "$qpid" 2>/dev/null; then
            note "$mode: QEMU zakończył się wcześniej"
            break
        fi
        screendump "$mon" "$shotdir/frame-$i.ppm" || note "$mode: zrzut $i nieudany"
        if [ -f "$shotdir/frame-$i.ppm" ]; then
            python3 - "$shotdir/frame-$i.ppm" "$shotdir/frame-$i.png" << 'PY'
import sys
from PIL import Image
Image.open(sys.argv[1]).save(sys.argv[2])
PY
            note "$mode: zrzut $i"
        fi
    done
    if [ "$mode" = "bios" ]; then
        if sshpass -p ananas ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
            -p 2222 ananas@127.0.0.1 \
            'echo SSH_OK; firefox --version || falkon --version || true; command -v thunar; command -v xfce4-terminal; command -v calamares; command -v ananas-appimage; ldconfig -p | grep libfuse.so.2; systemctl is-active lightdm || true' \
            > "$shotdir/ssh.txt" 2>&1; then
            note "SSH live: OK"
        else
            note "SSH live: niedostępny (zobacz $shotdir/ssh.txt)"
        fi
    fi
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
}

boot_qemu bios
boot_qemu uefi

if [ "$fail" -ne 0 ]; then
    note "Test treści ISO: NIEUDANY"
    exit 1
fi
note "Test treści ISO: OK"
