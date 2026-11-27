#!/usr/bin/env bash
# OpenWebUI patches applied on every container start so image updates cannot
# silently undo them:
# 1. File uploads stay asynchronous. Waiting inside the upload endpoint makes
#    the mobile client hit its 60 s timeout (Traefik 499, DioException).
# 2. Every chat waits for pending transcriptions before the prompt is built,
#    so the model always sees the finished transcript. The wait has to live in
#    process_chat_payload: the app sends a session_id, which disables the
#    separate file-context handler.
# 3. Chats inherit the machine configured on the model when they have no
#    machine field, so terminal tools work even if the client never selected one.
set -euo pipefail

if ! python3 - <<'PY'
from pathlib import Path
import sys

files_py = Path('/app/backend/open_webui/routers/files.py')
middleware_py = Path('/app/backend/open_webui/utils/middleware.py')

# Restore the upstream default: upload returns immediately, transcription
# continues in the background.
source = files_py.read_text()
if 'process_in_background: bool = Query(False)' in source:
    files_py.write_text(
        source.replace(
            'process_in_background: bool = Query(False)',
            'process_in_background: bool = Query(True)',
        )
    )
    print('openwebui-patch: uploads asynchronous again')

source = middleware_py.read_text()
changed = False

if 'from open_webui.models.files import Files' not in source:
    import_anchor = 'from open_webui.models.users import UserModel, Users\n'
    if import_anchor not in source:
        sys.exit('openwebui-patch: import anchor not found')
    source = source.replace(
        import_anchor,
        'from open_webui.models.files import Files\n' + import_anchor,
        1,
    )
    changed = True

# Remove the earlier version of the wait that lived in the file-context
# handler; the app does not use that handler at all.
old_start = '        # SymbiOS: wait for background transcription before the prompt is built.'
old_end = '        # Check if all files are in full context mode'
if old_start in source:
    start = source.index(old_start)
    end = source.find(old_end, start)
    if end == -1:
        sys.exit('openwebui-patch: old wait block end not found')
    source = source[:start] + source[end:]
    changed = True

new_marker = '# SymbiOS: wait for pending transcriptions'
if new_marker not in source:
    function_anchor = 'async def process_chat_payload(request, form_data, user, metadata, model):\n'
    if function_anchor not in source:
        sys.exit('openwebui-patch: chat function anchor not found')
    wait_block = """async def process_chat_payload(request, form_data, user, metadata, model):
    # SymbiOS: wait for pending transcriptions before the prompt is built.
    # Uploads return immediately, so the transcript is often still being
    # generated when the question arrives.
    attached_files = metadata.get('files') or []
    pending_file_ids = [
        item.get('id')
        for item in attached_files
        if item.get('type') == 'file' and item.get('id')
    ]
    wait_deadline = time.monotonic() + 600
    while pending_file_ids and time.monotonic() < wait_deadline:
        still_pending = []
        for file_id in pending_file_ids:
            file_record = await Files.get_file_by_id(file_id)
            status = (file_record.data or {}).get('status') if file_record else None
            if status in ('pending', 'processing'):
                still_pending.append(file_id)
        pending_file_ids = still_pending
        if not pending_file_ids:
            break
        await asyncio.sleep(2)

    # The client embedded the upload response, whose data was empty then.
    # Replace it with the completed record from the database.
    for file_item in attached_files:
        if file_item.get('type') != 'file' or not file_item.get('id'):
            continue
        file_record = await Files.get_file_by_id(file_item['id'])
        if file_record:
            file_item['file'] = {
                **(file_item.get('file') or {}),
                'data': dict(file_record.data or {}),
            }

"""
    source = source.replace(function_anchor, wait_block, 1)
    changed = True

if changed:
    middleware_py.write_text(source)
    print('openwebui-patch: chat waits for transcription')

# Chats must inherit the machine configured on the model. The web UI can lose
# the model default when its machine list loads late, and saved chats created
# before that default existed have no machine field at all. Applying it on the
# server keeps terminal tools available for both.
main_py = Path('/app/backend/open_webui/main.py')
main_source = main_py.read_text()
old_marker = '# SymbiOS: default new chats to the model machine'
machine_default_marker = '# SymbiOS: default chats to the model machine'
if old_marker in main_source:
    anchor = '    folder_defaults = {}\n'
    start = main_source.index(old_marker)
    end = main_source.find(anchor, start)
    if end == -1:
        sys.exit('openwebui-patch: old machine default block has no end')
    main_source = main_source[:start] + main_source[end:]
if machine_default_marker not in main_source:
    anchor = '    folder_defaults = {}\n'
    if anchor not in main_source:
        sys.exit('openwebui-patch: chat folder defaults anchor not found')
    block = """    # SymbiOS: default chats to the model machine
    # A chat that explicitly cleared its machine keeps that choice; a chat that
    # never had the field gets the model's default, however the client selected it.
    if ENABLE_TOOL_SERVERS and 'machine_id' not in form_data:
        chat_id = form_data.get('chat_id')
        apply_machine_default = not chat_id
        if chat_id:
            try:
                chat_item = await Chats.get_chat_by_id_and_user_id(chat_id, user.id)
                apply_machine_default = (
                    chat_item is not None and 'machine_id' not in (chat_item.chat or {})
                )
            except Exception:
                apply_machine_default = False
        if apply_machine_default:
            default_info = (request.app.state.MODELS.get(model_id) or {}).get('info') or {}
            default_meta = default_info.get('meta') or {}
            default_machine = default_meta.get('machineId') or default_meta.get('terminalId')
            if default_machine and await can_use_machine(user, default_machine, request):
                form_data['machine_id'] = default_machine

"""
    main_source = main_source.replace(anchor, block + anchor, 1)
    main_py.write_text(main_source)
    print('openwebui-patch: chats inherit the model machine')

# Clients that speak the newer terminal API call /api/v1/terminals/ while this
# Open WebUI release still mounts its machines at /api/v1/machines. Mounting the
# same router under both prefixes keeps those clients able to discover and use
# the configured terminal without a second connection.
compat_marker = '# SymbiOS: Conduit terminal API compatibility'
if compat_marker not in main_source:
    machine_route = "app.include_router(machines.router, prefix='/api/v1/machines', tags=['machines'])\n"
    if machine_route not in main_source:
        sys.exit('openwebui-patch: machines router mount not found')
    compat_route = (
        compat_marker + "\n"
        "app.include_router(\n"
        "    machines.router,\n"
        "    prefix='/api/v1/terminals',\n"
        "    tags=['terminals'],\n"
        "    include_in_schema=False,\n"
        ")\n"
    )
    main_source = main_source.replace(machine_route, machine_route + compat_route, 1)
    main_py.write_text(main_source)
    print('openwebui-patch: terminal API alias mounted')
PY
then
  echo "openwebui-patch: WARNING: patch failed, continuing unpatched" >&2
fi

exec bash /app/backend/start.sh
