#!/usr/bin/env python3
"""
Calabi Lens — Receiver Stub

Minimal WebSocket **client** that connects to the Calabi Lens stream,
parses length-prefix framed binary messages, measures RTT via ping/pong,
and prints frame metadata with periodic summaries.

Usage:
    python receiver_stub.py [ws://host:port/path]

Default address: ws://192.168.1.100:8765/stream

Requires: pip install websockets
"""

import asyncio
import json
import struct
import sys
import time
from typing import Optional

try:
    import websockets
except ImportError:
    print("Missing dependency. Install with:  pip install websockets", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Frame parsing
# ---------------------------------------------------------------------------

def parse_frame(data: bytes) -> dict:
    """Parse a single binary WebSocket message into header + blob sizes."""
    offset = 0

    # JSON header
    json_len = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    header = json.loads(data[offset : offset + json_len])
    offset += json_len

    # RGB blob
    rgb_len = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    offset += rgb_len  # skip RGB bytes

    # Depth blob
    depth_len = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    # offset += depth_len  # remaining bytes are depth (may be 0)

    header["_rgb_len"] = rgb_len
    header["_depth_len"] = depth_len
    return header

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

class Stats:
    def __init__(self):
        self.reset()

    def reset(self):
        self.frames = 0
        self.bytes_total = 0
        self.drop_count = 0
        self.last_rtt_ms: Optional[float] = None
        self.last_report = time.monotonic()

    def record(self, nbytes: int, dropped: int = 0):
        self.frames += 1
        self.bytes_total += nbytes
        self.drop_count += dropped

    def update_rtt(self, rtt_ms: float):
        self.last_rtt_ms = rtt_ms

    def report_if_due(self) -> Optional[str]:
        now = time.monotonic()
        elapsed = now - self.last_report
        if elapsed < 5.0:
            return None
        avg_kbps = (self.bytes_total / 1024) / elapsed if elapsed > 0 else 0
        rtt_str = f"{self.last_rtt_ms:.1f} ms" if self.last_rtt_ms is not None else "n/a"
        msg = (
            f"[summary] {self.frames} frames in {elapsed:.1f}s | "
            f"avg {avg_kbps:.1f} KB/s | "
            f"drops {self.drop_count} | "
            f"rtt {rtt_str}"
        )
        self.reset()
        return msg

# ---------------------------------------------------------------------------
# Ping / RTT measurement
# ---------------------------------------------------------------------------

async def ping_loop(ws, stats: Stats, interval: float = 2.0):
    """Send periodic pings and record RTT from pong latency."""
    while True:
        try:
            pong_waiter = await ws.ping()
            t0 = time.monotonic()
            await pong_waiter
            rtt_ms = (time.monotonic() - t0) * 1000
            stats.update_rtt(rtt_ms)
        except (websockets.ConnectionClosed, asyncio.CancelledError):
            break
        await asyncio.sleep(interval)

# ---------------------------------------------------------------------------
# Client loop
# ---------------------------------------------------------------------------

RECONNECT_BASE = 1.0   # seconds
RECONNECT_MAX  = 30.0  # cap

stats = Stats()

async def receive_loop(url: str):
    backoff = RECONNECT_BASE

    while True:
        print(f"[connecting] {url}")
        try:
            async with websockets.connect(url) as ws:
                print(f"[connected] {url}")
                backoff = RECONNECT_BASE  # reset on successful connect
                stats.reset()

                ping_task = asyncio.create_task(ping_loop(ws, stats))

                try:
                    async for message in ws:
                        if not isinstance(message, bytes):
                            continue
                        try:
                            hdr = parse_frame(message)
                        except Exception as e:
                            print(f"[error] Failed to parse frame: {e}")
                            continue

                        dropped = int(hdr.get("dropped_frames", 0))
                        stats.record(len(message), dropped=dropped)

                        print(
                            f"frame={hdr.get('frame_id'):>6}  "
                            f"ts_ns={hdr.get('timestamp_ns')}  "
                            f"tracking={hdr.get('tracking_state'):<14}  "
                            f"rgb={hdr['_rgb_len']:>8} B  "
                            f"depth={hdr['_depth_len']:>8} B"
                        )

                        summary = stats.report_if_due()
                        if summary:
                            print(summary)
                except websockets.ConnectionClosed:
                    pass
                finally:
                    ping_task.cancel()
                    try:
                        await ping_task
                    except asyncio.CancelledError:
                        pass

        except (OSError, websockets.WebSocketException) as e:
            print(f"[disconnected] {e}")

        print(f"[reconnecting] in {backoff:.1f}s …")
        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, RECONNECT_MAX)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

async def main(url: str):
    await receive_loop(url)

if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "ws://192.168.1.100:8765/stream"
    try:
        asyncio.run(main(url))
    except KeyboardInterrupt:
        print("\nShutting down.")
