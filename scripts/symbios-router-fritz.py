#!/usr/bin/env python3
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
#
# SymbiOS - FRITZ!Box port forwarding via data.lua API
# PBKDF2 login + edify/delete actions for port forwarding.
# Called by symbios-router-upnp.sh dispatcher.
# Reads credentials from environment (ROUTER_UPNP_USER, ROUTER_UPNP_PASS),
# falling back to inventory.yml (all.vars router_upnp_user/router_upnp_password).

import sys
import os
import time
import json
import hashlib
import binascii
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
import re

SCRIPT_NAME = os.path.basename(__file__)
INVENTORY_PATH = os.environ.get(
    'CONFIG_PATH',
    '/symbios/base-services/symbios-ui/config/inventory.yml')


def _inventory_var(lines, key):
    for line in lines:
        m = re.match(r'^\s*' + re.escape(key) + r':\s*(.*)$', line)
        if m:
            return m.group(1).strip().strip('\'"').strip()
    return ''


def load_config():
    user = os.environ.get('ROUTER_UPNP_USER', '')
    password = os.environ.get('ROUTER_UPNP_PASS', '')
    if not user:
        try:
            with open(INVENTORY_PATH) as f:
                lines = f.readlines()
        except OSError:
            lines = []
        user = _inventory_var(lines, 'router_upnp_user')
        password = _inventory_var(lines, 'router_upnp_password')
    return user, password


def get_local_ip():
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('192.168.188.1', 1))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip


def detect_user(xml):
    """Return the FRITZ!Box user to log in with, or '' when none is configured.

    login_sid.lua lists the configured users in <Users>. Most boxes only have
    the shared router password and no separate user; some create a default user
    (e.g. 'fritz4039') that the web UI hides. Prefer the last-used user
    (last="1"), falling back to the first entry.
    """
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return ''
    users = root.findall('Users/User')
    if not users:
        return ''
    for u in users:
        if u.get('last') == '1' and u.text:
            return u.text
    return users[0].text or ''


def login_sid(host, user, password):
    url = f'http://{host}/login_sid.lua?version=2'
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as resp:
            xml = resp.read().decode('utf-8')
    except Exception as e:
        return {'ok': False, 'error': f'HTTP error: {e}'}

    root = ET.fromstring(xml)
    challenge_el = root.find('Challenge')
    if challenge_el is None or not challenge_el.text:
        return {'ok': False, 'error': 'No challenge received'}

    block_el = root.find('BlockTime')
    if block_el is not None and block_el.text and block_el.text.strip() not in ('0', ''):
        return {'ok': False, 'error': f'Login blocked by the router, try again in {block_el.text}s'}

    challenge = challenge_el.text
    parts = challenge.split('$')
    if parts[0] != '2':
        return {'ok': False, 'error': f'Unexpected challenge format: {challenge}'}

    iter1 = int(parts[1])
    salt1_hex = parts[2]
    iter2 = int(parts[3])
    salt2_hex = parts[4]

    # An empty username is only valid when the box has no user at all; a
    # default user reported by the box must be used for the login.
    if not user:
        user = detect_user(xml)

    salt1 = binascii.unhexlify(salt1_hex)
    salt2 = binascii.unhexlify(salt2_hex)
    hash1 = hashlib.pbkdf2_hmac('sha256', password.encode(), salt1, iter1, dklen=32)
    hash2 = hashlib.pbkdf2_hmac('sha256', hash1, salt2, iter2, dklen=32)
    response = f'{salt2_hex}${hash2.hex()}'

    data = urllib.parse.urlencode({'response': response, 'username': user}).encode()
    try:
        req2 = urllib.request.Request(f'http://{host}/login_sid.lua?version=2',
                                       data=data, method='POST')
        with urllib.request.urlopen(req2) as resp2:
            xml2 = resp2.read().decode('utf-8')
    except Exception as e:
        return {'ok': False, 'error': f'Login error: {e}'}

    root2 = ET.fromstring(xml2)
    sid_el = root2.find('SID')
    if sid_el is None:
        return {'ok': False, 'error': 'No SID in response'}

    sid = sid_el.text
    if sid == '0000000000000000':
        return {'ok': False, 'error': 'Login failed - wrong credentials'}

    return {'ok': True, 'sid': sid}


