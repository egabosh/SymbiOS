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
from .decorators import login_required
from django.contrib import messages
from django.http import JsonResponse
from .views import _get_inventory_config
from .constants import CONFIG_PATH
from .utils.ssh_exec import run_command
from .utils.http import is_ajax_request
from .utils.secret_file import f_write_secret
from .setup_status import get_page_badge, PAGE_EXPLAIN

import json
import yaml
import os
import re
import shlex


def _start_reapply(playbooks=None, force=False, prefix='', stdin_data=None):
    """Start symbios-reapply.sh as a tracked job and return the job id.

    The job streams live output to the browser via /exec/output/.
    With force=True, playbooks that are not yet marked as installed are
    run anyway (--force).
    An optional prefix (a script name) is chained in front of the reapply with
    '&&', so it runs first and its output shows up in the same exec modal.
    An optional stdin_data payload is attached to the job (consumed by the
    prefix command, e.g. settings scripts reading --json-stdin; commands
    chained behind it see EOF, which Ansible ignores).
    Returns a (job_id, title, cmd) tuple.
    """
    from .utils.jobs import create_job
    if playbooks:
        args = ' '.join(playbooks)
        if force:
            flag = f'--only --force {args}'
        else:
            flag = f'--only {args}'
        title = 'Reapplying: ' + ', '.join(playbooks)
    else:
        flag = ''
        title = 'Reapplying all playbooks...'
    cmd = f'symbios-reapply.sh {flag}'
    if prefix:
        cmd = f'{prefix} && {cmd}'
    job_id = create_job(cmd, timeout=3600, stdin_data=stdin_data)
    return job_id, title, cmd


# DNS views live in views_settings_dns.py, AI probe endpoints in
# views_settings_ai.py (split per domain; shared helpers stay here).


@login_required
def settings_local_ip(request):
    try:
        ok, stdout, _ = run_command('symbios-get-local-ip.sh', timeout=10)
        local_ipv4 = stdout.strip() if ok and stdout else ""
        return JsonResponse({"local_ipv4": local_ipv4})
    except Exception as e:
        return JsonResponse({"local_ipv4": "", "error": str(e)})


def _is_valid_ssh_pubkey(key):
    parts = key.strip().split(None, 2)
    if len(parts) < 2:
        return False
    valid_types = {"ssh-rsa", "ssh-ed25519", "ssh-dss",
                   "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"}
    if parts[0] not in valid_types:
        return False
    try:
        import base64
        base64.b64decode(parts[1])
        return True
    except Exception:
        return False


def _read_host_authorized_keys():
    # Fetch live host keys via the settings CLI (JSON), not a volume mount
    # and not a raw cat: the script splits user keys from the preserved
    # symbios-base-webui system key. Returns (user_keys, system_keys).
    try:
        ok, stdout, _ = run_command('symbios-settings-ssh-keys.sh list --json',
                                    timeout=10)
        if ok and stdout:
            data = json.loads(stdout.strip())
            return data.get('user_keys', []), data.get('system_keys', [])
    except Exception:
        pass
    return [], []


