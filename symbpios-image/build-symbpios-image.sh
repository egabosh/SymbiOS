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

#!/bin/bash

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
        umount "${g_loopdev}p1" 2>/dev/null || true
        losetup -d "${g_loopdev}" 2>/dev/null || true
    fi
    # Remove working directory
    rm -rf "${g_work_dir:?}"
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
    # Download default image
    g_image_source="${g_work_dir}/${g_default_image_name}"
    echo "Downloading Raspberry Pi OS Trixie Desktop arm64..."
    wget -q --show-progress -O "${g_image_source}" "${g_default_image_url}"
fi

# Step 2: Extract if compressed
if [[ "${g_image_source}" == *.xz ]]
then
    echo "Extracting image (this may take a moment)..."
    xz -dk "${g_image_source}" -c > "${g_work_dir}/raspios.img"
    g_image_file="${g_work_dir}/raspios.img"
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

# Step 4: Copy firstrun.sh to boot partition
echo "Installing firstrun.sh..."
cp "${g_script_dir}/firstrun.sh" "${g_mount_point}/firstrun.sh"
chmod +x "${g_mount_point}/firstrun.sh"

# Verify
ls -la "${g_mount_point}/firstrun.sh"

# Step 5: Unmount
echo "Unmounting boot partition..."
umount "${g_mount_point}"

# Detach loop device
losetup -d "${g_loopdev}"
g_loopdev=""

# Step 6: Compress output image
g_output_file="${g_output_dir}/symbpios-$(date +%Y%m%d).img.xz"
echo "Compressing image to ${g_output_file}..."
xz -9 -T0 -c "${g_image_file}" > "${g_output_file}"

g_output_size="$(du -h "${g_output_file}" | cut -f1)"

echo ""
echo "=== Build complete ==="
echo "Output: ${g_output_file} (${g_output_size})"
echo ""
echo "Next steps:"
echo "  1. Open Raspberry Pi Imager"
echo "  2. Click 'Raspberry Pi OS (other)' -> 'Use custom'"
echo "  3. Select: ${g_output_file}"
echo "  4. Flash to SD card"
echo "  5. Boot the Pi - SymbiOS installs automatically on first boot"
echo "  6. Check progress: ssh into Pi and watch /var/log/symbios-firstrun.log"