def load_page(host, sid, lp, extra_params=''):
    """Load a UI page so subsequent data.lua calls return that page's data."""
    url = f'http://{host}/?sid={sid}&lp={lp}'
    if extra_params:
        url += '&' + extra_params
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            resp.read()
        return {'ok': True}
    except Exception as e:
        return {'ok': False, 'error': f'HTTP error: {e}'}


def data_lua(host, sid, page, extra_params=''):
    params = {'sid': sid, 'xhr': '1', 'page': page}
    if extra_params:
        for pair in extra_params.split('&'):
            if '=' in pair:
                k, v = pair.split('=', 1)
                params[k] = v

    data = urllib.parse.urlencode(params).encode('utf-8')
    try:
        req = urllib.request.Request(f'http://{host}/data.lua', data=data)
        with urllib.request.urlopen(req, timeout=10) as resp:
            content = resp.read().decode('utf-8')
        if content and content[0] == '{':
            return json.loads(content)
        else:
            return {'ok': False, 'error': 'Non-JSON response'}
    except Exception as e:
        return {'ok': False, 'error': f'HTTP error: {e}'}


def get_device_uid(host, sid):
    load_page(host, sid, 'portoverview')
    data = data_lua(host, sid, 'portoverview')
    local_ip = get_local_ip()

    for dev in data.get('data', {}).get('devices', []):
        if dev.get('forwarding_activ') or dev.get('local_ipv4') == local_ip:
            return dev.get('UID', '')

    for dev in data.get('data', {}).get('devices', []):
        if dev.get('forwarding_activ'):
            return dev.get('UID', '')

    return ''


def get_all_devices(host, sid):
    """Return the list of active devices from the netDev overview."""
    load_page(host, sid, 'netDev')
    data = data_lua(host, sid, 'netDev', 'xhrId=all')
    return data.get('data', {}).get('active', [])


def get_device_static_state(host, sid, uid):
    """Read the edit_device dialog data for a device.

    Returns dict with 'static' (bool: alwaysSameIp), 'ip' (current IPv4),
    or {'error': ...} on failure.
    """
    params = (
        f'xhrId=all&backToPage=netDev&dev={uid}&initalRefreshParamsSaved=true'
    )
    data = data_lua(host, sid, 'edit_device', params)
    if data.get('pid') != 'edit_device':
        return {'error': data.get('error', 'Could not read device dialog')}
    dev = data.get('data', {}).get('vars', {}).get('dev', {})
    ipv4 = dev.get('ipv4', {})
    return {
        'static': ipv4.get('dhcp', {}).get('alwaysSameIp') is True,
        'ip': ipv4.get('current', {}).get('ip', ''),
    }


def ensure_static_ip(host, sid, uid, ip):
    """Idempotently enable 'always same IPv4' for a device.

    Reads the current dialog state first; only writes when needed.
    Returns {'ok': True, 'message': ...} or {'ok': False, 'error': ...}.
    """
    state = get_device_static_state(host, sid, uid)
    if 'error' in state:
        return state
    if state['static'] and state['ip'] == ip:
        return {'ok': True, 'changed': False,
                'message': f'Static IP already set: {ip}'}
    if state['static'] and state['ip'] != ip:
        return {'ok': False, 'error':
                f'Device already has static IP {state["ip"]} '
                f'(requested {ip}) - change manually'}

    load_page(host, sid, 'edit_device',
              f'dev={uid}&dev_node={uid}&backToPage=netDev')
    params = (
        f'page=edit_device&dev={uid}&dev_node={uid}&backToPage=netDev'
        f'&apply=ok&dev_ip={ip}&static_dhcp=on'
    )
    result = data_lua(host, sid, 'edit_device', params)
    if result.get('pid') != 'edit_device':
        return {'ok': False, 'error':
                'Failed to enable static IP (unexpected response)'}
    return {'ok': True, 'changed': True,
            'message': f'Static IP enabled: {ip}'}


