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

# Step 4: Copy firstrun.sh and create systemd service for first-boot execution
echo "Installing firstrun.sh and first-boot systemd service..."
cp "${g_script_dir}/firstrun.sh" "${g_mount_point}/firstrun.sh"
chmod +x "${g_mount_point}/firstrun.sh"

# Create systemd service on root partition that runs firstrun.sh once on first boot.
# On Trixie, boot partition is at /boot/firmware, so firstrun.sh path varies.
g_rootfs="${g_work_dir}/rootfs"
mkdir -p "${g_rootfs}"

# Determine root device (second partition of the loop image)
g_root_dev="${g_loopdev}p2"
if [ ! -b "${g_root_dev}" ]
then
    echo "ERROR: Root partition ${g_root_dev} not found"
    exit 1
fi

mount "${g_root_dev}" "${g_rootfs}"

# Create the first-boot systemd service
cat > "${g_rootfs}/etc/systemd/system/symbios-firstrun.service" << 'SVCEOF'
[Unit]
Description=SymbiOS First Boot Installer
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/symbios-firstrun.done

[Service]
Type=oneshot
ExecStart=/bin/bash /boot/firmware/firstrun.sh
ExecStartPost=/bin/touch /var/lib/symbios-firstrun.done
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

# Enable the service
mkdir -p "${g_rootfs}/var/lib"
ln -sf "/etc/systemd/system/symbios-firstrun.service" "${g_rootfs}/etc/systemd/system/multi-user.target.wants/symbios-firstrun.service"

echo "First-boot service installed"
ls -la "${g_mount_point}/firstrun.sh"
ls -la "${g_rootfs}/etc/systemd/system/symbios-firstrun.service"

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
