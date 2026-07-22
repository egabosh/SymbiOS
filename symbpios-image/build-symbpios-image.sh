#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (C) 2025  SymbiOS Contributors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# Build a custom Raspberry Pi OS image with SymbiOS first-boot installer.
# The resulting image can be flashed via Raspberry Pi Imager ("Use custom").
#
# Requirements: root (for losetup/mount), wget, xz-utils, fdisk/util-linux
# Usage: sudo ./build-symbpios-image.sh [OPTIONS]

set -euo pipefail

# Default Raspberry Pi OS Trixie Desktop arm64 image
g_default_image_url="https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64.img.xz"
g_default_image_name="2026-06-18-raspios-trixie-arm64.img.xz"

# Script directory for firstrun.sh template
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse command-line arguments
function f_usage {
    cat << EOF
Usage: sudo $0 [OPTIONS]

Build a custom Raspberry Pi OS image with SymbiOS first-boot installer.

Options:
  -i, --image FILE    Use existing .img or .img.xz file instead of downloading
  -o, --output DIR    Output directory (default: current directory)
  -w, --workdir DIR   Working directory (default: /tmp/symbpios-image-build)
  -h, --help          Show this help

Examples:
  sudo $0                                        # Download latest Trixie Desktop and build
  sudo $0 --image raspios-trixie-arm64.img.xz    # Use a pre-downloaded image
  sudo $0 --output /data/images                  # Custom output directory
EOF
}

function f_cleanup {
    # Unmount and detach loop device if still attached
    if [ -n "${g_loopdev:-}" ] && losetup "${g_loopdev}" &>/dev/null
    then
        # Unmount virtual filesystems first (in case of failure during chroot)
        umount "${g_work_dir}/rootfs/var/cache/apt/archives" 2>/dev/null || true
        umount "${g_work_dir}/rootfs/sys" 2>/dev/null || true
        umount "${g_work_dir}/rootfs/proc" 2>/dev/null || true
        umount "${g_work_dir}/rootfs/dev/pts" 2>/dev/null || true
        umount "${g_work_dir}/rootfs/dev" 2>/dev/null || true
        umount "${g_work_dir}/rootfs" 2>/dev/null || true
        umount "${g_loopdev}p1" 2>/dev/null || true
        umount "${g_loopdev}p2" 2>/dev/null || true
        losetup -d "${g_loopdev}" 2>/dev/null || true
    fi
    # Note: working directory is NOT cleaned up to preserve the cached
    # .xz download and .img extraction for faster subsequent runs.
}

trap f_cleanup EXIT

# Defaults
g_image_arg=""
g_output_dir="$(pwd)"
g_work_dir="/tmp/symbpios-image-build"

while [[ $# -gt 0 ]]
do
    case "$1" in
        -i|--image)
            g_image_arg="$2"
            shift 2
            ;;
        -o|--output)
            g_output_dir="$2"
            shift 2
            ;;
        -w|--workdir)
            g_work_dir="$2"
            shift 2
            ;;
        -h|--help)
            f_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            f_usage
            exit 1
            ;;
    esac
done

# Check root
if [ "$(id -u)" -ne 0 ]
then
    echo "ERROR: This script must be run as root (needs losetup/mount)"
    exit 1
fi

# Check required tools
for f_cmd in wget xz fdisk losetup mount
do
    if ! command -v "${f_cmd}" &>/dev/null
    then
        echo "ERROR: Required tool '${f_cmd}' not found"
        exit 1
    fi
done

# Create directories
mkdir -p "${g_work_dir}" "${g_output_dir}"

# Step 1: Obtain the image file
if [ -n "${g_image_arg}" ]
then
    # Use provided image
    g_image_source="$(realpath "${g_image_arg}")"
    echo "Using provided image: ${g_image_source}"
