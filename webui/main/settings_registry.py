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
    },
    'ai-speech': {
        'script': 'symbios-settings-ai-speech.sh',
        'title': 'AI Speech',
        'icon': 'bi-mic',
        'explain': 'ai-speech',
        'playbooks': [],
        'force': False,
        'message': 'AI settings saved.',
    },
}
