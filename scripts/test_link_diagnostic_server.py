import asyncio
import json
import time
import unittest
from unittest.mock import patch
from link_diagnostic_server import Server, HEADER


class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.server = Server('a' * 64)
        self.udp, _ = await asyncio.get_running_loop().create_datagram_endpoint(
            lambda: self.server, local_addr=('127.0.0.1', 0))
        port = self.udp.get_extra_info('sockname')[1]
        self.tcp = await asyncio.start_server(self.server.control, '127.0.0.1', port, limit=4096)
        self.port = port

    async def asyncTearDown(self):
        self.tcp.close()
        await self.tcp.wait_closed()
        self.udp.close()

    async def connect(self, token='a' * 64, direction='upload'):
        r, w = await asyncio.open_connection('127.0.0.1', self.port)
        w.write(json.dumps(dict(token=token, direction=direction, rate=3)).encode() + b'\n')
        await w.drain()
        response = json.loads(await r.readline())
        return r, w, response

    async def test_auth(self):
        r, w, response = await self.connect(token='wrong')
        self.assertIn('error', response)
        self.assertIsNone(self.server.active)
        w.close()
        await w.wait_closed()

    async def test_upload_cookie_dedup_probe_and_busy(self):
        r, w, response = await self.connect()
        _, other, busy = await self.connect()
        self.assertIn('error', busy)
        other.close()
        await other.wait_closed()
        queue = asyncio.Queue()
        class Receiver(asyncio.DatagramProtocol):
            def datagram_received(self, data, addr):
                queue.put_nowait(data)
        udp, _ = await asyncio.get_running_loop().create_datagram_endpoint(
            Receiver, remote_addr=('127.0.0.1', self.port))
        cookie = bytes.fromhex(response['cookie'])
        probe = HEADER.pack(cookie, b'P', 0, time.monotonic())
        udp.sendto(probe)
        self.assertEqual(await asyncio.wait_for(queue.get(), 1), probe)
        bad = HEADER.pack(bytes(16), b'D', 1, time.monotonic()) + bytes(1168)
        udp.sendto(bad)
        packet = HEADER.pack(cookie, b'D', 2, time.monotonic()) + bytes(1168)
        udp.sendto(packet)
        udp.sendto(packet)
        await asyncio.sleep(.05)
        # A packet four seconds after the send window must be counted late,
        # not discarded by the old nine-second receive cutoff.
        late = HEADER.pack(cookie, b'D', 3, time.monotonic()) + bytes(1168)
        state = self.server.active
        with patch('link_diagnostic_server.time.monotonic', return_value=state['start'] + 12):
            self.server.datagram_received(late, state['addr'])
            self.server.datagram_received(late, state['addr'])
        w.write(b'{}\n')
        await w.drain()
        result = json.loads(await r.readline())
        self.assertEqual(result['received'], 2)
        self.assertEqual(result['bytes'], 2400)
        self.assertEqual(result['windowReceived'], 1)
        self.assertEqual(result['windowBytes'], 1200)
        udp.close()
        w.close()
        await w.wait_closed()
        await asyncio.sleep(.02)
        self.assertIsNone(self.server.active)

    async def test_download_stops_on_disconnect(self):
        r, w, response = await self.connect(direction='download')
        received = []
        class Receiver(asyncio.DatagramProtocol):
            def datagram_received(self, data, addr):
                received.append(data)
        udp, _ = await asyncio.get_running_loop().create_datagram_endpoint(
            Receiver, remote_addr=('127.0.0.1', self.port))
        udp.sendto(HEADER.pack(bytes.fromhex(response['cookie']), b'P', 0, time.monotonic()))
        await asyncio.sleep(.15)
        self.assertTrue(any(len(p) == 1200 for p in received))
        w.close()
        await w.wait_closed()
        await asyncio.sleep(.05)
        self.assertIsNone(self.server.active)
        count = len(received)
        await asyncio.sleep(.05)
        self.assertEqual(len(received), count)
        udp.close()


if __name__ == '__main__':
    unittest.main()
