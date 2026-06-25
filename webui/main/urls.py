from django.urls import path
from django.contrib.auth import views as auth_views
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
    path('health/data/', views.health_data, name='health_data'),
    path('', views.health, name='home'),
    path('health/', views.health, name='health'),
    path('settings/', views.settings, name='settings'),
    path('settings/', views.settings, name='settings'),
    path('settings/network/', views_settings.settings_network, name='settings_network'),
    path('settings/inventory/', views_settings.settings_inventory, name='settings_inventory'),
    path('settings/ddns/', views_settings.settings_ddns, name='settings_ddns'),
    path('settings/ddns/test-api/', views_settings.settings_ddns_test_api, name='settings_ddns_test_api'),
    path('settings/ddns/check-ip/', views_settings.settings_ddns_check_ip, name='settings_ddns_check_ip'),
    path('settings/ddns/host-status/', views_settings.settings_ddns_host_status, name='settings_ddns_host_status'),
    path('settings/mailserver/', views_mailserver.settings_mailserver, name='settings_mailserver'),
    path('settings/mailserver/discover/', views_mailserver.settings_mailserver_discover, name='settings_mailserver_discover'),
    path('settings/mailserver/test-email/', views_mailserver.settings_mailserver_test_email, name='settings_mailserver_test_email'),
    path('settings/mailserver/autoconfig.xml', views_mailserver.autoconfig_xml, name='autoconfig_xml'),
    path('settings/auth/', views_settings.settings_auth, name='settings_auth'),
    path('settings/local-ip/', views_settings.settings_local_ip, name='settings_local_ip'),
    path('logs/', views_logs.logs, name='logs'),
    path('logs/stream/', views.logs_stream, name='logs_stream'),
    path('logs/containers/', views.container_list, name='logs_containers'),
    path('configd-status/', views.configd_status, name='configd_status'),
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
    path('login/', auth_views.LoginView.as_view(template_name='main/login.html'), name='login'),
    path('logout/', views.logout_view, name='logout'),
    path('authelia-logout/', views.authelia_logout, name='authelia_logout'),
]
