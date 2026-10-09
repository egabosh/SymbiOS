#!/bin/bash
# SymbiOS - Manage standard media paths (libraries, inbox, shares base).
#
# Settings CLI-first architecture: the WebUI page /settings/media/ is a
# thin wrapper around this script, which owns validation and the
# inventory.yml write. The inventory write goes through
# symbios-inventory.py (merge, one transaction). See mediapaths.md and the
# AGENTS.md media rules for the semantics (read-only libraries, single
# writable inbox, group shares base) - this script only stores the paths,
# directories are owned by base-services/media.yml.

function f_usage {
  cat << EOF
Usage: $(basename "$0") <command> [options]

Manage SymbiOS standard media paths.

Commands:
  get [--json]                    Print current values (key=value lines,
                                  or a JSON object with --json)
  set [--media-root P --audio P --images P --videos P --books P
       --documents P --inbox P --shared P] [--check]
                                  Validate and write to inventory.yml.
                                  Every given path must be absolute.
                                  Options left out keep their current
                                  value. --check changes nothing.
  schema                          Print the field description as JSON
                                  (for generic WebUI form rendering)
  -h, --help                      Show this help and exit

Output: human status lines. The final line carries a machine-readable
state token (media-changed / media-unchanged).

Exit codes:
  0  ok, or nothing to do (unchanged)
  2  validation or usage error (empty or relative path, ...)
  1  technical error (inventory unreadable, ...)
EOF
}

source /etc/bash/gaboshlib.include
g_symbios_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
source "$g_symbios_dir/symbios-lib.sh"
source "$g_symbios_dir/symbios-settings-lib.sh"

# Domain fields in stable order: "inventory-key|flag-name".
f_fields="media_root|--media-root media_audio|--audio media_images|--images media_videos|--videos media_books|--books media_documents|--documents media_inbox|--inbox media_shared|--shared"

f_command="${1:-}"
case "${f_command}" in
  -h|--help|"")
    f_usage
    exit 0
    ;;
  get|set|schema)
    shift
    ;;
  *)
    echo "Unknown command: ${f_command}" >&2
    f_ss_fail_usage
    ;;
esac

if [[ "${f_command}" == "schema" ]]
then
  cat << 'EOF'
[
  {"name": "media_root", "type": "path", "label": "Media root",
   "required": true, "default": "/symbios/media", "secret": false},
  {"name": "media_audio", "type": "path", "label": "Audio library",
   "required": true, "default": "/symbios/media/audio", "secret": false},
  {"name": "media_images", "type": "path", "label": "Images library",
   "required": true, "default": "/symbios/media/images", "secret": false},
  {"name": "media_videos", "type": "path", "label": "Videos library",
   "required": true, "default": "/symbios/media/videos", "secret": false},
  {"name": "media_books", "type": "path", "label": "Books library",
   "required": true, "default": "/symbios/media/books", "secret": false},
  {"name": "media_documents", "type": "path", "label": "Documents archive",
   "required": true, "default": "/symbios/media/documents", "secret": false},
  {"name": "media_inbox", "type": "path", "label": "Inbox",
   "required": true, "default": "/symbios/media/inbox", "secret": false},
  {"name": "media_shared", "type": "path", "label": "Shares base",
   "required": true, "default": "/symbios/media/shared", "secret": false}
]
EOF
  exit 0
fi

if [[ "${f_command}" == "get" ]]
then
  if [[ "${1:-}" == "--json" ]]
  then
    f_json="{"
    f_first="yes"
    for f_pair in ${f_fields}
    do
      f_key="${f_pair%%|*}"
      [[ "${f_first}" == "yes" ]] || f_json="${f_json}, "
      f_first="no"
      f_val="$(f_symbios_var "${f_key}" "")"
      f_json="${f_json}\"${f_key}\": $(printf '%s' "${f_val}" | f_json_escape)"
    done
    echo "${f_json}}"
    exit 0
  elif [[ $# -gt 0 ]]
  then
    echo "Unknown option for get: $1" >&2
    f_ss_fail_usage
  fi
  for f_pair in ${f_fields}
  do
    f_key="${f_pair%%|*}"
    echo "${f_key}=$(f_symbios_var "${f_key}" "")"
  done
  exit 0
fi

# --- subcommand: set -----------------------------------------------------------

f_check="no"
f_given_any="no"
# Shell variables per key are created via printf -v (never eval: values
# come from WebUI forms and may hold quotes or $()+backticks), and read
# back via indirect expansion. The field list above stays the single
# source of truth.
for f_pair in ${f_fields}
do
  f_key="${f_pair%%|*}"
  printf -v "f_val_${f_key}" '%s' ""
  printf -v "f_given_${f_key}" '%s' "no"
done

while [[ $# -gt 0 ]]
do
  f_matched="no"
  for f_pair in ${f_fields}
  do
    f_key="${f_pair%%|*}"
    f_flag="${f_pair#*|}"
    if [[ "$1" == "${f_flag}" ]]
    then
      [[ $# -ge 2 ]] || f_ss_fail_usage
      printf -v "f_val_${f_key}" '%s' "$2"
      printf -v "f_given_${f_key}" '%s' "yes"
      f_given_any="yes"
      f_matched="yes"
      shift 2
      break
    fi
  done
  if [[ "${f_matched}" == "no" ]]
  then
    case "$1" in
      --check)
        f_check="yes"
        shift
        ;;
      -h|--help)
        f_usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        f_ss_fail_usage
        ;;
    esac
  fi
done

[[ "${f_given_any}" == "yes" ]] \
  || f_ss_fail_validation "Nothing to set - pass at least one path option"

# Every given path is required (the WebUI form always sends all of them)
# and must be absolute - same rules the view enforced before.
for f_pair in ${f_fields}
do
  f_key="${f_pair%%|*}"
  f_ref="f_given_${f_key}"
  f_given="${!f_ref}"
  [[ "${f_given}" == "yes" ]] || continue
  f_ref="f_val_${f_key}"
  f_val="${!f_ref}"
  if [[ -z "${f_val}" ]]
  then
    f_ss_fail_validation "Media path for ${f_key} is required"
  fi
  if [[ "${f_val}" != /* ]] || [[ "${f_val}" == *$'\n'* ]]
  then
    f_ss_fail_validation "Media path for ${f_key} must be an absolute single-line path"
  fi
done

# --- transactional write -------------------------------------------------------

f_merge="{"
f_merge_first="yes"
for f_pair in ${f_fields}
do
  f_key="${f_pair%%|*}"
  f_ref="f_given_${f_key}"
  f_given="${!f_ref}"
  [[ "${f_given}" == "yes" ]] || continue
  f_ref="f_val_${f_key}"
  f_val="${!f_ref}"
  [[ "${f_merge_first}" == "yes" ]] || f_merge="${f_merge}, "
  f_merge_first="no"
  f_merge="${f_merge}\"${f_key}\": $(printf '%s' "${f_val}" | f_json_escape)"
done
f_merge="${f_merge}}"

f_ss_merge "${f_merge}" "media" "${f_check}"
exit 0
