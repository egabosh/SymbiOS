from django.urls import path
from . import views

urlpatterns = [
    path('', views.settings, name='settings'),
    path('settings/', views.settings, name='settings'),
    path('settings/network/', views.settings_network, name='settings_network'),
    path('settings/ddns/', views.settings_ddns, name='settings_ddns'),
    path('settings/auth/', views.settings_auth, name='settings_auth'),
    path('logs/', views.logs, name='logs'),
    path('logs/stream/', views.logs_stream, name='logs_stream'),
    path('users_groups/', views.users_groups, name='users_groups'),
]

