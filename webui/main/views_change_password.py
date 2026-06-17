import subprocess
import os
from django.shortcuts import render, redirect
from django.contrib.auth.decorators import login_required
from django.contrib import messages

LDAP_URI = os.environ.get("LDAP_URI", "ldap://openldap")


def _get_ldap_vars():
    try:
        import yaml
        config_path = os.environ.get("CONFIG_PATH", "/config/inventory.yml")
        with open(config_path) as f:
            config = yaml.safe_load(f) or {}
        vars_ = config.get("all", {}).get("vars", {})
        return {
            "base_dn": vars_.get("ldap_basedn", "dc=openldap,dc=local"),
            "admin_pw": vars_.get("ldap_admin_password", "changeme"),
        }
    except Exception:
        return {"base_dn": "dc=openldap,dc=local", "admin_pw": "changeme"}


@login_required
def change_password(request):
    if request.method == "POST":
        new_password = request.POST.get("new_password", "")
        confirm_password = request.POST.get("confirm_password", "")

        if not new_password:
            messages.error(request, "Password is required.")
            return redirect("change_password")

        if new_password == "admin":
            messages.error(request, "Password cannot be 'admin'.")
            return redirect("change_password")

        if new_password != confirm_password:
            messages.error(request, "Passwords do not match.")
            return redirect("change_password")

        # Change password in LDAP
        ldap = _get_ldap_vars()
        user_dn = f"uid={request.user.username},ou=users,{ldap['base_dn']}"
        ldif = f"""dn: {user_dn}
changetype: modify
replace: userPassword
userPassword: {new_password}
"""
        cmd = ["ldapmodify", "-x", "-H", LDAP_URI, "-D", f"cn=head-of-ldap,{ldap['base_dn']}", "-w", ldap["admin_pw"]]
        try:
            proc = subprocess.run(cmd, input=ldif, capture_output=True, text=True, timeout=10)
            if proc.returncode == 0:
                request.session["force_password_change"] = False
                messages.success(request, "Password changed successfully.")
                return redirect("/")
            else:
                messages.error(request, f"Error: {proc.stderr}")
        except Exception as e:
            messages.error(request, f"Error: {e}")

    return render(request, "main/change_password.html")
