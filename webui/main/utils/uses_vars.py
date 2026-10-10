# SymbiOS - match changed inventory keys to installed playbooks.
#
# Playbooks declare the inventory keys they bake into state in their
# `# docs:` block (`uses_vars:`, see playbooks.md). After a settings save,
# the changed field names (which equal inventory keys by convention) are
# matched against the uses_vars of INSTALLED playbooks; matches are
# reapplied via symbios-reapply.sh --only (which skips non-installed).
# Explicit registry chains stay primary (author order); dynamic matches
# complete them in canonical order (base-services in install order,
# services alphabetically).

"""Match changed settings keys to consumer playbooks via docs uses_vars."""

from ..playbook_catalog import get_catalog

# Canonical base-services order (install.sh, then later additions).
BASE_ORDER = [
    'base-services/basics.yml',
    'base-services/localization.yml',
    'base-services/hardening.yml',
    'base-services/firewall.yml',
    'base-services/backup.yml',
    'base-services/autoupdate.yml',
    'base-services/runchecks.yml',
    'base-services/docker.yml',
    'base-services/dedyn.yml',
    'base-services/ldap.yml',
    'base-services/raspberry.yml',
    'base-services/symbios-ui.yml',
    'base-services/kvm.yml',
    'base-services/traefik.yml',
    'base-services/authelia.yml',
    'base-services/smtp.yml',
    'base-services/ssh-keys.yml',
    'base-services/matrix-client.yml',
    'base-services/media.yml',
    'base-services/network-bridges.yml',
    'base-services/notifications.yml',
    'base-services/openvpn-client.yml',
    'base-services/wlan-accesspoint.yml',
    'base-services/traefik-proxy.yml',
    'base-services/wol-suspend.yml',
]


def _get_installed_playbooks():
    """Read the state file and return a set of installed playbook paths."""
    state_file = '/config/installed-playbooks.yml'
    installed = set()
    try:
        with open(state_file) as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                path = line.split(':')[0].strip()
                if path:
                    installed.add(path)
    except (FileNotFoundError, PermissionError):
        pass
    return installed


def match_consumers(changed_keys, catalog_items, installed):
    """Pure matcher: ordered consumer playbooks for changed keys.

    changed_keys: iterable of inventory key names (secrets as names only).
    catalog_items: playbook_catalog entries (need playbook + docs.uses_vars).
    installed: set of installed playbook paths.
    Returns base-services (install order) then services (alphabetical).
    """
    keys = set(changed_keys or [])
    if not keys:
        return []
    order = {p: i for i, p in enumerate(BASE_ORDER)}
    hits_base = []
    hits_svc = []
    for item in catalog_items or []:
        pb = (item or {}).get('playbook') or ''
        if pb not in installed:
            continue
        uses = set(((item.get('docs') or {}).get('uses_vars')) or [])
        if keys & uses:
            if pb.startswith('base-services/'):
                hits_base.append(pb)
            else:
                hits_svc.append(pb)
    hits_base.sort(key=lambda p: (order.get(p, 99), p))
    hits_svc.sort()
    return hits_base + hits_svc


def consumers_for_keys(changed_keys):
    """Catalog-backed matcher for the settings save flow."""
    try:
        catalog = get_catalog()
    except Exception:
        return []
    return match_consumers(changed_keys, catalog, _get_installed_playbooks())
