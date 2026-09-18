#!/bin/bash

# SymbiOS - Debian-based server management platform
# Copyright (c) 2026, Oliver Bohlen
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

# symbios-file-manager.sh - Web FileManager host operations.
#
# Runs on the host as root (invoked through symbios-exec.sh) and exposes all
# file operations the WebUI file manager needs. JSON data goes to stdout;
# binary payloads (write/upload) arrive base64-encoded on stdin; binary
# downloads are streamed raw to stdout via the 'download' verb.
#
# Verbs:
#   list <path>                 JSON directory listing
#   stat <path>                 JSON metadata of a single path
#   read <path>                 JSON {binary,size,content_b64} of a file
#   download <path>             raw file bytes on stdout
#   write <path>                write base64(stdin) to <path> (truncate)
#   upload <dir> <name>         write base64(stdin) to <dir>/<name> (single shot)
#   upload-start <dir> <name>   create staged temp file, print JSON {"tmp":...}
#   upload-part <tmp>           append base64(stdin) to the staged temp file
#   upload-finish <dir> <name> <tmp>   atomically move staged file into place
#   upload-abort <tmp>          discard a staged temp file
#   mkdir <path>                create a directory (parents as needed)
#   delete <path>...            remove files/directories (recursive for dirs)
#   rename <src> <dst>          move/rename a single path
#   move <dest> <path>...       move multiple paths into <dest>
#   copy <dest> <path>...       copy multiple paths into <dest> (dirs deep)
#   chmod <mode> <recursive> <path>...
#   chown <owner> <group> <recursive> <path>...
#   users                       JSON {"users":[...],"groups":[...]}
#   run-script '<template>' <path>...
#
# run-script placeholders (shell-quoted at substitution time):
#   {{path}}  full path   {{dir}}  parent directory   {{name}}  basename
#   {{stem}}  basename without final extension

g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"


# ------------------------------------------------------------------ helpers

# Reject empty, relative and newline-containing paths.
function f_path_valid {
  local f_path="$1"
  [[ -n "$f_path" ]] || return 1
  [[ "${f_path:0:1}" == "/" ]] || return 1
  [[ "$f_path" != *$'\n'* ]] || return 1
  [[ "$f_path" != *$'\t'* ]] || return 1
  return 0
}

# f_chmod_syntax <mode>: numeric (0-7777) only; symbolic never reaches the host.
function f_chmod_syntax {
  [[ "$1" =~ ^[0-7]{3,4}$ ]]
}

