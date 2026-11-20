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
import json
import re
import shlex
from django.shortcuts import render, redirect
from django.http import HttpResponse
from django.contrib import messages
from .decorators import login_required
from .constants import CONFIG_PATH


def _get_inventory_config():
    try:
        with open(CONFIG_PATH, 'r') as f:
            return yaml.safe_load(f) or {}
    except Exception:
        return {}


# NOTE: inventory.yml is never written from the WebUI anymore. All writes
# go through scripts/symbios-inventory.py on the host (called via
# run_command), which provides the same guarantees the removed
# _save_inventory_config/_safe_write pair used to provide here (atomic tmp
# file + fsync + os.replace, .bak of the last good version). /config stays
# a read-only source for views (plus SSH keys and state, see symbios-exec
# rules in AGENTS.md).


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
        # Staff (admin) sessions continue to the dashboard. Non-staff users
        # authenticated via Authelia would loop between '/' and '/login/'
        # forever, so they get the 403 page instead.
        if getattr(request.user, 'is_staff', False):
            return redirect('/')
        from .decorators import access_denied
        return access_denied(request)
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
        from .utils.ssh_exec import run_command
        import shlex
        is_ajax = is_ajax_request(request)
        network_type = request.POST.get('network_type', '').strip()
        # Validation and the write live in the settings CLI.
        ok, stdout, stderr = run_command(
            'symbios-settings-setup.sh set'
            f' --network-type {shlex.quote(network_type)}',
            timeout=30)
        if ok:
            # Refresh the local copy: the steps below render from it.
            config = _get_inventory_config()
            vars_ = config.get('all', {}).get('vars', {})
            if is_ajax:
                return JsonResponse({'ok': True})
            messages.success(request, 'Server connection type saved.')
            return redirect('setup')
        if is_ajax:
            return JsonResponse(
                {'ok': False, 'error': (stderr or stdout or 'Invalid network type')},
                status=400)

    ldap_users = _get_ldap_users()
    steps = setup_steps(vars_, ldap_users=ldap_users)
    pending = [s for s in steps if not s['optional'] and s['status'] != 'done']
    complete = is_setup_complete(vars_, ldap_users=ldap_users)
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
    ldap_users = _get_ldap_users()
    steps = setup_steps(vars_, ldap_users=ldap_users)
    pending = [s for s in steps if not s['optional'] and s['status'] != 'done']
    return render(request, 'main/health.html', {
        'setup_incomplete': not is_setup_complete(vars_, ldap_users=ldap_users),
        'setup_pending': len(pending),
    })

@login_required
def health_data(request):
    from .health import run_all
    from django.http import JsonResponse
    return JsonResponse(run_all())


def _stats_index():
    """Read the generated host index without exposing raw filesystem paths."""
    try:
        with open('/log/traefik-stats/index.json', 'r') as index_file:
            data = json.load(index_file)
    except (OSError, ValueError):
        return {'generated_at': '', 'domains': []}
    if not isinstance(data, dict):
        return {'generated_at': '', 'domains': []}
    domains = [
        domain for domain in data.get('domains', [])
        if isinstance(domain, dict)
        and isinstance(domain.get('host'), str)
        and re.fullmatch(r'[A-Za-z0-9.-]+', domain['host'])
    ]
    return {
        'generated_at': data.get('generated_at', ''),
        'domains': domains,
    }


def _stats_bytes(size):
    """Return a compact human-readable byte count for the stats summary."""
    try:
        value = float(size)
    except (TypeError, ValueError):
        return '-'
    for unit in ('B', 'KiB', 'MiB', 'GiB', 'TiB'):
        if value < 1024 or unit == 'TiB':
            return f'{value:.1f} {unit}'
        value /= 1024
    return '-'


def _stats_summary(host):
    """Read the generated summary for one host from the /log volume mount."""
    if not re.fullmatch(r'[A-Za-z0-9.-]+', host):
        return None
    try:
        with open(f'/log/traefik-stats/summaries/{host}.json', 'r') as summary_file:
            data = json.load(summary_file)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    totals = data.get('totals')
    if not isinstance(totals, dict):
        totals = {}
        data['totals'] = totals
    totals['bytes_display'] = _stats_bytes(totals.get('bytes', 0))
    for key in ('daily', 'pages', 'assets', 'not_found_paths', 'referring_sites',
                'clients', 'browsers', 'operating_systems'):
        rows = data.get(key)
        if not isinstance(rows, list):
            continue
        for row in rows:
            if isinstance(row, dict):
                row['bytes_display'] = _stats_bytes(row.get('bytes', 0))
    period = data.get('period')
    if not isinstance(period, dict):
        period = {}
    start = str(period.get('from', ''))[:10]
    end = str(period.get('to', ''))[:10]
    if start and end and start != end:
        data['period_display'] = f'{start} - {end}'
    else:
        data['period_display'] = start or end or '-'
    return data


def _stats_base_context():
    """Share the setup banner context between the stats pages."""
    from .setup_status import setup_steps, is_setup_complete
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    ldap_users = _get_ldap_users()
    steps = setup_steps(vars_, ldap_users=ldap_users)
    pending = [s for s in steps if not s['optional'] and s['status'] != 'done']
    return {
        'setup_incomplete': not is_setup_complete(vars_, ldap_users=ldap_users),
        'setup_pending': len(pending),
    }


@login_required
def stats(request):
    """List the installed hosts that have a generated GoAccess report."""
    index = _stats_index()
    context = _stats_base_context()
    context.update({
        'domains': index['domains'],
        'generated_at': index['generated_at'],
        'invalid_total': sum(int(d.get('invalid_requests', 0) or 0) for d in index['domains']),
    })
    return render(request, 'main/stats.html', context)


@login_required
def stats_domain(request, host):
    """Show the report for one installed host."""
    index = _stats_index()
    domain = next((d for d in index['domains'] if d.get('host') == host), None)
    if domain is None:
        return HttpResponse('Unknown statistics host.', status=404)
    context = _stats_base_context()
    context.update({
        'host': host,
        'generated_at': index['generated_at'],
        'invalid_requests': int(domain.get('invalid_requests', 0) or 0),
        'summary': _stats_summary(host),
    })
    return render(request, 'main/stats_domain.html', context)


@login_required
def stats_report(request, host):
    """Serve one generated HTML report from the /log volume mount."""
    index = _stats_index()
    if not re.fullmatch(r'[A-Za-z0-9.-]+', host):
        return HttpResponse('Invalid statistics host.', status=404)
    if not any(d.get('host') == host for d in index['domains']):
        return HttpResponse('Unknown statistics host.', status=404)
    report_path = f'/log/traefik-stats/reports/{host}.html'
    try:
        with open(report_path, 'rb') as report_file:
            return HttpResponse(report_file.read(), content_type='text/html; charset=utf-8')
    except OSError:
        return HttpResponse(
            '<p>No statistics report is available yet. It is generated hourly '
            'by symbios-traefik-stats.sh.</p>',
            content_type='text/html; charset=utf-8',
            status=503,
        )


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
