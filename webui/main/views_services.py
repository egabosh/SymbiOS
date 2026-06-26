import os
import json
import time
from pathlib import Path
from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from django.http import JsonResponse, HttpResponse
from django.views.decorators.csrf import csrf_exempt
from . import service_discover

SERVICES_DIR = Path('/home/SymbiOS/services')
DOCKER_BASE = Path('/home/docker')
TRIGGER_DIR = Path('/config/triggers')
LOG_DIR = Path('/log')
CONFIG_PATH = os.environ.get('CONFIG_PATH', '/config/inventory.yml')


def _get_domain():
    try:
        with open(CONFIG_PATH, 'r') as f:
            import yaml
            config = yaml.safe_load(f)
        return config.get('all', {}).get('vars', {}).get('default_domain', 'local')
    except Exception:
        return 'local'


def _get_basic_services():
    domain = _get_domain()
    return [
        {'name': 'SymbiOS WebUI', 'slug': 'symbios-webui', 'icon': 'bi-globe', 'url': 'https://symbios.' + domain, 'description': 'Configuration and management interface', 'internal': False, 'basic': True},
        {'name': 'Traefik Dashboard', 'slug': 'traefik-dashboard', 'icon': 'bi-hdd-network', 'url': 'https://traefik.' + domain, 'description': 'Reverse proxy status and routing', 'internal': False, 'basic': True},
        {'name': 'Authelia', 'slug': 'authelia', 'icon': 'bi-shield-lock', 'url': 'https://auth.' + domain, 'description': 'Authentication and single sign-on', 'internal': False, 'basic': True},
        {'name': 'OpenLDAP', 'slug': 'openldap', 'icon': 'bi-database', 'url': 'ldaps://ldap.' + domain, 'description': 'Directory service for users and groups', 'internal': True, 'basic': True},
        {'name': 'Step-CA', 'slug': 'step-ca', 'icon': 'bi-key', 'url': 'https://pki.' + domain, 'description': 'PKI and certificate authority', 'internal': False, 'basic': True}
    ]


def _get_service_dirs(service_name):
    sdirs = []
    for d in DOCKER_BASE.iterdir():
        if d.is_dir() and d.name.startswith(service_name + '.') and (d / 'docker-compose.yml').exists():
            sdirs.append({'path': str(d), 'name': d.name})
    return sdirs


@login_required
def services(request):
    managed = service_discover.discover_services()
    basic = _get_basic_services()
    domain = _get_domain()
    return render(request, 'main/services.html', {'services': basic + managed, 'managed_services': managed, 'default_domain': domain, 'all_services': basic + managed})


@login_required
def services_manage(request):
    managed = service_discover.discover_services()
    domain = _get_domain()
    return render(request, 'main/services_manage.html', {'services': managed, 'default_domain': domain, 'all_services': _get_basic_services() + managed})


@login_required
def services_detail(request, service_name):
    basic = _get_basic_services()
    managed = service_discover.discover_services()
    all_services = basic + managed
    svc = None
    for s in all_services:
        key = s.get('slug', s.get('name', '').lower().replace(' ', '-').replace('/', '-'))
        if key == service_name.lower():
            svc = s
            break
    if svc is None:
        from django.http import Http404
        raise Http404("Service not found")
    return render(request, 'main/services_detail.html', {
        'service': svc,
        'all_services': all_services,
        'default_domain': _get_domain(),
        'basic_services': basic,
        'managed_services': managed
    })

@login_required
@csrf_exempt
def services_action(request, service_name):
    if request.method == 'POST':
        action = request.POST.get('action')
        TRIGGER_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = int(time.time())
        trigger_file = TRIGGER_DIR / f'{timestamp}-{action}-{service_name}.trigger'
        trigger_file.touch()
        return JsonResponse({'status': 'queued', 'trigger': str(trigger_file)})
    return JsonResponse({'error': 'Invalid action'}, status=400)


@login_required
def services_playbook_log(request, service_name):
    log_file = LOG_DIR / f'service-{service_name}.log'
    status_file = LOG_DIR / 'configd-status'
    result = {'running': False, 'status': 'idle', 'output': '', 'success': None}
    
    try:
        with open(status_file, 'r') as f:
            result['status'] = f.read().strip()
    except:
        pass
    
    if 'running' in result.get('status', '') and service_name in result.get('status', ''):
        result['running'] = True
    
    if log_file.exists():
        with open(log_file, 'r') as f:
            lines = f.readlines()[-200:]
        output = ''.join(lines)
        result['output'] = output
        if 'PLAY RECAP' in output:
            if 'failed=0' in output:
                result['success'] = True
            elif 'failed=' in output and 'failed=0' not in output:
                result['success'] = False
    
    return HttpResponse(result['output'], content_type='text/plain')


@login_required
def services_directories(request, service_name):
    dirs = _get_service_dirs(service_name)
    return JsonResponse({'directories': dirs})


@login_required
def services_status(request, service_name):
    hostname = request.GET.get('hostname', '')
    status = service_discover.get_service_status(service_name, hostname)
    return JsonResponse(status)


@login_required
def services_playbook_output(request, service_name):
    playbook = LOG_DIR / f'service-{service_name}.log'
    try:
        with open(playbook, 'r') as f:
            lines = f.readlines()[-100:]
        return HttpResponse(''.join(lines), content_type='text/plain')
    except:
        return HttpResponse('No playbook output found', status=404)
