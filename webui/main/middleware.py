import subprocess
import os
from django.contrib.auth import login, get_user_model
from django.shortcuts import redirect

LDAP_URI = os.environ.get("LDAP_URI", "ldap://openldap")


def _admin_password_is_default():
    """Check if admin's LDAP password is still 'admin'."""
    try:
        import yaml
        config_path = os.environ.get("CONFIG_PATH", "/config/inventory.yml")
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        base_dn = config.get("all", {}).get("vars", {}).get("ldap_basedn", "dc=openldap,dc=local")
    except Exception:
        base_dn = "dc=openldap,dc=local"
    admin_dn = f"uid=admin,ou=users,{base_dn}"
    proc = subprocess.run(
        ["ldapwhoami", "-x", "-H", LDAP_URI, "-D", admin_dn, "-w", "admin"],
        capture_output=True, text=True, timeout=10,
    )
    return proc.returncode == 0


class AutheliaMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        remote_user = request.META.get("HTTP_REMOTE_USER")

        if remote_user:
            User = get_user_model()
            try:
                user = User.objects.get(username=remote_user)
            except User.DoesNotExist:
                user = User(username=remote_user)
                user.is_staff = remote_user in ["admin", "root"]
                user.is_superuser = remote_user in ["admin", "root"]
                user.set_unusable_password()
                user.save()

            if request.session.get("_auth_user_id") != str(user.pk):
                request.session.cycle_key()
                login(request, user, backend="main.backends.LDAPBackend")

            if remote_user == "admin" and "force_password_change" not in request.session:
                if _admin_password_is_default():
                    request.session["force_password_change"] = True

        if (request.user.is_authenticated
                and request.session.get("force_password_change")
                and request.path not in ("/change-password/", "/logout/")):
            return redirect("/change-password/")

        return self.get_response(request)
