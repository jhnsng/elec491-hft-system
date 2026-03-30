"""Tests for UDP forwarder shutdown behavior."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

import data_forwarder
from data_forwarder import ByteBufferQueue, UDPForwarder, UDPSettings


class _FakeSocket:
    def __init__(self) -> None:
        self.sent_packets = []
        self.closed = False

    def sendto(self, packet: bytes, addr):
        self.sent_packets.append((packet, addr))

    def close(self) -> None:
        self.closed = True


def test_stop_drain_sends_all_queued_messages(monkeypatch):
    fake_socket = _FakeSocket()
    monkeypatch.setattr(data_forwarder.socket, "socket", lambda *args, **kwargs: fake_socket)

    total_messages = 4000
    queue = ByteBufferQueue(max_bytes=8 * 1024 * 1024)
    for i in range(total_messages):
        queue.put(bytes([i % 256]) * 32)

    forwarder = UDPForwarder(
        UDPSettings(host="127.0.0.1", port=9999, session="TEST", max_packet_size=1460),
        queue,
    )

    forwarder.start()
    forwarder.stop(drain=True)

    assert forwarder._messages_sent == total_messages
    assert forwarder._packets_sent == total_messages
    assert len(fake_socket.sent_packets) == total_messages
    assert fake_socket.closed is True
