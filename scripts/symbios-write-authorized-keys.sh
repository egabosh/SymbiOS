#!/bin/bash
# SymbiOS - Write SSH authorized_keys from stdin
# Usage: echo "key1\nkey2" | symbios-write-authorized-keys.sh
# Reads keys from stdin and writes to /root/.ssh/authorized_keys
# Always preserves the symbios-base-webui exec-gateway key.

source /etc/bash/gaboshlib.include

g_keys_file="/root/.ssh/authorized_keys"
g_tmp="${g_keys_file}.tmp.$$"

# Ensure .ssh directory exists
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Read keys from stdin, write atomically
cat > "$g_tmp"
if [[ $? -ne 0 ]]
then
  rm -f "$g_tmp"
  echo '{"ok":false,"error":"Failed to read keys from input"}' >&2
  exit 1
fi

# Validate: each non-empty, non-comment line should look like a valid key
g_invalid=0
while IFS= read -r g_line
do
  # Skip empty lines and comments
  [[ -z "$g_line" || "$g_line" == \#* ]] && continue
  # Basic check: at least 2 whitespace-separated fields
  g_fields=$(echo "$g_line" | wc -w)
  if (( g_fields < 2 ))
  then
    g_invalid=1
    break
  fi
done < "$g_tmp"

if [[ $g_invalid -eq 1 ]]
then
  rm -f "$g_tmp"
  echo '{"ok":false,"error":"Invalid key format detected"}' >&2
  exit 1
fi

# Preserve the symbios-base-webui exec-gateway key: if the new input does not
# contain it, extract it from the old file and append it.
if ! grep -q 'symbios-base-webui' "$g_tmp" 2>/dev/null
then
  if [[ -f "$g_keys_file" ]] && grep -q 'symbios-base-webui' "$g_keys_file" 2>/dev/null
  then
    grep 'symbios-base-webui' "$g_keys_file" >> "$g_tmp"
  fi
fi

# Atomic move
mv "$g_tmp" "$g_keys_file"
chmod 644 "$g_keys_file"

echo '{"ok":true,"message":"SSH keys written."}'
