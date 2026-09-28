"""Read-only Linux AF_PACKET counters; no payloads or credentials saved."""
import collections
import json
import select
import socket
import struct
import time

sockets = {}
for interface in ('tailscale0', 'eth0'):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
    s.bind((interface, 0))
    s.setblocking(False)
    sockets[s] = interface
counts = collections.Counter()
start = time.monotonic()
last = start
print('OBSERVER READY', flush=True)
try:
    while time.monotonic() - start < 180:
        ready, _, _ = select.select(list(sockets), [], [], .25)
        for s in ready:
            packet, address = s.recvfrom(256)
            interface = sockets[s]
            if interface == 'eth0':
                if len(packet) < 14:
                    continue
                packet = packet[14:]
            if not packet:
                continue
            version = packet[0] >> 4
            if version == 4 and len(packet) >= 28 and packet[9] == 17:
                offset = (packet[0] & 15) * 4
                src = socket.inet_ntop(socket.AF_INET, packet[12:16])
                dst = socket.inet_ntop(socket.AF_INET, packet[16:20])
            elif version == 6 and len(packet) >= 48 and packet[6] == 17:
                offset = 40
                src = socket.inet_ntop(socket.AF_INET6, packet[8:24])
                dst = socket.inet_ntop(socket.AF_INET6, packet[24:40])
            else:
                continue
            if len(packet) < offset + 8:
                continue
            sport, dport, length = struct.unpack_from('!HHH', packet, offset)
            if interface == 'tailscale0':
                if 39876 not in (sport, dport) or '100.73.7.74' not in (src, dst):
                    continue
            elif 41641 not in (sport, dport):
                continue
            # Length separates load datagrams from probes and keepalives.
            key = (interface, src, dst, length, address[2])
            counts[key] += 1
        now = time.monotonic()
        if now - last >= 1:
            print(json.dumps({'elapsed': round(now - start, 2),
                              'packets': [{'key': k, 'count': v} for k, v in counts.items()]}), flush=True)
            counts.clear()
            last = now
finally:
    for s in sockets:
        s.close()
