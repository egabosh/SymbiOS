#!/bin/bash
# SymbiOS - OpenWebUI sqlite database maintenance.
#
# All OpenWebUI runtime config lives in webui.db (config table, user and
# api_key tables); rows already stored there take precedence over ENV
# defaults at runtime. This script owns every DB write so the playbook
# services/openwebui.yml stays declarative. Secrets and URLs travel via
# environment (OWUI_*), never as argv. Tasks keep no_log: true.
#
# Subcommands print machine-readable tokens (Ansible changed_when):
#   api-key          ensure admin user + comfyui-automation key, print the key
#   patch-comfyui    negative_prompt None fix inside the container (no output)
#   workflows        ComfyUI workflow/node rows (prints restart|done)
#   sync-openai      base_url/api_key rows (prints changed on drift)
#   sync-speech      STT/TTS backend rows (prints changed on drift)
#   sync-image       ComfyUI image backend rows (prints changed on drift)
#   sync-retrieval   Tika/SearXNG rows (prints changed on drift)

function f_usage {
  cat << EOF
Usage: $(basename "$0") <subcommand>

  api-key          Ensure admin user + comfyui-automation API key, print key
  patch-comfyui    Apply negative_prompt None fix in the container
  workflows        Write ComfyUI workflow/node rows (OWUI_AI_SERVER/OWUI_AI_APIKEY)
  sync-openai      Sync openai base_url/api_key rows (OWUI_AI_SERVER/OWUI_AI_APIKEY)
  sync-speech      Sync STT/TTS rows (OWUI_STT_URL/KEY/MODEL, OWUI_TTS_URL/KEY/MODEL)
  sync-image       Sync image backend rows (OWUI_IMG_URL/MODEL/EDIT_URL/EDIT_MODEL)
  sync-retrieval   Sync Tika/SearXNG rows (OWUI_TIKA_URL, OWUI_SEARXNG_URL)

Config values travel via OWUI_* environment, never argv. Must run in
/symbios/services/openwebui (docker compose context).

Options:
  -h, --help          Show this help and exit
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]
then
  f_usage
  exit 0
fi

# Source shared libraries (absolute paths so cron works without profile PATH)
g_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /etc/bash/gaboshlib.include ]]
then
  . /etc/bash/gaboshlib.include
fi
source "${g_script_dir}/symbios-lib.sh"

g_db="${g_services_root}/openwebui/openwebui-data/webui.db"

function f_owui_api_key {
  local f_user_id f_uuid f_now f_key f_api_key
  # Create initial admin user if none exists
  f_user_id=$(sqlite3 "${g_db}" "SELECT id FROM \"user\" ORDER BY role='admin' DESC LIMIT 1")
  if [[ -z "${f_user_id}" ]]
  then
    f_uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
    f_now=$(date +%s%3N)
    sqlite3 "${g_db}" \
      "INSERT INTO \"user\"(id,name,email,role,profile_image_url,created_at,updated_at,last_active_at) \
       VALUES('${f_uuid}','admin','admin@localhost','admin','/user.png',${f_now},${f_now},${f_now})"
    f_user_id=${f_uuid}
  fi

  # Look for an existing key named 'comfyui-automation'
  f_key=$(sqlite3 "${g_db}" \
    "SELECT key FROM api_key WHERE json_extract(data,'\$.name')='comfyui-automation' LIMIT 1")
  if [[ -n "${f_key}" ]]
  then
    echo "${f_key}"
    return 0
  fi

  # Generate a fresh UUID, API key and timestamp
  f_uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
  f_api_key="sk-$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=')"
  f_now=$(date +%s%3N)

  # Insert the key into the database
  sqlite3 "${g_db}" \
    "INSERT INTO api_key(id,user_id,key,data,created_at,updated_at) \
     VALUES('${f_uuid}','${f_user_id}','${f_api_key}','{\"name\":\"comfyui-automation\"}',${f_now},${f_now})"

  echo "${f_api_key}"
}

function f_owui_patch_comfyui {
  local f_cid
  set -e
  f_cid=$(docker compose ps -q 2>/dev/null | head -1)
  [[ -z "${f_cid}" ]] && return 0
  if docker exec "${f_cid}" grep -q "payload.negative_prompt is not None" \
    /app/backend/open_webui/utils/images/comfyui.py 2>/dev/null
  then
    return 0
  fi
  docker exec "${f_cid}" sed -i \
    's|\(workflow\[node_id\]\[.inputs.\]\[node.key if node.key else .text.\]\s*=\s*\)payload\.negative_prompt$|\1payload.negative_prompt if payload.negative_prompt is not None else ""|' \
    /app/backend/open_webui/utils/images/comfyui.py
}

