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
from .views import _get_inventory_config, _save_inventory_config
from .utils.http import is_ajax_request
from .utils.ssh_exec import run_command
from .playbook_catalog import get_catalog
from .views_services import _sidebar_context


@login_required
def settings_wlan_ap(request):
    """WLAN Access Point configuration page.

    Fetches available wireless interfaces from the host, saves the
    configuration to inventory.yml, and runs the hostapd playbook.
    """
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    # Fetch available wireless interfaces from the host
    wireless_ifaces = []
    try:
        ok, stdout, _ = run_command(
            "iw dev 2>/dev/null | awk '/Interface/{print $2}' | sort -u",
            timeout=10)
        if ok and stdout:
            wireless_ifaces = [line.strip() for line in stdout.splitlines()
                               if line.strip()]
    except Exception:
        pass

    # If no wireless interfaces found, try lspci/lsusb as fallback hint
    if not wireless_ifaces:
        try:
            ok, stdout, _ = run_command(
                "ip -o link show | awk -F': ' '{print $2}' | "
                "while read iface; do "
                "  iw phy \"$(iw dev $iface info 2>/dev/null | "
                "  awk '/wiphy/{print $2}')\" info 2>/dev/null | "
                "  grep -q 'supports' && echo $iface; "
                "done 2>/dev/null || true",
                timeout=15)
            if ok and stdout:
                wireless_ifaces = [line.strip() for line in stdout.splitlines()
                                   if line.strip()]
        except Exception:
            pass

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        try:
            ap_interface = request.POST.get('ap_interface', '').strip()
            ap_name = request.POST.get('ap_name', '').strip()
            ap_passphrase = request.POST.get('ap_passphrase', '').strip()
            ap_country = request.POST.get('ap_country', '').strip().upper()
            # Checkbox: present in the form data when checked, absent otherwise.
            ap_enabled = request.POST.get('ap_enabled') is not None

            # Validate required fields
            if not ap_interface:
                msg = 'Please select a wireless interface.'
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': msg},
                                        status=400)
                messages.error(request, msg)
                return redirect('settings_wlan_ap')

            if not ap_name:
                msg = 'Please enter a WLAN name (SSID).'
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': msg},
                                        status=400)
                messages.error(request, msg)
                return redirect('settings_wlan_ap')

            if ap_passphrase and len(ap_passphrase) < 8:
                msg = 'WPA passphrase must be at least 8 characters.'
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': msg},
                                        status=400)
                messages.error(request, msg)
                return redirect('settings_wlan_ap')

            if ap_country and (len(ap_country) != 2 or not ap_country.isalpha()):
                msg = 'Country code must be two letters (e.g. DE, US).'
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': msg},
                                        status=400)
                messages.error(request, msg)
                return redirect('settings_wlan_ap')

            # Save to inventory.yml
            vars_['ap_interface'] = ap_interface
            vars_['ap_name'] = ap_name
            vars_['ap_passphrase'] = ap_passphrase
            vars_['ap_country'] = ap_country
            vars_['ap_enabled'] = ap_enabled
            vars_['ap_configured'] = True
            _save_inventory_config(config)

            # Run the hostapd playbook via the exec overlay
            cmd = 'symbios-run-playbook.sh base-services/wlan-accesspoint.yml'

            if is_ajax:
                from .utils.jobs import create_job
                job_id = create_job(cmd, timeout=300)
                return JsonResponse({
                    'ok': True,
                    'job': job_id,
                    'title': 'Configuring WLAN Access Point...',
                    'message': 'WLAN AP settings saved.',
                    'command': cmd,
                })

            messages.success(request, 'WLAN AP settings saved.')
            ok, stdout, stderr = run_command(cmd, timeout=120)
            if ok:
                messages.success(request, 'Hostapd configured successfully.')
            else:
                output = (stdout + '\n' + stderr).strip()
                messages.error(request,
                               f'Playbook finished with errors: {output[:500]}')
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)},
                                    status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_wlan_ap')

    # GET: read current config
    catalog = get_catalog()
    # Country code default: derive from the keyboard layout (uppercase) when
    # no explicit ap_country is configured yet.
    default_country = vars_.get('ap_country') or vars_.get('keyboard', '').upper()
    return render(request, 'main/settings_wlan_ap.html', {
        'vars': vars_,
        'ap_enabled': bool(vars_.get('ap_enabled', True)),
        'wireless_ifaces': wireless_ifaces,
        'default_country': default_country,
        'page_key': 'wlan_ap',
        'page_icon': 'bi-wifi',
        'page_title': 'WLAN Access Point',
        'page_explain': (
            'Configure a wireless LAN access point using hostapd. '
            'This creates a WiFi network that devices can connect to. '
            'No routing, DNS or DHCP is configured - only the access point itself.'
        ),
        'page_status': _get_ap_status(vars_),
        'page_status_label': _get_ap_status_label(vars_),
        'page_status_text': _get_ap_status_text(vars_),
        **_sidebar_context(catalog),
    })


def _get_ap_status(vars_):
    """Return the status indicator for the WLAN AP page badge."""
    if not vars_.get('ap_configured'):
        return 'missing'
    if not vars_.get('ap_enabled', True):
        return 'warn'
    return 'ok'


def _get_ap_status_label(vars_):
    """Return the badge label for the WLAN AP status."""
    if not vars_.get('ap_configured'):
        return 'Not configured'
    if not vars_.get('ap_enabled', True):
        return 'Disabled'
    return 'Configured'


def _get_ap_status_text(vars_):
    """Return the longer explanation text for the status badge."""
    if not vars_.get('ap_configured'):
        return 'WLAN Access Point has not been configured yet.'
    if not vars_.get('ap_enabled', True):
        return 'Access Point is disabled. Enable it to broadcast the WiFi network.'
    iface = vars_.get('ap_interface', '-')
    name = vars_.get('ap_name', '-')
    return f'Interface: {iface}, SSID: {name}'
