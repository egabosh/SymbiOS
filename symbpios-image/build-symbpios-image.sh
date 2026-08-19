#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (c) 2026, Oliver Bohlen
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
g_default_image_url="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz"
g_default_image_name="2026-06-18-raspios-trixie-arm64-lite.img.xz"

# Script directory for template files
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
    ionice -c3 nice -n19 xz -dk -T1 "${g_image_source}" -c > "${g_image_file}"
  fi
elif [[ "${g_image_source}" == *.img ]]
then
  g_image_file="${g_image_source}"
else
  echo "ERROR: Image file must be .img or .img.xz"
  exit 1
fi

# Step 2b: Expand image to make room for all packages.
# The stock Pi OS image is too small for desktop + all SymbiOS packages.
# Skip if root partition is already resized.
if [ -s "${g_work_dir}/resize_done" ]
then
  echo "Image already resized skipping expansion"
else
  g_expand_bytes=$((8 * 1024 * 1024 * 1024))
  echo "Expanding image by 8GB for package pre-installation..."
  truncate -s +${g_expand_bytes} "${g_image_file}"

  # Expand the root partition (partition 2) into the new space
  g_loopdev_tmp=$(losetup --find --show --partscan "${g_image_file}")
  sleep 1

  # Use parted to resize partition 2 to fill remaining space
  parted -s "${g_loopdev_tmp}" resizepart 2 100%

  # Resize the ext4 filesystem to fill the enlarged partition
  e2fsck -f -y "${g_loopdev_tmp}p2" || true
  resize2fs "${g_loopdev_tmp}p2"

  fdisk -l "${g_loopdev_tmp}"

  losetup -d "${g_loopdev_tmp}"
  echo "Image resized"
  date >"${g_work_dir}/resize_done"
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

if [ ! -b "${g_loopdev}p2" ]
then
  echo "ERROR: Root partition ${g_loopdev}p2 not found"
  exit 1
fi

echo "Loop device: ${g_loopdev}"
echo "Boot partition: ${g_loopdev}p1"
echo "Root partition: ${g_loopdev}p2"

# Create mount point and mount
g_mount_point_boot="${g_work_dir}/boot"
mkdir -p "${g_mount_point_boot}"
mount "${g_loopdev}p1" "${g_mount_point_boot}"
echo "Boot partition mounted at ${g_mount_point_boot}"

# Mount root partition for modifications
g_mount_point_root="${g_work_dir}/rootfs"
mkdir -p "${g_mount_point_root}"
mount "${g_loopdev}p2" "${g_mount_point_root}"
echo "Root partition mounted at ${g_mount_point_root}"

# Step 4: Write rc.local with inline first-boot installer
echo "Writing rc.local with inline SymbiOS installer..."
cat > "${g_mount_point_root}/etc/rc.local" << 'RCLOCALEOF'
#!/bin/bash
# SymbiOS boot sequence

exec > >(tee -a /var/log/symbios-boot.log) 2>&1

if [ ! -s /var/lib/symbios-install.done ]
then

  echo "=== SymbiOS Installer ==="
  echo "Started at: $(date)"

  for f_i in $(seq 1 10)
  do
    echo "Downloading installer (attempt ${f_i}/10)..."
    if wget -q -O /tmp/symbios-install.sh https://raw.githubusercontent.com/egabosh/SymbiOS/main/install.sh
    then
      echo "Starting installation..."
      if bash /tmp/symbios-install.sh
      then
        date > /var/lib/symbios-install.done
        echo "=== Installation successful - rebooting ==="
      else
        echo "=== Installation FAILED - rebooting to retry ==="
      fi
      sync
      sleep 2
      reboot
    fi
    sleep 10
  done
fi

# Print the IP address
_IP=$(hostname -I) || true
if [ "$_IP" ]; then
  printf "My IP address is %s\n" "$_IP"
fi

exit 0
RCLOCALEOF
chmod +x "${g_mount_point_root}/etc/rc.local"

echo "Pre-installing packages in image (this may take a while)..."

# Mount virtual filesystems for chroot
mount --bind /dev "${g_mount_point_root}/dev"
mount --bind /dev/pts "${g_mount_point_root}/dev/pts"
mount -t proc proc "${g_mount_point_root}/proc"
mount -t sysfs sysfs "${g_mount_point_root}/sys"

# Copy host resolv.conf for DNS resolution inside chroot
cp /etc/resolv.conf "${g_mount_point_root}/etc/resolv.conf"

# Mount host apt cache into chroot to avoid running out of disk space
mkdir -p /var/cache/apt/archives
mount --bind /var/cache/apt/archives "${g_mount_point_root}/var/cache/apt/archives"