@login_required
def settings_ssh_keys(request):
    # Fetch host authorized_keys via the settings CLI.
    user_keys, system_keys = _read_host_authorized_keys()

    if request.method == "POST":
        action = request.POST.get("action", "save")
        is_ajax = is_ajax_request(request)
        try:
            if action == "add":
                new_key = request.POST.get("new_key", "").strip()
                if not new_key:
                    raise ValueError("No key provided")
                cmd = ('symbios-settings-ssh-keys.sh add'
                       f' --key {shlex.quote(new_key)}')
                stdin_data = None
            elif action == "remove":
                remove_idx = request.POST.get("index", "")
                if not remove_idx.isdigit():
                    raise ValueError("Invalid key index")
                cmd = ('symbios-settings-ssh-keys.sh remove'
                       f' --index {shlex.quote(remove_idx)}')
                stdin_data = None
            elif action == "save":
                # Raw textarea lines go via stdin; the script validates
                # (comments/empty lines allowed) and preserves system keys.
                keys_text = request.POST.get("keys", "")
                cmd = 'symbios-settings-ssh-keys.sh set --stdin'
                stdin_data = keys_text
            else:
                raise ValueError(f"Unknown action: {action}")

            # Validation lives in the script; failures show up in the
            # exec modal (AJAX) or as an error message (fallback).
            if is_ajax:
                from .utils.jobs import create_job
                job_id = create_job(cmd, timeout=60, stdin_data=stdin_data)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': 'Saving SSH keys...',
                                     'message': 'SSH keys saved.',
                                     'command': cmd})

            ok, stdout, stderr = run_command(
                cmd, timeout=15, stdin_data=stdin_data)
            if not ok:
                raise RuntimeError(f"Failed to write authorized_keys: {stderr or stdout}")

            messages.success(request, "SSH keys saved.")
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=400)
            messages.error(request, f"Error: {e}")
        return redirect("settings_ssh_keys")

    # Enrich user keys with parsed type+comment
    key_info = []
    for k in user_keys:
        parts = k.split(None, 2)
        key_info.append({
            "line": k,
            "type": parts[0] if len(parts) > 0 else "",
            "data": parts[1] if len(parts) > 1 else "",
            "comment": parts[2] if len(parts) > 2 else "",
        })
    system_info = []
    for k in system_keys:
        parts = k.split(None, 2)
        system_info.append({
            "line": k,
            "type": parts[0] if len(parts) > 0 else "",
            "data": parts[1] if len(parts) > 1 else "",
            "comment": parts[2] if len(parts) > 2 else "",
        })
    return render(request, "main/settings_ssh_keys.html", {
        "keys": user_keys,
        "key_info": key_info,
        "system_keys": system_info,
    })


@login_required
def settings_config(request):
    raw_yaml = ''
    try:
        with open(CONFIG_PATH, 'r') as f:
            raw_yaml = f.read()
    except FileNotFoundError:
        raw_yaml = '# inventory.yml not found\n'
    except Exception as e:
        raw_yaml = f'# Error reading config: {e}\n'

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        content = request.POST.get('config_content', '')
        # Validate YAML before sending (fast local feedback; the CLI
        # re-validates authoritatively before writing).
        try:
            parsed = yaml.safe_load(content)
            if not isinstance(parsed, dict):
                if is_ajax:
                    return JsonResponse({'ok': False,
                                         'error': 'Config must be a YAML mapping (dictionary).'}, status=400)
                messages.error(request, 'Config must be a YAML mapping (dictionary).')
                return redirect('settings_config')
        except yaml.YAMLError as e:
            if is_ajax:
                return JsonResponse({'ok': False,
                                     'error': f'YAML syntax error: {e}'}, status=400)
            messages.error(request, f'YAML syntax error: {e}')
            return redirect('settings_config')
        # The write itself lives in the inventory CLI (single writer).
        try:
            ok, stdout, stderr = run_command(
                'symbios-inventory.py write', timeout=30,
                stdin_data=content)
            if not ok:
                err = (stderr or stdout or 'Failed to save config.')
                if is_ajax:
                    return JsonResponse({'ok': False, 'error': err}, status=400)
                messages.error(request, f'Error: {err}')
                return redirect('settings_config')
            if is_ajax:
                job_id, title, cmd = _start_reapply()
                return JsonResponse({'ok': True, 'job': job_id, 'title': title,
                                     'message': 'Config saved.',
                                     'command': cmd})
            messages.success(request, 'Config saved.')
            messages.info(request, 'Reapplying all playbooks in the background...')
            _start_reapply()
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False,
                                     'error': f'Error saving config: {e}'}, status=500)
            messages.error(request, f'Error saving config: {e}')
        return redirect('settings_config')

    return render(request, 'main/settings_config.html', {
        'config_content': raw_yaml,
    })


