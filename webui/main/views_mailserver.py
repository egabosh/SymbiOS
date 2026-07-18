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

import re
import smtplib
import ssl
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from email.message import EmailMessage
from django.shortcuts import render, redirect
from .decorators import login_required
from django.contrib import messages
from django.http import JsonResponse, HttpResponse
from .views import _get_inventory_config, _save_inventory_config
from .utils.ssh_exec import run_playbook


@login_required
def settings_mailserver(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})

    if request.method == 'POST':
        try:
            if request.POST.get('action') == 'delete':
                if vars_.get('twofa_enabled'):
                    messages.error(request, 'Cannot delete SMTP configuration while 2-Factor Authentication (2FA) is enabled. Disable 2FA under Settings \u2192 Auth first.')
                else:
                    for key in list(vars_):
                        if key.startswith('smtp_'):
                            del vars_[key]
                    _save_inventory_config(config)
                    ok, out = run_playbook('base-services/smtp.yml', timeout=180)
                    if ok:
                        messages.success(request, 'SMTP configuration deleted.')
                    else:
                        messages.error(request, f'Applied with errors: {out[:500]}')
                return redirect('settings_mailserver')

            smtp_server = request.POST.get('smtp_server', '').strip()
            smtp_port = request.POST.get('smtp_port', '').strip()
            smtp_user = request.POST.get('smtp_user', '').strip()
            smtp_password = request.POST.get('smtp_password', '').strip()
            smtp_from = request.POST.get('smtp_from', '').strip()
            smtp_tls = request.POST.get('smtp_tls', '').strip()

            missing = []
            if not smtp_server: missing.append('SMTP Server')
            if not smtp_port: missing.append('SMTP Port')
            if not smtp_password: missing.append('Password')
            if not smtp_from: missing.append('Email Address')
            if missing:
                messages.error(request, f'Required fields missing: {", ".join(missing)}.')
                return redirect('settings_mailserver')

            if not re.match(r'^[^@\s]+@[^@\s]+\.[^@\s]+$', smtp_from):
                messages.error(request, 'Invalid email address format. Must be like <strong>user@domain.tld</strong>.')
                return redirect('settings_mailserver')

            smtp_user = smtp_user.replace('%EMAILADDRESS%', smtp_from).replace('%EMAILLOCALPART%', smtp_from.split('@')[0])

            ok, err = _test_smtp(smtp_server, smtp_port, smtp_user, smtp_password, smtp_from, smtp_tls)
            if not ok:
                messages.error(request, f'{err}')
                return redirect('settings_mailserver')

            vars_['smtp_server'] = smtp_server
            vars_['smtp_port'] = smtp_port
            vars_['smtp_user'] = smtp_user
            vars_['smtp_password'] = smtp_password
            vars_['smtp_from'] = smtp_from
            vars_['smtp_tls'] = smtp_tls
            _save_inventory_config(config)
            ok, out = run_playbook('base-services/smtp.yml', timeout=180)
            if ok and vars_.get('twofa_enabled'):
                ok, out = run_playbook('base-services/authelia.yml', timeout=180)
            if ok:
                messages.success(request, 'Mailserver settings saved and applied.')
            else:
                messages.error(request, f'Applied with errors: {out[:500]}')
        except Exception as e:
            messages.error(request, f'Error: {e}')
        return redirect('settings_mailserver')

    return render(request, 'main/settings_mailserver.html', {'vars': vars_})


def _test_smtp(server, port, user, password, sender, tls_mode):
    try:
        port = int(port)
        if tls_mode == 'tls':
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            with smtplib.SMTP_SSL(server, port, context=ctx, timeout=10) as smtp:
                smtp.login(user, password)
        elif tls_mode == 'starttls':
            with smtplib.SMTP(server, port, timeout=10) as smtp:
                smtp.starttls()
                smtp.login(user, password)
        else:
            with smtplib.SMTP(server, port, timeout=10) as smtp:
                smtp.login(user, password)
        return True, ''
    except smtplib.SMTPAuthenticationError as e:
        return False, f'Authentication rejected ({e.smtp_code})'
    except smtplib.SMTPException as e:
        return False, str(e)
    except Exception as e:
        return False, str(e)


def _send_test_email(server, port, user, password, sender, to_address, tls_mode):
    try:
        port = int(port)
        msg = EmailMessage()
        msg['Subject'] = 'SymbiOS SMTP Test'
        msg['From'] = sender
        msg['To'] = to_address
        msg.set_content('This is a test email from your SymbiOS server.\n\nSMTP configuration is working correctly.')

        if tls_mode == 'tls':
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            with smtplib.SMTP_SSL(server, port, context=ctx, timeout=10) as smtp:
                smtp.login(user, password)
                smtp.send_message(msg)
        elif tls_mode == 'starttls':
            with smtplib.SMTP(server, port, timeout=10) as smtp:
                smtp.starttls()
                smtp.login(user, password)
                smtp.send_message(msg)
        else:
            with smtplib.SMTP(server, port, timeout=10) as smtp:
                smtp.login(user, password)
                smtp.send_message(msg)
        return True, ''
    except Exception as e:
        return False, str(e)


