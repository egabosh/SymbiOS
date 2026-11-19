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

"""Grouped definition of the settings sidebar.

Single source of truth for the left-hand settings menu. Each item keeps the
title, icon, URL and short description that used to live inline in
sidebar_settings.html. The level (basic/expert) drives the expert-mode toggle
in the browser: basic entries are always visible, expert entries only when the
user enables the expert mode (stored in localStorage by sidebar.js).

Adding a settings page means adding one row here; the template renders the
whole menu from this list.
"""

# Every URL below must stay reachable: urls.py is the routing source of truth.
SETTINGS_MENU = [
    {
        'key': 'system',
        'title': 'System & Updates',
        'icon': 'bi-sliders',
        'items': [
            {'url': '/settings/localization/', 'title': 'Localization',
             'icon': 'bi-globe2', 'desc': 'Timezone, keyboard, locale settings',
             'level': 'basic'},
            {'url': '/settings/maintenance/', 'title': 'Maintenance',
             'icon': 'bi-clock', 'desc': 'Daily backup & update window',
             'level': 'basic'},
            {'url': '/settings/backup/', 'title': 'Backup',
             'icon': 'bi-cloud-arrow-up', 'desc': 'Daily snapshots & restore',
             'level': 'basic'},
            {'url': '/settings/updates/', 'title': 'Updates',
             'icon': 'bi-arrow-repeat', 'desc': 'Keep system and apps up to date',
             'level': 'basic'},
        ],
    },
    {
        'key': 'network',
        'title': 'Network & Internet',
        'icon': 'bi-diagram-3',
        'items': [
            {'url': '/settings/dns/', 'title': 'DNS',
             'icon': 'bi-globe', 'desc': 'Public reachability configuration',
             'level': 'basic'},
            {'url': '/settings/acme/', 'title': 'ACME / TLS',
             'icon': 'bi-patch-check', 'desc': 'Certificate authority configuration',
             'level': 'expert'},
            {'url': '/settings/port-forwarding/', 'title': 'Port Forwarding',
             'icon': 'bi-diagram-3', 'desc': 'Open ports on the router automatically',
             'level': 'expert'},
            {'url': '/settings/reverse-proxy/', 'title': 'Reverse Proxy',
             'icon': 'bi-arrow-left-right', 'desc': 'Publish external targets under public hostnames',
             'level': 'expert'},
        ],
    },
    {
        'key': 'vpn',
        'title': 'VPN & Remote Access',
        'icon': 'bi-lock',
        'items': [
            {'url': '/settings/openvpn/', 'title': 'OpenVPN Client',
             'icon': 'bi-hdd-network', 'desc': 'Tunnels to remote networks',
             'level': 'expert'},
            {'url': '/settings/wireguard/', 'title': 'WireGuard Client',
             'icon': 'bi-shield-lock', 'desc': 'Tunnels to remote peers',
             'level': 'expert'},
            {'url': '/settings/ssh-keys/', 'title': 'SSH Keys',
             'icon': 'bi-key', 'desc': 'Manage authorized_keys for root',
             'level': 'expert'},
        ],
    },
    {
        'key': 'lan',
        'title': 'LAN & Power',
        'icon': 'bi-router',
        'items': [
            {'url': '/settings/wlan-accesspoint/', 'title': 'WLAN Access Point',
             'icon': 'bi-wifi', 'desc': 'Wireless LAN access point via hostapd',
             'level': 'expert'},
            {'url': '/settings/network-bridges/', 'title': 'Network Bridges',
             'icon': 'bi-diagram-3', 'desc': 'Assign unused interfaces to bridges',
             'level': 'expert'},
            {'url': '/settings/suspend/', 'title': 'Suspend',
             'icon': 'bi-moon', 'desc': 'Suspend idle hosts over SSH',
             'level': 'expert'},
            {'url': '/settings/wake-on-lan/', 'title': 'Wake-on-LAN',
             'icon': 'bi-lightning-charge', 'desc': 'Wake sleeping hosts on request',
             'level': 'expert'},
            {'url': '/settings/external-systems/', 'title': 'External Systems',
             'icon': 'bi-hdd-stack', 'desc': 'Manage remote hosts',
             'level': 'expert'},
        ],
    },
    {
        'key': 'storage',
        'title': 'Storage & Media',
        'icon': 'bi-hdd-stack',
        'items': [
            {'url': '/settings/disk/', 'title': 'Data Disk',
             'icon': 'bi-device-hdd', 'desc': 'Move data to a separate disk',
             'level': 'expert'},
            {'url': '/settings/raid-md/', 'title': 'RAID (mdadm)',
             'icon': 'bi-hdd-stack', 'desc': 'Classic RAID incl. RAID5',
             'level': 'expert'},
            {'url': '/settings/raid-btrfs/', 'title': 'RAID (btrfs)',
             'icon': 'bi-hdd-stack-fill', 'desc': 'Multi-device filesystems',
             'level': 'expert'},
            {'url': '/settings/media/', 'title': 'Media',
             'icon': 'bi-collection-play', 'desc': 'Shared media directories',
             'level': 'expert'},
            {'url': '/settings/shares/', 'title': 'Shares',
             'icon': 'bi-folder-symlink', 'desc': 'Group directories on the media root',
             'level': 'expert'},
        ],
    },
    {
        'key': 'security',
        'title': 'Security & Access',
        'icon': 'bi-shield-check',
        'items': [
            {'url': '/settings/auth/', 'title': 'Auth',
             'icon': 'bi-shield-lock', 'desc': '2FA / Authelia authentication',
             'level': 'basic'},
            {'url': '/settings/security/', 'title': 'Security',
             'icon': 'bi-shield-check', 'desc': 'Password policy configuration',
             'level': 'basic'},
        ],
    },
    {
        'key': 'communication',
        'title': 'Communication',
        'icon': 'bi-envelope',
        'items': [
            {'url': '/settings/mailserver/', 'title': 'Mailserver (SMTP)',
             'icon': 'bi-envelope', 'desc': 'Outgoing email for 2FA notifications',
             'level': 'basic'},
            {'url': '/settings/notifications/', 'title': 'Notifications',
             'icon': 'bi-bell', 'desc': 'Health alerts by mail and matrix',
             'level': 'basic'},
            {'url': '/settings/news/', 'title': 'News Feed',
             'icon': 'bi-newspaper', 'desc': 'Release notes and security notices',
             'level': 'basic'},
            {'url': '/settings/matrix/', 'title': 'Matrix Account',
             'icon': 'bi-chat-dots', 'desc': 'Sender account for matrix notifications',
             'level': 'expert'},
        ],
    },
    {
        'key': 'ai',
        'title': 'AI',
        'icon': 'bi-cpu',
        'items': [
            {'url': '/settings/ai/', 'title': 'AI',
             'icon': 'bi-cpu', 'desc': 'OpenAI-compatible server configuration',
             'level': 'expert'},
            {'url': '/settings/ai-speech/', 'title': 'AI Speech',
             'icon': 'bi-mic', 'desc': 'Speech-to-text and text-to-speech endpoints',
             'level': 'expert'},
            {'url': '/settings/ai-image/', 'title': 'AI Image',
             'icon': 'bi-image', 'desc': 'ComfyUI image generation and edit',
             'level': 'expert'},
            {'url': '/settings/ai-search/', 'title': 'AI Search & RAG',
             'icon': 'bi-search', 'desc': 'Tika document extraction and SearXNG web search',
             'level': 'expert'},
        ],
    },
    {
        'key': 'advanced',
        'title': 'Advanced',
        'icon': 'bi-file-earmark-code',
        'items': [
            {'url': '/settings/config/', 'title': 'Config Editor',
             'icon': 'bi-file-earmark-code', 'desc': 'Edit inventory.yml directly',
             'level': 'expert'},
        ],
    },
]