def _backup_status():
    """Read the backup status JSON written by the host's backup job."""
    try:
        with open('/log/backup-status.json') as fh:
            return json.load(fh)
    except (FileNotFoundError, PermissionError, json.JSONDecodeError, ValueError):
        return None


@login_required
def settings_backup(request):
    config = _get_inventory_config()
    if 'all' not in config:
        config['all'] = {}
    if 'vars' not in config['all']:
        config['all']['vars'] = {}
    vars_ = config['all']['vars']

    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        # Validation and the inventory write live in the settings CLI
        # (single source of truth). The exclude textarea goes via stdin;
        # no secrets are involved in this domain.
        encryption = ('true' if request.POST.get('backup_encryption') == 'on'
                      else 'false')
        set_cmd = ('symbios-settings-backup.sh set'
                   f' --host {shlex.quote(request.POST.get("backup_server_host", "").strip())}'
                   f' --port {shlex.quote(request.POST.get("backup_server_port", "").strip())}'
                   f' --user {shlex.quote(request.POST.get("backup_server_user", "").strip())}'
                   f' --path {shlex.quote(request.POST.get("backup_server_path", "").strip())}'
                   f' --encryption {encryption}'
                   ' --exclude-stdin')
        stdin_data = request.POST.get('backup_exclude', '')
        try:
            if is_ajax:
                from .utils.jobs import create_job
                cmd = (f'{set_cmd} && symbios-reapply.sh'
                       ' --only base-services/backup.yml')
                job_id = create_job(cmd, timeout=3600, stdin_data=stdin_data)
                return JsonResponse({'ok': True, 'job': job_id,
                                     'title': 'Reapplying: base-services/backup.yml',
                                     'message': 'Backup settings saved.',
                                     'command': cmd})
            ok, stdout, stderr = run_command(set_cmd, timeout=30,
                                            stdin_data=stdin_data)
            if not ok:
                messages.error(request, f'Error: {stderr or stdout}')
                return redirect('settings_backup')
            messages.success(request, 'Backup settings saved.')
            messages.info(request, 'Reapplying backup playbook in the background...')
            _start_reapply(playbooks=['base-services/backup.yml'])
        except Exception as e:
            if is_ajax:
                return JsonResponse({'ok': False, 'error': str(e)}, status=500)
            messages.error(request, f'Error: {e}')
        return redirect('settings_backup')

    # GET: collect snapshot list, service scopes and the SSH public key
    data = {'snapshots': [], 'services': [], 'mode': '', 'warning': '', 'pubkey': ''}
    try:
        ok, stdout, stderr = run_command('symbios-backup-list.sh', timeout=90)
        if ok and stdout:
            parsed = json.loads(stdout)
            if isinstance(parsed, dict):
                data.update(parsed)
    except Exception:
        pass
    return render(request, 'main/settings_backup.html', {
        'vars': vars_,
        'status': _backup_status(),
        'data': data,
        'snapshots_json': json.dumps(data.get('snapshots') or []),
        'services_json': json.dumps(data.get('services') or []),
    })


