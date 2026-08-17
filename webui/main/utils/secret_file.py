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

"""
Write secrets to temporary files on the host.

WebUI views write secrets (passwords, passphrases, API keys) to files with
restricted permissions (chmod 600) so they never appear in the command line
audit log. Bash scripts receive the file path as an argument and read the
secret from the file instead of receiving it as a CLI argument.

File naming: .secret-<type>-<timestamp>
  - <type>: ldap-password, luks-passphrase, api-key, etc.
  - <timestamp>: ISO format with microseconds for collision avoidance
  - Location: /symbios/base-services/symbios-ui/config/
"""

import os
import datetime
import yaml


# Container-visible config directory where secret files are written.
# The /config path is bind-mounted into the WebUI container; the host sees
# the same directory under base_services_root/symbios-ui/config.
SECRET_DIR = os.path.dirname(os.environ.get('CONFIG_PATH', '/config/inventory.yml'))


def _host_config_dir():
    """Translate the container /config path to the host-side path.

    The container writes secrets into /config (a bind mount), but the bash
    scripts run on the host and receive the file path as an argument, so the
    returned path must be valid on the host. The host config dir is derived
    from base_services_root in the inventory.
    """
    f_config_file = os.path.join(SECRET_DIR, 'inventory.yml')
    try:
        with open(f_config_file, 'r') as f:
            f_cfg = yaml.safe_load(f) or {}
        f_base = f_cfg.get('all', {}).get('vars', {}).get('base_services_root', '')
        if f_base:
            return os.path.join(f_base, 'symbios-ui', 'config')
    except Exception:
        pass
    return SECRET_DIR


def f_write_secret(secret_type, secret_value):
    """Write a secret to a temporary file and return the host path.

    Args:
        secret_type: Short descriptor (e.g. 'ldap-password', 'luks-passphrase').
        secret_value: The secret string to write.

    Returns:
        Absolute file path on the host (valid for the bash scripts).

    The file is chmod 600 (read/write only by the executing uid) so only the
    script can access it. The file is cleaned up by the bash script via
    'trap ... EXIT' or an explicit rm -f after reading.
    """
    f_timestamp = datetime.datetime.now().strftime("%Y-%m-%d-%H-%M-%S-%f")
    f_filename = f".secret-{secret_type}-{f_timestamp}"
    f_filepath = os.path.join(SECRET_DIR, f_filename)

    # Write the secret to the file
    with open(f_filepath, "w") as f:
        f.write(secret_value)

    # Restrict permissions: read/write only by the executing uid
    os.chmod(f_filepath, 0o600)

    # Return the path as seen from the host, where the bash scripts run
    return os.path.join(_host_config_dir(), f_filename)