else
    # Download default image (skip if already present)
    g_image_source="${g_work_dir}/${g_default_image_name}"
    if [ -f "${g_image_source}" ]
    then
        echo "Image already downloaded: ${g_image_source}"
    else
        echo "Downloading Raspberry Pi OS Trixie Desktop arm64..."
        wget -q --show-progress -O "${g_image_source}" "${g_default_image_url}"
    fi
fi

# Step 2: Extract if compressed (skip if .img already exists)
if [[ "${g_image_source}" == *.xz ]]
then
    g_image_file="${g_work_dir}/raspios.img"
    if [ -f "${g_image_file}" ] && [ "$(stat -c%s "${g_image_file}" 2>/dev/null)" -gt 0 ]
    then
        echo "Image already extracted: ${g_image_file}"
    else
        echo "Extracting image (this may take a moment)..."
        ionice -c3 nice -n19 xz -dk -T2 "${g_image_source}" -c > "${g_image_file}"
    fi
elif [[ "${g_image_source}" == *.img ]]
then
    g_image_file="${g_image_source}"
else
    echo "ERROR: Image file must be .img or .img.xz"
    exit 1
fi

echo "Image file: ${g_image_file}"
echo "Image size: $(du -h "${g_image_file}" | cut -f1)"

# Step 2b: Expand image to make room for all packages.
# The stock Pi OS image is too small for desktop + all SymbiOS packages.
# Skip if root partition is already >= 8GB (idempotent rebuilds).
g_orig_size=$(stat -c%s "${g_image_file}")
g_min_size=$((8 * 1024 * 1024 * 1024))
if [ "${g_orig_size}" -ge "${g_min_size}" ]
then
    echo "Image already >= 8GB ($(du -h "${g_image_file}" | cut -f1)), skipping expansion"
else
    g_expand_bytes=$((4 * 1024 * 1024 * 1024))
    echo "Expanding image by 4GB for package pre-installation..."
    truncate -s +${g_expand_bytes} "${g_image_file}"

    # Expand the root partition (partition 2) into the new space
    g_loopdev_tmp=$(losetup --find --show --partscan "${g_image_file}")
    sleep 1

    # Use parted to resize partition 2 to fill remaining space
    parted -s "${g_loopdev_tmp}" resizepart 2 100%

    # Resize the ext4 filesystem to fill the enlarged partition
    e2fsck -f -y "${g_loopdev_tmp}p2" || true
    resize2fs "${g_loopdev_tmp}p2"

    losetup -d "${g_loopdev_tmp}"
    echo "Image expanded: $(du -h "${g_image_file}" | cut -f1)"
fi

# Step 3: Mount boot partition via loop device
echo "Attaching image as loop device with partition scanning..."
g_loopdev=$(losetup --find --show --partscan "${g_image_file}")

# Wait for partition device nodes to appear
sleep 1

if [ ! -b "${g_loopdev}p1" ]
then
    echo "ERROR: Boot partition ${g_loopdev}p1 not found"
    exit 1
fi

echo "Loop device: ${g_loopdev}"
echo "Boot partition: ${g_loopdev}p1"

# Create mount point and mount
g_mount_point="${g_work_dir}/boot"
mkdir -p "${g_mount_point}"
mount "${g_loopdev}p1" "${g_mount_point}"

echo "Boot partition mounted at ${g_mount_point}"

# Step 4: Copy firstrun.sh, disable splash, and create systemd service
echo "Installing firstrun.sh and first-boot systemd service..."
cp "${g_script_dir}/firstrun.sh" "${g_mount_point}/firstrun.sh"
chmod +x "${g_mount_point}/firstrun.sh"

# Disable splash screen on boot partition so first-boot output is visible.
# Remove 'quiet' and 'splash' from cmdline.txt so kernel messages are shown.
if [ -f "${g_mount_point}/cmdline.txt" ]
then
    sed -i 's/ quiet//g; s/ splash//g' "${g_mount_point}/cmdline.txt"
    echo "cmdline.txt: removed quiet and splash"
    cat "${g_mount_point}/cmdline.txt"