function f_owui_workflows {
  OWUI_DB="${g_db}" python3 <<'PYEOF'
import json, os, sqlite3, time

DB = os.environ["OWUI_DB"]

WF = {
    "3": {"class_type": "KSampler", "inputs": {
        "cfg": 8, "denoise": 1, "latent_image": ["5", 0], "model": ["4", 0],
        "negative": ["6", 0], "positive": ["7", 0], "sampler_name": "euler",
        "scheduler": "normal", "seed": 42, "steps": 20}},
    "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "sd15.safetensors"}},
    "5": {"class_type": "EmptyLatentImage", "inputs": {"batch_size": 1, "height": 512, "width": 512}},
    "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["4", 1], "text": "NEGATIVE_PROMPT"}},
    "7": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["4", 1], "text": "PROMPT"}},
    "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
    "9": {"class_type": "SaveImage", "inputs": {"filename_prefix": "ComfyUI", "images": ["8", 0]}},
}
EDIT_WF = {
    "3": {"class_type": "KSampler", "inputs": {
        "cfg": 8, "denoise": 0.7, "latent_image": ["10", 0], "model": ["4", 0],
        "negative": ["6", 0], "positive": ["7", 0], "sampler_name": "euler",
        "scheduler": "normal", "seed": 42, "steps": 20}},
    "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": "sd15.safetensors"}},
    "5": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
    "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["4", 1], "text": "NEGATIVE_PROMPT"}},
    "7": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["4", 1], "text": "PROMPT"}},
    "8": {"class_type": "SaveImage", "inputs": {"filename_prefix": "ComfyUI", "images": ["5", 0]}},
    "10": {"class_type": "VAEEncode", "inputs": {"samples": ["11", 0], "vae": ["4", 2]}},
    "11": {"class_type": "LoadImage", "inputs": {"image": ""}},
}
gen_nodes = [
    {"type": "model",           "node_ids": ["4"], "key": "ckpt_name"},
    {"type": "prompt",          "node_ids": ["7"], "key": "text"},
    {"type": "negative_prompt", "node_ids": ["6"], "key": "text"},
    {"type": "width",           "node_ids": ["5"], "key": "width"},
    {"type": "height",          "node_ids": ["5"], "key": "height"},
    {"type": "n",               "node_ids": ["5"], "key": "batch_size"},
    {"type": "steps",           "node_ids": ["3"], "key": "steps"},
    {"type": "seed",            "node_ids": ["3"], "key": "seed"},
]
edit_nodes = [
    {"type": "model",           "node_ids": ["4"], "key": "ckpt_name"},
    {"type": "prompt",          "node_ids": ["7"], "key": "text"},
    {"type": "negative_prompt", "node_ids": ["6"], "key": "text"},
    {"type": "image",           "node_ids": ["11"], "key": "image"},
]

db = sqlite3.connect(DB)
c = db.cursor()
now = int(time.time())

c.execute("SELECT key FROM config")
existing = {row[0] for row in c.fetchall()}

def upsert(key, value):
    c.execute(
        "INSERT INTO config (key, value, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at",
        (key, json.dumps(value) if not isinstance(value, str) else value, now),
    )

upsert("COMFYUI_WORKFLOW_NODES", gen_nodes)
upsert("image_generation.comfyui.workflow", json.dumps(WF))
upsert("image_generation.comfyui.nodes", gen_nodes)

upsert("IMAGES_EDIT_COMFYUI_WORKFLOW_NODES", edit_nodes)
upsert("IMAGES_EDIT_COMFYUI_WORKFLOW", json.dumps(EDIT_WF))
upsert("images.edit.comfyui.workflow", json.dumps(EDIT_WF))
upsert("images.edit.comfyui.nodes", edit_nodes)

upsert("ui.prompt_suggestions", [])

needs_restart = False
ai_server = os.environ.get("OWUI_AI_SERVER", "")
ai_apikey = os.environ.get("OWUI_AI_APIKEY", "")
if ai_server and "openai.enable" not in existing:
    upsert("openai.enable", True)
    upsert("openai.api_base_urls", [ai_server])
    upsert("openai.api_keys", [ai_apikey])
    upsert("openai.api_configs", {})
    needs_restart = True

