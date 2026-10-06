#!/bin/bash
# Build the AnanasOS hybrid live ISO (BIOS + UEFI) on Ubuntu 24.04.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$HOME/ananas-build}"
CHROOT="$WORK/chroot"
if [ -z "$CHROOT" ] || [ "$CHROOT" = "/" ] || [ "$CHROOT" = "/mnt" ]; then
    echo "Zła ścieżka chroot." >&2
    exit 1
fi
ISO_ROOT="$WORK/iso"
STAMPS="$WORK/stamps"
LOG="$WORK/build.log"

if [ -d /mnt/c/Users/miski ]; then
    OUT_DIR="${OUT_DIR:-/mnt/c/Users/miski/AnanasOS-iso}"
else
    OUT_DIR="${OUT_DIR:-$WORK/output}"
fi
OUT_ISO="$OUT_DIR/AnanasOS-1.0-amd64.iso"

mkdir -p "$WORK" "$STAMPS" "$OUT_DIR"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Uruchom jako root: sudo bash $0" >&2
    exit 1
fi

case "$WORK" in
    /mnt/*)
        echo "Katalog roboczy nie może leżeć na /mnt (OneDrive). Ustaw WORK na dysk ext4." >&2
        exit 1
        ;;
esac

stages=(host debootstrap packages configure squash iso)
if [ -n "${FORCE_FROM:-}" ]; then
    drop=0
    for stage in "${stages[@]}"; do
        if [ "$stage" = "$FORCE_FROM" ]; then
            drop=1
        fi
        if [ "$drop" = 1 ]; then
            rm -f "$STAMPS/$stage"
        fi
    done
fi

stage_done() { [ -f "$STAMPS/$1" ]; }
mark() { mkdir -p "$STAMPS"; touch "$STAMPS/$1"; }

umount_chroot() {
    local point
    for point in "$CHROOT/dev/pts" "$CHROOT/dev" "$CHROOT/proc" "$CHROOT/sys" "$CHROOT/run"; do
        if mountpoint -q "$point" 2>/dev/null; then
            umount -lf "$point" || true
        fi
    done
}
trap umount_chroot EXIT

mount_chroot() {
    mkdir -p "$CHROOT/dev" "$CHROOT/proc" "$CHROOT/sys" "$CHROOT/run" "$CHROOT/dev/pts"
    mountpoint -q "$CHROOT/dev" || mount --bind /dev "$CHROOT/dev"
    mountpoint -q "$CHROOT/dev/pts" || mount -t devpts devpts "$CHROOT/dev/pts"
    mountpoint -q "$CHROOT/proc" || mount -t proc proc "$CHROOT/proc"
    mountpoint -q "$CHROOT/sys" || mount -t sysfs sys "$CHROOT/sys"
    mountpoint -q "$CHROOT/run" || mount --bind /run "$CHROOT/run"
    if [ -e /etc/resolv.conf ]; then
        mkdir -p "$CHROOT/etc"
        rm -f "$CHROOT/etc/resolv.conf"
        cp -L /etc/resolv.conf "$CHROOT/etc/resolv.conf"
    fi
}

chroot_do() {
    chroot "$CHROOT" env DEBIAN_FRONTEND=noninteractive "$@"
}

apt_install() {
    if chroot_do apt-get install -y "$@"; then
        return 0
    fi
    log "apt: ponawiam konfigurację pakietów"
    mount_chroot
    chroot_do dpkg --configure -a || true
    chroot_do apt-get install -y "$@"
}

stage_host() {
    if stage_done host; then
        log "host: pomijam"
        return
    fi
    log "host: narzędzia do złożenia ISO"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        debootstrap ubuntu-keyring squashfs-tools xorriso \
        grub-pc-bin grub-efi-amd64-bin grub-common \
        mtools dosfstools python3-pil fonts-dejavu-core \
        ca-certificates wget gnupg rsync
    mark host
}

stage_debootstrap() {
    if stage_done debootstrap; then
        log "debootstrap: pomijam"
        return
    fi
    if [ -f "$CHROOT/etc/debian_version" ] && [ ! -d "$CHROOT/debootstrap" ]; then
        log "debootstrap: katalog już istnieje, uznaję za gotowy"
        mark debootstrap
        return
    fi
    if [ -d "$CHROOT" ]; then
        log "debootstrap: usuwam niedokończony katalog"
        umount_chroot
        rm -rf "$CHROOT"
    fi
    log "debootstrap: Ubuntu 24.04 (noble)"
    debootstrap --arch=amd64 --variant=minbase noble "$CHROOT" http://archive.ubuntu.com/ubuntu
    mark debootstrap
}

write_sources() {
    cat > "$CHROOT/etc/apt/sources.list" << 'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
    cat > "$CHROOT/etc/apt/apt.conf.d/99ananas" << 'EOF'
Acquire::Retries "5";
Acquire::http::Timeout "30";
APT::Install-Recommends "true";
EOF
    cat > "$CHROOT/etc/apt/preferences.d/no-snap.pref" << 'EOF'
Package: snapd
Pin: release *
Pin-Priority: -1
EOF
}

stage_packages() {
    if stage_done packages; then
        log "packages: pomijam"
        return
    fi
    log "packages: system, pulpit, instalator, Firefox"
    mount_chroot
    write_sources
    chroot_do apt-get update
    printf '%s\n' \
        'lightdm shared/default-x-display-manager select lightdm' \
        'tzdata tzdata/Areas select Europe' \
        'tzdata tzdata/Zones/Europe select Warsaw' \
        'keyboard-configuration keyboard-configuration/layoutcode string pl' \
        'keyboard-configuration keyboard-configuration/modelcode string pc105' \
        'locales locales/locales_to_be_generated multiselect pl_PL.UTF-8 UTF-8, en_US.UTF-8 UTF-8' \
        'locales locales/default_environment_locale select pl_PL.UTF-8' \
        | chroot_do debconf-set-selections || true
    apt_install systemd systemd-sysv sudo adduser passwd ca-certificates wget gnupg

    apt_install \
        linux-generic linux-firmware intel-microcode amd64-microcode \
        casper os-prober \
        grub-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed shim-signed \
        plymouth network-manager network-manager-gnome \
        locales tzdata keyboard-configuration console-setup \
        bash-completion nano less htop curl wget ca-certificates gnupg \
        unzip zip file-roller dosfstools e2fsprogs parted efibootmgr rsync \
        openssh-server

    apt_install \
        xorg xserver-xorg mesa-utils mesa-vulkan-drivers \
        xfce4 xfce4-terminal xfce4-power-manager xfce4-pulseaudio-plugin \
        xfce4-screenshooter thunar thunar-archive-plugin thunar-volman \
        mousepad lightdm lightdm-gtk-greeter dbus-x11 \
        policykit-1 polkitd pkexec mate-polkit \
        gvfs gvfs-backends gvfs-fuse udisks2 ntfs-3g \
        pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol \
        fuse3 libfuse2t64 \
        fonts-dejavu fonts-noto-core fonts-noto-color-emoji \
        language-pack-pl language-pack-en \
        yaru-theme-gtk yaru-theme-icon \
        desktop-file-utils shared-mime-info xdg-user-dirs xdg-utils \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        libxcb-xinerama0 libxcb-cursor0

    apt_install --no-install-recommends calamares gparted || \
        apt_install calamares gparted

    if ! apt_install qt6-gtk-platformtheme; then
        log "packages: brak qt6-gtk-platformtheme, jadę dalej"
    fi

    log "packages: Firefox z repozytorium Mozilli"
    chroot_do install -d -m 0755 /etc/apt/keyrings
    wget -qO "$CHROOT/etc/apt/keyrings/packages.mozilla.org.asc" \
        https://packages.mozilla.org/apt/repo-signing-key.gpg
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > "$CHROOT/etc/apt/sources.list.d/mozilla.list"
    cat > "$CHROOT/etc/apt/preferences.d/mozilla.pref" << 'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
    chroot_do apt-get update
    if apt_install firefox; then
        apt_install firefox-l10n-pl || log "packages: brak polskiego pakietu Firefoxa"
    else
        log "packages: Mozilla Firefox niedostępny, instaluję Falkon"
        apt_install falkon
    fi

    mark packages
}

strip_cr() {
    local path
    while IFS= read -r -d '' path; do
        case "$path" in
            *.png|*.jpg|*.jpeg|*.gif|*.webp|*.gz|*.ko|*.ko.zst|*.so) continue ;;
        esac
        sed -i 's/\r$//' "$path" || true
    done < <(find "$@" -type f -print0 2>/dev/null || true)
}

stage_configure() {
    if stage_done configure; then
        log "configure: pomijam"
        return
    fi
    log "configure: motyw, logowanie, instalator"
    mount_chroot

    python3 "$SRC/scripts/make-boot-artwork.py" \
        --logo "$SRC/logo.png" \
        --out "$WORK/artwork"

    mkdir -p \
        "$CHROOT/usr/share/ananas" \
        "$CHROOT/usr/share/plymouth/themes/ananas" \
        "$CHROOT/usr/share/icons/hicolor/256x256/apps" \
        "$CHROOT/usr/local/bin" \
        "$CHROOT/usr/local/sbin" \
        "$CHROOT/etc/lightdm/lightdm.conf.d" \
        "$CHROOT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml" \
        "$CHROOT/etc/xdg/Thunar" \
        "$CHROOT/etc/calamares/branding/ananas" \
        "$CHROOT/etc/calamares/modules" \
        "$CHROOT/etc/polkit-1/rules.d" \
        "$CHROOT/etc/skel/.config" \
        "$CHROOT/usr/share/applications" \
        "$CHROOT/usr/share/mime/packages" \
        "$CHROOT/etc/xdg/autostart" \
        "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom"

    install -m 0644 "$WORK/artwork/wallpaper.png" "$CHROOT/usr/share/ananas/wallpaper.png"
    install -m 0644 "$WORK/artwork/login.png" "$CHROOT/usr/share/ananas/login.png"
    install -m 0644 "$WORK/artwork/login-live.png" "$CHROOT/usr/share/ananas/login-live.png"
    install -m 0644 "$WORK/artwork/grub-background.png" "$CHROOT/usr/share/ananas/grub-background.png"
    install -m 0644 "$WORK/artwork/icon-256.png" "$CHROOT/usr/share/ananas/icon-256.png"
    install -m 0644 "$WORK/artwork/icon-256.png" "$CHROOT/usr/share/icons/hicolor/256x256/apps/ananas.png"
    install -m 0644 "$WORK/artwork/logo-trimmed.png" "$CHROOT/usr/share/ananas/logo.png"
    install -m 0644 "$WORK/artwork/plymouth-splash.png" "$CHROOT/usr/share/plymouth/themes/ananas/logo.png"
    install -m 0644 "$WORK/artwork/plymouth-wordmark.png" "$CHROOT/usr/share/plymouth/themes/ananas/wordmark.png"
    install -m 0644 "$SRC/branding/plymouth/ananas.plymouth" "$CHROOT/usr/share/plymouth/themes/ananas/ananas.plymouth"
    install -m 0644 "$SRC/branding/plymouth/ananas.script" "$CHROOT/usr/share/plymouth/themes/ananas/ananas.script"

    cp -a "$SRC/branding/etc/." "$CHROOT/etc/"
    install -m 0644 "$SRC/branding/lightdm/lightdm.conf" "$CHROOT/etc/lightdm/lightdm.conf"
    install -m 0644 "$SRC/branding/lightdm/lightdm-gtk-greeter.conf" "$CHROOT/etc/lightdm/lightdm-gtk-greeter.conf"
    install -m 0644 "$SRC/branding/xfce/xfce4-desktop.xml" \
        "$CHROOT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
    install -m 0644 "$SRC/branding/xfce/xsettings.xml" \
        "$CHROOT/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml"
    install -m 0644 "$SRC/branding/xfce/mimeapps.list" "$CHROOT/etc/xdg/mimeapps.list"
    install -m 0644 "$SRC/branding/xfce/mimeapps.list" "$CHROOT/etc/skel/.config/mimeapps.list"
    install -m 0755 "$SRC/branding/xfce/ananas-wallpaper" "$CHROOT/usr/local/bin/ananas-wallpaper"
    install -m 0644 "$SRC/branding/xfce/ananas-wallpaper.desktop" \
        "$CHROOT/etc/xdg/autostart/ananas-wallpaper.desktop"
    install -m 0644 "$SRC/branding/appimage/uca.xml" "$CHROOT/etc/xdg/Thunar/uca.xml"
    install -m 0755 "$SRC/branding/appimage/ananas-appimage" "$CHROOT/usr/local/bin/ananas-appimage"
    install -m 0644 "$SRC/branding/appimage/ananas-appimage.desktop" \
        "$CHROOT/usr/share/applications/ananas-appimage.desktop"
    install -m 0644 "$SRC/branding/appimage/ananas-appimage.xml" \
        "$CHROOT/usr/share/mime/packages/ananas-appimage.xml"
    install -m 0755 "$SRC/branding/live/ananas-live-desktop" "$CHROOT/usr/local/bin/ananas-live-desktop"
    install -m 0755 "$SRC/branding/live/ananas-remove-live-user" "$CHROOT/usr/local/sbin/ananas-remove-live-user"
    install -m 0755 "$SRC/branding/live/99ananas" \
        "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom/99ananas"
    install -m 0644 "$SRC/branding/live/ananas-live-desktop.desktop" \
        "$CHROOT/etc/xdg/autostart/ananas-live-desktop.desktop"
    install -m 0755 "$SRC/branding/live/ananas-install.desktop" \
        "$CHROOT/usr/share/applications/ananas-install.desktop"
    install -m 0755 "$SRC/branding/live/ananas-plymouth-quit" \
        "$CHROOT/usr/local/bin/ananas-plymouth-quit"
    install -m 0755 "$SRC/branding/live/ananas-live-autologin" \
        "$CHROOT/usr/local/sbin/ananas-live-autologin"
    install -m 0644 "$SRC/branding/live/ananas-live-autologin.service" \
        "$CHROOT/etc/systemd/system/ananas-live-autologin.service"
    mkdir -p "$CHROOT/etc/systemd/system/graphical.target.wants"
    ln -sfn /etc/systemd/system/ananas-live-autologin.service \
        "$CHROOT/etc/systemd/system/graphical.target.wants/ananas-live-autologin.service"
    ln -sfn /dev/null "$CHROOT/etc/systemd/system/getty@tty1.service"
    install -m 0644 "$SRC/branding/live/49-ananas-live.rules" \
        "$CHROOT/etc/polkit-1/rules.d/49-ananas-live.rules"

    install -m 0644 "$SRC/branding/calamares/settings.conf" "$CHROOT/etc/calamares/settings.conf"
    install -m 0644 "$SRC/branding/calamares/branding.desc" "$CHROOT/etc/calamares/branding/ananas/branding.desc"
    install -m 0644 "$WORK/artwork/logo-trimmed.png" "$CHROOT/etc/calamares/branding/ananas/logo.png"
    cp -a "$SRC/branding/calamares/modules/." "$CHROOT/etc/calamares/modules/"
    printf 'AnanasOS 1.0\nBased on Ubuntu 24.04 LTS\n' > "$CHROOT/etc/ananasos-release"

    strip_cr \
        "$CHROOT/usr/local" \
        "$CHROOT/usr/share/plymouth/themes/ananas" \
        "$CHROOT/usr/share/applications/ananas-install.desktop" \
        "$CHROOT/usr/share/applications/ananas-appimage.desktop" \
        "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom/99ananas" \
        "$CHROOT/etc/calamares" \
        "$CHROOT/etc/lightdm" \
        "$CHROOT/etc/xdg" \
        "$CHROOT/etc/polkit-1/rules.d/49-ananas-live.rules" \
        "$CHROOT/etc/casper.conf" \
        "$CHROOT/etc/os-release" \
        "$CHROOT/etc/lsb-release" \
        "$CHROOT/etc/issue" \
        "$CHROOT/etc/motd" \
        "$CHROOT/etc/hostname" \
        "$CHROOT/etc/hosts" \
        "$CHROOT/etc/default" \
        "$CHROOT/etc/plymouth/plymouthd.conf" \
        "$CHROOT/etc/ssh/sshd_config.d/ananas.conf" \
        "$CHROOT/etc/ananasos-release"

    printf '%s\n' \
        'lightdm shared/default-x-display-manager select lightdm' \
        'tzdata tzdata/Areas select Europe' \
        'tzdata tzdata/Zones/Europe select Warsaw' \
        'keyboard-configuration keyboard-configuration/layoutcode string pl' \
        'keyboard-configuration keyboard-configuration/modelcode string pc105' \
        | chroot_do debconf-set-selections || true

    sed -i 's/^# *\(pl_PL.UTF-8 UTF-8\)/\1/' "$CHROOT/etc/locale.gen"
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' "$CHROOT/etc/locale.gen"
    if ! grep -q '^pl_PL.UTF-8 UTF-8' "$CHROOT/etc/locale.gen"; then
        echo 'pl_PL.UTF-8 UTF-8' >> "$CHROOT/etc/locale.gen"
    fi
    if ! grep -q '^en_US.UTF-8 UTF-8' "$CHROOT/etc/locale.gen"; then
        echo 'en_US.UTF-8 UTF-8' >> "$CHROOT/etc/locale.gen"
    fi
    ln -sfn /usr/share/zoneinfo/Europe/Warsaw "$CHROOT/etc/localtime"
    echo Europe/Warsaw > "$CHROOT/etc/timezone"
    chroot_do locale-gen
    chroot_do update-locale LANG=pl_PL.UTF-8

    chroot_do apt-get purge -y gdm3 gnome-shell ubuntu-session || true
    chroot_do apt-get autoremove -y || true
    rm -f "$CHROOT/etc/systemd/system/multi-user.target.wants/casper-md5check.service"
    mkdir -p "$CHROOT/etc/systemd/system/casper-md5check.service.d"
    cat > "$CHROOT/etc/systemd/system/casper-md5check.service.d/disable.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=/bin/true
EOF
    chroot_do systemctl enable lightdm NetworkManager systemd-resolved || true
    chroot_do systemctl disable gdm3 || true
    chroot_do systemctl mask gdm3 || true
    ln -sfn /lib/systemd/system/lightdm.service \
        "$CHROOT/etc/systemd/system/display-manager.service"
    chroot_do systemctl disable systemd-networkd systemd-networkd-wait-online || true
    chroot_do systemctl disable ssh || true
    ln -sfn /lib/systemd/system/graphical.target "$CHROOT/etc/systemd/system/default.target"
    printf '/usr/sbin/lightdm\n' > "$CHROOT/etc/X11/default-display-manager"

    chroot_do update-mime-database /usr/share/mime || true
    chroot_do update-desktop-database /usr/share/applications || true
    chroot_do gtk-update-icon-cache -f /usr/share/icons/hicolor || true

    if [ -d "$CHROOT/usr/lib/calamares/modules" ]; then
        log "configure: moduły Calamares"
        ls "$CHROOT/usr/lib/calamares/modules" | tee "$WORK/calamares-modules.txt" || true
    else
        find "$CHROOT/usr/lib" -path '*calamares*' -name '*.so' | tee "$WORK/calamares-modules.txt" || true
    fi

    if [ -f "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom/15autologin" ]; then
        sed -i 's/if \[ -f \$GDMCustomFile \]; then/if false; then/' \
            "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom/15autologin"
    fi
    if [ -f "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom/25adduser" ]; then
        sed -i 's|chroot /root /usr/lib/user-setup/user-setup-apply|db_set passwd/auto-login false\nchroot /root /usr/lib/user-setup/user-setup-apply|' \
            "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom/25adduser"
        python3 - "$CHROOT/usr/share/initramfs-tools/scripts/casper-bottom/25adduser" << 'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text()
old = "db_set passwd/user-password-crypted U6aMy0wojraho"
new = "db_set passwd/user-password-crypted '$6$UrKizi2pblvKGaxx$aRSU8GBIhepui8tkqDP9Zc36WVnYpbFsQCt1S0rlSSioUw.detTlC9kgZX6BPlUY1uNf4QPcodl2YHEp2.0Ge.'"
if old in text:
    text = text.replace(old, new, 1)
text = text.replace('if [ ! -f /root/usr/bin/sddm ]; then\n    chroot /root passwd -d "$USERNAME"\nfi\n', '')
text = text.replace('if [ ! -f /root/usr/bin/sddm ]; then\nfi\n', '')
p.write_text(text)
PY
    fi
    chroot_do update-alternatives --install \
        /usr/share/images/desktop-base/desktop-background desktop-background \
        /usr/share/ananas/wallpaper.png 200
    chroot_do update-alternatives --set desktop-background /usr/share/ananas/wallpaper.png
    if [ -d "$CHROOT/usr/share/desktop-base/profiles/xdg-config/xfce4/xfconf/xfce-perchannel-xml" ]; then
        install -m 0644 "$SRC/branding/xfce/xfce4-desktop.xml" \
            "$CHROOT/usr/share/desktop-base/profiles/xdg-config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
    fi

    log "configure: Plymouth i initramfs"
    rm -f "$CHROOT/usr/share/plymouth/themes/default.plymouth"
    chroot_do update-alternatives --install \
        /usr/share/plymouth/themes/default.plymouth default.plymouth \
        /usr/share/plymouth/themes/ananas/ananas.plymouth 200
    chroot_do update-alternatives --set default.plymouth \
        /usr/share/plymouth/themes/ananas/ananas.plymouth
    if [ -f "$CHROOT/usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth" ]; then
        chroot_do update-alternatives --install \
            /usr/share/plymouth/themes/text.plymouth text.plymouth \
            /usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth 100 || true
    fi
    chroot_do update-initramfs -u

    mark configure
}

shrink_rootfs() {
    log "squash: porządki rozmiaru"
    rm -rf \
        "$CHROOT/usr/lib/firmware/nvidia" \
        "$CHROOT/lib/firmware/nvidia" \
        "$CHROOT/usr/lib/firmware/amdgpu" \
        "$CHROOT/lib/firmware/amdgpu" \
        "$CHROOT/usr/lib/firmware/radeon" \
        "$CHROOT/lib/firmware/radeon"
    chroot_do apt-get clean || true
    rm -rf "$CHROOT/var/lib/apt/lists/"* "$CHROOT/var/cache/apt/archives/"*.deb
    mkdir -p "$CHROOT/var/lib/apt/lists/partial"
    find "$CHROOT/var/log" -type f -delete || true
    rm -rf "$CHROOT/tmp/"* "$CHROOT/root/.bash_history"
    find "$CHROOT/usr/share/doc" -type f ! -name copyright -delete || true
    find "$CHROOT/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
        ! -name pl ! -name pl_PL ! -name en ! -name en_US ! -name en_GB \
        -exec rm -rf {} + || true
    : > "$CHROOT/etc/machine-id"
    rm -f "$CHROOT/var/lib/dbus/machine-id"
    ln -sfn /etc/machine-id "$CHROOT/var/lib/dbus/machine-id"
    rm -f "$CHROOT/etc/resolv.conf"
    ln -sfn /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
}

stage_squash() {
    if stage_done squash; then
        log "squash: pomijam"
        return
    fi
    umount_chroot
    shrink_rootfs
    mkdir -p "$ISO_ROOT/casper"
    rm -f "$ISO_ROOT/casper/filesystem.squashfs"
    log "squash: pakowanie (to trwa)"
    mksquashfs "$CHROOT" "$ISO_ROOT/casper/filesystem.squashfs" \
        -comp zstd -Xcompression-level 19 -noappend -b 1M \
        -e boot/grub
    printf '%s' "$(du -sx --block-size=1 "$CHROOT" | cut -f1)" > "$ISO_ROOT/casper/filesystem.size"
    dpkg-query --admindir="$CHROOT/var/lib/dpkg" -W --showformat='${Package} ${Version}\n' \
        > "$ISO_ROOT/casper/filesystem.manifest"
    mark squash
}

copy_kernel() {
    local kver kernel initrd
    kver="$(ls "$CHROOT/lib/modules" | sort -V | tail -1)"
    kernel="$CHROOT/boot/vmlinuz-$kver"
    initrd="$CHROOT/boot/initrd.img-$kver"
    if [ ! -f "$kernel" ] || [ ! -f "$initrd" ]; then
        echo "Brak kernela albo initrd dla $kver" >&2
        exit 1
    fi
    cp -f "$kernel" "$ISO_ROOT/casper/vmlinuz"
    cp -f "$initrd" "$ISO_ROOT/casper/initrd"
    log "iso: kernel $kver"
}

make_boot_images() {
    local shim="" grubefi="" mm="" embedded
    mkdir -p "$ISO_ROOT/boot/grub/fonts" "$ISO_ROOT/boot/grub/i386-pc" "$ISO_ROOT/EFI/BOOT" "$ISO_ROOT/EFI/ubuntu"

    if [ -d "$CHROOT/usr/lib/grub/i386-pc" ]; then
        cp -a "$CHROOT/usr/lib/grub/i386-pc/." "$ISO_ROOT/boot/grub/i386-pc/"
    else
        cp -a /usr/lib/grub/i386-pc/. "$ISO_ROOT/boot/grub/i386-pc/"
    fi
    if [ -d "$CHROOT/usr/lib/grub/x86_64-efi" ]; then
        mkdir -p "$ISO_ROOT/boot/grub/x86_64-efi"
        cp -a "$CHROOT/usr/lib/grub/x86_64-efi/." "$ISO_ROOT/boot/grub/x86_64-efi/"
    fi

    embedded="$WORK/embedded.cfg"
    sed 's/\r$//' "$SRC/branding/grub/embedded.cfg" > "$embedded"
    grub-mkimage -O i386-pc -o "$WORK/core.img" -c "$embedded" -p /boot/grub \
        biosdisk part_msdos part_gpt iso9660 fat ext2 ntfs \
        normal boot linux configfile search search_fs_file search_label search_fs_uuid \
        all_video gfxterm png font vbe vga video video_fb video_bochs \
        echo test regexp ls cat help reboot halt
    cat "$ISO_ROOT/boot/grub/i386-pc/cdboot.img" "$WORK/core.img" > "$ISO_ROOT/boot/grub/eltorito.img"

    for candidate in \
        "$CHROOT/usr/lib/shim/shimx64.efi.signed.latest" \
        "$CHROOT/usr/lib/shim/shimx64.efi.signed" \
        "$CHROOT/usr/lib/shim/shimx64.efi"
    do
        if [ -f "$candidate" ]; then
            shim="$candidate"
            break
        fi
    done
    for candidate in \
        "$CHROOT/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
        "$CHROOT/usr/lib/grub/x86_64-efi-signed/grubx64.efi"
    do
        if [ -f "$candidate" ]; then
            grubefi="$candidate"
            break
        fi
    done
    for candidate in \
        "$CHROOT/usr/lib/shim/mmx64.efi" \
        "$CHROOT/usr/lib/shim/mmx64.efi.signed"
    do
        if [ -f "$candidate" ]; then
            mm="$candidate"
            break
        fi
    done

    if [ -n "$shim" ] && [ -n "$grubefi" ]; then
        log "iso: podpisany shim i GRUB (Secure Boot)"
        cp -f "$shim" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
        cp -f "$grubefi" "$ISO_ROOT/EFI/BOOT/grubx64.efi"
        if [ -n "$mm" ]; then
            cp -f "$mm" "$ISO_ROOT/EFI/BOOT/mmx64.efi"
        fi
    else
        log "iso: GRUB EFI bez podpisu"
        grub-mkimage -O x86_64-efi -o "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" -c "$embedded" -p /boot/grub \
            part_gpt part_msdos fat iso9660 ntfs ext2 \
            normal boot linux configfile search search_fs_file search_label search_fs_uuid \
            all_video gfxterm gfxterm_background png font echo test regexp \
            efi_gop efi_uga video video_fb video_bochs \
            loopback chain ls cat help reboot halt
        cp -f "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" "$ISO_ROOT/EFI/BOOT/grubx64.efi"
    fi

    sed 's/\r$//' "$SRC/branding/grub/efi-ubuntu.cfg" > "$ISO_ROOT/EFI/ubuntu/grub.cfg"
    local font="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    if [ ! -f "$font" ]; then
        font="$CHROOT/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    fi
    grub-mkfont -s 18 -o "$ISO_ROOT/boot/grub/fonts/unicode.pf2" \
        --range=0x20-0x7e,0xa0-0x17f "$font"

    local efi_img="$ISO_ROOT/boot/grub/efiboot.img"
    rm -f "$efi_img"
    dd if=/dev/zero of="$efi_img" bs=1M count=16 status=none
    mkfs.vfat -n ANANASEFI "$efi_img" >/dev/null
    mmd -i "$efi_img" ::/EFI ::/EFI/BOOT ::/EFI/ubuntu
    mcopy -i "$efi_img" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/
    mcopy -i "$efi_img" "$ISO_ROOT/EFI/BOOT/grubx64.efi" ::/EFI/BOOT/
    if [ -f "$ISO_ROOT/EFI/BOOT/mmx64.efi" ]; then
        mcopy -i "$efi_img" "$ISO_ROOT/EFI/BOOT/mmx64.efi" ::/EFI/BOOT/
    fi
    mcopy -i "$efi_img" "$ISO_ROOT/EFI/ubuntu/grub.cfg" ::/EFI/ubuntu/grub.cfg
}

stage_iso() {
    if stage_done iso && [ -f "$OUT_ISO" ]; then
        log "iso: pomijam, jest $OUT_ISO"
        return
    fi
    umount_chroot
    mkdir -p "$ISO_ROOT/casper" "$ISO_ROOT/.disk" "$ISO_ROOT/boot/grub"
    copy_kernel
    sed 's/\r$//' "$SRC/branding/grub/grub.cfg" > "$ISO_ROOT/boot/grub/grub.cfg"
    sed 's/\r$//' "$SRC/branding/grub/loopback.cfg" > "$ISO_ROOT/boot/grub/loopback.cfg"
    cp -f "$WORK/artwork/grub-background.png" "$ISO_ROOT/boot/grub/ananas-boot.png"
    printf '%s\n' 'AnanasOS 1.0 (noble) amd64' > "$ISO_ROOT/.disk/info"
    touch "$ISO_ROOT/.disk/base_installable"
    make_boot_images

    local hybrid="/usr/lib/grub/i386-pc/boot_hybrid.img"
    if [ ! -f "$hybrid" ]; then
        hybrid="$CHROOT/usr/lib/grub/i386-pc/boot_hybrid.img"
    fi
    log "iso: xorriso"
    rm -f "$OUT_ISO"
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -joliet \
        -joliet-long \
        -rational-rock \
        -volid "ANANASOS" \
        -eltorito-boot boot/grub/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        --grub2-mbr "$hybrid" \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        -append_partition 2 0xEF "$ISO_ROOT/boot/grub/efiboot.img" \
        -appended_part_as_gpt \
        -partition_cyl_align off \
        -output "$OUT_ISO" \
        "$ISO_ROOT"

    sha256sum "$OUT_ISO" | tee "$OUT_DIR/AnanasOS-1.0-amd64.iso.sha256"
    ls -lh "$OUT_ISO"
    mark iso
    log "Gotowe: $OUT_ISO"
}

stage_host
stage_debootstrap
stage_packages
stage_configure
stage_squash
stage_iso
