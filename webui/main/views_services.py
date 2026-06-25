from django.shortcuts import render
from django.contrib.auth.decorators import login_required
from .views import _get_inventory_config


@login_required
def services(request):
    config = _get_inventory_config()
    vars_ = config.get('all', {}).get('vars', {})
    default_domain = vars_.get('default_domain', 'local')
    symbios_domain = vars_.get('symbios_domain', 'symbios.local')

    if default_domain == 'local':
        # No public domain configured - show local-only hint
        pass

    services_list = [
        {
            'name': 'SymbiOS WebUI',
            'url': f'https://{symbios_domain}/',
            'description': 'SymbiOS system management interface',
            'icon': 'bi bi-house-gear',
            'internal': False,
        },
        {
            'name': 'Traefik Dashboard',
            'url': f'https://traefik.{default_domain}/',
            'description': 'Reverse proxy dashboard & metrics',
            'icon': 'bi bi-diagram-3',
            'internal': False,
        },
        {
            'name': 'Authelia',
            'url': f'https://auth.{default_domain}/',
            'description': 'Single Sign-On, 2FA & access control',
            'icon': 'bi bi-shield-check',
            'internal': False,
        },
        {
            'name': 'OpenLDAP',
            'url': f'ldaps://ldap.{default_domain}/',
            'description': 'LDAP directory service (authentication backend)',
            'icon': 'bi bi-database',
            'internal': True,
        },
        {
            'name': 'Step-CA (ACME-PKI)',
            'url': 'https://acme-pki-stepca:9000/',
            'description': 'Internal ACME certificate authority',
            'icon': 'bi bi-patch-check',
            'internal': True,
        },
    ]

    return render(request, 'main/services.html', {
        'services': services_list,
        'default_domain': default_domain,
        'symbios_domain': symbios_domain,
    })
