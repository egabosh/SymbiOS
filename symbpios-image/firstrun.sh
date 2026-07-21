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

# SymbiOS first-boot installer
# Placed on the boot partition by build-symbpios-image.sh.
# Executed automatically by the raspi-config firstboot systemd service,
# then deleted.

exec > >(tee -a /var/log/symbios-firstrun.log) 2>&1

echo "=== SymbiOS First Boot Installer ==="
echo "Started at: $(date)"

# Wait for network connectivity
echo "Waiting for network..."
f_network_ready=0
for f_i in $(seq 1 60)
do
    if ping -c1 -W2 8.8.8.8 &>/dev/null
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

# Download SymbiOS installer
echo "Downloading SymbiOS installer..."
wget -q https://raw.githubusercontent.com/egabosh/SymbiOS/refs/heads/main/install.sh -O /tmp/symbios-install.sh
chmod +x /tmp/symbios-install.sh

# Run SymbiOS installer
echo "Starting SymbiOS installation at $(date)..."
bash /tmp/symbios-install.sh
f_install_exit=$?

echo "SymbiOS installation finished at: $(date) (exit code: ${f_install_exit})"
echo "=== End of SymbiOS First Boot ==="
