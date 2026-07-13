"""Lightweight, database-free user objects.

The WebUI holds no local users or passwords. Identity comes either from the
Authelia forward-auth header (via Traefik) or from the host-local break-glass
on 127.0.0.1:8080. We just need request.user to behave enough like a Django
user for the views and templates.
"""


class SymbiosUser:
    is_authenticated = True
    is_active = True

    def __init__(self, username, is_staff=False, is_superuser=False):
        self.username = username
        self.is_staff = is_staff
        self.is_superuser = is_superuser
        self.pk = username
        self.id = username

    def get_username(self):
        return self.username

    def get_session_auth_hash(self):
        return ''

    def __str__(self):
        return self.username


class AnonymousUser:
    is_authenticated = False
    is_active = False
    username = ''
    is_staff = False
    is_superuser = False
    pk = None
    id = None

    def get_username(self):
        return ''

    def get_session_auth_hash(self):
        return ''

    def __str__(self):
        return 'AnonymousUser'
