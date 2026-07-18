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

from django.urls import path, re_path
from . import views
from . import views_settings
from . import views_mailserver
from . import views_users
from . import views_logs
from . import views_change_password
from . import views_services

urlpatterns = [
    path('health/', views.health, name='health'),
    path('services/', views_services.services, name='services'),
    path('services/manage/', views_services.services_manage, name='services_manage'),
    re_path(r'^services/(?P<playbook>.+\.yml)/$', views_services.services_detail, name='services_detail'),
    re_path(r'^services/(?P<playbook>.+\.yml)/action/$', views_services.services_action, name='services_action'),
    re_path(r'^services/(?P<playbook>.+\.yml)/output/$', views_services.services_output, name='services_output'),
    re_path(r'^services/(?P<playbook>.+\.yml)/log-start/$', views_services.services_log_start, name='services_log_start'),
    re_path(r'^services/(?P<playbook>.+\.yml)/log-stop/$', views_services.services_log_stop, name='services_log_stop'),
    re_path(r'^services/(?P<playbook>.+\.yml)/log-tail/$', views_services.services_log_tail, name='services_log_tail'),
    re_path(r'^services/(?P<playbook>.+\.yml)/status/$', views_services.services_status, name='services_status'),
    re_path(r'^services/(?P<playbook>.+\.yml)/source/$', views_services.services_source, name='services_source'),
    path('health/data/', views.health_data, name='health_data'),
    path('', views.health, name='home'),
    path('settings/', views.settings, name='settings'),
    path('settings/ddns/', views_settings.settings_ddns, name='settings_ddns'),
    path('settings/ddns/test-api/', views_settings.settings_ddns_test_api, name='settings_ddns_test_api'),
    path('settings/ddns/check-ip/', views_settings.settings_ddns_check_ip, name='settings_ddns_check_ip'),
    path('settings/ddns/host-status/', views_settings.settings_ddns_host_status, name='settings_ddns_host_status'),
    path('settings/mailserver/', views_mailserver.settings_mailserver, name='settings_mailserver'),
    path('settings/mailserver/discover/', views_mailserver.settings_mailserver_discover, name='settings_mailserver_discover'),
    path('settings/mailserver/test-email/', views_mailserver.settings_mailserver_test_email, name='settings_mailserver_test_email'),
    path('settings/mailserver/autoconfig.xml', views_mailserver.autoconfig_xml, name='autoconfig_xml'),
    path('settings/auth/', views_settings.settings_auth, name='settings_auth'),
    path('settings/ssh-keys/', views_settings.settings_ssh_keys, name='settings_ssh_keys'),
    path('settings/config/', views_settings.settings_config, name='settings_config'),
    path('settings/backup/', views_settings.settings_backup, name='settings_backup'),
    path('settings/backup/test/', views_settings.settings_backup_test, name='settings_backup_test'),
    path('settings/disk/', views_settings.settings_disk, name='settings_disk'),
    path('settings/disk/list/', views_settings.settings_disk_list, name='settings_disk_list'),
    path('settings/disk/status/', views_settings.settings_disk_status, name='settings_disk_status'),
    path('settings/disk/setup/', views_settings.settings_disk_setup, name='settings_disk_setup'),
    path('settings/disk/umount/', views_settings.settings_disk_umount, name='settings_disk_umount'),
    path('settings/local-ip/', views_settings.settings_local_ip, name='settings_local_ip'),
    path('settings/playbooks/', views_settings.settings_playbooks, name='settings_playbooks'),
    path('settings/playbooks/upload/', views_settings.settings_playbooks_upload, name='settings_playbooks_upload'),
    path('settings/playbooks/delete/', views_settings.settings_playbooks_delete, name='settings_playbooks_delete'),
    path('logs/', views_logs.logs, name='logs'),
    path('logs/stream/', views.logs_stream, name='logs_stream'),
    path('logs/containers/', views.container_list, name='logs_containers'),
    path('users/', views_users.users, name='users'),
    path('users/create/', views_users.user_create, name='user_create'),
    path('users/<str:uid>/delete/', views_users.user_delete, name='user_delete'),
    path('users/<str:uid>/password/', views_users.user_set_password, name='user_set_password'),
    path('users/<str:uid>/email/', views_users.user_update_email, name='user_update_email'),
    path('users/group/add-user/', views_users.group_add_user, name='group_add_user'),
    path('users/group/remove-user/', views_users.group_remove_user, name='group_remove_user'),
    path('groups/', views_users.groups, name='groups'),
    path('groups/create/', views_users.group_create, name='group_create'),
    path('groups/<str:name>/delete/', views_users.group_delete, name='group_delete'),
    path('change-password/', views_change_password.change_password, name='change_password'),
    path('logout/', views.logout_view, name='logout'),
    path('authelia-logout/', views.authelia_logout, name='authelia_logout'),
]