@login_required
def settings_backup_test(request):
    """AJAX POST - test SSH/SCP connectivity to the backup server."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    host = request.POST.get('host', '').strip()
    port = request.POST.get('port', '').strip() or '22'
    user = request.POST.get('user', '').strip() or 'root'
    path = request.POST.get('path', '').strip()

    if not host:
        return JsonResponse({'ok': False, 'error': 'Host is required'})

    try:
        port_int = int(port)
        if port_int < 1 or port_int > 65535:
            return JsonResponse({'ok': False, 'error': 'Invalid port number'})
    except ValueError:
        return JsonResponse({'ok': False, 'error': 'Port must be a number'})

    # Delegate to symbios-test-ssh.sh via the exec gateway
    cmd = f'symbios-test-ssh.sh {shlex.quote(host)} {shlex.quote(port)} {shlex.quote(user)}'
    if path:
        cmd += f' {shlex.quote(path)}'
    try:
        ok, stdout, stderr = run_command(cmd, timeout=20)
        if ok and stdout:
            return JsonResponse(json.loads(stdout))
        else:
            return JsonResponse({'ok': False, 'error': stderr or 'SSH test failed'})
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e)})


def _validate_backup_date_scope(date_str, scope):
    """Validate a snapshot date and restore scope. Returns an error or None."""
    if not re.match(r'^\d{4}-\d{2}-\d{2}$', date_str or ''):
        return 'Invalid date format (expected YYYY-MM-DD)'
    if scope != '--full' and not re.match(r'^[\w.-]+$', scope or ''):
        return 'Invalid service name'
    return None


@login_required
def settings_backup_snapshots(request):
    """AJAX GET - refresh the list of available snapshots."""
    try:
        ok, stdout, stderr = run_command('symbios-backup-list.sh', timeout=90)
        if ok and stdout:
            return JsonResponse(json.loads(stdout))
        return JsonResponse({'ok': False, 'error': stderr or 'Listing failed'})
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e)})


@login_required
def settings_backup_passphrase(request):
    """AJAX POST - show or generate the backup encryption passphrase.

    The passphrase is generated on the host and stored in the config dir;
    it never appears in a shell command line or audit log.
    """
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'}, status=400)
    action = request.POST.get('action', 'show')
    cmd = ('symbios-backup.sh gen-passphrase' if action == 'generate'
           else 'symbios-backup.sh get-passphrase')
    try:
        ok, stdout, stderr = run_command(cmd, timeout=20)
        if ok and stdout:
            return JsonResponse(json.loads(stdout))
        return JsonResponse({'ok': False, 'error': stderr or 'Command failed'})
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e)})


@login_required
def settings_backup_restore_plan(request):
    """AJAX POST - show what a restore of <date>/<scope> would do."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'}, status=400)
    date_str = request.POST.get('date', '').strip()
    scope = request.POST.get('scope', '--full').strip() or '--full'
    err = _validate_backup_date_scope(date_str, scope)
    if err:
        return JsonResponse({'ok': False, 'error': err}, status=400)
    cmd = f'symbios-restore.sh plan {shlex.quote(date_str)} {shlex.quote(scope)}'
    try:
        ok, stdout, stderr = run_command(cmd, timeout=120)
        if ok and stdout:
            return JsonResponse(json.loads(stdout))
        return JsonResponse({'ok': False, 'error': stderr or 'Plan failed'})
    except Exception as e:
        return JsonResponse({'ok': False, 'error': str(e)})


@login_required
def settings_backup_restore(request):
    """AJAX POST - start a restore as a detached background job."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'}, status=400)
    date_str = request.POST.get('date', '').strip()
    scope = request.POST.get('scope', '--full').strip() or '--full'
    err = _validate_backup_date_scope(date_str, scope)
    if err:
        return JsonResponse({'ok': False, 'error': err}, status=400)
    from .utils.jobs import create_job
    cmd = (f'symbios-restore.sh restore {shlex.quote(date_str)} '
           f'{shlex.quote(scope)} --yes')
    job_id = create_job(cmd, timeout=3600)
    target = 'the whole system' if scope == '--full' else f'"{scope}"'
    return JsonResponse({
        'ok': True,
        'job': job_id,
        'title': f'Restoring {target} from {date_str}...',
        'message': 'Restore started.',
        'command': cmd,
    })


@login_required
def settings_backup_runnow(request):
    """AJAX POST - start a backup run right now (as a background job)."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'}, status=400)
    from .utils.jobs import create_job
    cmd = 'backup.sh'
    job_id = create_job(cmd, timeout=3600)
    return JsonResponse({
        'ok': True,
        'job': job_id,
        'title': 'Running backup...',
        'message': 'Backup started.',
        'command': cmd,
    })