# f_namesyntax <name>: a single path component (no slashes, no dot trickery).
function f_namesyntax {
  local f_name="$1"
  [[ -n "$f_name" ]] || return 1
  [[ "$f_name" != */* ]] || return 1
  [[ "$f_name" != "." ]] || return 1
  [[ "$f_name" != ".." ]] || return 1
  [[ "$f_name" != *$'\n'* ]] || return 1
  [[ "$f_name" != *$'\t'* ]] || return 1
  return 0
}

# f_id_syntax <owner|group>: alphanumeric user/group names (no shell/colon).
function f_id_syntax {
  [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
}

# Run a small python3 snippet that emits the listing/stat JSON. Python keeps
# unicode filenames, quoting and mode bits sane (builds the JSON document).
function f_python_list {
  python3 - "$@" <<'PYEOF'
import json, os, pwd, grp, stat as st, sys

def fmt(path):
    try:
        s = os.lstat(path)
    except OSError:
        return None
    mode = s.st_mode
    islink = st.S_ISLNK(mode)
    # Follow links only to decide the effective type (dir/file), never to
    # read data: symlinked config files must be edited via their link.
    link_target = ""
    if islink:
        try:
            link_target = os.readlink(path)
        except OSError:
            pass
    try:
        is_dir = st.S_ISDIR(os.stat(path).st_mode)
    except OSError:
        is_dir = False
    try:
        owner = pwd.getpwuid(s.st_uid).pw_name
    except KeyError:
        owner = str(s.st_uid)
    try:
        group = grp.getgrgid(s.st_gid).gr_name
    except KeyError:
        group = str(s.st_gid)
    return {
        "name": os.path.basename(path) or path,
        "type": "dir" if is_dir else ("link" if islink else "file"),
        "size": s.st_size,
        "perm": st.filemode(mode),
        "mode": st.S_IMODE(mode),
        "owner": owner,
        "group": group,
        "mtime": int(s.st_mtime),
        "link": link_target,
        "path": path,
    }

def main():
    mode = sys.argv[1]
    path = sys.argv[2]
    if mode == "list":
        try:
            names = sorted(os.listdir(path), key=str.lower)
        except OSError as e:
            sys.stderr.write(str(e))
            sys.exit(1)
        out = []
        for n in names:
            e = fmt(os.path.join(path, n))
            if e:
                out.append(e)
        # dirs first, then files
        out.sort(key=lambda e: (0 if e["type"] == "dir" else 1, e["name"].lower()))
        print(json.dumps(out))
    else:  # stat
        e = fmt(path)
        if not e:
            sys.stderr.write("no such file or directory")
            sys.exit(1)
        print(json.dumps(e))
    sys.exit(0)

main()
PYEOF
}

# f_b64read <path>: read file, base64-encode, honor binary detection.
function f_python_read {
  python3 - "$1" <<'PYEOF'
import base64, json, os, sys

path = sys.argv[1]
MAX_TEXT = 2 * 1024 * 1024  # refuse to push large files into the editor
try:
    size = os.path.getsize(path)
    if size > MAX_TEXT:
        print(json.dumps({"binary": True, "size": size, "content_b64": "",
                          "too_large": True}))
        sys.exit(0)
    with open(path, "rb") as fh:
        data = fh.read()
except OSError as e:
    sys.stderr.write(str(e))
    sys.exit(1)
binary = b"\x00" in data[:8192]
if not binary:
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        binary = True
print(json.dumps({"binary": binary, "size": size,
                  "content_b64": "" if binary else base64.b64encode(data).decode("ascii")}))
sys.exit(0)
PYEOF
}

# f_usage <message>: print usage-and-exit style JSON error.
function f_usage {
  f_json_error "Usage: $0 $1"
}


# ------------------------------------------------------------------ actions

function f_list {
  [[ $# -ge 1 ]] || f_usage "list <path>"
  f_path_valid "$1" || f_json_error "Invalid path"
  [[ -d "$1" || -L "$1" ]] || f_json_error "Not a directory: $1"
  f_python_list list "$1" || f_json_error "Cannot read directory: $1"
}

function f_stat {
  [[ $# -ge 1 ]] || f_usage "stat <path>"
  f_path_valid "$1" || f_json_error "Invalid path"
  [[ -e "$1" || -L "$1" ]] || f_json_error "No such file or directory: $1"
  f_python_list stat "$1" || f_json_error "Cannot stat: $1"
}

function f_read {
  [[ $# -ge 1 ]] || f_usage "read <path>"
  f_path_valid "$1" || f_json_error "Invalid path"
  [[ -f "$1" ]] || f_json_error "Not a regular file: $1"
  f_python_read "$1" || f_json_error "Cannot read file: $1"
}

function f_download {
  [[ $# -ge 1 ]] || f_usage "download <path>"
  f_path_valid "$1" || f_json_error "Invalid path"
  [[ -f "$1" ]] || f_json_error "Not a regular file: $1"
  cat "$1"
}

function f_write {
  [[ $# -ge 1 ]] || f_usage "write <path>"
  f_path_valid "$1" || f_json_error "Invalid path"
  # Base64 payload arrives on stdin (never on the command line / audit log).
  # Decode into a temp file first so a corrupt payload never truncates the
  # target (a failed editor save must not destroy the original file).
  local f_tmp
  f_tmp="$(mktemp --tmpdir symbios-fm-write.XXXXXX 2>/dev/null)" || f_json_error "Cannot create temp file"
  base64 -d 2>/dev/null > "$f_tmp" || { rm -f "$f_tmp" 2>/dev/null; f_json_error "Invalid base64 payload"; }
  cat "$f_tmp" > "$1" || { rm -f "$f_tmp" 2>/dev/null; f_json_error "Cannot write file: $1"; }
  rm -f "$f_tmp" 2>/dev/null
}

function f_upload {
  [[ $# -ge 2 ]] || f_usage "upload <dir> <name>"
  f_path_valid "$1" || f_json_error "Invalid directory"
  [[ -d "$1" ]] || f_json_error "Not a directory: $1"
  f_namesyntax "$2" || f_json_error "Invalid file name: $2"
  local f_tmp f_target
  f_tmp="$(mktemp --tmpdir symbios-fm-upload.XXXXXX 2>/dev/null)" || f_json_error "Cannot create temp file"
  base64 -d 2>/dev/null > "$f_tmp" || { rm -f "$f_tmp" 2>/dev/null; f_json_error "Invalid base64 payload"; }
  f_target="$1/$2"
  cat "$f_tmp" > "$f_target" || { rm -f "$f_tmp" 2>/dev/null; f_json_error "Cannot upload file: $2"; }
  rm -f "$f_tmp" 2>/dev/null
}

# Staging paths come from mktemp below (always /tmp/symbios-fm-upload.*). Only
# accept those, never arbitrary /tmp files - otherwise the WebUI could move or
# delete any temp file on the host via upload-finish/upload-abort.
function f_upload_staging_valid {
  local f_tmp="$1"
  [[ -n "$f_tmp" ]] || return 1
  [[ "$f_tmp" == /tmp/symbios-fm-upload.* ]] || return 1
  [[ "$f_tmp" != *$'\n'* ]] || return 1
  return 0
}

function f_upload_start {
  [[ $# -ge 2 ]] || f_usage "upload-start <dir> <name>"
  f_path_valid "$1" || f_json_error "Invalid directory"
  [[ -d "$1" ]] || f_json_error "Not a directory: $1"
  f_namesyntax "$2" || f_json_error "Invalid file name: $2"
  local f_tmp
  f_tmp="$(mktemp /tmp/symbios-fm-upload.XXXXXX 2>/dev/null)" || f_json_error "Cannot create staging file"
  printf '{"ok":true,"tmp":"%s"}\n' "$f_tmp"
}

function f_upload_part {
  [[ $# -ge 1 ]] || f_usage "upload-part <tmp>"
  f_upload_staging_valid "$1" || f_json_error "Invalid staging file"
  base64 -d 2>/dev/null >> "$1" || { rm -f "$1" 2>/dev/null; f_json_error "Invalid base64 payload"; }
  printf '{"ok":true}\n'
}

function f_upload_finish {
  [[ $# -ge 3 ]] || f_usage "upload-finish <dir> <name> <tmp>"
  f_path_valid "$1" || f_json_error "Invalid directory"
  [[ -d "$1" ]] || f_json_error "Not a directory: $1"
  f_namesyntax "$2" || f_json_error "Invalid file name: $2"
  f_upload_staging_valid "$3" || f_json_error "Invalid staging file"
  mv -f "$3" "$1/$2" || f_json_error "Cannot finalize upload: $2"
  printf '{"ok":true}\n'
}

function f_upload_abort {
  [[ $# -ge 1 ]] || f_usage "upload-abort <tmp>"
  f_upload_staging_valid "$1" || f_json_error "Invalid staging file"
  rm -f "$1" 2>/dev/null
  printf '{"ok":true}\n'
}

function f_mkdir {
  [[ $# -ge 1 ]] || f_usage "mkdir <path>"
  f_path_valid "$1" || f_json_error "Invalid path"
  mkdir -p "$1" || f_json_error "Cannot create directory: $1"
}

function f_delete {
  [[ $# -ge 1 ]] || f_usage "delete <path>..."
  local f_p f_check
  for f_p in "$@"
  do
    f_path_valid "$f_p" || f_json_error "Invalid path: $f_p"
    f_check="${f_p%/}"
    [[ "$f_check" != "/" ]] || f_json_error "Refusing to delete /"
  done
  rm -rf -- "$@" || f_json_error "Cannot delete"
}

function f_rename {
  [[ $# -ge 2 ]] || f_usage "rename <src> <dst>"
  f_path_valid "$1" || f_json_error "Invalid source path"
  f_path_valid "$2" || f_json_error "Invalid destination path"
  [[ "$2" != "/" ]] || f_json_error "Refusing to rename to /"
  mv -f -- "$1" "$2" || f_json_error "Cannot rename"
}

function f_move {
  local f_dest="$1"
  shift
  [[ -n "$f_dest" ]] || f_usage "move <dest> <path>..."
  f_path_valid "$f_dest" || f_json_error "Invalid destination"
  [[ -d "$f_dest" ]] || f_json_error "Destination is not a directory: $f_dest"
  [[ $# -ge 1 ]] || f_json_error "No source paths"
  local f_p
  for f_p in "$@"
  do
    f_path_valid "$f_p" || f_json_error "Invalid source path: $f_p"
  done
  mv -f -- "$@" "$f_dest" || f_json_error "Cannot move"
}

function f_copy {
  local f_dest="$1"
  shift
  [[ -n "$f_dest" ]] || f_usage "copy <dest> <path>..."
  f_path_valid "$f_dest" || f_json_error "Invalid destination"
  [[ -d "$f_dest" ]] || f_json_error "Destination is not a directory: $f_dest"
  [[ $# -ge 1 ]] || f_json_error "No source paths"
  local f_p
  for f_p in "$@"
  do
    f_path_valid "$f_p" || f_json_error "Invalid source path: $f_p"
  done
  cp -a -- "$@" "$f_dest" || f_json_error "Cannot copy"
}

function f_chmod {
  [[ $# -ge 3 ]] || f_usage "chmod <mode> <recursive> <path>..."
  local f_mode="$1"
  local f_recursive="$2"
  shift 2
  f_chmod_syntax "$f_mode" || f_json_error "Invalid mode: $f_mode (octal 3-4 digits)"
  local f_path
  for f_path in "$@"
  do
    f_path_valid "$f_path" || f_json_error "Invalid path: $f_path"
  done
  if [[ "$f_recursive" == "1" ]]
  then
    chmod -R "$f_mode" -- "$@" || f_json_error "Cannot chmod"
  else
    chmod "$f_mode" -- "$@" || f_json_error "Cannot chmod"
  fi
}

function f_chown {
  [[ $# -ge 4 ]] || f_usage "chown <owner> <group> <recursive> <path>..."
  local f_owner="$1"
  local f_group="$2"
  local f_recursive="$3"
  shift 3
  local f_spec f_path
  if [[ -n "$f_owner" ]]
  then
    f_id_syntax "$f_owner" || f_json_error "Invalid owner: $f_owner"
    if [[ -n "$f_group" ]]
    then
      f_id_syntax "$f_group" || f_json_error "Invalid group: $f_group"
      f_spec="${f_owner}:${f_group}"
    else
      f_spec="${f_owner}"
    fi
  else
    # Owner unchanged, group only.
    if [[ -n "$f_group" ]]
    then
      f_id_syntax "$f_group" || f_json_error "Invalid group: $f_group"
      f_spec=":${f_group}"
    else
      f_json_error "Nothing to change (owner and group empty)"
    fi
  fi
  for f_path in "$@"
  do
    f_path_valid "$f_path" || f_json_error "Invalid path: $f_path"
  done
  if [[ "$f_recursive" == "1" ]]
  then
    chown -R "${f_spec}" -- "$@" || f_json_error "Cannot chown"
  else
    chown "${f_spec}" -- "$@" || f_json_error "Cannot chown"
  fi
}

function f_users {
  python3 - <<'PYEOF'
import grp, json, pwd
print(json.dumps({
    "users": [u.pw_name for u in pwd.getpwall()],
    "groups": [g.gr_name for g in grp.getgrall()],
}))
PYEOF
}

function f_run_script {
  [[ $# -ge 2 ]] || f_usage "run-script '<template>' <path>..."
  local f_template="$1"
  shift
  [[ -n "$f_template" ]] || f_json_error "Empty script template"
  local f_p f_dir f_name f_stem f_cmd
  for f_p in "$@"
  do
    f_path_valid "$f_p" || f_json_error "Invalid path: $f_p"
    f_dir="$(dirname "$f_p")"
    f_name="$(basename "$f_p")"
    f_stem="${f_name%.*}"
    f_cmd="$f_template"
    f_cmd="${f_cmd//\{\{path\}\}/$(printf '%q' "$f_p")}"
    f_cmd="${f_cmd//\{\{dir\}\}/$(printf '%q' "$f_dir")}"
    f_cmd="${f_cmd//\{\{name\}\}/$(printf '%q' "$f_name")}"
    f_cmd="${f_cmd//\{\{stem\}\}/$(printf '%q' "$f_stem")}"
    echo "==> ${f_p}"
    bash -c "${f_cmd}" || f_json_error "Script failed for ${f_p}"
  done
}


# ------------------------------------------------------------------- main

g_action="${1:-}"
shift 2>/dev/null || true

case "$g_action" in
  list)    f_list "$@" ;;
  stat)    f_stat "$@" ;;
  read)    f_read "$@" ;;
  download) f_download "$@" ;;
  write)   f_write "$@" ;;
  upload)  f_upload "$@" ;;
  upload-start) f_upload_start "$@" ;;
  upload-part)  f_upload_part "$@" ;;
  upload-finish) f_upload_finish "$@" ;;
  upload-abort)  f_upload_abort "$@" ;;
  mkdir)   f_mkdir "$@" ;;
  delete)  f_delete "$@" ;;
  rename)  f_rename "$@" ;;
  move)    f_move "$@" ;;
  copy)    f_copy "$@" ;;
  chmod)   f_chmod "$@" ;;
  chown)   f_chown "$@" ;;
  users)   f_users ;;
  run-script) f_run_script "$@" ;;
  *)
    f_usage "list|stat|read|download|write|upload|upload-start|upload-part|upload-finish|upload-abort|mkdir|delete|rename|move|copy|chmod|chown|users|run-script"
    ;;
esac