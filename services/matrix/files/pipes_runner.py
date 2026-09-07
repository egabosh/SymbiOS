#!/usr/bin/env python3
# pipes_runner.py - single-process replacement for the per-room
# matrix-commander "-m _" pipes.
#
# One async process hosts one matrix-nio AsyncClient per room. Every room
# keeps its existing credential/device/store directory, so device identities
# and olm history are preserved. The runner:
#   - syncs continuously with full_state (complete member list)
#   - reads each room FIFO (tail -F semantics) and sends lines as HTML text
#   - shares the megolm key with all joined members at send time
#   - answers inbound key requests from members
#   - optionally forwards stored historical session keys to all members once
#     at startup (guarded by a marker file per room)
#
# Config file: JSON list under key "rooms":
#   {
#     "rooms": [
#       {
#         "name": "Share",
#         "alias": "#Share:matrix.defiant.dedyn.io",
#         "data": "/data/Share",                  # dir with credentials.json + store/
#         "fifo": "/fifos/matrix-room-Share.fifo",# container path of the fifo
#         "forward_history": true
#       }
#     ]
#   }

import argparse
import asyncio
import json
import logging
import os
import sys
import traceback

from nio import (
    AsyncClient,
    RoomKeyRequest,
    RoomResolveAliasResponse,
    ToDeviceMessage,
)

log = logging.getLogger("pipes-runner")

HTML_CONTENT = {
    "format": "org.matrix.custom.html",
}