@login_required
def settings_mailserver_discover(request):
    server = request.GET.get('server', '').strip().lower()
    email = request.GET.get('email', '').strip().lower()

    if not server and not email:
        return JsonResponse({'error': 'No server or email provided'})

    result = {'server': server, 'port': '587', 'tls': 'starttls', 'user': '%EMAILADDRESS%'}

    # Extract domain from email if provided
    domain = ''
    if email and '@' in email:
        domain = email.split('@')[1]
    if not domain and server:
        domain = server

    if not domain:
        return JsonResponse({'error': 'Could not determine domain'})

    found = False

    # Try autoconfig sources in order
    autoconfig_urls = [
        f'https://autoconfig.thunderbird.net/v1.1/{domain}',
        f'https://autoconfig.{domain}/mail/config-v1.1.xml',
        f'https://{domain}/.well-known/autoconfig/mail/config-v1.1.xml',
    ]

    for url in autoconfig_urls:
        if found:
            break
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'SymbiOS'})
            with urllib.request.urlopen(req, timeout=10) as resp:
                xml = resp.read()
                root = ET.fromstring(xml)
                for server_elem in root.findall('.//outgoingServer'):
                    if server_elem.find('hostname') is not None:
                        host = server_elem.find('hostname').text
                        result['server'] = host
                        if server_elem.find('port') is not None:
                            result['port'] = server_elem.find('port').text
                        socket_elem = server_elem.find('socketType')
                        if socket_elem is not None:
                            st = socket_elem.text.upper()
                            if st == 'SSL':
                                result['tls'] = 'tls'
                            elif st == 'STARTTLS':
                                result['tls'] = 'starttls'
                            else:
                                result['tls'] = ''
                        user_elem = server_elem.find('username')
                        if user_elem is not None:
                            result['user'] = user_elem.text
                        found = True
                        break
        except Exception:
            pass

    if not found:
        port_guess = {'587': 'starttls', '465': 'tls', '25': ''}
        for p, t in port_guess.items():
            try:
                import socket
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(3)
                if s.connect_ex((domain, int(p))) == 0:
                    result['server'] = domain
                    result['port'] = p
                    result['tls'] = t
                    s.close()
                    break
                s.close()
            except Exception:
                pass

    return JsonResponse(result)


def autoconfig_xml(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    smtp_server = vars_.get('smtp_server', '')
    smtp_port = vars_.get('smtp_port', '587')
    smtp_tls = vars_.get('smtp_tls', 'starttls')
    smtp_user = vars_.get('smtp_user', '%EMAILADDRESS%')
    smtp_from = vars_.get('smtp_from', '')

    domain = smtp_from.split('@')[-1] if '@' in smtp_from else ''

    if not smtp_server or not domain:
        return HttpResponse('<clientConfig version="1.1"/>',
                            content_type='text/xml')

    socket_type = 'SSL' if smtp_tls == 'tls' else 'STARTTLS' if smtp_tls == 'starttls' else 'plain'

    xml = f'''<?xml version="1.0"?>
<clientConfig version="1.1">
  <emailProvider id="{smtp_server}">
    <domain>{domain}</domain>
    <displayName>{domain}</displayName>
    <displayShortName>{domain}</displayShortName>
    <incomingServer type="imap">
      <hostname>{smtp_server}</hostname>
      <port>{smtp_port}</port>
      <socketType>{socket_type}</socketType>
      <username>{smtp_user}</username>
      <authentication>password-cleartext</authentication>
    </incomingServer>
    <outgoingServer type="smtp">
      <hostname>{smtp_server}</hostname>
      <port>{smtp_port}</port>
      <socketType>{socket_type}</socketType>
      <username>{smtp_user}</username>
      <authentication>password-cleartext</authentication>
    </outgoingServer>
  </emailProvider>
</clientConfig>'''
    return HttpResponse(xml, content_type='text/xml')


@login_required
def settings_mailserver_test_email(request):
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'})

    to_address = request.POST.get('to_address', '').strip()
    if not to_address or '@' not in to_address or '.' not in to_address.split('@')[-1]:
        return JsonResponse({'error': 'Invalid recipient email address.'})

    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    smtp_server = request.POST.get('smtp_server', '').strip() or vars_.get('smtp_server', '')
    smtp_port = request.POST.get('smtp_port', '').strip() or vars_.get('smtp_port', '')
    smtp_user = request.POST.get('smtp_user', '').strip() or vars_.get('smtp_user', '%EMAILADDRESS%')
    smtp_password = request.POST.get('smtp_password', '').strip() or vars_.get('smtp_password', '')
    smtp_from = request.POST.get('smtp_from', '').strip() or vars_.get('smtp_from', '')
    smtp_tls = request.POST.get('smtp_tls', '').strip() or vars_.get('smtp_tls', '')

    if not smtp_server or not smtp_port or not smtp_password or not smtp_from:
        return JsonResponse({'error': 'SMTP not fully configured. Save settings first.'})

    smtp_user = smtp_user.replace('%EMAILADDRESS%', smtp_from).replace('%EMAILLOCALPART%', smtp_from.split('@')[0])

    ok, err = _test_smtp(smtp_server, smtp_port, smtp_user, smtp_password, smtp_from, smtp_tls)
    if not ok:
        return JsonResponse({'error': f'SMTP auth failed: {err}'})

    ok, err = _send_test_email(smtp_server, smtp_port, smtp_user, smtp_password, smtp_from, to_address, smtp_tls)
    if ok:
        return JsonResponse({'success': f'Test email sent to {to_address}.'})
    else:
        return JsonResponse({'error': f'Failed to send: {err}'})