def unset_static_ip(host, sid, uid, ip=''):
    """Disable 'always same IPv4' for a device (returns device to DHCP)."""
    state = get_device_static_state(host, sid, uid)
    if 'error' in state:
        return state
    if not state['static']:
        return {'ok': True, 'changed': False,
                'message': 'Static IP already disabled'}
    if ip and state['ip'] and state['ip'] != ip:
        return {'ok': False, 'error':
                f'Device static IP is {state["ip"]}, not {ip} - aborting'}

    load_page(host, sid, 'edit_device',
              f'dev={uid}&dev_node={uid}&backToPage=netDev')
    current_ip = state['ip'] or ip
    params = (
        f'page=edit_device&dev={uid}&dev_node={uid}&backToPage=netDev'
        f'&apply=ok&dev_ip={current_ip}&static_dhcp=off'
    )
    result = data_lua(host, sid, 'edit_device', params)
    if result.get('pid') != 'edit_device':
        return {'ok': False, 'error':
                'Failed to disable static IP (unexpected response)'}
    return {'ok': True, 'changed': True,
            'message': 'Static IP disabled (device uses DHCP)'}


def fb_login(host, user, password):
    result = login_sid(host, user, password)
    if result.get('ok'):
        print(json.dumps({
            'ok': True,
            'router_type': 'fritzbox',
            'sid': result['sid'],
            'gateway': host,
        }))
    else:
        print(json.dumps(result))
    return 0 if result.get('ok') else 1


def fb_list(host, user, password):
    login = login_sid(host, user, password)
    if not login.get('ok'):
        print(json.dumps(login))
        return 1

    sid = login['sid']
    dev_uid = get_device_uid(host, sid)
    if not dev_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Could not determine device UID in FRITZ!Box',
        }))
        return 1

    load_page(host, sid, 'portoverview')
    port_data = data_lua(host, sid, 'portoverview')
    ipv6_active = port_data.get('data', {}).get('ipv6_activ', False)
    for dev in port_data.get('data', {}).get('devices', []):
        if dev.get('UID') == dev_uid:
            rules = dev.get('rules', [])
            result = {
                'ok': True,
                'router_type': 'fritzbox',
                'ipv6_activ': ipv6_active,
                'interface_id': dev.get('interface_id', ''),
                'allow_pcp_and_upnp': dev.get('allow_pcp_and_upnp', False),
                'device_name': dev.get('devicename', ''),
                'device_uid': dev.get('UID', ''),
                'rules': [],
                'mappings': [],
            }
            local_ip = dev.get('local_ipv4', '')
            # IPv6 rules are device-bound, so the real forwarding target is
            # the device's current global IPv6 address, not its IPv4 one.
            local_ipv6 = get_current_ipv6_addr(host, sid, dev_uid) if ipv6_active else ''
            for r in rules:
                app_name = r.get('app', '')
                desc = r.get('description', '')
                accesstype = r.get('accesstype', 'ipv4')
                rule = {
                    'UID': r.get('UID', ''),
                    'app': app_name,
                    'port': r.get('port', ''),
                    'fwport': r.get('fwport', ''),
                    'fwendport': r.get('fwendport', ''),
                    'protocol': r.get('protocol', ''),
                    'accesstype': accesstype,
                    'type': r.get('type', ''),
                    'activated': r.get('activated', False) in [True, '1', 1],
                    'state': r.get('state', '0'),
                    'rulestate': r.get('rulestate', ''),
                    'description': desc,
                }
                result['rules'].append(rule)

                # Show the address family the rule actually forwards to:
                # IPv6-only rules target the IPv6 address, IPv4/IPv4+IPv6
                # rules the IPv4 address (IPv6 carried separately).
                if accesstype == 'ipv6':
                    target_client = local_ipv6 or local_ip
                    target_client_ipv6 = ''
                else:
                    target_client = local_ip
                    target_client_ipv6 = local_ipv6 if accesstype == 'ipv4_ipv6' else ''
                mapping = {
                    'external_port': r.get('port', ''),
                    'protocol': r.get('protocol', ''),
                    'internal_client': target_client,
                    'internal_client_ipv6': target_client_ipv6,
                    'internal_port': r.get('fwport', ''),
                    'description': app_name or desc,
                    'enabled': r.get('state', '') == '2',
                    'accesstype': accesstype,
                }
                result['mappings'].append(mapping)

            print(json.dumps(result))
            return 0

    print(json.dumps({'ok': False, 'error': 'Device not found'}))
    return 1


