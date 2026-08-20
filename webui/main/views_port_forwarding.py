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

from django.shortcuts import render, redirect
from django.http import JsonResponse
from django.contrib import messages
from .decorators import login_required
from .utils.ssh_exec import run_command
from .utils.http import is_ajax_request
from .setup_status import get_page_badge, PAGE_EXPLAIN

import json
import shlex


SCRIPT = 'symbios-router-upnp.sh'


def _auto_accesstype(ip_mode):
    """IP version for the standard forwards, derived from the DNS IPv6 mode."""
    return {'only': 'ipv6', 'yes': 'ipv4_ipv6'}.get(ip_mode, 'ipv4')


def _status_accesstypes(ip_mode):
    """Which accesstypes count as 'open' for the standard ports."""
    if ip_mode == 'only':
        return ('ipv6',)
    if ip_mode == 'yes':
        return ('ipv4', 'ipv6', 'ipv4_ipv6')
    return ('ipv4', 'ipv4_ipv6')


def _run_upnp(args, timeout=15):
    cmd = f'{SCRIPT} {args}'
    ok, stdout, stderr = run_command(cmd, timeout=timeout)
    # The router script always emits a single JSON line on stdout, even for
    # expected failures (e.g. a rule the router refuses), which it signals
    # with exit code 1. Parse stdout first and let the caller see the real
    # error; the raw stderr only carries shell-banner noise and must not
    # shadow the structured answer.
    try:
        return json.loads(stdout)
    except (json.JSONDecodeError, ValueError):
        pass
    if not ok:
        raise RuntimeError(stderr or 'Command failed')
    raise RuntimeError(f'Invalid JSON from script: {stdout[:500]}')


def _add_ufw_extra_inbound(ext_port, protocol):
    """Record an IPv6 port forward in inventory so a reapply re-opens UFW."""
    try:
        port = int(ext_port)
    except (TypeError, ValueError):
        return
    proto = protocol.lower()
    if proto not in ('tcp', 'udp'):
        return
    from .views import _get_inventory_config, _save_inventory_config
    config = _get_inventory_config()
    vars_ = config.setdefault('all', {}).setdefault('vars', {})
    entries = vars_.setdefault('ufw_extra_inbound', [])
    entry = {'port': port, 'proto': proto}
    if entry not in entries:
        entries.append(entry)
        _save_inventory_config(config)


def _remove_ufw_extra_inbound(ext_port, protocol):
    """Remove a recorded IPv6 port forward from inventory."""
    from .views import _get_inventory_config, _save_inventory_config
    config = _get_inventory_config()
    vars_ = config.setdefault('all', {}).setdefault('vars', {})
    entries = vars_.get('ufw_extra_inbound', [])
    kept = [e for e in entries
            if str(e.get('port', '')) != str(ext_port)
            or str(e.get('proto', '')).lower() != protocol.lower()]
    if len(kept) != len(entries):
        vars_['ufw_extra_inbound'] = kept
        _save_inventory_config(config)


def _get_local_ip():
    """Get the host's primary LAN IP for the default forwarding target."""
    try:
        ok, stdout, _ = run_command('symbios-get-local-ip.sh', timeout=10)
        if ok and stdout:
            return stdout.strip()
    except Exception:
        pass
    return ''


def _get_server_info():
    """Get the server's short hostname, LAN IPv4 and global IPv6 (GUA)."""
    try:
        ok, stdout, _ = run_command('symbios-get-local-ips.sh', timeout=10)
        if ok and stdout:
            info = json.loads(stdout)
            return {
                'hostname': info.get('hostname', ''),
                'ipv4': info.get('ipv4', ''),
                'ipv6': info.get('ipv6', ''),
            }
    except Exception:
        pass
    # Fall back to the well-tested IPv4-only lookup
    return {'hostname': '', 'ipv4': _get_local_ip(), 'ipv6': ''}


