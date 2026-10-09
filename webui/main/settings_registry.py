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

"""Registry for generically rendered settings pages.

Each entry maps a URL slug (/settings/<slug>/) to its settings CLI script
plus the page chrome and the reapply chain. Adding a domain is one row
here - no new view, no new template. Conventions (see views_settings_generic):

- The script answers `schema` (field list or {"fields": [...]}) and
  `get --json` (flat value object).
- `set --json-stdin` accepts the full field object; secrets travel only
  this way. Empty secrets are OMITTED from the payload (keep stored);
  clearing a secret stays available on the dedicated page (if any).
- Select fields resolve options from schema `options` (strings or
  {value, label}) or from `detect` (a script subcommand printing one
  option per line, e.g. "timezones").
- Secret current values never come back (`get --json` reports
  <name>_set); the form renders them empty with a "configured" hint.
- `reapply_if_changed` (optional field list) limits the reapply to real
  flips of those fields (e.g. traefik only when public access changed).
"""

SETTINGS = {
    'localization': {
        'script': 'symbios-settings-localization.sh',
        'title': 'Language & Timezone',
        'icon': 'bi-clock-history',
        'explain': 'localization',
        'playbooks': ['base-services/localization.yml',
                      'base-services/raspberry.yml'],
        'force': False,
        'message': 'Localization settings saved.',
    },
    'ai': {
        'script': 'symbios-settings-ai.sh',
        'title': 'AI',
        'icon': 'bi-cpu',
        'explain': 'ai',
        'playbooks': [],
        'force': False,
        'message': 'AI settings saved.',
        'tests': [{'endpoint': '/settings/ai/test/',
                 'label': 'Test connection'}],
    },
    'ai-speech': {
        'script': 'symbios-settings-ai-speech.sh',
        'title': 'AI Speech',
        'icon': 'bi-mic',
        'explain': 'ai-speech',
        'playbooks': [],
        'force': False,
        'message': 'AI settings saved.',
        'tests': [{'endpoint': '/settings/ai-speech/test/',
                 'label': 'Test connection'}],
    },
    'ai-image': {
        'script': 'symbios-settings-ai-image.sh',
        'title': 'AI Image',
        'icon': 'bi-image',
        'explain': 'ai-image',
        'playbooks': [],
        'force': False,
        'message': 'AI settings saved.',
        'tests': [{'endpoint': '/settings/ai-image/test/',
                 'label': 'Test connection'}],
    },
    'ai-search': {
        'script': 'symbios-settings-ai-search.sh',
        'title': 'AI Search & RAG',
        'icon': 'bi-search',
        'explain': 'ai-search',
        'playbooks': [],
        'force': False,
        'message': 'AI settings saved.',
        'tests': [{'endpoint': '/settings/ai-search/test/',
                 'label': 'Test connection'}],
    },
    'auth': {
        'script': 'symbios-settings-auth.sh',
        'title': 'Login & 2FA',
        'icon': 'bi-shield-lock',
        'explain': 'auth',
        'playbooks': ['base-services/authelia.yml'],
        'force': False,
        'message': 'Auth settings saved.',
    },
    'acme': {
        'script': 'symbios-settings-acme.sh',
        'title': 'Security Certificates (TLS)',
        'icon': 'bi-patch-check',
        'explain': 'acme',
        'playbooks': ['base-services/traefik.yml'],
        'force': False,
        'message': 'ACME settings saved.',
    },
    'security': {
        'script': 'symbios-settings-security.sh',
        'title': 'Security',
        'icon': 'bi-shield-check',
        'explain': 'security',
        'playbooks': ['base-services/traefik.yml'],
        'force': False,
        'message': 'Security settings saved.',
        # Reapply only when one of these fields actually flipped (a
        # policy-only save needs no traefik run).
        'reapply_if_changed': ['webui_public_access'],
    },
    'media': {
        'script': 'symbios-settings-media.sh',
        'title': 'Media',
        'icon': 'bi-collection-play',
        'explain': 'media',
        'playbooks': ['base-services/media.yml'],
        'force': False,
        'message': 'Media settings saved.',
    },
    'notifications': {
        'script': 'symbios-settings-notifications.sh',
        'title': 'Notifications',
        'icon': 'bi-bell',
        'explain': 'notifications',
        'playbooks': ['base-services/notifications.yml'],
        'force': False,
        'message': 'Notification settings saved.',
        # matrix-client first, but only when matrix was enabled - then
        # the daemon is up before the alias points at its FIFO.
        'conditional_playbooks': [
            {'playbooks': ['base-services/matrix-client.yml'],
             'when': {'field': 'notify_matrix_enabled', 'equals': True}},
        ],
        'tests': [
            {'endpoint': '/settings/notifications/test-mail/',
             'label': 'Send test mail'},
            {'endpoint': '/settings/notifications/test-matrix/',
             'label': 'Send test message'},
        ],
    },
    'matrix': {
        'script': 'symbios-settings-matrix.sh',
        'title': 'Matrix Account',
        'icon': 'bi-chat-dots',
        'explain': 'matrix',
        'playbooks': ['base-services/matrix-client.yml'],
        'force': False,
        'message': 'Matrix account saved. Verify the new device, then check the room.',
        'tests': [
            {'endpoint': '/settings/matrix/probe/',
             'label': 'Probe homeserver'},
        ],
    },
}
