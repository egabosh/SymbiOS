#!/bin/bash
# SymbiOS - Merge OIDC-created duplicate accounts into the original ones.
#
# When a user logs in via OIDC (Authelia) and the localpart is already
# taken by a local (password) account, Synapse does not merge them: it
# creates a second account with a numeric suffix (@olli -> @olli1). The
# new account is empty, the original keeps the chat history.
#
# This script finds such suffix accounts and moves the OIDC identity
# (the row in user_external_ids) onto the original account, then removes
# the empty duplicate. Afterwards the OIDC login lands on the account
# that holds the history.
#
# Usage:
#   symbios-matrix-oidc-merge.sh --list     Show OIDC links and duplicates
#   symbios-matrix-oidc-merge.sh --merge     Merge the duplicates (DB backup first)
#   symbios-matrix-oidc-merge.sh -h, --help

g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

function f_usage {
  cat << EOF
Usage: $(basename "$0") [--list | --merge]

Merge OIDC duplicate accounts (e.g. @olli1) into the original account
(@olli) so the OIDC login lands on the account with the history.

Options:
  --list     Show the OIDC identity links and the detected duplicates
  --merge    Perform the merge (takes a database backup first)
  -h, --help Show this help and exit
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]
then
  f_usage
  exit 0
fi

f_action="${1:---list}"

# Database access: the compose file holds the credentials.
f_compose="${g_services_root}/matrix/docker-compose.yml"
if ! [[ -f "${f_compose}" ]]
then
  g_echo_error "Matrix is not installed (${f_compose} missing)"
  exit 1
fi
f_env="${g_services_root}/matrix/env.db"
f_db_user="$(grep -E '^POSTGRES_USER=' "${f_env}" 2>/dev/null | cut -d= -f2-)"
f_db_name="$(grep -E '^POSTGRES_DB=' "${f_env}" 2>/dev/null | cut -d= -f2-)"
f_db_name="${f_db_name:-synapse}"
if [[ -z "${f_db_user}" ]]
then
  g_echo_error "No POSTGRES_USER in ${f_env}"
  exit 1
fi

function f_psql {
  docker exec -i matrix-db psql -U "${f_db_user}" -d "${f_db_name}" -f - "$@"
}

# List the OIDC links and detect duplicates: a linked account whose
# localpart without the numeric suffix exists as well.
f_sql_list='
SELECT e.user_id AS linked_user,
       (SELECT u.name FROM users u
         WHERE u.name = regexp_replace(e.user_id, '"'"'([0-9]+)$'"'"', '"'"''"'"', '"'"'g'"'"')
           AND u.name <> e.user_id) AS original_user,
       e.auth_provider, e.external_id
  FROM user_external_ids e
 ORDER BY e.user_id;
'

f_sql_merge='
BEGIN;

-- Move the OIDC identity onto the original account.
UPDATE user_external_ids e
   SET user_id = u.name
  FROM users u
 WHERE u.name = regexp_replace(e.user_id, '"'"'([0-9]+)$'"'"', '"'"''"'"', '"'"'g'"'"')
   AND u.name <> e.user_id
   AND e.user_id IN (
     SELECT e2.user_id FROM user_external_ids e2
      WHERE EXISTS (SELECT 1 FROM users u2
                     WHERE u2.name = regexp_replace(e2.user_id, '"'"'([0-9]+)$'"'"', '"'"''"'"', '"'"'g'"'"')
                       AND u2.name <> e2.user_id));

-- Remove the empty duplicate accounts (their rows are the ones still
-- pointing to the suffixed user id).
DO $$
DECLARE r record;
        t record;
BEGIN
  FOR r IN SELECT DISTINCT e.user_id FROM user_external_ids e
             WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.name = e.user_id)
  LOOP
    FOR t IN SELECT c.table_name FROM information_schema.columns c
              WHERE c.table_schema = '"'"'public'"'"' AND c.column_name = '"'"'device_id'"'"' AND c.table_name <> '"'"'devices'"'"'
    LOOP
      EXECUTE format('"'"'DELETE FROM %I WHERE device_id IN (SELECT device_id FROM devices WHERE user_id = %L)'"'"', t.table_name, r.user_id);
    END LOOP;
    FOR t IN SELECT c.table_name FROM information_schema.columns c
              WHERE c.table_schema = '"'"'public'"'"' AND c.column_name = '"'"'user_id'"'"' AND c.table_name <> '"'"'users'"'"'
    LOOP
      EXECUTE format('"'"'DELETE FROM %I WHERE user_id = %L'"'"', t.table_name, r.user_id);
    END LOOP;
    EXECUTE format('"'"'DELETE FROM users WHERE name = %L'"'"', r.user_id);
  END LOOP;
END $$;

COMMIT;
'

if [[ "${f_action}" == "--list" ]]
then
  g_echo "OIDC identity links (linked_user | original_user | provider | sub):"
  f_psql <<< "${f_sql_list}"
  exit 0
fi

if [[ "${f_action}" != "--merge" ]]
then
  g_echo_error "Unknown action ${f_action} (see --help)"
  exit 1
fi

# Detect the duplicates before touching anything.
f_dupes="$(f_psql -t -A <<< "${f_sql_list}" | awk -F'|' '$2 != "" {print $1 " -> " $2}')"
if [[ -z "${f_dupes}" ]]
then
  g_echo_note "No duplicate accounts found - nothing to merge"
  exit 0
fi
g_echo_warn "Duplicates to merge:"
echo "${f_dupes}"

f_stamp="$(date +%Y%m%d-%H%M)"
g_echo "Taking a database backup before the merge..."
if ! docker exec matrix-db pg_dump -U "${f_db_user}" -d "${f_db_name}" \
     | gzip > "${g_backup_root}/synapse-pre-oidc-merge-${f_stamp}.sql.gz"
then
  g_echo_error "Backup failed - aborting"
  exit 1
fi
g_echo "Backup written to ${g_backup_root}/synapse-pre-oidc-merge-${f_stamp}.sql.gz"

f_psql <<< "${f_sql_merge}"

g_echo "Merge done - the OIDC logins now land on the original accounts"
exit 0