def _static_ip_command(ip, accesstype='ipv4'):
    """Command prefix that ensures a static IPv4 on FRITZ!Box routers.

    Returns e.g. 'symbios-router-upnp.sh staticip 192.168.188.20 && '
    when the router is a FRITZ!Box and the forward is IPv4-based; otherwise
    an empty string (generic UPnP routers cannot reserve IPs via UPnP, the
    staticip command reports a manual hint there). IPv6-only forwards do not
    need a static IPv4, so they never get the prefix.
    """
    if accesstype not in ('ipv4', 'ipv4_ipv6') or not ip:
        return ''
    try:
        router_info = _run_upnp('detect', timeout=10)
    except Exception:
        router_info = None
    if router_info and router_info.get('router_type') == 'fritzbox':
        return f'{SCRIPT} staticip {shlex.quote(ip)} && '
    return ''


def _get_static_ip_status(local_ip, router_info=None):
    """Query whether 'always same IPv4' is active for the server on the router.

    Returns None when the router is not reachable, or a dict with 'static',
    'ip', 'error'. Generic UPnP routers cannot reserve IPs via UPnP, so the
    dict carries 'manual': True there (the template then shows a hint to
    configure the reservation in the router's web interface). Pass in a
    previously fetched router_info to avoid a second detect call.
    """
    if not local_ip:
        return None
    if router_info is None:
        try:
            router_info = _run_upnp('detect', timeout=10)
        except Exception:
            return None
    if not router_info or router_info.get('available') is not True:
        return None
    if router_info.get('router_type') == 'generic_upnp':
        return {'static': False, 'manual': True, 'ip': local_ip}
    if router_info.get('router_type') != 'fritzbox':
        return None
    try:
        result = _run_upnp(f'staticip-status {shlex.quote(local_ip)}', timeout=15)
    except Exception:
        return None
    if not result.get('ok'):
        return {'static': False, 'error': result.get('error', 'Status unknown')}
    return {'static': bool(result.get('static')), 'ip': result.get('ip', '')}


