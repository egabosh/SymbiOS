from django.urls import path
from django.contrib.auth import views as auth_views
from . import views
from . import views_change_password

urlpatterns = [
    path('', views.settings, name='settings'),
    path('settings/', views.settings, name='settings'),
    path('settings/network/', views.settings_network, name='settings_network'),
    path('settings/inventory/', views.settings_inventory, name='settings_inventory'),
    path('settings/ddns/', views.settings_ddns, name='settings_ddns'),
    path('settings/auth/', views.settings_auth, name='settings_auth'),
    path('logs/', views.logs, name='logs'),
    path('logs/stream/', views.logs_stream, name='logs_stream'),
    path('users/', views.users, name='users'),
    path('users/create/', views.user_create, name='user_create'),
    path('users/<str:uid>/delete/', views.user_delete, name='user_delete'),
    path('users/<str:uid>/password/', views.user_set_password, name='user_set_password'),
    path('users/<str:uid>/email/', views.user_update_email, name='user_update_email'),
    path('users/group/add-user/', views.group_add_user, name='group_add_user'),
    path('users/group/remove-user/', views.group_remove_user, name='group_remove_user'),
    path('groups/', views.groups, name='groups'),
    path('groups/create/', views.group_create, name='group_create'),
    path('groups/<str:name>/delete/', views.group_delete, name='group_delete'),
    path('change-password/', views_change_password.change_password, name='change_password'),
    path('login/', auth_views.LoginView.as_view(template_name='main/login.html'), name='login'),
    path('logout/', auth_views.LogoutView.as_view(next_page='/login/'), name='logout'),
]