def fb_upnp_enable(host, sid, dev_uid):
    data_lua(host, sid, 'portoverview',
             f'autoShar_{dev_uid}=1&apply=%C3%9Cbernehmen')


def get_current_ipv6_addr(host, sid, dev_uid):
    """Return the device's current global IPv6 address from the edit dialog.

    FRITZ!Box never updates the stored device interface_id when the host's
    SLAAC address changes, so IPv6 rule creation must derive the IID from the
    most recently used global address instead - otherwise the rule binds to a
    stale, unreachable IID (the box still creates it, but traffic is dropped).
    """
    params = (f'xhrId=all&backToPage=netDev&dev={dev_uid}'
              f'&initalRefreshParamsSaved=true')
    dlg = data_lua(host, sid, 'edit_device', params)
    if dlg.get('pid') != 'edit_device':
        return ''
    ipv6 = dlg.get('data', {}).get('vars', {}).get('dev', {}).get('ipv6', {})
    current = ipv6.get('current', {}).get('ip', '')
    if current and not current.startswith('fe80:') \
            and not current.startswith('fd00:'):
        return current
    best, best_used = '', -1
    for entry in ipv6.get('ipList', []):
        addr = entry.get('ip', '')
        if not addr or addr.startswith('fe80:') or addr.startswith('fd00:'):
            continue
        try:
            lastused = int(entry.get('lastused', 0))
        except (TypeError, ValueError):
            lastused = 0
        if lastused > best_used:
            best_used, best = lastused, addr
    return best


def addr_to_iid(addr):
    """Extract the interface ID part of an IPv6 address as '::xxxx...'."""
    if '::' in addr:
        return '::' + addr.split('::')[-1]
    return '::' + ':'.join(addr.split(':')[-4:])