@login_required
def settings_port_forwarding(request):
    """Main port forwarding settings page with router detection."""
    from .views import _get_inventory_config, _save_inventory_config
    config = _get_inventory_config()
    vars_ = (config.get('all', {}).get('vars', {}) if isinstance(config, dict) else {})

    # DNS IPv6 mode decides the IP version of the standard forwards:
    # '' (IPv4 only) -> IPv4, 'only' -> IPv6, 'yes' -> IPv4+IPv6.
    ip_mode = vars_.get('ddns_ipv6', '')

    is_ajax = is_ajax_request(request)

    # Change actions must not repeat the expensive GET-time router introspection
    # (IPv6 status ~9s, mapping list ~7s). Resolve only what each action needs
    # so the exec-modal gets the job id immediately.
    if request.method == 'POST':
        action = request.POST.get('action', '')

        try:
            if action == 'choose-method':
                # Remember whether the user wants automatic or manual forwards
                # so the page skips the (slow) router introspection in manual
                # mode and restores the chosen view on every visit.
                method = request.POST.get('method', '').strip()
                if method in ('auto', 'manual', ''):
                    vars_['port_forwarding_method'] = method
                    if method == 'manual':
                        # The user takes care of the forwarding rules and the
                        # fixed IP in the router themselves. Trust that without
                        # probing the router, and consider the ports + static
                        # IPv4 step done so the setup assistant completes.
                        vars_['port_forwarding_configured'] = True
                        vars_['port_forwarding_static_ip_configured'] = True
                    else:
                        # Back to automatic mode: the real router state decides
                        # again (ports discovered on the next page render).
                        vars_['port_forwarding_configured'] = False
                        vars_['port_forwarding_static_ip_configured'] = False
                    _save_inventory_config(config)
                if is_ajax:
                    return JsonResponse({'ok': True})
                return redirect('settings_port_forwarding')

            elif action == 'save-credentials':
                username = request.POST.get('username', '').strip()
                password = request.POST.get('password', '').strip()
                # Pass the password via a secret file so it never appears on
                # the command line (and thus in the exec audit log).
                if password:
                    from .utils.secret_file import f_write_secret
                    f_pw_file = f_write_secret('router-password', password)
                    result = _run_upnp(
                        f'config {shlex.quote(username)} --password-file {f_pw_file}',
                        timeout=10)
                else:
                    result = _run_upnp(
                        f'config {shlex.quote(username)} {shlex.quote(password)}',
                        timeout=10)
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job('echo "Router login saved"', timeout=5)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Saving router login...',
                                         'message': 'Router login saved.'})
                messages.success(request, 'Router login saved.')
                return redirect('settings_port_forwarding')

            elif action == 'quick-enable':
                # One-click: ensure static IP (FRITZ!Box), then add the
                # standard rules (HTTP 80, HTTPS 443) plus the optional SSH
                # rule (33 -> 33) only if requested.
                # The IP version follows ddns_ipv6: '' (IPv4 only) creates IPv4
                # rules, 'only' creates IPv6 rules and 'yes' dual-stack rules.
                # Runs via the exec modal job so the user sees live output.
                from .utils.jobs import create_job
                local_ip = _get_local_ip()
                include_ssh = request.POST.get('include_ssh') in ('1', 'on', 'true', 'yes')
                auto_at = _auto_accesstype(ip_mode)
                rules = [
                    (80, 80, 'SymbiOS HTTP', auto_at),
                    (443, 443, 'SymbiOS HTTPS', auto_at),
                ]
                # The server's sshd listens on port 33 directly, so SSH maps
                # 33 -> 33 - identical external/internal ports also satisfy
                # the FRITZ!Box IPv6 constraint.
                if include_ssh:
                    rules.append((33, 33, 'SymbiOS SSH', auto_at))
                router_info = None
                try:
                    router_info = _run_upnp('detect', timeout=10)
                except Exception:
                    router_info = None
                static_ip_cmd = ''
                if router_info and router_info.get('router_type') == 'fritzbox' and local_ip:
                    static_ip_cmd = f'{SCRIPT} staticip {shlex.quote(local_ip)} && '
                cmd = static_ip_cmd + ' && '.join(
                    f'{SCRIPT} add {ext} TCP {intp} {shlex.quote(local_ip)} "{desc}" {at}'
                    for ext, intp, desc, at in rules)
                port_list = ' and '.join(str(e) for e, _, _, _ in rules)
                # Persist UFW allows for IPv6 forwards so a reapply re-opens them.
                if auto_at in ('ipv6', 'ipv4_ipv6'):
                    _add_ufw_extra_inbound(80, 'TCP')
                    _add_ufw_extra_inbound(443, 'TCP')
                if is_ajax:
                    job_id = create_job(cmd, timeout=90)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Enabling port forwarding...',
                                         'message': f'Ensuring static IP and opening ports {port_list} on the router.'})
                ok, stdout, stderr = run_command(cmd, timeout=90)
                if ok:
                    messages.success(request, 'Port forwarding rules added.')
                else:
                    messages.error(request, f'Failed: {stderr or stdout}')
                return redirect('settings_port_forwarding')

            elif action == 'secure-static-ip':
                # Explicitly make the server's IPv4 permanent on the router so
                # IPv4 port forwards keep working. Only meaningful on a
                # FRITZ!Box (generic UPnP routers must be configured manually).
                from .utils.jobs import create_job
                local_ip = _get_local_ip()
                cmd = f'{SCRIPT} staticip {shlex.quote(local_ip)}'
                if is_ajax:
                    job_id = create_job(cmd, timeout=30)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Securing static IP...',
                                         'message': 'Making the server\'s IPv4 address permanent on the router.'})
                ok, stdout, stderr = run_command(cmd, timeout=30)
                if ok and stdout:
                    result = json.loads(stdout)
                    if result.get('ok'):
                        # Persist that the static IPv4 step is settled so the
                        # setup assistant and the page badge reflect it.
                        vars_['port_forwarding_static_ip_configured'] = True
                        _save_inventory_config(config)
                        messages.success(request, result.get('message', 'Static IP secured.'))
                    else:
                        messages.error(request, result.get('error', 'Failed to secure static IP.'))
                else:
                    messages.error(request, f'Failed: {stderr or stdout}')
                return redirect('settings_port_forwarding')

            elif action == 'add':
                ext_port = request.POST.get('ext_port', '').strip()
                protocol = request.POST.get('protocol', 'TCP').strip().upper()
                int_port = request.POST.get('int_port', '').strip()
                int_client = request.POST.get('int_client', '').strip()
                description = request.POST.get('description', 'SymbiOS').strip()
                accesstype = request.POST.get('accesstype', 'ipv4').strip()

                if accesstype not in ('ipv4', 'ipv6', 'ipv4_ipv6'):
                    accesstype = 'ipv4'

                if not ext_port or not int_port or not int_client:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': 'All port fields are required'}, status=400)
                    messages.error(request, 'All port fields are required.')
                    return redirect('settings_port_forwarding')

                args = (f'add {shlex.quote(ext_port)} {shlex.quote(protocol)} {shlex.quote(int_port)} {shlex.quote(int_client)} '
                        f'{shlex.quote(description)} {shlex.quote(accesstype)}')
                # An IPv4 forward only keeps working if the server's IPv4
                # never changes. On a FRITZ!Box, ensure 'always same IPv4'
                # first so the rule points to a stable address.
                static_prefix = _static_ip_command(int_client, accesstype)
                cmd = static_prefix + f'{SCRIPT} {args}'
                # IPv6 forwards connect directly to the host's GUA, so an
                # extra UFW allow rule is needed on the host. Keep the
                # inventory in sync so a reapply re-creates it.
                if accesstype in ('ipv6', 'ipv4_ipv6'):
                    _add_ufw_extra_inbound(ext_port, protocol)
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(cmd, timeout=15)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Adding port forwarding...',
                                         'message': 'Port forwarding added.'})
                ok, stdout, stderr = run_command(cmd, timeout=30)
                # The staticip prefix and the add each emit one JSON line;
                # the add result is the last one.
                result = None
                if ok and stdout:
                    for line in reversed(stdout.splitlines()):
                        try:
                            result = json.loads(line)
                            break
                        except (json.JSONDecodeError, ValueError):
                            continue
                if result and result.get('ok'):
                    messages.success(request, result.get('message', 'Port forwarding added.'))
                elif result:
                    messages.error(request, result.get('error', 'Failed to add port forwarding.'))
                else:
                    messages.error(request, f'Failed: {stderr or stdout}')
                return redirect('settings_port_forwarding')

            elif action == 'delete':
                ext_port = request.POST.get('ext_port', '').strip()
                protocol = request.POST.get('protocol', 'TCP').strip().upper()
                if not ext_port:
                    if is_ajax:
                        return JsonResponse({'ok': False, 'error': 'Port number required'}, status=400)
                    messages.error(request, 'Port number required.')
                    return redirect('settings_port_forwarding')

                args = f'delete {ext_port} {protocol}'
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(f'{SCRIPT} {args}', timeout=15)
                    _remove_ufw_extra_inbound(ext_port, protocol)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Deleting port forwarding...',
                                         'message': 'Port forwarding deleted.'})
                result = _run_upnp(args, timeout=15)
                if result.get('ok'):
                    _remove_ufw_extra_inbound(ext_port, protocol)
                    messages.success(request, result.get('message', 'Port forwarding deleted.'))
                else:
                    messages.error(request, result.get('error', 'Failed to delete port forwarding.'))
                return redirect('settings_port_forwarding')

            elif action == 'remove-credentials':
                # Drop the stored router login entirely.
                if is_ajax:
                    from .utils.jobs import create_job
                    job_id = create_job(f'{SCRIPT} config remove', timeout=10)
                    return JsonResponse({'ok': True, 'job': job_id,
                                         'title': 'Removing router login...',
                                         'message': 'Router login removed.'})
                result = _run_upnp('config remove', timeout=10)
                if result.get('ok'):
                    messages.success(request, 'Router login removed.')
                else:
                    messages.error(request, result.get('error', 'Failed to remove router login.'))
                return redirect('settings_port_forwarding')

        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
            return redirect('settings_port_forwarding')

    # --- GET: full page render ---
    pf_method = vars_.get('port_forwarding_method', '')
    auto_at = _auto_accesstype(ip_mode)

    # Server identity for the default forwarding target and the manual guide
    server_info = _get_server_info()
    local_ip = server_info['ipv4']
    local_ipv6 = server_info['ipv6']
    server_name = server_info['hostname']
    base_domain = vars_.get('base_domain', '')

    # The expensive router introspection only runs in automatic mode; manual
    # mode (and the choice screen) render immediately without probing.
    router_info = None
    detect_error = None
    credentials_configured = False
    credentials_username = ''
    mappings = []
    list_error = None
    ipv6_info = None
    port_status = []
    port_status_known = False

    if pf_method == 'auto':
        try:
            router_info = _run_upnp('detect', timeout=10)
        except Exception as e:
            detect_error = str(e)

        # Check if credentials are stored
        try:
            cfg = _run_upnp('config', timeout=10)
            credentials_configured = cfg.get('configured', False)
            credentials_username = cfg.get('username', '')
        except Exception:
            pass

        # IPv6 state (FRITZ!Box only, read-only)
        try:
            if router_info and router_info.get('router_type') == 'fritzbox':
                ipv6_info = _run_upnp('ipv6info', timeout=20)
        except Exception:
            ipv6_info = None

        # GET: list current mappings
        # FRITZ!Box requires credentials; generic UPnP does not
        should_list = credentials_configured
        if router_info and router_info.get('router_type') == 'generic_upnp':
            should_list = True
        if should_list:
            try:
                list_result = _run_upnp('list', timeout=15)
                if list_result.get('ok'):
                    mappings = list_result.get('mappings', [])
                else:
                    list_error = list_result.get('error', 'Failed to list mappings')
            except Exception as e:
                list_error = str(e)

        # Current status of the standard ports (which rules are already open).
        # Matches by external + internal port so unrelated rules (e.g. the old
        # "SSH DEV" 33->33 forward) do not count as the standard SSH rule.
        status_types = _status_accesstypes(ip_mode)
        standard_ports = [
            {'port': 80, 'internal_port': 80, 'purpose': 'HTTP (Traefik)'},
            {'port': 443, 'internal_port': 443, 'purpose': 'HTTPS (Traefik)'},
            # sshd listens on port 33 directly, so 33 -> 33 works on IPv6 too.
            {'port': 33, 'internal_port': 33, 'purpose': 'SSH (optional)'},
        ]
        for sp in standard_ports:
            match = next((m for m in mappings
                          if m.get('enabled')
                          and str(m.get('external_port', '')) == str(sp['port'])
                          and str(m.get('internal_port', '')) == str(sp['internal_port'])
                          and m.get('accesstype', 'ipv4') in status_types), None)
            port_status.append({**sp,
                                'open': bool(match),
                                'internal_client': match.get('internal_client', '') if match else '',
                                'internal_ipv6': local_ipv6,
                                'accesstype': auto_at})
        port_status_known = bool(should_list) and not list_error

        # Persist whether the standard web forwards (80/443) are present so the
        # setup assistant and the page badge reflect real router state without
        # needing host execution there. Only written when the rules were actually
        # fetched, and only on change.
        if port_status_known:
            status_by_port = {p['port']: p['open'] for p in port_status}
            configured = bool(status_by_port.get(80) and status_by_port.get(443))
            if bool(vars_.get('port_forwarding_configured')) != configured:
                from .views import _save_inventory_config
                vars_['port_forwarding_configured'] = configured
                _save_inventory_config(config)

    # Whether the WebUI can actually change rules on the router: it must be
    # reachable, and either a login is stored (FRITZ!Box) or the router needs
    # no login at all (generic UPnP).
    can_control_router = bool(
        router_info and router_info.get('available')
        and (credentials_configured
             or router_info.get('router_type') == 'generic_upnp'))

    # Whether the server's IPv4 is permanent on the router, so IPv4 port
    # forwards keep working. Only determinable for FRITZ!Box routers.
    static_ip_status = None
    if pf_method == 'auto' and router_info and router_info.get('available'):
        static_ip_status = _get_static_ip_status(local_ip, router_info)

    return render(request, 'main/settings_port_forwarding.html', {
        'pf_method': pf_method,
        'ip_mode': ip_mode,
        'auto_at': auto_at,
        'base_domain': base_domain,
        'router_info': router_info,
        'detect_error': detect_error,
        'credentials_configured': credentials_configured,
        'credentials_username': credentials_username,
        'can_control_router': can_control_router,
        'static_ip_status': static_ip_status,
        'static_ip_configured': bool(vars_.get('port_forwarding_static_ip_configured')),
        'local_ip': local_ip,
        'local_ipv6': local_ipv6,
        'server_name': server_name,
        'mappings': mappings,
        'list_error': list_error,
        'port_status': port_status,
        'port_status_known': port_status_known,
        'ipv6_info': ipv6_info,
        'page_key': 'port-forwarding',
        'page_icon': 'bi-diagram-3',
        'page_title': 'Port Forwarding',
        'page_explain': PAGE_EXPLAIN['port-forwarding'],
        'page_status': get_page_badge('port-forwarding', vars_)[0],
        'page_status_label': get_page_badge('port-forwarding', vars_)[1],
        'page_status_text': get_page_badge('port-forwarding', vars_)[2],
    })