fi

# Disable rainbow splash in config.txt
if [ -f "${g_mount_point}/config.txt" ]
then
    echo "disable_splash=1" >> "${g_mount_point}/config.txt"
    echo "config.txt: added disable_splash=1"
fi

# Mount root partition for modifications
g_rootfs="${g_work_dir}/rootfs"
mkdir -p "${g_rootfs}"

g_root_dev="${g_loopdev}p2"
if [ ! -b "${g_root_dev}" ]
then
    echo "ERROR: Root partition ${g_root_dev} not found"
    exit 1
fi

mount "${g_root_dev}" "${g_rootfs}"

# Use rc.local for first-boot execution — runs AFTER the system is
# fully booted (all systemd services started), avoiding conflicts with
# Docker, network, and other services that start during boot.
# firstrun.sh is idempotent: it checks for Imager files and the
# installed-playbooks state file before doing anything.
cat > "${g_rootfs}/etc/rc.local" << 'RCLOCALEOF'
#!/bin/bash
# SymbiOS first-boot trigger
# Runs once after the system is fully booted.
# Deleted by firstrun.sh after successful execution.

if [ ! -f /var/lib/symbios-firstrun.done ]
then
    /bin/bash /boot/firmware/firstrun.sh
fi

exit 0
RCLOCALEOF
chmod +x "${g_rootfs}/etc/rc.local"

# Disable graphical interface in systemd so it does not start automatically.
# The SymbiOS playbook handles display manager setup (lightdm, X11, etc.) later.
systemctl --root="${g_rootfs}" disable lightdm.service 2>/dev/null || true
systemctl --root="${g_rootfs}" disable gdm3.service 2>/dev/null || true
systemctl --root="${g_rootfs}" disable sddm.service 2>/dev/null || true
echo "Graphical interface disabled in systemd"

# Disable Raspberry Pi OS first-boot wizard (keyboard layout, user creation).
# This is handled by cloud-init in Trixie. We handle user creation in
# firstrun.sh (Imager customizations) and basics.yml (symbios user).
systemctl --root="${g_rootfs}" mask cloud-init.service 2>/dev/null || true
systemctl --root="${g_rootfs}" mask cloud-init-local.service 2>/dev/null || true
systemctl --root="${g_rootfs}" mask cloud-final.service 2>/dev/null || true
systemctl --root="${g_rootfs}" mask cloud-config.service 2>/dev/null || true

# Disable the first-boot wizard modules in cloud-init config
mkdir -p "${g_rootfs}/etc/cloud/cloud.cfg.d"
cat > "${g_rootfs}/etc/cloud/cloud.cfg.d/99-disable-first-boot.cfg" << 'CIEOF'
# Disable Pi OS first-boot wizard — SymbiOS handles setup via firstrun.sh
cloud_init_modules:
  - clear_hotplug
  - write_password
  - users_groups
runcmd: []
CIEOF

# Create cloud-init semaphore so it thinks it already ran
mkdir -p "${g_rootfs}/var/lib/cloud/sem"
cat > "${g_rootfs}/var/lib/cloud/sem/semaphore" << 'SEMEOF'
{
  "mode": "once",
  "name": "SymbiOS",
  "data": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "stamp": "$(date +%s)"
}
SEMEOF

echo "Cloud-init first-boot wizard disabled"

# Ensure getty runs on tty1 with autologin so user can see output
mkdir -p "${g_rootfs}/etc/systemd/system/getty@tty1.service.d"
cat > "${g_rootfs}/etc/systemd/system/getty@tty1.service.d/override.conf" << 'GETTYEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
GETTYEOF

echo "rc.local installed, lightdm masked"
ls -la "${g_mount_point}/firstrun.sh"
ls -la "${g_rootfs}/etc/rc.local"

