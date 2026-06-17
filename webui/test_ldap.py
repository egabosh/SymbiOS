import urllib.request, urllib.parse, http.cookiejar, re, subprocess

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

def get_csrf(html):
    m = re.search(r'csrfmiddlewaretoken.*?value="([^"]+)"', html)
    return m.group(1) if m else None

# Login
resp = opener.open("http://localhost:8080/login/")
csrf = get_csrf(resp.read().decode())
data = urllib.parse.urlencode({"csrfmiddlewaretoken": csrf, "username": "admin", "password": "admin"}).encode()
opener.addheaders = [("Referer", "http://localhost:8080/login/")]
r = opener.open("http://localhost:8080/login/", data)
print("1. Login:", r.status, "->", r.url)

# Users page
page = opener.open("http://localhost:8080/users_groups/").read().decode()
csrf2 = get_csrf(page)
has_admin = "uid=admin" in page
print("2. Users page:", "admin found" if has_admin else "admin NOT found")

# Create user
data2 = urllib.parse.urlencode({
    "csrfmiddlewaretoken": csrf2,
    "uid": "testwebui",
    "cn": "Test WebUI",
    "password": "Test1234",
    "group": "ldap-users"
}).encode()
opener.addheaders = [("Referer", "http://localhost:8080/users_groups/")]
r2 = opener.open("http://localhost:8080/users_groups/create/", data2)
result = r2.read().decode()
has_error = "alert-danger" in result
if has_error:
    m = re.search(r'alert-danger[^>]*>([^<]+)', result)
    print("3. Create user ERROR:", m.group(1).strip() if m else "unknown")
else:
    print("3. Create user: OK (redirected to users_groups)")

# Verify in LDAP
proc = subprocess.run(
    ["ldapsearch", "-x", "-H", "ldap://openldap",
     "-D", "cn=head-of-ldap,dc=openldap,dc=local",
     "-w", "JnBvLrwsU5TovirBHsmt4hGSHuL3VMJy",
     "-b", "dc=openldap,dc=local",
     "(uid=testwebui)", "uid"],
    capture_output=True, text=True, timeout=10
)
if "uid: testwebui" in proc.stdout:
    print("4. LDAP verify: testwebui EXISTS")
else:
    print("4. LDAP verify: testwebui NOT FOUND")
    print("   ldapsearch output:", proc.stdout[:200])
    print("   ldapsearch stderr:", proc.stderr[:200])

# Try set password
page3 = opener.open("http://localhost:8080/users_groups/").read().decode()
csrf3 = get_csrf(page3)
data3 = urllib.parse.urlencode({"csrfmiddlewaretoken": csrf3, "password": "NeuesPW2026"}).encode()
opener.addheaders = [("Referer", "http://localhost:8080/users_groups/")]
r3 = opener.open("http://localhost:8080/users_groups/testwebui/password/", data3)
result3 = r3.read().decode()
has_error3 = "alert-danger" in result3
if has_error3:
    m = re.search(r'alert-danger[^>]*>([^<]+)', result3)
    print("5. Set password ERROR:", m.group(1).strip() if m else "unknown")
else:
    print("5. Set password: OK")

# Try delete
page4 = opener.open("http://localhost:8080/users_groups/").read().decode()
csrf4 = get_csrf(page4)
data4 = urllib.parse.urlencode({"csrfmiddlewaretoken": csrf4}).encode()
opener.addheaders = [("Referer", "http://localhost:8080/users_groups/")]
r4 = opener.open("http://localhost:8080/users_groups/testwebui/delete/", data4)
result4 = r4.read().decode()
has_error4 = "alert-danger" in result4
if has_error4:
    m = re.search(r'alert-danger[^>]*>([^<]+)', result4)
    print("6. Delete user ERROR:", m.group(1).strip() if m else "unknown")
else:
    print("6. Delete user: OK")

# Final LDAP check
proc2 = subprocess.run(
    ["ldapsearch", "-x", "-H", "ldap://openldap",
     "-D", "cn=head-of-ldap,dc=openldap,dc=local",
     "-w", "JnBvLrwsU5TovirBHsmt4hGSHuL3VMJy",
     "-b", "dc=openldap,dc=local",
     "(objectClass=posixAccount)", "uid"],
    capture_output=True, text=True, timeout=10
)
users = [l.split(": ")[1] for l in proc2.stdout.split("\n") if l.startswith("uid: ")]
print("7. All LDAP users:", users)
