#!/usr/bin/env python3
"""Minecraft の wake proxy。

常時稼働の小さな VM (既定では無料枠の e2-micro) で 25565 番を待ち受け、
Minecraft 本体の VM が止まっている間だけ肩代わりする。

- 本体が起きている: そのまま TCP をリレーする (透過プロキシ)
- 本体が止まっている:
    - サーバー一覧のステータス ping には「停止中」の MOTD を返す
    - 参加 (ログイン) しようとしたクライアントを合図に Compute Engine API で
      本体 VM を起動し、案内メッセージを出して切断する

これにより、本体 VM がアイドル自動停止しても、プレイヤーは「一度参加を押す →
1〜2 分待って再接続」だけでサーバーを起こせる。接続先アドレスはこの VM の
外部 IP で固定されるため、本体 VM の外部 IP が起動のたびに変わっても影響しない。

設定はすべて環境変数で受け取る (systemd ユニット側で与える)。
プロトコル仕様: https://minecraft.wiki/w/Java_Edition_protocol
"""

from __future__ import annotations

import json
import logging
import os
import socket
import threading
import time
import urllib.error
import urllib.request

LOG = logging.getLogger("wake-proxy")

LISTEN_HOST = os.environ.get("WAKE_PROXY_LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("WAKE_PROXY_LISTEN_PORT", "25565"))
BACKEND_HOST = os.environ["WAKE_PROXY_BACKEND_HOST"]
BACKEND_PORT = int(os.environ.get("WAKE_PROXY_BACKEND_PORT", "25565"))
PROJECT_ID = os.environ["WAKE_PROXY_PROJECT_ID"]
ZONE = os.environ["WAKE_PROXY_ZONE"]
INSTANCE = os.environ["WAKE_PROXY_INSTANCE"]

# バックエンドへの接続タイムアウト。停止中の VM 宛ては応答がないのでここで待たされる。
BACKEND_TIMEOUT = float(os.environ.get("WAKE_PROXY_BACKEND_TIMEOUT", "2"))
# 直近の接続失敗を覚えておく秒数。サーバー一覧の連打で毎回待たされないようにする。
BACKEND_DOWN_TTL = float(os.environ.get("WAKE_PROXY_BACKEND_DOWN_TTL", "3"))
# インスタンス状態 (RUNNING/TERMINATED) のキャッシュ秒数。
INSTANCE_STATUS_TTL = float(os.environ.get("WAKE_PROXY_INSTANCE_STATUS_TTL", "15"))
# 起動要求を出してから次の起動要求を受け付けるまでの秒数。
START_COOLDOWN = float(os.environ.get("WAKE_PROXY_START_COOLDOWN", "120"))
# ハンドシェイクを読み終えるまでのタイムアウト。
HANDSHAKE_TIMEOUT = float(os.environ.get("WAKE_PROXY_HANDSHAKE_TIMEOUT", "10"))
MAX_CONNECTIONS = int(os.environ.get("WAKE_PROXY_MAX_CONNECTIONS", "64"))
MAX_PLAYERS = int(os.environ.get("WAKE_PROXY_MAX_PLAYERS", "20"))

# MOTD とキックメッセージ。§ は Minecraft の色コード。
MOTD_SLEEPING = os.environ.get(
    "WAKE_PROXY_MOTD_SLEEPING",
    "§7§oサーバーは停止中です\n"
    "§a参加を押すと起動します",
)
MOTD_STARTING = os.environ.get(
    "WAKE_PROXY_MOTD_STARTING",
    "§eサーバーを起動しています...\n"
    "§7しばらく待ってから再読み込みしてください",
)
KICK_MESSAGE = os.environ.get(
    "WAKE_PROXY_KICK_MESSAGE",
    "サーバーを起動しています。\n\n"
    "Mod の読み込みに 1〜2 分かかります。\n"
    "少し待ってからもう一度参加してください。",
)

COMPUTE_API_BASE = "https://compute.googleapis.com/compute/v1"
METADATA_TOKEN_URL = (
    "http://metadata.google.internal/computeMetadata/v1"
    "/instance/service-accounts/default/token"
)
# 起動中とみなすインスタンス状態。
LIVE_STATUSES = frozenset({"PROVISIONING", "STAGING", "RUNNING"})


class ProtocolError(Exception):
    """Minecraft のパケットとして解釈できなかった。"""


# --- パケットの読み書き ----------------------------------------------------


def encode_varint(value: int) -> bytes:
    out = bytearray()
    while True:
        chunk = value & 0x7F
        value >>= 7
        if value:
            out.append(chunk | 0x80)
        else:
            out.append(chunk)
            return bytes(out)


def encode_string(value: str) -> bytes:
    raw = value.encode("utf-8")
    return encode_varint(len(raw)) + raw


def send_packet(sock: socket.socket, packet_id: int, payload: bytes) -> None:
    body = encode_varint(packet_id) + payload
    sock.sendall(encode_varint(len(body)) + body)


class SocketReader:
    """読んだバイト列を控えておくソケット読み取り器。

    バックエンドへリレーするときに、読み終えたハンドシェイクをそのまま流し直す。
    """

    def __init__(self, sock: socket.socket) -> None:
        self._sock = sock
        self.consumed = bytearray()

    def read_exactly(self, count: int) -> bytes:
        chunks = []
        remaining = count
        while remaining > 0:
            chunk = self._sock.recv(remaining)
            if not chunk:
                raise ProtocolError("read 中に接続が閉じられた")
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        self.consumed += data
        return data

    def read_varint(self) -> int:
        value = 0
        for offset in range(5):
            byte = self.read_exactly(1)[0]
            value |= (byte & 0x7F) << (7 * offset)
            if not byte & 0x80:
                return value
        raise ProtocolError("VarInt が長すぎる")

    def read_packet(self) -> bytes:
        """1 パケット読み、パケット ID を含む本体を返す。"""
        length = self.read_varint()
        if not 0 < length <= 2097151:
            raise ProtocolError(f"想定外のパケット長: {length}")
        return self.read_exactly(length)


class BytesCursor:
    def __init__(self, data: bytes) -> None:
        self._data = data
        self._pos = 0

    def read(self, count: int) -> bytes:
        if self._pos + count > len(self._data):
            raise ProtocolError("パケットが途中で切れている")
        chunk = self._data[self._pos : self._pos + count]
        self._pos += count
        return chunk

    def varint(self) -> int:
        value = 0
        for offset in range(5):
            byte = self.read(1)[0]
            value |= (byte & 0x7F) << (7 * offset)
            if not byte & 0x80:
                return value
        raise ProtocolError("VarInt が長すぎる")

    def string(self) -> str:
        return self.read(self.varint()).decode("utf-8", "replace")


def read_handshake(reader: SocketReader) -> tuple[int, int]:
    """Handshake パケットを読み、(プロトコル版, next_state) を返す。"""
    cursor = BytesCursor(reader.read_packet())
    packet_id = cursor.varint()
    if packet_id != 0x00:
        raise ProtocolError(f"Handshake ではないパケット ID: {packet_id}")
    protocol = cursor.varint()
    cursor.string()  # 接続先として使われたホスト名。ここでは見ない。
    cursor.read(2)  # ポート
    return protocol, cursor.varint()


# --- バックエンド ----------------------------------------------------------


_backend_lock = threading.Lock()
_backend_down_until = 0.0


def connect_backend() -> socket.socket | None:
    """本体 VM の Minecraft に繋ぐ。落ちていれば None。"""
    global _backend_down_until

    with _backend_lock:
        if time.monotonic() < _backend_down_until:
            return None
    try:
        return socket.create_connection((BACKEND_HOST, BACKEND_PORT), BACKEND_TIMEOUT)
    except OSError:
        with _backend_lock:
            _backend_down_until = time.monotonic() + BACKEND_DOWN_TTL
        return None


# --- Compute Engine API ----------------------------------------------------


_token_lock = threading.Lock()
_token_value: str | None = None
_token_expires_at = 0.0


def access_token() -> str:
    """メタデータサーバーから VM のサービスアカウントのトークンを得る。"""
    global _token_value, _token_expires_at

    with _token_lock:
        if _token_value and time.monotonic() < _token_expires_at:
            return _token_value

    request = urllib.request.Request(
        METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.load(response)

    with _token_lock:
        _token_value = payload["access_token"]
        # 期限ぎりぎりで使わないよう 60 秒の余裕を持たせる。
        _token_expires_at = time.monotonic() + max(60.0, float(payload.get("expires_in", 3600)) - 60.0)
        return _token_value


def compute_api(path: str = "", method: str = "GET") -> dict:
    url = (
        f"{COMPUTE_API_BASE}/projects/{PROJECT_ID}/zones/{ZONE}"
        f"/instances/{INSTANCE}{path}"
    )
    request = urllib.request.Request(
        url, method=method, headers={"Authorization": f"Bearer {access_token()}"}
    )
    if method == "POST":
        request.data = b""
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


_status_lock = threading.Lock()
_status_value: str | None = None
_status_fetched_at = 0.0


def instance_status(max_age: float = INSTANCE_STATUS_TTL) -> str | None:
    """本体 VM の状態 (RUNNING / TERMINATED など)。取得できなければ None。"""
    global _status_value, _status_fetched_at

    with _status_lock:
        if _status_value and time.monotonic() - _status_fetched_at < max_age:
            return _status_value

    try:
        status = compute_api().get("status")
    except (urllib.error.URLError, OSError, ValueError, KeyError) as exc:
        LOG.warning("インスタンス状態の取得に失敗: %s", exc)
        return None

    with _status_lock:
        _status_value = status
        _status_fetched_at = time.monotonic()
    return status


_start_lock = threading.Lock()
_last_start_at = 0.0


def request_start(trigger: str) -> None:
    """本体 VM を起動する。多重起動はクールダウンと状態確認で抑える。"""
    global _last_start_at

    with _start_lock:
        now = time.monotonic()
        if now - _last_start_at < START_COOLDOWN:
            LOG.info("起動要求はクールダウン中のため無視 (%s)", trigger)
            return

        status = instance_status(max_age=0.0)
        if status in LIVE_STATUSES:
            LOG.info("インスタンスは既に %s なので起動不要 (%s)", status, trigger)
            _last_start_at = now
            return

        try:
            compute_api("/start", method="POST")
        except (urllib.error.URLError, OSError, ValueError) as exc:
            LOG.error("インスタンス %s の起動に失敗: %s", INSTANCE, exc)
            return

        _last_start_at = now
        LOG.info("インスタンス %s の起動を要求した (%s)", INSTANCE, trigger)


# --- クライアントの相手 ----------------------------------------------------


def serve_status(conn: socket.socket, reader: SocketReader, protocol: int, starting: bool) -> None:
    """サーバー一覧向けに「停止中」「起動中」のステータスを返す。

    protocol はクライアントが名乗ったものをそのまま返す。こうするとクライアントは
    バージョン不一致 (赤い×) ではなく通常表示になり、MOTD が読める。
    """
    reader.read_packet()  # Status Request (中身は空)

    payload = {
        "version": {
            "name": "起動中" if starting else "停止中",
            "protocol": protocol,
        },
        "players": {"max": MAX_PLAYERS, "online": 0, "sample": []},
        "description": {"text": MOTD_STARTING if starting else MOTD_SLEEPING},
    }
    send_packet(conn, 0x00, encode_string(json.dumps(payload, ensure_ascii=False)))

    # Ping Request が来たら Pong を返す (来ないまま切られることもある)。
    try:
        body = reader.read_packet()
    except (ProtocolError, OSError):
        return
    if body and body[0] == 0x01:
        send_packet(conn, 0x01, body[1:])


def kick_with_message(conn: socket.socket, reader: SocketReader) -> None:
    """ログイン中のクライアントを案内メッセージ付きで切断する。"""
    try:
        reader.read_packet()  # Login Start。中身は使わない。
    except (ProtocolError, OSError):
        pass
    # login 状態の Disconnect は 0x00 / JSON テキストコンポーネント。
    send_packet(conn, 0x00, encode_string(json.dumps({"text": KICK_MESSAGE}, ensure_ascii=False)))


def relay(client: socket.socket, backend: socket.socket, prefix: bytes) -> None:
    """読み終えた分を流し直してから、双方向にそのまま中継する。"""
    client.settimeout(None)
    backend.settimeout(None)
    if prefix:
        backend.sendall(prefix)

    def pump(src: socket.socket, dst: socket.socket) -> None:
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            for sock in (src, dst):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    upstream = threading.Thread(target=pump, args=(client, backend), daemon=True)
    upstream.start()
    pump(backend, client)
    upstream.join(timeout=5)


def handle_client(conn: socket.socket, addr: tuple[str, int]) -> None:
    conn.settimeout(HANDSHAKE_TIMEOUT)
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    reader = SocketReader(conn)

    protocol, next_state = read_handshake(reader)

    backend = connect_backend()
    if backend is not None:
        try:
            relay(conn, backend, bytes(reader.consumed))
        finally:
            try:
                backend.close()
            except OSError:
                pass
        return

    starting = instance_status() in LIVE_STATUSES
    if next_state == 1:
        serve_status(conn, reader, protocol, starting)
        return

    # next_state 2 = login, 3 = transfer。どちらも「参加しようとした」合図。
    threading.Thread(
        target=request_start,
        args=(f"{addr[0]} からの参加要求",),
        daemon=True,
    ).start()
    kick_with_message(conn, reader)


def _run_handler(slots: threading.BoundedSemaphore, conn: socket.socket, addr: tuple[str, int]) -> None:
    try:
        handle_client(conn, addr)
    except (ProtocolError, OSError) as exc:
        LOG.debug("%s との接続を終了: %s", addr[0], exc)
    except Exception:  # noqa: BLE001 - 1 接続の失敗でプロキシ全体を落とさない
        LOG.exception("%s の処理中に予期しないエラー", addr[0])
    finally:
        try:
            conn.close()
        except OSError:
            pass
        slots.release()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("WAKE_PROXY_LOG_LEVEL", "INFO").upper(),
        format="%(asctime)s %(levelname)s %(message)s",
    )

    slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(128)

    LOG.info(
        "wake proxy を開始: %s:%d -> %s:%d (対象 %s/%s)",
        LISTEN_HOST,
        LISTEN_PORT,
        BACKEND_HOST,
        BACKEND_PORT,
        ZONE,
        INSTANCE,
    )

    while True:
        conn, addr = server.accept()
        if not slots.acquire(blocking=False):
            LOG.warning("同時接続数の上限 (%d) に達したため %s を切断", MAX_CONNECTIONS, addr[0])
            conn.close()
            continue
        threading.Thread(target=_run_handler, args=(slots, conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