# Step 4b: Pre-install packages and upgrade to speed up first boot.
# This runs apt inside the image's root filesystem so packages are
# already present when the Pi boots and the playbook runs.
echo "Pre-installing packages in image (this may take a while)..."

# Mount virtual filesystems for chroot
mount --bind /dev "${g_rootfs}/dev"
mount --bind /dev/pts "${g_rootfs}/dev/pts"
mount -t proc proc "${g_rootfs}/proc"
mount -t sysfs sysfs "${g_rootfs}/sys"

# Copy host resolv.conf for DNS resolution inside chroot
cp /etc/resolv.conf "${g_rootfs}/etc/resolv.conf"

# Mount host apt cache into chroot to avoid running out of disk space
# on the image's root partition (only ~4GB total).
mkdir -p /var/cache/apt/archives
mount --bind /var/cache/apt/archives "${g_rootfs}/var/cache/apt/archives"

# All packages from basics.yml + raspberry.yml + ansible from install.sh
g_packages="file bc psmisc procps htop iotop sysstat strace net-tools vim git netcat-traditional debconf-utils iputils-ping lsof inotify-tools rsync dos2unix locales iproute2 curl moreutils telnet libstring-approx-perl postfix zip whois libfile-readbackwards-perl pwgen jq apt-transport-https html-xml-utils wget bind9-host bind9-dnsutils python3-pip python3-venv python3-html2text python3-passlib man-db cryptsetup ffmpeg mediainfo nmap libcrypt-cbc-perl libcrypt-des-perl cifs-utils golang make sshfs imagemagick libimage-exiftool-perl sqlite3 openssh-server gpg rblcheck crudini kpartx hd-idle jnettop tmux ethtool logrotate smartmontools at certbot btrfs-progs mdadm ufw btrfsmaintenance sudo ldmtool traceroute mailutils rsyslog postgresql-client ntpsec-ntpdate systemd-resolved ansible x11vnc cinnamon-desktop-environment cinnamon-l10n gnome-terminal dconf-cli dphys-swapfile tsdecrypt x264 x265 flatpak ttf-mscorefonts-installer fonts-terminus mint-y-icons arj p7zip unace unadf bvi fdupes debootstrap geoip-bin speedtest-cli gnome-characters blueman dconf-editor vlc gthumb mediainfo-gui easytag audacity asunder audacious guvcview easyeffects calf-plugins gpodder wireguard wireguard-tools tinyproxy rpi-imager hardinfo redshift-gtk heimdall-flash adb fastboot mkbootimg brasero"