@login_required
def settings_port_forwarding_detect(request):
    """AJAX GET - re-detect router (for live refresh)."""
    try:
        router_info = _run_upnp('detect', timeout=10)
        return JsonResponse(router_info)
    except Exception as e:
        return JsonResponse({'available': False, 'error': str(e)})


@login_required
def settings_port_forwarding_list(request):
    """AJAX GET - list port mappings (for live refresh)."""
    try:
        result = _run_upnp('list', timeout=15)
        return JsonResponse(result)
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e), 'mappings': []})


@login_required
def settings_port_forwarding_config(request):
    """AJAX GET/POST - manage router UPnP credentials."""
    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        username = request.POST.get('username', '').strip()
        password = request.POST.get('password', '').strip()
        try:
            # Pass the password via a secret file so it never appears on the
            # command line (and thus in the exec audit log).
            if password:
                from .utils.secret_file import f_write_secret
                f_pw_file = f_write_secret('router-password', password)
                cmd = f'{SCRIPT} config {shlex.quote(username)} --password-file {f_pw_file}'
            else:
                cmd = f'{SCRIPT} config {shlex.quote(username)} {shlex.quote(password)}'
            ok, stdout, stderr = run_command(cmd, timeout=10)
            if ok and stdout:
                result = json.loads(stdout)
                return JsonResponse(result)
            return JsonResponse({'ok': False, 'error': stderr or 'Failed to save credentials'})
        except Exception as e:
            return JsonResponse({'ok': False, 'error': str(e)})

    # GET: return current config status
    try:
        result = _run_upnp('config', timeout=10)
        return JsonResponse(result)
    except Exception as e:
        return JsonResponse({'ok': True, 'configured': False, 'error': str(e)})


# shlex.quote is replaced by shlex.quote for consistency and security