# ---------------------------------------------------------------------------
# Data Disk - move /symbios data root to a separate disk
# ---------------------------------------------------------------------------

_DATA_PART_SCRIPT = '/usr/local/sbin/symbios-data-partition.sh'


@login_required
def settings_disk(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    badge = get_page_badge('disk', vars_)
    return render(request, 'main/settings_disk.html', {
        'vars': vars_,
        'page_key': 'disk',
        'page_icon': 'bi-device-hdd',
        'page_title': 'Data Disk',
        'page_explain': PAGE_EXPLAIN['disk'],
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


@login_required
def settings_disk_list(request):
    """AJAX GET - list block devices via shell script."""
    ok, stdout, stderr = run_command(
        f'{_DATA_PART_SCRIPT} list', timeout=10)
    if not ok:
        return JsonResponse({'ok': False, 'error': stderr or 'lsblk failed'})
    try:
        data = json.loads(stdout)
        devices = data.get('blockdevices', [])
        filtered = [_describe_block(dev) for dev in devices]
        return JsonResponse({'ok': True, 'devices': filtered})
    except json.JSONDecodeError as e:
        return JsonResponse({'ok': False, 'error': f'Failed to parse lsblk: {e}'})


def _describe_block(dev):
    """Build a flat description dict for a block device (recursive for children)."""
    item = {
        'name': dev.get('name', ''),
        'path': '/dev/' + dev.get('name', ''),
        'size': dev.get('size', ''),
        'type': dev.get('type', ''),
        'fstype': dev.get('fstype') or '',
        'mountpoint': dev.get('mountpoint') or '',
        'model': (dev.get('model') or '').strip(),
        'uuid': dev.get('uuid') or '',
        'label': (dev.get('label') or '').strip(),
        'tran': dev.get('tran') or '',
        'rm': dev.get('rm', False),
        'children': [],
    }
    for child in dev.get('children', []) or []:
        item['children'].append(_describe_block(child))
    return item


@login_required
def settings_disk_status(request):
    """AJAX GET - check /symbios mount status and LUKS status."""
    ok, stdout, stderr = run_command(
        f'{_DATA_PART_SCRIPT} status', timeout=15)
    if not ok:
        return JsonResponse({
            'ok': False, 'error': stderr or 'status check failed',
            'data_device': '', 'data_fstype': '', 'data_size': '',
            'data_used': '', 'data_avail': '',
            'luks_name': '', 'luks_device': '',
            'luks_open': False, 'needs_unlock': False,
        })
    try:
        data = json.loads(stdout)
        return JsonResponse(data)
    except json.JSONDecodeError:
        return JsonResponse({
            'ok': False, 'error': f'Invalid JSON from script: {stdout[:500]}',
            'data_device': '', 'data_fstype': '', 'data_size': '',
            'data_used': '', 'data_avail': '',
            'luks_name': '', 'luks_device': '',
            'luks_open': False, 'needs_unlock': False,
        })


@login_required
def settings_disk_setup(request):
    """AJAX POST - format, optionally encrypt, and mount a disk as /symbios.
    Returns a job_id for the exec modal (streams live output)."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    device = request.POST.get('device', '').strip()
    encrypt = 'yes' if request.POST.get('encrypt', 'no') == 'yes' else 'no'
    password = request.POST.get('password', '').strip()

    if not device:
        return JsonResponse({'ok': False, 'error': 'No device selected'})
    if not device.startswith('/dev/'):
        return JsonResponse({'ok': False, 'error': 'Invalid device path'})
    if encrypt == 'yes' and not password:
        return JsonResponse({'ok': False, 'error': 'Password required for LUKS encryption'})

    f_pw_file = None
    if encrypt == 'yes':
        f_pw_file = f_write_secret('luks-passphrase', password)
        cmd_parts = [f'{_DATA_PART_SCRIPT} setup', device, encrypt, f_pw_file]
    else:
        cmd_parts = [f'{_DATA_PART_SCRIPT} setup', device, encrypt]
    cmd = ' '.join(cmd_parts)

    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=600)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Migrating /symbios to new disk...',
                             'message': f'Setting up {device} as /symbios.',
                             'command': cmd})

    # Fallback: synchronous execution
    ok, stdout, stderr = run_command(cmd, timeout=600)
    output = stdout
    if stderr:
        output = output + '\n' + stderr

    try:
        data = json.loads(output)
        return JsonResponse(data)
    except json.JSONDecodeError:
        if ok:
            return JsonResponse({'ok': True, 'message': 'Disk setup complete.'})
        return JsonResponse({'ok': False, 'error': f'Setup failed:\n{output[-2000:]}'})


@login_required
def settings_disk_rollback(request):
    """AJAX POST - rollback last /symbios migration via exec modal."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    cmd = f'{_DATA_PART_SCRIPT} rollback'

    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=300)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Rolling back /symbios migration...',
                             'message': 'Restoring original /symbios location.',
                             'command': cmd})

    ok, stdout, stderr = run_command(cmd, timeout=300)
    output = stdout
    if stderr:
        output = output + '\n' + stderr
    try:
        data = json.loads(output)
        return JsonResponse(data)
    except json.JSONDecodeError:
        if ok:
            return JsonResponse({'ok': True, 'message': 'Rollback complete.'})
        return JsonResponse({'ok': False, 'error': f'Rollback failed:\n{output[-2000:]}'})


