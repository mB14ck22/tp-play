"""Bounded iOS packet-header counters for diagnostic UDP and WireGuard only."""
import asyncio
import collections
import json
import time
import socket
import struct
import hashlib
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.pcapd import PcapdService


async def main():
    device = await create_using_usbmux(serial='00008120-0018718E1EF0201E', autopair=False)
    counts = collections.Counter()
    seen = set()
    duplicates = 0
    start = time.monotonic()
    async with PcapdService(device) as service:
        print('PHONE OBSERVER READY', flush=True)
        async def capture():
            nonlocal duplicates
            async for packet in service.watch():
                frame = packet.data[14:]
                if not frame:
                    continue
                if frame[0] >> 4 == 4 and len(frame) >= 28 and frame[9] == 17:
                    offset = (frame[0] & 15) * 4
                    src = socket.inet_ntop(socket.AF_INET, frame[12:16])
                    dst = socket.inet_ntop(socket.AF_INET, frame[16:20])
                elif frame[0] >> 4 == 6 and len(frame) >= 48 and frame[6] == 17:
                    offset = 40
                    src = socket.inet_ntop(socket.AF_INET6, frame[8:24])
                    dst = socket.inet_ntop(socket.AF_INET6, frame[24:40])
                else:
                    continue
                if len(frame) < offset + 8:
                    continue
                sport, dport, length = struct.unpack_from('!HHH', frame, offset)
                if not ({sport, dport} & {39876, 41641}):
                    continue
                identity = (packet.interface_name, src, dst, hashlib.blake2s(frame[offset:], digest_size=16).digest())
                if identity in seen:
                    duplicates += 1
                    continue
                seen.add(identity)
                counts[(packet.interface_name, src, dst, length)] += 1
        async def report():
            while True:
                await asyncio.sleep(1)
                print(json.dumps({'elapsed': round(time.monotonic() - start, 2),
                                  'packets': [{'key': k, 'count': v} for k, v in counts.items()]}), flush=True)
                counts.clear()
        tasks = [asyncio.create_task(capture()), asyncio.create_task(report())]
        try:
            done, _ = await asyncio.wait(tasks, timeout=180, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    await device.close()


asyncio.run(main())