chroot "${g_rootfs}" /bin/bash -c "
    export DEBIAN_FRONTEND=noninteractive
    dpkg --configure -a
    apt-get -y update --allow-releaseinfo-change
    apt-get -y install --no-install-recommends ${g_packages}
    apt-get -y dist-upgrade
    apt-get -y autoremove
    apt-get -y clean
    rm -rf /var/lib/apt/lists/*
"

# Install ansible-galaxy collection
chroot "${g_rootfs}" /bin/bash -c "
    ansible-galaxy collection install community.general 2>/dev/null || true
"

# Pre-configure keyboard and console to avoid ncurses dialog on first boot.
# Without this, keyboard-configuration / console-setup shows an interactive
# ncurses prompt that blocks boot and prevents rc.local (firstrun.sh) from running.
echo "Pre-configuring keyboard and console settings..."
chroot "${g_rootfs}" /bin/bash -c "
    echo 'keyboard-configuration keyboard-configuration/layoutcode string us' | debconf-set-selections
    echo 'keyboard-configuration keyboard-configuration/modelcode string pc105' | debconf-set-selections
    echo 'keyboard-configuration keyboard-configuration/xkb-keymap select us' | debconf-set-selections
    echo 'keyboard-configuration keyboard-configuration/variant string English (US)' | debconf-set-selections
    echo 'console-setup console-setup/charmap select UTF-8' | debconf-set-selections
    echo 'console-setup console-setup/codeset select guess' | debconf-set-selections
    echo 'console-setup console-setup/fontsize string 16x32' | debconf-set-selections
    echo 'console-setup console-setup/fontface string Fixed' | debconf-set-selections
    echo 'locales locales/default_environment_locale select en_US.UTF-8' | debconf-set-selections
    echo 'locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8' | debconf-set-selections
    dpkg-reconfigure -f noninteractive locales 2>/dev/null || true
    dpkg-reconfigure -f noninteractive keyboard-configuration 2>/dev/null || true
    dpkg-reconfigure -f noninteractive console-setup 2>/dev/null || true
    locale-gen en_US.UTF-8 2>/dev/null || true
    update-locale LANG=en_US.UTF-8 2>/dev/null || true
"

# Disable raspi-config first-boot wizard (ncurses user/keyboard dialog)
# This runs as a systemd service and shows the interactive setup wizard
chroot "${g_rootfs}" /bin/bash -c "
    systemctl mask raspi-config.service 2>/dev/null || true
    systemctl mask raspi-config-noint.service 2>/dev/null || true
    systemctl mask setup-first-boot.service 2>/dev/null || true
    systemctl mask initial-setup.service 2>/dev/null || true
    # Create marker file so raspi-config thinks first-boot is done
    mkdir -p /var/lib/raspi-config
    echo 'done' > /var/lib/raspi-config/first-boot-done
"

# Remove resolv.conf copy (will be regenerated on boot)
rm -f "${g_rootfs}/etc/resolv.conf"

# Unmount host apt cache
umount "${g_rootfs}/var/cache/apt/archives"

# Unmount virtual filesystems
umount "${g_rootfs}/sys"
umount "${g_rootfs}/proc"
umount "${g_rootfs}/dev/pts"
umount "${g_rootfs}/dev"

echo "Package pre-installation complete"

# Step 5: Unmount
echo "Unmounting partitions..."
umount "${g_rootfs}"
umount "${g_mount_point}"

# Detach loop device
losetup -d "${g_loopdev}"
g_loopdev=""

# Step 6: Compress output image
g_output_file="${g_output_dir}/symbpios-$(date +%Y%m%d).img.xz"
echo "Compressing image to ${g_output_file}..."

# Use -1 (fast) instead of -9 (extremely slow, RAM-hungry) and limit threads
# to avoid OOM on systems with limited RAM. Level 1 already achieves good
# compression for disk images; level 9 saves ~5% more but takes 10x longer
# and uses ~600MB RAM per thread.
ionice -c3 nice -n19 xz -1 -T2 -c "${g_image_file}" > "${g_output_file}"

# Sanity check: output file must not be empty
if [ ! -s "${g_output_file}" ]
then
    echo "ERROR: Compressed image is empty (0 bytes). xz may have failed."
    echo "Try running without -T flag or check available disk space / memory."
    rm -f "${g_output_file}"
    exit 1
fi

g_output_size="$(du -h "${g_output_file}" | cut -f1)"

# Step 7: Generate Imager Content Repository JSON
echo "Generating Imager Content Repository JSON..."
"${g_script_dir}/generate-repo-json.sh" -i "${g_output_file}" -o "${g_output_dir}"

echo ""
echo "=== Build complete ==="
echo "Output: ${g_output_file} (${g_output_size})"
echo ""
echo "Next steps:"
echo "  1. Open Raspberry Pi Imager"
echo "  2. Go to App Options -> Content Repository -> Use custom file"
echo "  3. Select the generated .json file"
echo "  4. Click 'Raspberry Pi OS (other)' -> 'Use custom' -> select the .img.xz"
echo "  5. Click the settings gear to customize user, WiFi, SSH keys"
echo "  6. Flash to SD card"
echo "  7. Boot the Pi - SymbiOS installs automatically on first boot"
echo "  8. Check progress: ssh into Pi and watch /var/log/symbios-firstrun.log"
