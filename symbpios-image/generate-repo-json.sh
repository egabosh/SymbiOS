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

# Generate a Raspberry Pi Imager Content Repository JSON for a SymbiOS image.
#
# The Imager greys out customization when using "Use custom" with a local .img
# file because it has no metadata. This script generates a repository JSON that
# tells the Imager the image supports customization (user, WiFi, SSH keys).
#
# Usage: ./generate-repo-json.sh -i IMAGE_FILE [-o OUTPUT_DIR]
#
# After generating, point the Imager to the JSON:
#   App Options -> Content Repository -> Use custom file -> select the JSON

set -euo pipefail

function f_usage {
    cat << EOF
Usage: $0 [OPTIONS]

Generate a Raspberry Pi Imager Content Repository JSON for a SymbiOS image.

Options:
  -i, --image FILE    Path to the SymbiOS .img or .img.xz file (required)
  -o, --output DIR    Output directory for JSON (default: same as image)
  -n, --name NAME     Display name in Imager (default: "SymbiOS")
  -h, --help          Show this help

After generating, open Raspberry Pi Imager and go to:
  App Options -> Content Repository -> Use custom file -> select the JSON
EOF
}

function f_generate_json {
    local f_image_path="$1"
    local f_image_name="$2"

    cat << JSONEOF
{
    "imager": {
        "latest_version": "2.0.0",
        "url": "https://www.raspberrypi.com/software/",
        "devices": [
            {
                "name": "Raspberry Pi 5",
                "tags": ["pi5-64bit", "pi5-32bit"],
                "default": true,
                "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_5.png",
                "description": "Raspberry Pi 5, 500 / 500+, and Compute Module 5",
                "matching_type": "exclusive"
            },
            {
                "name": "Raspberry Pi 4",
                "tags": ["pi4-64bit", "pi4-32bit"],
                "icon": "https://downloads.raspberrypi.com/imager/icons/RPi_4.png",
                "description": "Raspberry Pi 4 Model B, 400, and Compute Module 4 / 4S",
                "matching_type": "inclusive"
            },
            {
                "name": "No filtering",
                "tags": [],
                "description": "Show every possible image",
                "matching_type": "inclusive"
            }
        ]
    },
    "os_list": [
        {
            "name": "${f_image_name}",
            "description": "SymbiOS - Debian server management platform with first-boot installer",
            "icon": "https://downloads.raspberrypi.com/raspios_arm64/Raspberry_Pi_OS_(64-bit).png",
            "url": "file://${f_image_path}",
            "init_format": "systemd",
            "devices": [
                "pi5-64bit",
                "pi4-64bit"
            ]
        }
    ]
}
JSONEOF
}

# Defaults
g_image_arg=""
g_output_dir=""
g_image_name="SymbiOS"

# Parse arguments
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
        -n|--name)
            g_image_name="$2"
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

if [ -z "${g_image_arg}" ]
then
    echo "ERROR: --image is required"
    f_usage
    exit 1
fi

# Resolve to absolute path
g_image_path="$(realpath "${g_image_arg}")"

if [ ! -f "${g_image_path}" ]
then
    echo "ERROR: Image file not found: ${g_image_path}"
    exit 1
fi

# Determine output directory
if [ -z "${g_output_dir}" ]
then
    g_output_dir="$(dirname "${g_image_path}")"
fi

mkdir -p "${g_output_dir}"

# Generate JSON filename from image filename
g_json_name="$(basename "${g_image_path}")"
g_json_name="${g_json_name%.xz}"
g_json_name="${g_json_name%.img}"
g_json_name="${g_json_name}.json"
g_json_path="${g_output_dir}/${g_json_name}"

f_generate_json "${g_image_path}" "${g_image_name}" > "${g_json_path}"

echo "=== Content Repository JSON generated ==="
echo "Output: ${g_json_path}"
echo ""
echo "To enable Imager customization:"
echo "  1. Open Raspberry Pi Imager"
echo "  2. Go to App Options -> Content Repository -> Use custom file"
echo "  3. Select: ${g_json_path}"
echo "  4. Re-select your SymbiOS image"
echo "  5. Click the settings gear to customize user, WiFi, SSH keys"