def fb_add(host, user, password, ext_port, proto, int_port, int_client, desc,
           accesstype='ipv4'):
    """Add a port forwarding rule.

    accesstype: 'ipv4', 'ipv6' or 'ipv4_ipv6'. FRITZ!Box rules are bound to
    the device (landevice + interface_id), so the box adapts the target
    address automatically when the WAN IPv6 prefix changes.

    Note: FRITZ!Box only accepts IPv6 port forwards when ext_port equals
    int_port (no IPv6 port mapping); different ports are silently dropped.
    """
    login = login_sid(host, user, password)
    if not login.get('ok'):
        print(json.dumps(login))
        return 1

    sid = login['sid']
    dev_uid = get_device_uid(host, sid)
    if not dev_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Could not determine device UID',
        }))
        return 1

    fb_upnp_enable(host, sid, dev_uid)

    load_page(host, sid, 'portoverview')

    # Build rule params - semi-colon separated fields as FRITZ!Box expects
    uid_rule = f'newRule{os.getpid()}'
    desc_safe = desc.replace(';', '')
    rule = (
        f'UID={uid_rule};accesstype={accesstype};app={desc_safe};'
        f'description=other;directory=;activated=1;'
        f'fwport={int_port};fwendport={int_port};port={ext_port};'
        f'myfritz_adr=;scheme=;protocol={proto};'
        f'rulestate=new;type=port;myfritzdevice_uid=;myfritzservice_uid=;'
    )
    extra = (
        f'rulecount=1&rule1={rule}'
        f'&landevice={dev_uid}'
        f'&exposed_ipv4_node=&local_ipv4={int_client}'
        f'&device={dev_uid}&edify=ok'
    )

    # FRITZ!Box only supports IPv6 port forwards when the external port equals
    # the internal port; different ports are silently dropped (verified
    # against FRITZ!Box 7430, OS 7.57). Report this up front instead of
    # letting the box swallow the rule.
    if accesstype == 'ipv6' and int_port != ext_port:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': ('FRITZ!Box only supports IPv6 port forwards with the '
                      'same external and internal port (port mapping is IPv4 '
                      f'only). Use an internal port of {ext_port} or choose '
                      'accesstype "ipv4".'),
        }))
        return 1
    if accesstype == 'ipv4_ipv6' and int_port != ext_port:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': ('FRITZ!Box only supports IPv6 port forwards with the '
                      'same external and internal port. The rule would be '
                      'created as IPv4 only; use an internal port of '
                      f'{ext_port} or accesstype "ipv4".'),
        }))
        return 1

    # IPv6 rules are device-bound: pass interface_id, ipv6_rulenode and the
    # four split interface_id fields so the box resolves the target from the
    # current prefix + device interface ID. Without the split fields the box
    # silently drops IPv6 rules (verified against FRITZ!Box 7430, OS 7.57).
    if accesstype in ('ipv6', 'ipv4_ipv6'):
        dev = None
        for d in data_lua(host, sid, 'portoverview').get('data', {}).get(
                'devices', []):
            if d.get('UID') == dev_uid:
                dev = d
                break
        if dev:
            # The box's stored interface_id can go stale after a host address
            # change; bind the rule to the device's current global IPv6
            # address instead (falling back to the stored IID if no global
            # address is reported).
            addr = get_current_ipv6_addr(host, sid, dev_uid)
            iid = addr_to_iid(addr) if addr else dev.get('interface_id', '')
            groups = [g for g in iid.split(':') if g][:4]
            while len(groups) < 4:
                groups.append('')
            extra += (
                f'&ipv6_rulenode={dev.get("ipv6_rulenode", "")}'
                f'&ifaceid={iid}'
                f'&interface_id1={groups[0]}&interface_id2={groups[1]}'
                f'&interface_id3={groups[2]}&interface_id4={groups[3]}'
                f'&isIpv6Active=true'
            )

    result = data_lua(host, sid, 'portoverview', extra)
    if result.get('pid') != 'portoverview':
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Failed to create port forwarding',
        }))
        return 1

    # Verify the rule actually appeared. FRITZ!Box silently drops rules it
    # cannot fulfil (e.g. IPv6 rules without a global prefix), while still
    # returning pid=portoverview, so a false-positive must be caught here.
    time.sleep(1)
    fresh = data_lua(host, sid, 'portoverview').get('data', {}).get(
        'devices', [])
    found = False
    for dev in fresh:
        if dev.get('UID') != dev_uid:
            continue
        for r in dev.get('rules', []):
            at = r.get('accesstype', '')
            if (str(r.get('port', '')) == str(ext_port)
                    and r.get('protocol', '').upper() == proto.upper()
                    and r.get('state', '') == '2'
                    and (at == accesstype
                         or (accesstype == 'ipv4_ipv6'
                             and at in ('ipv4', 'ipv6')))):
                found = True
                break
        break

    if not found:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': (f'Rule not activated. FRITZ!Box dropped the '
                      f'{accesstype}/{proto}/{ext_port} rule. For IPv6 the '
                      f'external port must equal the internal port; also '
                      f'check that the device has a correct IPv6 '
                      f'interface_id.'),
            'warning': 'Check the FRITZ!Box port forwarding list.',
        }))
        return 1

    print(json.dumps({
        'ok': True,
        'router_type': 'fritzbox',
        'message': f'Port forwarding added: {proto}/{ext_port} '
                   f'\u2192 {int_client}:{int_port}',
        'accesstype': accesstype,
    }))
    return 0


