#!/usr/bin/env python3
# SymbiOS - FRITZ!Box port forwarding via data.lua API
# PBKDF2 login + edify/delete actions for port forwarding.
# Called by symbios-router-upnp.sh dispatcher.
# Reads credentials from environment: ROUTER_UPNP_USER, ROUTER_UPNP_PASS

import sys
import os
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
    data = data_lua(host, sid, 'portoverview')
    local_ip = get_local_ip()

    for dev in data.get('data', {}).get('devices', []):
        if dev.get('forwarding_activ') or dev.get('local_ipv4') == local_ip:
            return dev.get('UID', '')

    for dev in data.get('data', {}).get('devices', []):
        if dev.get('forwarding_activ'):
            return dev.get('UID', '')

    return ''


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

    port_data = data_lua(host, sid, 'portoverview')
    for dev in port_data.get('data', {}).get('devices', []):
        if dev.get('UID') == dev_uid:
            rules = dev.get('rules', [])
            result = {
                'ok': True,
                'router_type': 'fritzbox',
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
                rule = {
                    'UID': r.get('UID', ''),
                    'app': app_name,
                    'port': r.get('port', ''),
                    'fwport': r.get('fwport', ''),
                    'fwendport': r.get('fwendport', ''),
                    'protocol': r.get('protocol', ''),
                    'accesstype': r.get('accesstype', ''),
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
                }
                result['mappings'].append(mapping)

            print(json.dumps(result))
            return 0

    print(json.dumps({'ok': False, 'error': 'Device not found'}))
    return 1


def fb_upnp_enable(host, sid, dev_uid):
    data_lua(host, sid, 'portoverview',
             f'autoShar_{dev_uid}=1&apply=%C3%9Cbernehmen')


def fb_add(host, user, password, ext_port, proto, int_port, int_client, desc):
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

    # Build rule params — semi-colon separated fields as FRITZ!Box expects
    uid_rule = f'newRule{os.getpid()}'
    desc_safe = desc.replace(';', '')
    rule = (
        f'UID={uid_rule};accesstype=ipv4;app={desc_safe};'
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

    result = data_lua(host, sid, 'portoverview', extra)
    if result.get('pid') == 'portoverview':
        print(json.dumps({
            'ok': True,
            'router_type': 'fritzbox',
            'message': f'Port forwarding added: {proto}/{ext_port} '
                       f'\u2192 {int_client}:{int_port}',
        }))
        return 0
    else:
        print(json.dumps({
            'ok': False,
            'router_type': 'fritzbox',
            'error': 'Failed to create port forwarding',
        }))
        return 1


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


def main():
    host = '192.168.188.1'
    action = sys.argv[1] if len(sys.argv) > 1 else 'help'
    user, password = load_config()

    if action == 'login':
        return fb_login(host, user, password)

    elif action == 'list':
        return fb_list(host, user, password)

    elif action == 'add':
        if len(sys.argv) < 6:
            print(json.dumps({
                'ok': False,
                'error': 'Usage: add <ext_port> <protocol> '
                         '<int_port> <int_client> [description]',
            }))
            return 1
        ext_port = sys.argv[2]
        proto = sys.argv[3].upper()
        int_port = sys.argv[4]
        int_client = sys.argv[5]
        desc = sys.argv[6] if len(sys.argv) > 6 else 'SymbiOS'
        return fb_add(host, user, password, ext_port, proto,
                       int_port, int_client, desc)

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

    elif action in ('help', '--help', '-h'):
        print(f'Usage: {SCRIPT_NAME} <action> [args...]')
        print()
        print('FRITZ!Box port forwarding backend (called by symbios-router-upnp.sh)')
        print()
        print('Actions:')
        print('  login                           Test authentication')
        print('  list                            List port forwarding rules')
        print('  add <ext> <proto> <int> <client> [desc]   Add rule')
        print('  delete <ext> [proto]            Delete rule')
        return 0

    else:
        print(json.dumps({
            'ok': False,
            'error': f'Unknown action: {action}',
        }))
        return 1


if __name__ == '__main__':
    sys.exit(main())