@login_required
def settings_disk_umount(request):
    """AJAX POST - unmount and close a LUKS /symbios volume."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    cmd = f'{_DATA_PART_SCRIPT} umount'
    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=300)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Unmounting /symbios...',
                             'message': '/symbios unmounted and LUKS volume closed.',
                             'command': cmd})

    ok, stdout, stderr = run_command(cmd, timeout=30)
    try:
        data = json.loads(stdout)
        return JsonResponse(data)
    except json.JSONDecodeError:
        return JsonResponse({'ok': True, 'message': '/symbios unmounted and LUKS volume closed.'})


@login_required
def settings_disk_change_password(request):
    """AJAX POST - change LUKS passphrase for an encrypted /symbios device."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})

    current_password = request.POST.get('current_password', '').strip()
    new_password = request.POST.get('new_password', '').strip()

    if not current_password:
        return JsonResponse({'ok': False, 'error': 'Current password is required'})
    if not new_password:
        return JsonResponse({'ok': False, 'error': 'New password is required'})
    if current_password == new_password:
        return JsonResponse({'ok': False, 'error': 'New password must differ from current password'})

    f_old_pw = f_write_secret('luks-current-password', current_password)
    f_new_pw = f_write_secret('luks-new-password', new_password)
    cmd_parts = [
        f'{_DATA_PART_SCRIPT} change-password',
        f_old_pw,
        f_new_pw,
    ]
    cmd = ' '.join(cmd_parts)

    is_ajax = is_ajax_request(request)
    if is_ajax:
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=60)
        return JsonResponse({'ok': True, 'job': job_id,
                             'title': 'Changing LUKS passphrase...',
                             'message': 'Updating encryption key.',
                             'command': cmd})

    ok, stdout, stderr = run_command(cmd, timeout=60)
    output = stdout
    if stderr:
        output = output + '\n' + stderr
    try:
        data = json.loads(output)
        return JsonResponse(data)
    except json.JSONDecodeError:
        if ok:
            return JsonResponse({'ok': True, 'message': 'LUKS passphrase changed.'})
        return JsonResponse({'ok': False, 'error': f'Password change failed:\n{output[-2000:]}'})


