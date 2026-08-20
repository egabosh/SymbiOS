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

import yaml
import os
import json
import shlex
from django.shortcuts import render, redirect
from django.contrib import messages
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


def _ldap_admin_bind(password):
    """Bind against LDAP as the admin user.

    Returns one of:
      'ok'          - bind succeeded
      'invalid'     - wrong password (LDAP_INVALID_CREDENTIALS, rc 49)
      'unavailable' - LDAP server not reachable or another LDAP error
    """
    import subprocess
    from .constants import LDAP_URI
    config = _get_inventory_config()
    base_dn = config.get('all', {}).get('vars', {}).get('ldap_basedn', 'dc=openldap,dc=local')
    admin_dn = f'uid=admin,ou=users,{base_dn}'
    proc = subprocess.run(
        ['ldapwhoami', '-x', '-H', LDAP_URI, '-D', admin_dn, '-w', password],
        capture_output=True, text=True, timeout=10,
    )
    if proc.returncode == 0:
        return 'ok'
    if proc.returncode == 49:
        return 'invalid'
    return 'unavailable'


def login_view(request):
    """LAN break-glass login: password checked directly against LDAP.

    This is used when the WebUI is reached on the LAN IP (http://<local-ip>:8080)
    without Traefik/Authelia. The host-local path on 127.0.0.1 stays passwordless.
    Only the admin user can log in here, so the form only asks for the password.
    """
    if getattr(request.user, 'is_authenticated', False):
        return redirect('/')
    if request.method == 'POST':
        password = request.POST.get('password', '')
        result = _ldap_admin_bind(password)
        if result == 'unavailable':
            messages.error(request, 'LDAP server is not reachable. Please check the LDAP service and try again.')
        elif result != 'ok':
            messages.error(request, 'Invalid credentials.')
        else:
            request.session['lan_admin'] = True
            if _ldap_admin_bind('admin') == 'ok':
                request.session['force_password_change'] = True
            return redirect('/')
    return render(request, 'main/login.html')


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


@login_required
def setup(request):
    """Guided setup assistant - orchestrates the settings pages (no duplicate forms)."""
    from .setup_status import setup_steps, is_setup_complete, network_type_label
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        from .utils.http import is_ajax_request
        from django.http import JsonResponse
        is_ajax = is_ajax_request(request)
        network_type = request.POST.get('network_type', '').strip()
        if network_type in ('home', 'root', 'airgapped'):
            vars_['network_type'] = network_type
            _save_inventory_config(config)
            if is_ajax:
                return JsonResponse({'ok': True})
            messages.success(request, 'Server connection type saved.')
            return redirect('setup')
        if is_ajax:
            return JsonResponse({'ok': False, 'error': 'Invalid network type'}, status=400)

    steps = setup_steps(vars_)
    pending = [s for s in steps if not s['optional'] and s['status'] != 'done']
    complete = is_setup_complete(vars_)
    network_step = next((s for s in steps if s['key'] == 'network'), None)
    main_steps = [s for s in steps if s['key'] != 'network']

    # Auto-detect the connection type from the host's IP addresses and default
    # gateway so the setup assistant can pre-select an option. The user still
    # confirms; the detection is only a suggestion.
    detected_network = _detect_network_type()
    if not vars_.get('network_type') and detected_network:
        vars_['network_type'] = detected_network

    return render(request, 'main/setup.html', {
        'vars': vars_,
        'network_step': network_step,
        'main_steps': main_steps,
        'pending_count': len(pending),
        'complete': complete,
        'network_type': vars_.get('network_type', ''),
        'network_type_label': network_type_label(vars_.get('network_type', '')),
        'detected_network': detected_network,
    })


def _detect_network_type():
    """Best-effort detection of the server connection type (home/root).

    Runs the host helper script and returns 'home', 'root' or '' when nothing
    can be determined. Never raises: a detection failure just yields no
    suggestion and the user picks the option manually.
    """
    try:
        from .utils.ssh_exec import run_command
        ok, stdout, _ = run_command('symbios-detect-network-type.sh', timeout=10)
        if ok and stdout:
            return json.loads(stdout).get('network_type', '') or ''
    except Exception:
        pass
    return ''


@login_required
def health(request):
    from .setup_status import setup_steps, is_setup_complete
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    steps = setup_steps(vars_)
    pending = [s for s in steps if not s['optional'] and s['status'] != 'done']
    return render(request, 'main/health.html', {
        'setup_incomplete': not is_setup_complete(vars_),
        'setup_pending': len(pending),
    })

@login_required
def health_data(request):
    from .health import run_all
    from django.http import JsonResponse
    return JsonResponse(run_all())


@login_required
def health_recheck(request, check_name):
    """Run a single health check on demand and return JSON result."""
    from django.http import JsonResponse
    from .utils.ssh_exec import run_command
    ok, stdout, stderr = run_command(f'symbios-run-check.sh {shlex.quote(check_name)}', timeout=30)
    if not ok:
        return JsonResponse({'ok': False, 'error': stderr or 'Check failed'}, status=500)
    import json
    try:
        result = json.loads(stdout)
    except (json.JSONDecodeError, ValueError):
        return JsonResponse({'ok': False, 'error': 'Invalid response from check'}, status=500)
    return JsonResponse({'ok': True, 'check': result})


@login_required
def container_list(request):
    from .utils.log_utils import _get_container_list
    from django.http import JsonResponse
    containers = _get_container_list()
    return JsonResponse({"containers": containers})


def logout_view(request):
    lan_admin = request.session.get('lan_admin')
    config = _get_inventory_config()
    vars_ = config.get("all", {}).get("vars", {})
    base_domain = vars_.get("base_domain", "")
    request.session.flush()
    if lan_admin:
        # LAN break-glass session (LDAP login) ends on the login page.
        return redirect('/login/')
    if base_domain:
        return redirect(f"https://auth.{base_domain}/logout")
    return redirect("/authelia-logout/")


def authelia_logout(request):
    return render(request, "main/authelia_logout.html")
