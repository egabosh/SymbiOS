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

"""Shared password policy validation for the SymbiOS WebUI."""

import re

# Password policy definitions: (min_length, require_alpha, require_digit,
# require_special)
POLICIES = {
    'none':     (1,  False, False, False),
    'low':      (8,  False, False, False),
    'medium':   (10, True,  True,  True),
    'high':     (16, True,  True,  True),
    'paranoid': (32, True,  True,  True),
}

POLICY_LABELS = {
    'none':     'None (min. 1 character)',
    'low':      'Low (min. 8 characters)',
    'medium':   'Medium (min. 10 characters, letters + digits + special)',
    'high':     'High (min. 16 characters, letters + digits + special)',
    'paranoid': 'Paranoid (min. 32 characters, letters + digits + special)',
}

SPECIAL_CHARS = re.compile(r'[!@#$%^&*()_+\-=\[\]{}|;:\'",.<>?/`~\\]')


def get_password_policy():
    """Read the password policy from inventory.yml. Defaults to 'medium'."""
    try:
        from .views import _get_inventory_config
        config = _get_inventory_config()
        return config.get('all', {}).get('vars', {}).get(
            'password_policy', 'medium')
    except Exception:
        return 'medium'


def validate_password(password, policy=None):
    """Validate a password against the given policy.

    Returns None if valid, or an error message string.
    """
    if policy is None:
        policy = get_password_policy()
    settings = POLICIES.get(policy, POLICIES['medium'])
    min_len, req_alpha, req_digit, req_special = settings

    if len(password) < min_len:
        return (f'Password must be at least {min_len} '
                f'character{"s" if min_len != 1 else ""} long.')
    if req_alpha and not any(c.isalpha() for c in password):
        return 'Password must contain at least one letter.'
    if req_digit and not any(c.isdigit() for c in password):
        return 'Password must contain at least one digit.'
    if req_special and not SPECIAL_CHARS.search(password):
        return 'Password must contain at least one special character.'
    return None