def fb_delete(host, user, password, ext_port, proto):
    login = login_sid(host, user, password)
    if not login.get('ok'):
        print(json.dumps(login))
        return 1

    sid = login['sid']
    dev_uid = get_device_uid(host, sid)
    if not dev_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Could not determine device UID',
        }))
        return 1

    load_page(host, sid, 'portoverview')
    port_data = data_lua(host, sid, 'portoverview')

    # Find rule UID matching port+protocol
    rule_uid = ''
    rule_accesstype = ''
    target_dev = {}
    target_rule = {}
    for dev in port_data.get('data', {}).get('devices', []):
        if dev.get('UID') == dev_uid:
            target_dev = dev
            for r in dev.get('rules', []):
                if (str(r.get('port', '')) == ext_port
                        and r.get('protocol', '').upper() == proto.upper()):
                    rule_uid = r.get('UID', '')
                    rule_accesstype = r.get('accesstype', '')
                    target_rule = r
                    break
            break

    if not rule_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': f'No rule found for {proto}/{ext_port}',
        }))
        return 1

    # Build the delete submit exactly like the FRITZ!Box UI (port_edit.js):
    # the target rule is kept in the list marked rulestate=delete and committed
    # via edify=ok together with the device context fields. This removes only
    # this one rule - the box wipes the whole IPv6 rule set when a delete is
    # submitted with delete=ok and the IPv6 device fields instead (verified
    # against FRITZ!Box 7430, OS 7.31).
    app = str(target_rule.get('app', '')).replace(';', '')
    desc = str(target_rule.get('description', '') or '').replace(';', '')
    if not desc:
        desc = app
    activated = '1' if target_rule.get('activated') else '0'
    del_rule = (
        f'UID={rule_uid};'
        f'accesstype={rule_accesstype};'
        f'app={app};description={desc};directory=;'
        f'activated={activated};'
        f'fwport={target_rule.get("fwport", "")};'
        f'fwendport={target_rule.get("fwendport", "")};'
        f'port={target_rule.get("port", "")};'
        f'myfritz_adr=;scheme=;'
        f'protocol={target_rule.get("protocol", "")};'
        f'rulestate=delete;type=port;'
        f'myfritzdevice_uid=;myfritzservice_uid=;'
    )

    iid = target_dev.get('interface_id', '')
    groups = [g for g in iid.split(':') if g][:4]
    while len(groups) < 4:
        groups.append('')
    ipv6_active = port_data.get('data', {}).get('ipv6_activ', False)
    extra = (
        f'rulecount=1&rule1={del_rule}'
        f'&ipv4exposedhost_count=0&exposed_ipv4_node='
        f'&device={dev_uid}&local_ipv4={target_dev.get("local_ipv4", "")}'
        f'&landevice={dev_uid}'
        f'&ipv6_rulenode={target_dev.get("ipv6_rulenode", "")}'
        f'&isIpv6Active={"true" if ipv6_active else "false"}'
        f'&ifaceid={iid}'
        f'&interface_id1={groups[0]}&interface_id2={groups[1]}'
        f'&interface_id3={groups[2]}&interface_id4={groups[3]}'
        f'&edify=ok'
    )

    data_lua(host, sid, 'portoverview', extra)

    # Verify the rule is actually gone (the box silently ignores invalid
    # delete submits while still returning pid=portoverview).
    time.sleep(1)
    fresh = data_lua(host, sid, 'portoverview').get('data', {}).get(
        'devices', [])
    still_there = False
    for dev in fresh:
        if dev.get('UID') != dev_uid:
            continue
        for r in dev.get('rules', []):
            if (str(r.get('port', '')) == str(ext_port)
                    and r.get('protocol', '').upper() == proto.upper()
                    and r.get('UID', '') == rule_uid):
                still_there = True
                break
        break

    if still_there:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': (f'Failed to delete {proto}/{ext_port} rule '
                      f'(UID={rule_uid}).'),
            'warning': 'Check the FRITZ!Box port forwarding list.',
        }))
        return 1

    print(json.dumps({
        'ok': True,
        'router_type': 'fritzbox',
        'message': f'Port forwarding deleted: {proto}/{ext_port}',
        'accesstype': rule_accesstype,
    }))
    return 0


