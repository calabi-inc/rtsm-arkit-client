#!/usr/bin/env python3
"""
Calabi Lens - Receiver Server Stub

Minimal WebSocket server that accepts Calabi Lens connections, parses
length-prefixed binary messages, and prints frame metadata with periodic
throughput summaries.

Usage:
    python receiver_server_stub.py
    python receiver_server_stub.py --host 0.0.0.0 --port 8765 --path /stream

Requires:
    pip install websockets
"""

import argparse
import asyncio
import json
import struct
import sys
import time
from dataclasses import dataclass
from typing import Optional

try:
    import websockets
except ImportError:
    print("Missing dependency. Install with: pip install websockets", file=sys.stderr)
    sys.exit(1)


def parse_frame(data: bytes) -> dict:
    """Parse one binary message: [json_len][json][rgb_len][rgb][depth_len][depth]."""
    offset = 0

    json_len = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    header = json.loads(data[offset : offset + json_len])
    offset += json_len

    rgb_len = struct.unpack_from("<I", data, offset)[0]
    offset += 4 + rgb_len

    depth_len = struct.unpack_from("<I", data, offset)[0]

    header["_rgb_len"] = rgb_len
    header["_depth_len"] = depth_len
    return header


@dataclass
class Stats:
    frames: int = 0
    bytes_total: int = 0
    drop_count: int = 0
    last_report: float = 0.0
    last_rtt_ms: Optional[float] = None

    def __post_init__(self):
        self.last_report = time.monotonic()

    def record(self, nbytes: int, dropped: int = 0):
        self.frames += 1
        self.bytes_total += nbytes
        self.drop_count += dropped

    def report_if_due(self) -> Optional[str]:
        now = time.monotonic()
        elapsed = now - self.last_report
        if elapsed < 5.0:
            return None

        avg_kbps = (self.bytes_total / 1024.0) / elapsed if elapsed > 0 else 0.0
        msg = (
            f"[summary] {self.frames} frames in {elapsed:.1f}s | "
            f"avg {avg_kbps:.1f} KB/s | drops {self.drop_count}"
        )
        self.frames = 0
        self.bytes_total = 0
        self.drop_count = 0
        self.last_report = now
        return msg


def websocket_path(ws):
    """Best-effort path extraction across websockets versions."""
    # Older versions often expose ws.path directly.
    path = getattr(ws, "path", None)
    if isinstance(path, str) and path:
        return path

    # Newer versions may expose request.path.
    req = getattr(ws, "request", None)
    req_path = getattr(req, "path", None)
    if isinstance(req_path, str) and req_path:
        return req_path

    # Unknown API surface; return empty string as "not available".
    return ""


async def client_handler(ws, expected_path: str):
    client = f"{ws.remote_address[0]}:{ws.remote_address[1]}" if ws.remote_address else "unknown"
    request_path = websocket_path(ws)

    # Only enforce path when we can confidently read one.
    if request_path and request_path != expected_path:
        print(f"[reject] {client} path={request_path!r} (expected {expected_path!r})")
        await ws.close(code=1008, reason=f"Expected path {expected_path}")
        return
    if not request_path:
        print(f"[connected] {client} path=<unknown> (path check skipped)")
    else:
        print(f"[connected] {client} path={request_path}")
    stats = Stats()

    try:
        async for message in ws:
            if not isinstance(message, bytes):
                continue

            try:
                hdr = parse_frame(message)
            except Exception as exc:
                print(f"[error] parse failed from {client}: {exc}")
                continue

            dropped = int(hdr.get("dropped_frames", 0))
            stats.record(len(message), dropped=dropped)

            print(
                f"client={client}  "
                f"frame={hdr.get('frame_id'):>6}  "
                f"ts_ns={hdr.get('timestamp_ns')}  "
                f"tracking={hdr.get('tracking_state'):<14}  "
                f"rgb={hdr['_rgb_len']:>8} B  "
                f"depth={hdr['_depth_len']:>8} B"
            )

            summary = stats.report_if_due()
            if summary:
                print(f"{summary} | client={client}")

    except websockets.ConnectionClosed as exc:
        print(f"[disconnected] {client} code={exc.code} reason={exc.reason}")
    except Exception as exc:
        print(f"[error] client={client}: {exc}")
    finally:
        print(f"[closed] {client}")


async def run_server(host: str, port: int, path: str):
    print(f"[listening] ws://{host}:{port}{path}")
    async with websockets.serve(lambda ws: client_handler(ws, path), host, port):
        await asyncio.Future()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Calabi Lens receiver server stub")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8765, help="Port (default: 8765)")
    parser.add_argument("--path", default="/stream", help="Expected websocket path (default: /stream)")
    return parser


def main():
    args = build_parser().parse_args()
    try:
        asyncio.run(run_server(args.host, args.port, args.path))
    except KeyboardInterrupt:
        print("\nShutting down.")


if __name__ == "__main__":
    main()
