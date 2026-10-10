#!/usr/bin/env python3
# SymbiOS - Verify docs uses_vars coverage in playbooks.
#
# Every services/*.yml and base-services/*.yml playbook with a # docs:
# header must declare the inventory keys it bakes into state (see
# playbooks.md#playbook-conventions). This check fails on USED-BUT-
# UNDECLARED keys (a settings change would silently miss the reapply);
# over-declared keys are informational only (extra reapplies are safe).
# Scripts called as playbook tasks contribute the keys they read via
# f_symbios_var (plus the exemption map below for custom readers).

"""Check docs uses_vars coverage. Exit 1 on used-but-undeclared keys."""

import glob
import os
import re
import sys
import yaml

JINJA_SKIP = set("""if else elif endif for endfor in is not and or as do set
block endblock macro endmacro import from true false none True False None loop
recursive item vars hostvars groups omit defined undefined divisibleby odd even
eq ne lt le gt ge ternary int string float bool list title capitalize attr
pprint urlize wordcount batch slice groupby sum sort round unique join indent
split upper lower splitlines join indent wordcount wordwrap truncate striptags
urlencode tojson fromjson toyaml fromyaml b64encode b64decode quote shell_quote
basename dirname expanduser realpath relpath splitext regex_replace regex_search
regex_findall fileglob password_hash shuffle equalto lessthan greaterthan
string_startswith number integer mapping iterable sequence length first last
random shuffle max min abs round int float bool string list default mandatory
comment select selectattr reject rejectattr sort unique reverse first last
dictsort flatten subelements permutations product checksum md5 sha1 hash
lookup query q now utcfromtimestamp to_datetime strftime parse_datestring
dict2items items2dict xmlattr keys values safe escape trim upper lower split
rsplit title float round length filesizeformat urlize float round length join
map select splitlines join striptags title capitalize trim replace
test failed success skipped changed combine combine_recursive flatten
zip_longest to_uuid to_datetime textareafield lines splitlines ipaddr ipwrap
hwaddr macaddr dictsort flatten subelements win_basename to_uuid
equalto ne lessthan lessthanorequalto greaterthan greaterthanorequalto nin
string number integer float mapping iterable sequence divisibleby odd even
ternary title capitalize quote shell_quote shlex_quote basename dirname
expanduser realpath relpath splitext fileglob shuffle
ipaddr ipwrap hwaddr macaddr combine dictsort flatten""".split())

INFRA = {'data_root', 'git_root', 'services_root', 'base_services_root',
         'docker_root', 'containerd_root', 'backup_root',
         'ansible_python_interpreter', 'ansible_user', 'ldap_basedn'}

# Scripts with custom inventory readers (no f_symbios_var call to find).
SCRIPT_EXTRA = {
    'symbios-bridge-assign.sh': ['bridge_assignments'],
    'symbios-nextcloud-media-scan.sh': ['nextcloud_media_scan_mounts'],
}

def f_usage():
    print("Usage: symbios-check-uses-vars.py [--repo DIR]")
    print("")
    print("Verify docs uses_vars coverage in services/ and base-services/")
    print("playbooks. Fails on used-but-undeclared inventory keys;")
    print("over-declared keys are informational only.")
    print("")
    print("Options:")
    print("  --repo DIR          Repo root (default: script's parent dir)")
    print("  -h, --help          Show this help and exit")


def inventory_keys(repo):
    with open(os.path.join(repo, 'inventory.yml')) as fh:
        return set(yaml.safe_load(fh)['all']['vars'].keys())


def parse_docs_uses(path):
    """Return (has_docs, uses_list_or_None, parse_ok) from the # docs: header."""
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return False, [], True
    comment_lines = []
    in_block = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('#'):
            in_block = True
            comment_lines.append(line)
        elif in_block and stripped == '':
            continue
        elif in_block:
            break
    yaml_lines = []
    in_docs = False
    for line in comment_lines:
        content = line[2:] if line.startswith('# ') else line[1:]
        if not in_docs:
            if content.startswith('docs:'):
                in_docs = True
                yaml_lines.append(content)
        else:
            yaml_lines.append(content)
    if not yaml_lines:
        return False, [], True
    try:
        doc = yaml.safe_load('\n'.join(yaml_lines))
    except yaml.YAMLError:
        return True, [], False
    docs = doc.get('docs') if isinstance(doc, dict) else None
    if not isinstance(docs, dict):
        return True, [], False
    uses = docs.get('uses_vars')
    if uses is None:
        return True, None, True
    return True, list(uses), True


def script_read_keys(repo, name):
    """Inventory keys a scripts/ helper reads (f_symbios_var + exemptions)."""
    keys = list(SCRIPT_EXTRA.get(name, []))
    try:
        text = open(os.path.join(repo, 'scripts', name)).read()
    except OSError:
        return keys
    keys += re.findall(r'f_symbios_var ([a-z_][a-z0-9_]*)', text)
    return keys