# ---------------------------------------------------------------------------
# Playbooks management
# ---------------------------------------------------------------------------

USER_PLAYBOOKS_DIR = "/config/user-playbooks"


def _ensure_user_playbooks_dir():
    os.makedirs(USER_PLAYBOOKS_DIR, exist_ok=True)


def _safe_playbook_name(name):
    """Sanitize a playbook filename: only allow [a-z0-9_-] and require .yml."""
    name = os.path.basename(name)
    name = re.sub(r'[^a-z0-9_\-\.]', '-', name.lower())
    if not name.endswith('.yml'):
        name = name.rsplit('.', 1)[0] + '.yml'
    return name


@login_required
def settings_playbooks(request):
    """Show list of user-uploaded playbooks with upload form."""
    from .playbook_catalog import parse_docs, get_catalog
    from .views_services import _sidebar_context
    _ensure_user_playbooks_dir()
    files = sorted(f for f in os.listdir(USER_PLAYBOOKS_DIR)
                   if f.endswith('.yml') and f != 'inventory.yml')
    playbooks = []
    for fn in files:
        path = os.path.join(USER_PLAYBOOKS_DIR, fn)
        docs = parse_docs(path)
        playbooks.append({
            'filename': fn,
            'title': (docs or {}).get('short_description', fn[:-4]) if docs else fn[:-4],
            'has_docs': docs is not None,
        })
    playbooks_md = ''
    docs_path = os.path.join(os.path.dirname(__file__), 'docs', 'playbooks.md')
    try:
        with open(docs_path) as fh:
            playbooks_md = fh.read()
    except FileNotFoundError:
        pass
    all_catalog = get_catalog()
    return render(request, 'main/settings_playbooks.html', {
        'playbooks': playbooks,
        'playbooks_md': playbooks_md,
        **_sidebar_context(all_catalog),
    })


