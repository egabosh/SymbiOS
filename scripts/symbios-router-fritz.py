#!/usr/bin/env python3
# SymbiOS - FRITZ!Box port forwarding via data.lua API
# PBKDF2 login + edify/delete actions for port forwarding.
# Called by symbios-router-upnp.sh dispatcher.
# Reads credentials from environment: ROUTER_UPNP_USER, ROUTER_UPNP_PASS

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
CONFIG_PATH = '/symbios/base-services/symbios-ui/config/router-upnp.conf'


def load_config():
    user = os.environ.get('ROUTER_UPNP_USER', '')
    password = os.environ.get('ROUTER_UPNP_PASS', '')
    if not user and os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            for line in f:
                m = re.match(r"ROUTER_UPNP_USER='(.*)'", line)
                if m:
                    user = m.group(1)
                m = re.match(r"ROUTER_UPNP_PASS='(.*)'", line)
                if m:
                    password = m.group(1)
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

    challenge = challenge_el.text
    parts = challenge.split('$')
    if parts[0] != '2':
        return {'ok': False, 'error': f'Unexpected challenge format: {challenge}'}

    iter1 = int(parts[1])
    salt1_hex = parts[2]
    iter2 = int(parts[3])
    salt2_hex = parts[4]

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

                mapping = {
                    'external_port': r.get('port', ''),
                    'protocol': r.get('protocol', ''),
                    'internal_client': local_ip,
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


def fb_add(host, user, password, ext_port, proto, int_port, int_client, desc,
           accesstype='ipv4'):
    """Add a port forwarding rule.

    accesstype: 'ipv4', 'ipv6' or 'ipv4_ipv6'. FRITZ!Box rules are bound to
    the device (landevice + interface_id), so the box adapts the target
    address automatically when the WAN IPv6 prefix changes.
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

    # Build rule params — semi-colon separated fields as FRITZ!Box expects
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

    # IPv6 rules are device-bound: pass interface_id and ipv6_rulenode so the
    # box resolves the target from the current prefix + device interface ID
    if accesstype in ('ipv6', 'ipv4_ipv6'):
        dev = None
        for d in data_lua(host, sid, 'portoverview').get('data', {}).get(
                'devices', []):
            if d.get('UID') == dev_uid:
                dev = d
                break
        if dev:
            extra += (
                f'&ipv6_rulenode={dev.get("ipv6_rulenode", "")}'
                f'&ifaceid={dev.get("interface_id", "")}'
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
            if (str(r.get('port', '')) == str(ext_port)
                    and r.get('protocol', '').upper() == proto.upper()
                    and r.get('accesstype', '') == accesstype
                    and r.get('state', '') == '2'):
                found = True
                break
        break

    if not found:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': (f'Rule not activated. FRITZ!Box dropped the '
                      f'{accesstype}/{proto}/{ext_port} rule (the box may '
                      f'not support IPv6 forwardings without a global '
                      f'IPv6 prefix).'),
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
    for dev in port_data.get('data', {}).get('devices', []):
        if dev.get('UID') == dev_uid:
            for r in dev.get('rules', []):
                if (str(r.get('port', '')) == ext_port
                        and r.get('protocol', '').upper() == proto.upper()):
                    rule_uid = r.get('UID', '')
                    break
            break

    if not rule_uid:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': f'No rule found for {proto}/{ext_port}',
        }))
        return 1

    del_rule = (
        f'UID={rule_uid};accesstype=ipv4;type=port;'
        f'myfritzdevice_uid=;myfritzservice_uid=;'
    )
    extra = (
        f'rulecount=1&rule1={del_rule}'
        f'&landevice={dev_uid}'
        f'&exposed_ipv4_node=&delete=ok'
    )

    data_lua(host, sid, 'portoverview', extra)

    print(json.dumps({
        'ok': True,
        'router_type': 'fritzbox',
        'message': f'Port forwarding deleted: {proto}/{ext_port}',
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