class RoomPipe:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.name = cfg["name"]
        self.alias = cfg.get("alias", "")
        self.data_dir = cfg["data"]
        self.fifo_path = cfg["fifo"]
        self.history_forward = bool(cfg.get("forward_history", False))

        self.store_path = os.path.join(self.data_dir, "store")
        self.creds_path = os.path.join(self.data_dir, "credentials.json")
        self.creds = json.load(open(self.creds_path))
        self.room_id = None
        self.client = None
        self.fifo_fd = None
        self.fifo_buffer = ""
        self.fifo_reopen_delay = 0.5

    def log(self, msg, *args, **kwargs):
        log.info("[%s] " + msg, self.name, *args, **kwargs)

    def logw(self, msg, *args, **kwargs):
        log.warning("[%s] " + msg, self.name, *args, **kwargs)

    async def setup(self):
        client = AsyncClient(
            self.creds["homeserver"],
            user=self.creds["user_id"],
            device_id=self.creds["device_id"],
            store_path=self.store_path,
        )
        client.access_token = self.creds["access_token"]
        client.user_id = self.creds["user_id"]
        client.load_store()
        self.client = client

        if self.alias:
            self.room_id = await self.resolve_alias()
        if not self.room_id:
            self.room_id = self.creds.get("room_id") or None
        if not self.room_id:
            self.logw("no room id resolvable, will retry later")
        self.log("using room id %s", self.room_id)

        asyncio.ensure_future(self.run_sync())

    async def run_sync(self):
        import traceback as _tb
        while True:
            try:
                self.log("starting sync")
                await self.client.sync_forever(timeout=30000, full_state=True)
            except Exception as exc:
                self.logw(
                    "sync crashed: %r\n%s",
                    exc,
                    "".join(_tb.format_exception(type(exc), exc, exc.__traceback__)),
                )
            self.client.synced = False
            await asyncio.sleep(5)

    async def resolve_alias(self):
        try:
            resp = await self.client.room_resolve_alias(self.alias)
        except Exception as exc:
            self.logw("alias resolve failed: %r", exc)
            return None
        if isinstance(resp, RoomResolveAliasResponse):
            if resp.room_alias:
                self.alias = resp.room_alias
            return resp.room_id
        self.logw("alias resolve error for %s: %r", self.alias, resp)
        return None

    async def wait_room_forever(self):
        while True:
            if self.room_id and self.room_id in self.client.rooms:
                room = self.client.rooms[self.room_id]
                self.log(
                    "room %s encrypted=%s members=%s",
                    self.room_id, room.encrypted, sorted(room.users.keys()),
                )
                return True
            await asyncio.sleep(5)

    def build_room_key_content(self, group_session):
        return {
            "algorithm": "m.megolm.v1.aes-sha2",
            "room_id": group_session.room_id,
            "session_id": group_session.id,
            "session_key": group_session.export_session(
                group_session.first_known_index
            ),
        }

    def answer_one(self, request) -> bool:
        machine = self.client.olm
        group_session = machine.inbound_group_store.get(
            request.room_id, request.sender_key, request.session_id
        )
        if not group_session:
            self.logw(
                "key request for unknown session %s (room %s)",
                request.session_id, request.room_id,
            )
            return False
        try:
            device = machine.device_store[request.sender][request.requesting_device_id]
        except KeyError:
            self.logw(
                "key request from unknown device %s of %s",
                request.requesting_device_id, request.sender,
            )
            return False
        session = machine.session_store.get(device.curve25519)
        if not session:
            self.logw(
                "no olm session for %s / %s, request stays queued",
                request.sender, request.requesting_device_id,
            )
            return False
        olm_dict = machine._olm_encrypt(
            session, device, "m.room_key",
            self.build_room_key_content(group_session),
        )
        machine.outgoing_to_device_messages.append(
            ToDeviceMessage(
                "m.room.encrypted", device.user_id, device.device_id, olm_dict
            )
        )
        self.log(
            "answered key request for session %s -> %s / %s",
            request.session_id, request.sender, request.requesting_device_id,
        )
        return True

    async def sweep_key_requests(self):
        machine = self.client.olm
        handled = set()
        requests = list(machine.received_key_requests.values())
        for event in machine.key_request_from_untrusted.values():
            if event.request_id not in machine.received_key_requests:
                requests.append(event)
        for event in requests:
            if isinstance(event, RoomKeyRequest) and event.sender != self.client.user_id:
                if self.answer_one(event):
                    handled.add(event.request_id)
        for rid in handled:
            machine.received_key_requests.pop(rid, None)
            machine.key_request_from_untrusted.pop(rid, None)

    async def forward_history(self):
        if not self.history_forward or not self.room_id:
            return
        marker = os.path.join(self.store_path, "history_forwarded")
        if os.path.exists(marker):
            self.log("history already forwarded, skipping")
            return
        machine = self.client.olm
        account = getattr(machine, "account", None)
        if account is not None:
            own_curve = account.identity_keys["curve25519"]
        else:
            own_device = machine.device_store[self.client.user_id]
            own_curve = own_device[self.client.device_id].curve25519
        members = self.client.rooms[self.room_id].users
        sessions = [
            s for s in machine.inbound_group_store
            if s.room_id == self.room_id and s.sender_key == own_curve
        ]
        self.log(
            "forwarding %d stored sessions of %s to %d members",
            len(sessions), self.room_id, len(members),
        )
        sent = 0
        for user_id in members:
            try:
                devices = machine.device_store[user_id]
            except KeyError:
                continue
            for device in devices.values():
                if device.id == machine.device_id:
                    continue
                session_for_olm = machine.session_store.get(device.curve25519)
                if not session_for_olm:
                    continue
                for group_session in sessions:
                    olm_dict = machine._olm_encrypt(
                        session_for_olm, device, "m.room_key",
                        self.build_room_key_content(group_session),
                    )
                    machine.outgoing_to_device_messages.append(
                        ToDeviceMessage(
                            "m.room.encrypted", device.user_id,
                            device.device_id, olm_dict,
                        )
                    )
                    sent += 1
        try:
            with open(marker, "w") as fp:
                fp.write(self.room_id + "\n")
        except OSError as exc:
            self.logw("could not write history marker: %r", exc)
        self.log("queued %d historical room-key messages", sent)

    # fifo handling with tail -F semantics
    def _open_fifo(self):
        try:
            fd = os.open(self.fifo_path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            self.logw("cannot open fifo %s: %r", self.fifo_path, exc)
            return None
        return fd

    async def fifo_loop(self, msg_queue):
        loop = asyncio.get_event_loop()
        while True:
            if self.fifo_fd is None:
                self.fifo_fd = self._open_fifo()
                self.fifo_reopen_delay = 0.5
            if self.fifo_fd is not None:
                loop.add_reader(self.fifo_fd, self._on_fifo_read, msg_queue)
            await asyncio.sleep(0.3)
            # if reader callback closed the fd, reopen after backoff
            if self.fifo_fd is None:
                self.logw("fifo closed, reopening in %.1fs", self.fifo_reopen_delay)
                await asyncio.sleep(self.fifo_reopen_delay)
                self.fifo_reopen_delay = min(self.fifo_reopen_delay * 2, 5.0)

    def _on_fifo_read(self, msg_queue):
        if self.fifo_fd is None:
            return
        try:
            data = os.read(self.fifo_fd, 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if data == b"":
            loop = asyncio.get_event_loop()
            loop.remove_reader(self.fifo_fd)
            os.close(self.fifo_fd)
            self.fifo_fd = None
            return
        self.fifo_reopen_delay = 0.5
        self.fifo_buffer += data.decode("utf-8", errors="replace")
        while "\n" in self.fifo_buffer:
            line, self.fifo_buffer = self.fifo_buffer.split("\n", 1)
            if line.strip():
                msg_queue.put_nowait(line.rstrip())

    def keys_needed_by_any_device(self):
        # True if any active member device is not yet marked as having received
        # the current outbound room key. Lets us avoid rotating the session on
        # every send (which would flood sessions) while still covering newly
        # added or previously-missed devices (e.g. remote users like Marco).
        machine = self.client.olm
        gs = machine.outbound_group_sessions.get(self.room_id)
        if gs is None:
            return True
        have = getattr(gs, "users_shared_with", set())
        ignored = getattr(gs, "users_ignored", set())
        own = (self.client.user_id, self.client.device_id)
        for user_id in self.client.rooms[self.room_id].users:
            try:
                devices = machine.device_store.active_user_devices(user_id)
            except Exception:
                continue
            for device in devices:
                if device.id == self.client.device_id:
                    continue
                pair = (user_id, device.id)
                if pair in have or pair in ignored:
                    continue
                # Device has an olm session but has not received this room key.
                if machine.session_store.get(device.curve25519):
                    return True
        return False

    async def share_keys_now(self):
        # Share the fresh megolm session key with every active member device.
        # share_group_session_parallel rotates the outbound session for the
        # room when it is already marked as shared, so the following room_send
        # encrypts with a session that every member just received.
        machine = self.client.olm
        users = list(self.client.rooms[self.room_id].users)
        sent = 0
        per_user = {}
        try:
            for sharing_with, to_device_dict in machine.share_group_session_parallel(
                self.room_id, users, ignore_unverified_devices=True,
            ):
                messages = to_device_dict.get("messages", {})
                for user_id, device_map in messages.items():
                    per_user.setdefault(user_id, 0)
                    for device_id, olm_dict in device_map.items():
                        machine.outgoing_to_device_messages.append(
                            ToDeviceMessage(
                                "m.room.encrypted", user_id, device_id, olm_dict,
                            )
                        )
                        per_user[user_id] += 1
                        sent += 1
        except Exception as exc:
            self.logw("forced key share failed: %r", exc)
            return
        breakdown = ", ".join(
            "%s:%d" % (u, n) for u, n in sorted(per_user.items())
        )
        if sent:
            try:
                await self.client.send_to_device_messages()
            except Exception as exc:
                self.logw("sending shared keys failed: %r", exc)
            self.log("shared fresh room key with %d member devices of %s [%s]",
                     sent, self.room_id, breakdown)

    async def sender_loop(self, msg_queue):
        while True:
            body = await msg_queue.get()
            if not body.strip():
                continue
            if not self.room_id or self.room_id not in self.client.rooms:
                self.logw("cannot send, room not available yet - requeueing")
                await msg_queue.put(body)
                await asyncio.sleep(3)
                continue
            # Share a fresh megolm session key with all members so that remote
            # and newly added devices (e.g. Marco) can decrypt, then send.
            await self.share_keys_now()
            content = {
                "msgtype": "m.text",
                "body": body,
                "format": HTML_CONTENT["format"],
                "formatted_body": body,
            }
            try:
                resp = await self.client.room_send(
                    self.room_id, "m.room.message", content,
                    ignore_unverified_devices=True,
                )
                self.log(
                    "sent to %s: %s -> %s", self.room_id, body[:48],
                    getattr(resp, "event_id", repr(resp)[:80]),
                )
            except Exception as exc:
                self.logw(
                    "send failed: %r\n%s",
                    exc,
                    "".join(
                        traceback.format_exception(
                            type(exc), exc, exc.__traceback__
                        )
                    ),
                )
                await asyncio.sleep(2)

    async def responder_loop(self):
        while True:
            try:
                await self.sweep_key_requests()
            except Exception as exc:
                self.logw("key request sweep failed: %r", exc)
            await asyncio.sleep(3)

    async def run(self):
        await self.setup()
        await asyncio.sleep(2)
        await self.wait_room_forever()
        await self.forward_history()
        msg_queue = asyncio.Queue()
        await asyncio.gather(
            self.fifo_loop(msg_queue),
            self.sender_loop(msg_queue),
            self.responder_loop(),
            return_exceptions=True,
        )


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("config", help="path to pipes.json")
    args = parser.parse_args()

    cfg = json.load(open(args.config))
    pipes = [RoomPipe(room) for room in cfg["rooms"]]
    log.info("starting %d room pipes", len(pipes))
    results = await asyncio.gather(
        *(p.run() for p in pipes), return_exceptions=True
    )
    for pipe, res in zip(pipes, results):
        if isinstance(res, BaseException):
            log.error(
                "[%s] pipe ended with exception: %r\n%s",
                pipe.name, res,
                "".join(
                    traceback.format_exception(
                        type(res), res, res.__traceback__
                    )
                ),
            )


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s,%(msecs)03d: %(levelname)-8s: %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    sys.exit(asyncio.run(main()))