def fb_staticip(host, user, password, ip, dev_uid=''):
    login = login_sid(host, user, password)
    if not login.get('ok'):
        print(json.dumps(login))
        return 1

    sid = login['sid']
    if not dev_uid:
        dev_uid = get_device_uid(host, sid)
    if not dev_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Could not determine device UID',
        }))
        return 1

    result = ensure_static_ip(host, sid, dev_uid, ip)
    if result.get('ok'):
        print(json.dumps({
            'ok': True,
            'router_type': 'fritzbox',
            'message': result.get('message'),
            'changed': result.get('changed', False),
            'device_uid': dev_uid,
        }))
        return 0
    print(json.dumps({
        'ok': False,
        'router_type': 'fritzbox',
        'error': result.get('error'),
    }))
    return 1


def fb_staticip_status(host, user, password, ip='', dev_uid=''):
    """Read-only: report whether 'always same IPv4' is active for this device."""
    login = login_sid(host, user, password)
    if not login.get('ok'):
        print(json.dumps(login))
        return 1

    sid = login['sid']
    if not dev_uid:
        dev_uid = get_device_uid(host, sid)
    if not dev_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Could not determine device UID',
        }))
        return 1

    state = get_device_static_state(host, sid, dev_uid)
    if 'error' in state:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': state['error'],
        }))
        return 1
    print(json.dumps({
        'ok': True,
        'router_type': 'fritzbox',
        'static': state['static'],
        'ip': state['ip'],
        'device_uid': dev_uid,
    }))
    return 0


def fb_unset_staticip(host, user, password, ip, dev_uid=''):
    login = login_sid(host, user, password)
    if not login.get('ok'):
        print(json.dumps(login))
        return 1

    sid = login['sid']
    if not dev_uid:
        dev_uid = get_device_uid(host, sid)
    if not dev_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Could not determine device UID',
        }))
        return 1

    result = unset_static_ip(host, sid, dev_uid, ip)
    if result.get('ok'):
        print(json.dumps({
            'ok': True,
            'router_type': 'fritzbox',
            'message': result.get('message'),
            'changed': result.get('changed', False),
            'device_uid': dev_uid,
        }))
        return 0
    print(json.dumps({
        'ok': False,
        'router_type': 'fritzbox',
        'error': result.get('error'),
    }))
    return 1


def fb_ipv6info(host, user, password):
    """Report IPv6 state of the router and per-device IPv6 addresses.

    FRITZ!Box does not assign static IPv6 addresses per device (SLAAC only);
    port forwardings are device-bound (landevice + interface_id) and follow
    the current WAN prefix automatically.
    """
    login = login_sid(host, user, password)
    if not login.get('ok'):
        print(json.dumps(login))
        return 1

    sid = login['sid']
    load_page(host, sid, 'portoverview')
    port_data = data_lua(host, sid, 'portoverview')
    ipv6_active = port_data.get('data', {}).get('ipv6_activ', False)

    devices = []
    for dev in port_data.get('data', {}).get('devices', []):
        devices.append({
            'UID': dev.get('UID', ''),
            'name': dev.get('devicename', ''),
            'interface_id': dev.get('interface_id', ''),
            'local_ipv4': dev.get('local_ipv4', ''),
            'forwarding_activ': dev.get('forwarding_activ', False),
        })

    # Current IPv6 address of the SymbiOS device (from the edit dialog)
    dev_uid = get_device_uid(host, sid)
    current_ipv6 = ''
    if dev_uid:
        params = (
            f'xhrId=all&backToPage=netDev&dev={dev_uid}'
            f'&initalRefreshParamsSaved=true'
        )
        dlg = data_lua(host, sid, 'edit_device', params)
        dev = dlg.get('data', {}).get('vars', {}).get('dev', {})
        ipv6 = dev.get('ipv6', {})
        current_ipv6 = ipv6.get('current', {}).get('ip', '')
        lst = ipv6.get('ipList', [])
        if not current_ipv6 or current_ipv6.startswith('fe80:'):
            for entry in lst:
                addr = entry.get('ip', '')
                if addr and not addr.startswith('fe80:'):
                    current_ipv6 = addr
                    break
        if not current_ipv6:
            for entry in lst:
                addr = entry.get('ip', '')
                if addr:
                    current_ipv6 = addr
                    break

    print(json.dumps({
        'ok': True,
        'router_type': 'fritzbox',
        'ipv6_activ': ipv6_active,
        'note': ('FRITZ!Box assigns IPv6 via SLAAC only. Rules are device-'
                 'bound (interface_id) and adapt automatically when the WAN '
                 'prefix changes.'),
        'static_ipv6_supported': False,
        'current_device_ipv6': current_ipv6,
        'devices': devices,
    }))
    return 0