db.commit()
db.close()
print("restart" if needs_restart else "done")
PYEOF
}

function f_owui_sync_kv {
  local f_key="${1}" f_want="${2}" f_now
  local f_cur
  f_now=$(date +%s%3N)
  f_cur=$(sqlite3 "${g_db}" "SELECT value FROM config WHERE key='${f_key}'")
  if [[ "${f_cur}" != "${f_want}" ]]
  then
    sqlite3 "${g_db}" "INSERT INTO config (key, value, updated_at) VALUES ('${f_key}', '${f_want}', ${f_now})
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
    echo changed
  fi
}

function f_owui_sync_openai {
  local f_base="[\"${OWUI_AI_SERVER:-}\"]" f_key="[\"${OWUI_AI_APIKEY:-}\"]"
  local f_cur_base f_cur_key f_now
  f_now=$(date +%s%3N)
  f_cur_base=$(sqlite3 "${g_db}" "SELECT value FROM config WHERE key='openai.api_base_urls'")
  f_cur_key=$(sqlite3 "${g_db}" "SELECT value FROM config WHERE key='openai.api_keys'")
  if [[ "${f_cur_base}" != "${f_base}" || "${f_cur_key}" != "${f_key}" ]]
  then
    sqlite3 "${g_db}" \
      "INSERT INTO config (key, value, updated_at) VALUES
         ('openai.enable', 'true', ${f_now}),
         ('openai.api_base_urls', '${f_base}', ${f_now}),
         ('openai.api_keys', '${f_key}', ${f_now})
       ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
    echo changed
  fi
}

function f_owui_sync_speech {
  local f_changed=""
  [[ -n "${OWUI_STT_URL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv audio.stt.openai.api_base_url "\"${OWUI_STT_URL}\"")"
  [[ -n "${OWUI_STT_KEY:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv audio.stt.openai.api_key "\"${OWUI_STT_KEY}\"")"
  [[ -n "${OWUI_STT_MODEL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv audio.stt.model "\"${OWUI_STT_MODEL}\"")"
  [[ -n "${OWUI_TTS_URL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv audio.tts.openai.api_base_url "\"${OWUI_TTS_URL}\"")"
  [[ -n "${OWUI_TTS_KEY:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv audio.tts.openai.api_key "\"${OWUI_TTS_KEY}\"")"
  [[ -n "${OWUI_TTS_MODEL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv audio.tts.model "\"${OWUI_TTS_MODEL}\"")"
  echo "${f_changed}"
}

function f_owui_sync_image {
  local f_changed=""
  [[ -n "${OWUI_IMG_URL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv image_generation.comfyui.base_url "\"${OWUI_IMG_URL}\"")"
  [[ -n "${OWUI_IMG_MODEL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv image_generation.model "\"${OWUI_IMG_MODEL}\"")"
  [[ -n "${OWUI_IMG_EDIT_URL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv images.edit.comfyui.base_url "\"${OWUI_IMG_EDIT_URL}\"")"
  [[ -n "${OWUI_IMG_EDIT_MODEL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv images.edit.model "\"${OWUI_IMG_EDIT_MODEL}\"")"
  echo "${f_changed}"
}

function f_owui_sync_retrieval {
  local f_changed=""
  [[ -n "${OWUI_TIKA_URL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv rag.tika_server_url "\"${OWUI_TIKA_URL}\"")"
  [[ -n "${OWUI_SEARXNG_URL:-}" ]] && f_changed="${f_changed}$(f_owui_sync_kv web.search.searxng_query_url "\"${OWUI_SEARXNG_URL}\"")"
  echo "${f_changed}"
}

# Main: dispatch subcommand (DB path fixed, values via OWUI_* environment)
f_cmd="${1:-}"
case "${f_cmd}" in
  api-key)
    f_owui_api_key
    ;;
  patch-comfyui)
    f_owui_patch_comfyui
    ;;
  workflows)
    f_owui_workflows
    ;;
  sync-openai)
    f_owui_sync_openai
    ;;
  sync-speech)
    f_owui_sync_speech
    ;;
  sync-image)
    f_owui_sync_image
    ;;
  sync-retrieval)
    f_owui_sync_retrieval
    ;;
  *)
    f_usage >&2
    exit 1
    ;;
esac