def file_jinja_ids(text):
    """Identifiers from Jinja spans (literals blanked), minus Jinja keywords."""
    ids = set()
    for span in re.findall(r'\{\{.*?\}\}|\{%.*?%\}', text):
        span2 = re.sub(r"'[^']*'|\"[^\"]*\"", ' ', span)
        ids.update(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', span2))
    return ids - JINJA_SKIP


def file_locals(text):
    """Play-local names: register/set_fact/loop_var/include-vars (not inventory)."""
    locals_ = {'service_name', 'service_domain', 'item'}
    for m in re.finditer(r'^\s*register:\s*([A-Za-z_][A-Za-z0-9_]*)', text, re.M):
        locals_.add(m.group(1))
    for m in re.finditer(r'loop_var:\s*([A-Za-z_][A-Za-z0-9_]*)', text):
        locals_.add(m.group(1))
    for m in re.finditer(r'(?:set_fact:|vars:)\n((?:\s+[a-z_][a-z0-9_]*:.*\n)+)', text):
        for k in re.findall(r'^\s+([a-z_][a-z0-9_]*):', m.group(1), re.M):
            locals_.add(k)
    return locals_


def playbook_used_keys(repo, path, inv, _depth=0):
    """Inventory keys baked into state by a playbook (tasks + called scripts).

    Direct shared-task includes (../shared-tasks/*.yml) are scanned one
    level deep so their inventory gates (e.g. base-domain-guard,
    router-forward) attribute to the calling playbook.
    """
    lines = open(path).read().splitlines()
    code = [l for l in lines if not l.lstrip().startswith('#')]
    ids = set()
    for line in code:
        if re.match(r'\s*- name:', line):
            continue
        ids.update(file_jinja_ids(line))
    for line in code:
        m = re.match(r'\s*(when|failed_when|changed_when):\s*(.*)$', line)
        if m:
            rhs = re.sub(r"'[^']*'|\"[^\"]*\"", ' ', m.group(2))
            ids.update(re.findall(r'[A-Za-z_][A-Za-z0-9_]*', rhs))
    text = '\n'.join(code)
    used = (ids - file_locals(text)) & inv - INFRA
    # Scripts EXECUTED as single-line shell/command tasks contribute the
    # keys they read (task-time effect). Mentions inside deployed multi-line
    # script bodies run at runtime (cron/hooks) and do not count. Libraries
    # (*-lib.sh, sourced not executed) never count.
    for line in code:
        if not re.match(r'\s*(ansible\.builtin\.)?(shell|command|cmd):', line):
            continue
        for name in set(re.findall(r'symbios-[a-z0-9-]+\.sh', line)):
            if name.endswith('-lib.sh'):
                continue
            used.update(k for k in script_read_keys(repo, name)
                        if k in inv and k not in INFRA)
    # One level into directly included shared tasks (their gates belong
    # to the caller); nested includes resolve via the visited set.
    if _depth < 2:
        for name in set(re.findall(r'include_tasks:\s*\.\./shared-tasks/([a-z0-9-]+\.yml)',
                                   text)):
            sub = os.path.join(repo, 'shared-tasks', name)
            if os.path.isfile(sub):
                used |= playbook_used_keys(repo, sub, inv, _depth + 1)
    return used


def main(argv):
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args = list(argv)
    if '-h' in args or '--help' in args:
        f_usage()
        return 0
    if '--repo' in args:
        i = args.index('--repo')
        repo = args[i + 1]
    inv = inventory_keys(repo)
    errors = 0
    files = sorted(glob.glob(os.path.join(repo, 'services', '*.yml'))
                   + glob.glob(os.path.join(repo, 'base-services', '*.yml')))
    for path in files:
        rel = os.path.relpath(path, repo)
        has_docs, uses, parse_ok = parse_docs_uses(path)
        if not has_docs:
            print("WARN %s: no docs header, skipped" % rel)
            continue
        if not parse_ok:
            print("ERROR %s: docs header does not parse as YAML" % rel)
            errors += 1
            continue
        if uses is None:
            print("ERROR %s: docs header without uses_vars" % rel)
            errors += 1
            continue
        used = playbook_used_keys(repo, path, inv)
        missing = sorted(used - set(uses))
        extra = sorted(set(uses) - used)
        for key in missing:
            print("ERROR %s: uses %s but not declared in uses_vars" % (rel, key))
            errors += 1
        for key in extra:
            print("INFO %s: declares %s (no task usage found)" % (rel, key))
    if errors:
        print("FAIL: %d used-but-undeclared keys" % errors)
        return 1
    print("OK: uses_vars coverage complete (%d playbooks)" % len(files))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
