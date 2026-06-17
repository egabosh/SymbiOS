import subprocess
import os
from django.contrib.auth.backends import ModelBackend
from django.contrib.auth import get_user_model

LDAP_URI = os.environ.get("LDAP_URI", "ldap://openldap")


class LDAPBackend(ModelBackend):
    """Authenticate against LDAP -- only admin user allowed."""

    def authenticate(self, request, username=None, password=None, **kwargs):
        if not username or not password:
            return None

        if username != "admin":
            return None

        try:
            import yaml
            config_path = os.environ.get("CONFIG_PATH", "/config/inventory.yml")
            with open(config_path) as f:
                config = yaml.safe_load(f) or {}
            base_dn = config.get("all", {}).get("vars", {}).get("ldap_basedn", "dc=openldap,dc=local")
        except Exception:
            base_dn = "dc=openldap,dc=local"

        user_dn = f"uid={username},ou=users,{base_dn}"

        cmd = ["ldapwhoami", "-x", "-H", LDAP_URI, "-D", user_dn, "-w", password]
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        except Exception:
            return None

        if proc.returncode != 0:
            return None

        User = get_user_model()
        try:
            user = User.objects.get(username=username)
        except User.DoesNotExist:
            user = User(username=username)
            user.is_staff = True
            user.is_superuser = True
            user.set_unusable_password()
            user.save()

        if request and password == "admin":
            request.session["force_password_change"] = True

        return user

    def get_user(self, user_id):
        User = get_user_model()
        try:
            return User.objects.get(pk=user_id)
        except User.DoesNotExist:
            return None