# All packages from basics.yml + raspberry.yml + ansible from install.sh
g_packages="yq file bc psmisc procps htop iotop sysstat strace net-tools vim git netcat-traditional debconf-utils iputils-ping lsof inotify-tools rsync dos2unix locales iproute2 curl moreutils telnet libstring-approx-perl postfix zip whois libfile-readbackwards-perl pwgen jq apt-transport-https html-xml-utils wget bind9-host bind9-dnsutils python3-pip python3-venv python3-html2text python3-passlib man-db cryptsetup ffmpeg mediainfo nmap libcrypt-cbc-perl libcrypt-des-perl cifs-utils golang make sshfs imagemagick libimage-exiftool-perl sqlite3 openssh-server gpg rblcheck crudini kpartx jnettop tmux ethtool logrotate at certbot btrfs-progs mdadm ufw btrfsmaintenance sudo ldmtool traceroute mailutils rsyslog postgresql-client ntpsec-ntpdate systemd-resolved ansible x11vnc cinnamon-desktop-environment cinnamon-l10n gnome-terminal dconf-cli dphys-swapfile tsdecrypt x264 x265 flatpak ttf-mscorefonts-installer fonts-terminus mint-y-icons arj p7zip unace unadf bvi fdupes debootstrap geoip-bin speedtest-cli gnome-characters blueman dconf-editor vlc gthumb mediainfo-gui easytag audacity asunder audacious guvcview easyeffects calf-plugins gpodder wireguard wireguard-tools tinyproxy rpi-imager hardinfo redshift-gtk heimdall-flash adb fastboot mkbootimg brasero lightdm lightdm-gtk-greeter qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager virt-viewer qemu-utils"

chroot "${g_mount_point_root}" /bin/bash -c "
  export LANG=C
  export DEBIAN_FRONTEND=noninteractive
  dpkg --configure -a
  apt-get -y update --allow-releaseinfo-change
  apt-get -y remove --purge plymouth cloud-guest-utils cloud-init rpi-cloud-init-mods
  apt-get -y install --no-install-recommends ${g_packages}
  apt-get -y dist-upgrade || echo 'WARNING: dist-upgrade failed in chroot, continuing'
  apt-get -y autoremove
  apt-get -y cleana
  rm -rf /var/lib/apt/lists/*
"

# Install ansible-galaxy collection
chroot "${g_mount_point_root}" /bin/bash -c "
  export LANG=C
  ansible-galaxy collection install community.general 2>/dev/null || true
"

# Disable graphical interface in systemd so it does not start automatically.
chroot "${g_mount_point_root}" /bin/bash -c "
  export LANG=C
  systemctl disable lightdm.service || true
"

# Disable Raspberry Pi OS first-boot wizard (keyboard layout, user creation).
# This is handled by cloud-init in Trixie. We handle user creation in
# basics.yml (symbios user).
chroot "${g_mount_point_root}" /bin/bash -c "
  export LANG=C
  systemctl disable userconfig.service || true
  systemctl mask    userconfig.service || true
" 2>/dev/null


# Remove resolv.conf copy (will be regenerated on boot)
rm -f "${g_mount_point_root}/etc/resolv.conf"

# Unmount host apt cache
umount "${g_mount_point_root}/var/cache/apt/archives"

# Unmount virtual filesystems
umount "${g_mount_point_root}/sys"
umount "${g_mount_point_root}/proc"
umount "${g_mount_point_root}/dev/pts"
umount "${g_mount_point_root}/dev"

echo "Package pre-installation complete"

# Step 5: Unmount
echo "Unmounting partitions..."
umount "${g_mount_point_root}"
umount "${g_mount_point_boot}"

# Detach loop device
losetup -d "${g_loopdev}"
g_loopdev=""

# Step 6: Compress output image
g_output_file="${g_output_dir}/symbpios-$(date +%Y%m%d).img.xz"
echo "Compressing image to ${g_output_file}..."
ionice -c3 nice -n19 xz -1 -T1 -c "${g_image_file}" > "${g_output_file}"

# Sanity check: output file must not be empty
if [ ! -s "${g_output_file}" ]
then
  echo "ERROR: Compressed image (${g_output_file}) is empty (0 bytes). xz may have failed."
  exit 1
fi

g_output_size="$(du -h "${g_output_file}" | cut -f1)"

## Step 7: Generate Imager Content Repository JSON
#echo "Generating Imager Content Repository JSON..."
#"${g_script_dir}/generate-repo-json.sh" -i "${g_output_file}" -o "${g_output_dir}"

echo ""
echo "=== Build complete ==="
echo "Output: ${g_output_file} (${g_output_size})"
echo ""
echo "Next steps:"
echo "  1. Open Raspberry Pi Imager"
echo "  2. Click 'Raspberry Pi OS (other)' -> 'Use custom' -> select the .img.xz"
echo "  3. Flash to SD card"
echo "  4. Boot the Pi - SymbiOS installs automatically on first boot"
echo "  5. Check progress: ssh into Pi and watch /var/log/symbios-boot.log"
