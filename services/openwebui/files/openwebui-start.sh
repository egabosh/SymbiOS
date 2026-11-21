#!/usr/bin/env bash
# OpenWebUI patches applied on every container start so image updates cannot
# silently undo them:
# 1. File uploads stay asynchronous. Waiting inside the upload endpoint makes
#    the mobile client hit its 60 s timeout (Traefik 499, DioException).
# 2. Every chat waits for pending transcriptions before the prompt is built,
#    so the model always sees the finished transcript. The wait has to live in
#    process_chat_payload: the app sends a session_id, which disables the
#    separate file-context handler.
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
PY
then
  echo "openwebui-patch: WARNING: patch failed, continuing unpatched" >&2
fi

exec bash /app/backend/start.sh