@login_required
def settings_playbooks_upload(request):
    """AJAX POST - upload one or more .yml playbook files."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})
    _ensure_user_playbooks_dir()
    uploaded = request.FILES.getlist('playbooks')
    if not uploaded:
        return JsonResponse({'ok': False, 'error': 'No files provided'})
    saved = []
    errors = []
    for f in uploaded:
        fn = _safe_playbook_name(f.name)
        if fn in ('inventory.yml', 'traefik-static.yml'):
            errors.append(f'{fn}: reserved filename')
            continue
        dest = os.path.join(USER_PLAYBOOKS_DIR, fn)
        try:
            with open(dest, 'wb') as out:
                for chunk in f.chunks():
                    out.write(chunk)
            saved.append(fn)
        except Exception as e:
            errors.append(f'{fn}: {e}')
    # Invalidate catalog cache so new playbooks appear immediately
    from .playbook_catalog import get_catalog
    get_catalog(force=True)
    return JsonResponse({'ok': True, 'saved': saved, 'errors': errors})


@login_required
def settings_playbooks_delete(request):
    """AJAX POST - delete a user-uploaded playbook."""
    if request.method != 'POST':
        return JsonResponse({'ok': False, 'error': 'POST required'})
    fn = _safe_playbook_name(request.POST.get('filename', ''))
    path = os.path.join(USER_PLAYBOOKS_DIR, fn)
    if not os.path.isfile(path):
        return JsonResponse({'ok': False, 'error': 'File not found'})
    os.remove(path)
    from .playbook_catalog import get_catalog
    get_catalog(force=True)
    return JsonResponse({'ok': True, 'message': f'Deleted {fn}'})


# ---------------------------------------------------------------------------
# Updates - manual update triggers and automatic-update status
# ---------------------------------------------------------------------------

# Manual actions offered on the Updates page: action name -> (host command,
# exec-modal title, success message). All commands are idempotent SymbiOS
# scripts that live in scripts/ (deployed to PATH on the host).
UPDATE_ACTIONS = {
    'update_all': ('autoupdate.sh',
                   'Running all updates...',
                   'Full update started.'),
    'update_debian': ('autoupdate.sh debian',
                      'Updating the operating system...',
                      'Operating system update started.'),
    'update_docker': ('autoupdate.sh docker',
                      'Updating apps (Docker)...',
                      'App update started.'),
    'update_symbios': ('symbios-update.sh',
                       'Updating the SymbiOS platform...',
                       'SymbiOS platform update started.'),
    'check_symbios': ('symbios-update.sh --dry-run',
                      'Checking for SymbiOS updates...',
                      'Update check started (nothing is changed).'),
}


def _updates_autoupdate_schedule():
    """Read the daily autoupdate cron time from the host, or None."""
    try:
        ok, stdout, _ = run_command('cat /etc/cron.d/autoupdate_local',
                                    timeout=10)
        if not ok:
            return None
        for line in stdout.splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            # A daily "M H * * *" entry means automatic updates are active
            if len(parts) >= 5 and parts[2:5] == ['*', '*', '*']:
                try:
                    minute, hour = int(parts[0]), int(parts[1])
                except ValueError:
                    break
                return f'{hour:02d}:{minute:02d}'
    except Exception:
        pass
    return None


def _updates_last_run():
    """Load the last autoupdate result written by autoupdate.sh (/log mount)."""
    try:
        with open('/log/autoupdate-last.json') as fh:
            data = json.load(fh)
    except Exception:
        return None
    # Turn the ISO timestamp into a human-readable string for the template
    raw = data.get('last_run') if isinstance(data, dict) else None
    if raw:
        try:
            from datetime import datetime
            dt = datetime.fromisoformat(raw)
            data['last_run_display'] = dt.strftime('%b %d, %Y %H:%M')
        except ValueError:
            data['last_run_display'] = raw
    return data


@login_required
def settings_updates(request):
    """Updates page - start updates via the exec overlay and show status."""
    if request.method == 'POST':
        is_ajax = is_ajax_request(request)
        action = request.POST.get('action', '')
        entry = UPDATE_ACTIONS.get(action)
        if not entry:
            msg = 'Unknown action.'
            if is_ajax:
                return JsonResponse({'ok': False, 'error': msg}, status=400)
            messages.error(request, msg)
            return redirect('settings_updates')
        cmd, title, message = entry

        # Updates run far longer than a web request: always start them as a
        # detached job whose live output streams into the exec modal.
        from .utils.jobs import create_job
        job_id = create_job(cmd, timeout=7200)
        if is_ajax:
            return JsonResponse({'ok': True, 'job': job_id,
                                 'title': title,
                                 'message': message,
                                 'command': cmd})
        messages.success(request, message)
        messages.info(request, title)
        return redirect('settings_updates')

    schedule = _updates_autoupdate_schedule()
    last_run = _updates_last_run()
    if schedule:
        badge = ('ok', 'Automatic daily',
                 f'Updates run automatically every day at {schedule}. '
                 'You do not have to do anything.')
    else:
        badge = ('missing', 'Not configured',
                 'The autoupdate playbook is not installed - please start '
                 'updates manually here or reinstall it.')
    return render(request, 'main/settings_updates.html', {
        'schedule': schedule,
        'last_run': last_run,
        'page_key': 'updates',
        'page_icon': 'bi-arrow-repeat',
        'page_title': 'Updates',
        'page_explain': PAGE_EXPLAIN.get('updates', ''),
        'page_status': badge[0],
        'page_status_label': badge[1],
        'page_status_text': badge[2],
    })


# Editable standard media locations (see mediapaths.md). Missing
# directories are created by base-services/media.yml on apply; the shared
# media GID is fixed infrastructure and intentionally not editable here.
# CLI flags per media key for symbios-settings-media.sh (mirrors the
# script's field list; the view only forwards values, validation lives
# in the script).

