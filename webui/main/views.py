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

import yaml
import os
from django.shortcuts import render, redirect
from .decorators import login_required
from .constants import CONFIG_PATH


def _get_inventory_config():
    try:
        with open(CONFIG_PATH, 'r') as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


def _safe_write(path, data):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def _save_inventory_config(config):
    # Keep a backup of the last good version
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f:
                bak = CONFIG_PATH + '.bak'
                with open(bak, 'w') as b:
                    b.write(f.read())
        except Exception:
            pass
    dumped = yaml.dump(config, default_flow_style=False, allow_unicode=True)
    _safe_write(CONFIG_PATH, dumped)


def _get_ldap_groups():
    """Get all LDAP groups by calling symbios-ldap-list.sh via symbios-exec.sh."""
    from .utils.ssh_exec import run_command
    ok, stdout, stderr = run_command("symbios-ldap-list.sh --groups", timeout=30)
    if ok and stdout.strip():
        try:
            import json
            groups = json.loads(stdout.strip())
            return groups if groups else ['users']
        except Exception:
            pass
    return ['users']


def _get_ldap_users():
    """Get all LDAP users with groups by calling symbios-ldap-list.sh via symbios-exec.sh."""
    from .utils.ssh_exec import run_command
    ok, stdout, stderr = run_command("symbios-ldap-list.sh --users", timeout=30)
    if ok and stdout.strip():
        try:
            import json
            return json.loads(stdout.strip())
        except Exception:
            pass
    return []


@login_required
def settings(request):
    return render(request, 'main/settings.html')


def health(request):
    return render(request, 'main/health.html')

def health_data(request):
    from .health import run_all
    from django.http import JsonResponse
    return JsonResponse(run_all())


@login_required
def container_list(request):
    from .utils.log_utils import _get_container_list
    from django.http import JsonResponse
    containers = _get_container_list()
    return JsonResponse({"containers": containers})


def logout_view(request):
    config = _get_inventory_config()
    vars_ = config.get("all", {}).get("vars", {})
    base_domain = vars_.get("base_domain", "")
    request.session.flush()
    if base_domain:
        return redirect(f"https://auth.{base_domain}/logout")
    return redirect("/authelia-logout/")


def authelia_logout(request):
    return render(request, "main/authelia_logout.html")