def main():
    host = '192.168.188.1'
    action = sys.argv[1] if len(sys.argv) > 1 else 'help'
    user, password = load_config()

    if action == 'login':
        return fb_login(host, user, password)

    elif action == 'list':
        return fb_list(host, user, password)

    elif action == 'ipv6info':
        return fb_ipv6info(host, user, password)

    elif action == 'add':
        if len(sys.argv) < 6:
            print(json.dumps({
                'ok': False,
                'error': 'Usage: add <ext_port> <protocol> '
                         '<int_port> <int_client> [description] [accesstype]',
            }))
            return 1
        ext_port = sys.argv[2]
        proto = sys.argv[3].upper()
        int_port = sys.argv[4]
        int_client = sys.argv[5]
        desc = sys.argv[6] if len(sys.argv) > 6 else 'SymbiOS'
        accesstype = sys.argv[7] if len(sys.argv) > 7 else 'ipv4'
        if accesstype not in ('ipv4', 'ipv6', 'ipv4_ipv6'):
            print(json.dumps({
                'ok': False,
                'error': f'Invalid accesstype: {accesstype} '
                         '(use ipv4, ipv6 or ipv4_ipv6)',
            }))
            return 1
        return fb_add(host, user, password, ext_port, proto,
                       int_port, int_client, desc, accesstype)

    elif action == 'delete':
        if len(sys.argv) < 3:
            print(json.dumps({
                'ok': False,
                'error': 'Usage: delete <ext_port> [protocol]',
            }))
            return 1
        ext_port = sys.argv[2]
        proto = sys.argv[3].upper() if len(sys.argv) > 3 else 'TCP'
        return fb_delete(host, user, password, ext_port, proto)

    elif action == 'staticip':
        if len(sys.argv) < 3:
            print(json.dumps({
                'ok': False,
                'error': 'Usage: staticip <ip> [device_uid]  '
                         '(sets static IPv4 for this device)',
            }))
            return 1
        uid = sys.argv[3] if len(sys.argv) > 3 else ''
        return fb_staticip(host, user, password, sys.argv[2], uid)

    elif action == 'staticip-status':
        ip = sys.argv[2] if len(sys.argv) > 2 else ''
        uid = sys.argv[3] if len(sys.argv) > 3 else ''
        return fb_staticip_status(host, user, password, ip, uid)

    elif action == 'unset-staticip':
        if len(sys.argv) < 3:
            print(json.dumps({
                'ok': False,
                'error': 'Usage: unset-staticip <ip> [device_uid]  '
                         '(removes static IPv4 for this device)',
            }))
            return 1
        uid = sys.argv[3] if len(sys.argv) > 3 else ''
        return fb_unset_staticip(host, user, password, sys.argv[2], uid)

    elif action in ('help', '--help', '-h'):
        print(f'Usage: {SCRIPT_NAME} <action> [args...]')
        print()
        print('FRITZ!Box port forwarding backend (called by symbios-router-upnp.sh)')
        print()
        print('Actions:')
        print('  login                           Test authentication')
        print('  list                            List port forwarding rules')
        print('  add <ext> <proto> <int> <client> [desc] [accesstype]   Add rule')
        print('                                    accesstype: ipv4|ipv6|ipv4_ipv6')
        print('  delete <ext> [proto]            Delete rule')
        print('  staticip <ip>                   Ensure static IPv4 for this device')
        print('  staticip-status [ip]            Report whether static IPv4 is active')
        print('  unset-staticip <ip>             Remove static IPv4 for this device')
        print('  ipv6info                        Report IPv6 state and device')
        print('                                    addresses (read-only)')
        return 0

    else:
        print(json.dumps({
            'ok': False,
            'error': f'Unknown action: {action}',
        }))
        return 1


if __name__ == '__main__':
    sys.exit(main())
