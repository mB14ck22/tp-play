#!/usr/bin/env python3
"""Bounded authenticated UDP load test. Bind to a private VPN address, not WAN.
Wire header: 16-byte random cookie, kind (P probe/D data), 3 pad,
uint32 sequence, float64 sender monotonic timestamp, all network byte order.
TCP carries newline JSON control; UDP and TCP share a port.
"""
import argparse
import asyncio
import hmac
import json
import secrets
import struct
import time
from pathlib import Path

HEADER = struct.Struct('!16sc3xId')
SIZE = 1200
RATES = (3, 5, 7, 10, 15, 20)


class Measurement:
    def __init__(self):
        self.seen = set()
        self.bytes = 0
        self.jitter = 0.0
        self.last = None
        self.window_received = 0
        self.window_bytes = 0

    def add(self, seq, stamp, size, now, in_window=True):
        if seq in self.seen or len(self.seen) >= 30000:
            return
        self.seen.add(seq)
        self.bytes += size
        if in_window:
            self.window_received += 1
            self.window_bytes += size
        if self.last and seq > self.last[0]:
            delta = abs((now - self.last[2]) - (stamp - self.last[1]))
            self.jitter += (delta - self.jitter) / 16
        self.last = (seq, stamp, now)


class Server(asyncio.DatagramProtocol):
    def __init__(self, token):
        self.token = token
        self.active = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        s = self.active
        if not s or len(data) < HEADER.size or len(data) > SIZE:
            return
        cookie, kind, seq, stamp = HEADER.unpack_from(data)
        if not hmac.compare_digest(cookie, s['cookie']):
            return
        # Require the authenticated TCP peer's address, and pin the UDP port.
        if addr[0] != s['ip'] or (s['addr'] and addr != s['addr']):
            return
        now = time.monotonic()
        if not s['addr']:
            s['addr'] = addr
            s['start'] = now
        if kind == b'P':
            if now - s['last_probe'] >= .02:
                s['last_probe'] = now
                self.transport.sendto(data[:HEADER.size], addr)
        elif kind == b'D' and s['direction'] == 'upload' and now - s['start'] <= 18:
            s['measurement'].add(seq, stamp, len(data), now, now - s['start'] <= 8)

    async def send_load(self, s):
        while s['addr'] is None:
            await asyncio.sleep(.002)
        start = time.monotonic()
        # Pacing is based on elapsed time, with a 20ms burst cap; never catch up
        # an arbitrarily large backlog after server scheduling stalls.
        credit = 0.0
        previous = start
        while time.monotonic() - start < 8:
            now = time.monotonic()
            credit = min(credit + (now - previous) * s['rate'] * 1e6 / (8 * SIZE),
                         s['rate'] * 1e6 / (8 * SIZE) * .020)
            previous = now
            while credit >= 1:
                packet = HEADER.pack(s['cookie'], b'D', s['sent'], time.monotonic())
                self.transport.sendto(packet + bytes(SIZE - HEADER.size), s['addr'])
                s['sent'] += 1
                credit -= 1
            await asyncio.sleep(.002)

    async def control(self, reader, writer):
        state = None
        sender = None
        try:
            request = json.loads(await asyncio.wait_for(reader.readline(), 3))
            if not isinstance(request, dict):
                raise ValueError('Invalid request')
            if not hmac.compare_digest(str(request.get('token', '')).encode(), self.token.encode()):
                raise ValueError('Authentication failed')
            if self.active:
                raise ValueError('Another test is running')
            rate = request.get('rate')
            direction = request.get('direction')
            if rate not in RATES or direction not in ('upload', 'download'):
                raise ValueError('Unsupported test parameters')
            state = dict(cookie=secrets.token_bytes(16), ip=writer.get_extra_info('peername')[0],
                         addr=None, start=0, last_probe=0, rate=rate, direction=direction,
                         sent=0, measurement=Measurement())
            self.active = state
            writer.write(json.dumps({'cookie': state['cookie'].hex(), 'seconds': 8, 'version': 2, 'drainSeconds': 10}).encode() + b'\n')
            await writer.drain()
            if direction == 'download':
                sender = asyncio.create_task(self.send_load(state))
            finish = await asyncio.wait_for(reader.readline(), 30)
            if not finish:
                return
            if sender:
                sender.cancel()
                await asyncio.gather(sender, return_exceptions=True)
            m = state['measurement']
            writer.write(json.dumps(dict(sent=state['sent'], received=len(m.seen),
                                         bytes=m.bytes, windowReceived=m.window_received,
                                         windowBytes=m.window_bytes, jitterMs=m.jitter * 1000)).encode() + b'\n')
            await writer.drain()
        except (ValueError, asyncio.TimeoutError, ConnectionError):
            if not writer.is_closing():
                writer.write(b'{"error":"Unavailable, invalid request or authentication failed"}\n')
        finally:
            if sender:
                sender.cancel()
                await asyncio.gather(sender, return_exceptions=True)
            if self.active is state:
                self.active = None
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass


async def main(args):
    token = Path(args.token_file).read_text().strip()
    if len(token) < 32:
        raise ValueError('Use a random token of at least 32 characters')
    server = Server(token)
    loop = asyncio.get_running_loop()
    udp, _ = await loop.create_datagram_endpoint(lambda: server, local_addr=(args.bind, args.port))
    tcp = await asyncio.start_server(server.control, args.bind, args.port, limit=4096)
    print(f'Link diagnostic ready on {args.bind}:{args.port}', flush=True)
    try:
        async with tcp:
            await tcp.serve_forever()
    finally:
        udp.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bind', required=True)
    parser.add_argument('--port', type=int, default=39876)
    parser.add_argument('--token-file', required=True)
    asyncio.run(main(parser.parse_args()))
