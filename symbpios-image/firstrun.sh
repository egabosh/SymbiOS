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

# SymbiOS first-boot installer
# Placed on the boot partition by build-symbpios-image.sh.
#
# This script processes Raspberry Pi Imager customizations (user, WiFi,
# SSH keys) before running the SymbiOS installer, so users can fully
# customize the image via the Imager.
#
# Output is visible on the console (tty1) via the systemd service.
# This script also logs to /var/log/symbios-firstrun.log.

# rc.local runs after the system is fully booted, so plymouth should
# already be stopped. Stop it anyway just in case.
systemctl stop plymouth.service 2>/dev/null || true
systemctl stop plymouth-quit.service 2>/dev/null || true
systemctl stop plymouth-read-write.service 2>/dev/null || true

# Clear screen for clean output
clear

# Log to both console and file
exec > >(tee -a /var/log/symbios-firstrun.log) 2>&1

echo "=== SymbiOS First Boot Installer ==="
echo "Started at: $(date)"
echo ""

# --- Process Raspberry Pi Imager customizations ---

# Determine boot partition path (works for both /boot and /boot/firmware)
f_boot=""
if [ -d "/boot/firmware" ] && [ -f "/boot/firmware/userconf.txt" -o -f "/boot/firmware/wpa_supplicant.conf" -o -d "/boot/firmware/sshkeys" ]
then
    f_boot="/boot/firmware"
elif [ -f "/boot/userconf.txt" -o -f "/boot/wpa_supplicant.conf" -o -d "/boot/sshkeys" ]
then
    f_boot="/boot"
fi

# Process userconf.txt — create user account
if [ -n "${f_boot}" ] && [ -f "${f_boot}/userconf.txt" ]
then
    echo "Processing userconf.txt..."
    f_user_line=$(head -1 "${f_boot}/userconf.txt")
    f_username=$(echo "$f_user_line" | cut -d: -f1)
    f_password_hash=$(echo "$f_user_line" | cut -d: -f2)

    if [ -n "${f_username}" ] && [ -n "${f_password_hash}" ]
    then
        if id "${f_username}" &>/dev/null
        then
            echo "  User '${f_username}' already exists, updating password"
            echo "${f_username}:${f_password_hash}" | chpasswd -e
        else
            echo "  Creating user '${f_username}'"
            useradd -m -s /bin/bash "${f_username}"
            echo "${f_username}:${f_password_hash}" | chpasswd -e
            # Add to sudo and docker groups
            usermod -aG sudo,docker,adm "${f_username}"
            # Allow passwordless sudo
            echo "${f_username} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${f_username}"
            chmod 440 "/etc/sudoers.d/${f_username}"
        fi
        # Set as default login user for TTY
        chage -d "" "${f_username}" 2>/dev/null || true
    fi
fi

# Process wpa_supplicant.conf — configure WiFi
if [ -n "${f_boot}" ] && [ -f "${f_boot}/wpa_supplicant.conf" ]
then
    echo "Processing wpa_supplicant.conf..."
    cp "${f_boot}/wpa_supplicant.conf" /etc/wpa_supplicant/wpa_supplicant.conf
    chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
    echo "  WiFi configuration installed"

    # Bring up WiFi if a wireless interface exists
    if command -v wpa_cli &>/dev/null
    then
        f_wlan=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wlan' | head -1)
        if [ -n "${f_wlan}" ]
        then
            wpa_cli -i "${f_wlan}" reconfigure 2>/dev/null || true
            echo "  WiFi interface ${f_wlan} reconfigured"
        fi
    fi
fi

# Process SSH keys — install authorized_keys
if [ -n "${f_boot}" ] && [ -d "${f_boot}/sshkeys" ]
then
    echo "Processing SSH keys..."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    for f_keyfile in "${f_boot}"/sshkeys/*
    do
        [ -f "${f_keyfile}" ] || continue
        f_key=$(cat "${f_keyfile}")
        if [ -n "${f_key}" ]
        then
            echo "${f_key}" >> /root/.ssh/authorized_keys
            echo "  Installed key: $(basename "${f_keyfile}")"
        fi
    done
    chmod 600 /root/.ssh/authorized_keys

    # Also install for the custom user if one was created
    if [ -n "${f_username:-}" ] && id "${f_username}" &>/dev/null
    then
        f_user_home=$(eval echo "~${f_username}")
        mkdir -p "${f_user_home}/.ssh"
        chmod 700 "${f_user_home}/.ssh"
        cp /root/.ssh/authorized_keys "${f_user_home}/.ssh/authorized_keys"
        chown -R "${f_username}:${f_username}" "${f_user_home}/.ssh"
        echo "  SSH keys also installed for user '${f_username}'"
    fi
fi

# Clean up Imager customization files from boot partition
if [ -n "${f_boot}" ]
then
    rm -f "${f_boot}/userconf.txt" "${f_boot}/userconf" 2>/dev/null || true
    rm -f "${f_boot}/wpa_supplicant.conf" 2>/dev/null || true
    rm -rf "${f_boot}/sshkeys" 2>/dev/null || true
    echo "Imager customization files cleaned up"
fi

# --- Wait for network ---
echo "Waiting for network..."
f_network_ready=0
for f_i in $(seq 1 60)
do
    if ping -c1 -W2 raw.githubusercontent.com &>/dev/null
    then
        echo "Network available after ${f_i} attempts"
        f_network_ready=1
        break
    fi
    sleep 2
done

if [ "${f_network_ready}" -ne 1 ]
then
    echo "ERROR: Network not available after 120 seconds"
    exit 1
fi

# --- Run SymbiOS installer ---
echo "Downloading SymbiOS installer..."
wget -q https://raw.githubusercontent.com/egabosh/SymbiOS/refs/heads/main/install.sh -O /tmp/symbios-install.sh
chmod +x /tmp/symbios-install.sh

echo "Starting SymbiOS installation at $(date)..."
bash /tmp/symbios-install.sh
f_install_exit=$?

echo "SymbiOS installation finished at: $(date) (exit code: ${f_install_exit})"

# Mark first boot as complete — prevents re-execution on next boot
if [ "${f_install_exit}" -eq 0 ]
then
    touch /var/lib/symbios-firstrun.done
    echo "First boot marked as complete"
    echo "=== End of SymbiOS First Boot ==="
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "ERROR: Installation failed (exit code: ${f_install_exit})"
    echo "=== First boot NOT marked — will retry on next boot ==="
fi
