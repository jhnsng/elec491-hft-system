"""Tests for the OUCH 5.0 paper trading server."""
import socket
import struct
import threading
import time
from pathlib import Path

import pytest

import sys
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from ouch_server import (
    OUCHSettings,
    PaperOrder,
    build_accepted,
    build_canceled,
    build_executed,
    parse_enter_order,
    parse_cancel_order,
    _nanos_since_midnight,
    _frame_message,
    recv_framed_message,
    ENTER_ORDER_FMT,
    CANCEL_ORDER_FMT,
    ACCEPTED_FMT,
    CANCELED_FMT,
    EXECUTED_FMT,
    OUCHSession,
    OUCHServer,
)
from ouch_metrics import OUCHMetricsTracker
from orderbook import OrderBook


###############################################################################
# Struct size verification
###############################################################################


class TestStructSizes:
    """Verify struct formats match the OUCH 5.0 spec byte counts."""

    def test_enter_order_size(self):
        assert ENTER_ORDER_FMT.size == 45

    def test_cancel_order_size(self):
        assert CANCEL_ORDER_FMT.size == 9

    def test_accepted_size(self):
        assert ACCEPTED_FMT.size == 62

    def test_canceled_size(self):
        assert CANCELED_FMT.size == 18

    def test_executed_size(self):
        assert EXECUTED_FMT.size == 34


###############################################################################
# Message parsing
###############################################################################


class TestMessageParsing:
    """Test inbound message parsing."""

    def test_parse_enter_order_valid(self):
        msg = ENTER_ORDER_FMT.pack(
            b'O', 42, b'B', 100, b'SPY     ', 2950000,
            b'0', b'Y', b'A', b'N', b'N', b'DEMO_ORD_ID   ',
        )
        fields = parse_enter_order(msg)
        assert fields["user_ref_num"] == 42
        assert fields["side"] == b'B'
        assert fields["quantity"] == 100
        assert fields["symbol"] == b'SPY     '
        assert fields["price"] == 2950000
        assert fields["time_in_force"] == b'0'
        assert fields["display"] == b'Y'
        assert fields["capacity"] == b'A'
        assert fields["cl_ord_id"] == b'DEMO_ORD_ID   '

    def test_parse_enter_order_sell_short(self):
        msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'T', 500, b'AAPL    ', 1500000,
            b'0', b'Y', b'P', b'N', b'N', b'SHORT_ORDER   ',
        )
        fields = parse_enter_order(msg)
        assert fields["side"] == b'T'
        assert fields["quantity"] == 500

    def test_parse_enter_order_too_short(self):
        with pytest.raises(ValueError, match="too short"):
            parse_enter_order(b'O' + b'\x00' * 10)

    def test_parse_enter_order_wrong_type(self):
        msg = b'X' + b'\x00' * 44
        with pytest.raises(ValueError, match="Expected type O"):
            parse_enter_order(msg)

    def test_parse_cancel_order_valid(self):
        msg = CANCEL_ORDER_FMT.pack(b'X', 42, 0)
        fields = parse_cancel_order(msg)
        assert fields["user_ref_num"] == 42
        assert fields["quantity"] == 0

    def test_parse_cancel_order_partial(self):
        msg = CANCEL_ORDER_FMT.pack(b'X', 7, 50)
        fields = parse_cancel_order(msg)
        assert fields["user_ref_num"] == 7
        assert fields["quantity"] == 50

    def test_parse_cancel_order_too_short(self):
        with pytest.raises(ValueError, match="too short"):
            parse_cancel_order(b'X\x00\x00')

    def test_parse_cancel_order_wrong_type(self):
        with pytest.raises(ValueError, match="Expected type X"):
            parse_cancel_order(b'O' + b'\x00' * 8)


###############################################################################
# Message building
###############################################################################


class TestMessageBuilding:
    """Test outbound message building and round-trip unpacking."""

    def test_build_accepted_round_trip(self):
        msg = build_accepted(
            timestamp_ns=1_000_000_000,
            user_ref_num=1,
            side=b'B',
            quantity=100,
            symbol=b'AAPL    ',
            price=1500000,
            time_in_force=b'0',
            display=b'Y',
            order_ref_num=42,
            capacity=b'A',
            ise=b'N',
            cross_type=b'N',
            order_state=b'L',
            cl_ord_id=b'TEST_ID       ',
        )
        assert len(msg) == 62
        assert msg[0:1] == b'A'
        fields = ACCEPTED_FMT.unpack(msg)
        assert fields[0] == b'A'
        assert fields[1] == 1_000_000_000
        assert fields[2] == 1
        assert fields[3] == b'B'
        assert fields[4] == 100
        assert fields[5] == b'AAPL    '
        assert fields[6] == 1500000
        assert fields[9] == 42   # order_ref_num (index 9)
        assert fields[13] == b'L'  # order_state (index 13)

    def test_build_accepted_dead_state(self):
        msg = build_accepted(
            timestamp_ns=0,
            user_ref_num=99,
            side=b'S',
            quantity=50,
            symbol=b'MSFT    ',
            price=3000000,
            time_in_force=b'3',
            display=b'N',
            order_ref_num=1,
            capacity=b'P',
            ise=b'Y',
            cross_type=b'N',
            order_state=b'D',
            cl_ord_id=b'DEAD_ORDER    ',
        )
        fields = ACCEPTED_FMT.unpack(msg)
        assert fields[13] == b'D'  # order_state (index 13)

    def test_build_canceled_round_trip(self):
        msg = build_canceled(
            timestamp_ns=2_000_000_000,
            user_ref_num=5,
            canceled_quantity=200,
            reason=b'U',
        )
        assert len(msg) == 18
        assert msg[0:1] == b'C'
        fields = CANCELED_FMT.unpack(msg)
        assert fields[2] == 5
        assert fields[3] == 200
        assert fields[4] == b'U'

    def test_build_executed_round_trip(self):
        msg = build_executed(
            timestamp_ns=3_000_000_000,
            user_ref_num=7,
            executed_quantity=50,
            price=2950000,
            liquidity_flag=b'R',
            match_number=1001,
        )
        assert len(msg) == 34
        assert msg[0:1] == b'E'
        fields = EXECUTED_FMT.unpack(msg)
        assert fields[2] == 7
        assert fields[3] == 50
        assert fields[4] == 2950000
        assert fields[5] == b'R'
        assert fields[6] == 1001


###############################################################################
# SoupBinTCP framing
###############################################################################


class TestSoupBinTCPFraming:
    """Test the 2-byte length prefix framing."""

    def test_frame_message(self):
        payload = b'\x01\x02\x03'
        framed = _frame_message(payload)
        assert framed == b'\x00\x03\x01\x02\x03'

    def test_frame_message_empty(self):
        framed = _frame_message(b'')
        assert framed == b'\x00\x00'

    def test_recv_framed_message_via_socketpair(self):
        s1, s2 = socket.socketpair()
        try:
            payload = b'Hello OUCH'
            s1.sendall(_frame_message(payload))
            received = recv_framed_message(s2)
            assert received == payload
        finally:
            s1.close()
            s2.close()

    def test_recv_multiple_messages(self):
        s1, s2 = socket.socketpair()
        try:
            s1.sendall(_frame_message(b'MSG1'))
            s1.sendall(_frame_message(b'MSG2'))
            assert recv_framed_message(s2) == b'MSG1'
            assert recv_framed_message(s2) == b'MSG2'
        finally:
            s1.close()
            s2.close()


###############################################################################
# Timestamp
###############################################################################


class TestTimestamp:
    """Test the nanoseconds-since-midnight helper."""

    def test_nanos_since_midnight_range(self):
        ts = _nanos_since_midnight()
        assert 0 <= ts < 86_400_000_000_000

    def test_nanos_since_midnight_monotonic(self):
        ts1 = _nanos_since_midnight()
        ts2 = _nanos_since_midnight()
        assert ts2 >= ts1


###############################################################################
# OUCHSettings
###############################################################################


class TestOUCHSettings:
    """Test the config dataclass."""

    def test_defaults(self):
        settings = OUCHSettings()
        assert settings.host == "127.0.0.1"
        assert settings.port == 9100
        assert settings.enabled is False

    def test_custom(self):
        settings = OUCHSettings(host="0.0.0.0", port=9200, enabled=True)
        assert settings.host == "0.0.0.0"
        assert settings.port == 9200
        assert settings.enabled is True

    def test_frozen(self):
        settings = OUCHSettings()
        with pytest.raises(AttributeError):
            settings.port = 9200


###############################################################################
# Paper trading logic via OUCHSession
###############################################################################


class TestPaperTradingLogic:
    """Test the enter/cancel paper trading logic via OUCHSession.

    Uses real socketpairs to communicate with the session thread.
    """

    def _make_session(self, orderbook: OrderBook):
        client_sock, server_sock = socket.socketpair()
        stop_event = threading.Event()
        session = OUCHSession(server_sock, ("test", 0), orderbook, stop_event)
        return session, client_sock, stop_event

    def _send_and_recv(
        self, client_sock: socket.socket, msg: bytes, expected_responses: int = 1
    ) -> list:
        client_sock.sendall(_frame_message(msg))
        time.sleep(0.15)
        responses = []
        client_sock.settimeout(1.0)
        for _ in range(expected_responses):
            try:
                resp = recv_framed_message(client_sock)
                responses.append(resp)
            except (socket.timeout, ConnectionError):
                break
        return responses

    def test_enter_order_accepted(self):
        book = OrderBook()
        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'B', 100, b'SPY     ', 100,
            b'0', b'Y', b'A', b'N', b'N', b'TEST_CL_ORD   ',
        )
        resps = self._send_and_recv(client, msg, 1)
        assert len(resps) >= 1
        assert resps[0][0:1] == b'A'

        stop.set()
        client.close()
        t.join(timeout=2.0)

    def test_enter_buy_crosses_best_ask(self):
        book = OrderBook()
        book.add_order(1, "SPY", "S", 2950000, 500, 0)
        best_bid, best_ask = book.get_bbo()
        assert best_ask == 2950000

        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'B', 100, b'SPY     ', 3000000,
            b'0', b'Y', b'A', b'N', b'N', b'BUY_CROSS     ',
        )
        resps = self._send_and_recv(client, msg, 2)
        assert len(resps) == 2
        assert resps[0][0:1] == b'A'
        assert resps[1][0:1] == b'E'
        exec_fields = EXECUTED_FMT.unpack(resps[1])
        assert exec_fields[4] == 2950000  # executed at best ask

        stop.set()
        client.close()
        t.join(timeout=2.0)

    def test_enter_sell_crosses_best_bid(self):
        book = OrderBook()
        book.add_order(1, "SPY", "B", 2940000, 500, 0)

        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'S', 50, b'SPY     ', 2900000,
            b'0', b'Y', b'A', b'N', b'N', b'SELL_CROSS    ',
        )
        resps = self._send_and_recv(client, msg, 2)
        assert len(resps) == 2
        assert resps[0][0:1] == b'A'
        assert resps[1][0:1] == b'E'
        exec_fields = EXECUTED_FMT.unpack(resps[1])
        assert exec_fields[4] == 2940000  # executed at best bid

        stop.set()
        client.close()
        t.join(timeout=2.0)

    def test_enter_buy_no_cross(self):
        book = OrderBook()
        book.add_order(1, "SPY", "S", 2950000, 500, 0)

        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'B', 100, b'SPY     ', 2900000,
            b'0', b'Y', b'A', b'N', b'N', b'BUY_NO_CROSS  ',
        )
        resps = self._send_and_recv(client, msg, 1)
        assert len(resps) == 1
        assert resps[0][0:1] == b'A'

        # Verify no Executed message follows
        client.settimeout(0.3)
        try:
            extra = recv_framed_message(client)
            pytest.fail(f"Should not have received extra message: {extra}")
        except (socket.timeout, ConnectionError):
            pass

        stop.set()
        client.close()
        t.join(timeout=2.0)

    def test_enter_no_bbo(self):
        """Empty orderbook should produce Accepted only, no Executed."""
        book = OrderBook()

        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'B', 100, b'SPY     ', 3000000,
            b'0', b'Y', b'A', b'N', b'N', b'NO_BBO_ORDER  ',
        )
        resps = self._send_and_recv(client, msg, 1)
        assert len(resps) == 1
        assert resps[0][0:1] == b'A'

        stop.set()
        client.close()
        t.join(timeout=2.0)

    def test_cancel_known_order(self):
        book = OrderBook()
        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        # Enter an order that won't cross
        enter_msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'B', 200, b'SPY     ', 100,
            b'0', b'Y', b'A', b'N', b'N', b'TO_CANCEL     ',
        )
        self._send_and_recv(client, enter_msg, 1)

        # Cancel it
        cancel_msg = CANCEL_ORDER_FMT.pack(b'X', 1, 0)
        resps = self._send_and_recv(client, cancel_msg, 1)
        assert len(resps) == 1
        assert resps[0][0:1] == b'C'
        cancel_fields = CANCELED_FMT.unpack(resps[0])
        assert cancel_fields[3] == 200  # canceled_quantity = remaining
        assert cancel_fields[4] == b'U'  # user-requested

        stop.set()
        client.close()
        t.join(timeout=2.0)

    def test_cancel_unknown_order_ignored(self):
        book = OrderBook()
        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        cancel_msg = CANCEL_ORDER_FMT.pack(b'X', 999, 0)
        client.sendall(_frame_message(cancel_msg))
        time.sleep(0.2)
        client.settimeout(0.3)
        try:
            recv_framed_message(client)
            pytest.fail("Should not have received a response")
        except (socket.timeout, ConnectionError):
            pass  # correct: silently ignored

        stop.set()
        client.close()
        t.join(timeout=2.0)

    def test_cancel_already_executed_ignored(self):
        """Cancel an order that was already fully executed - should be ignored."""
        book = OrderBook()
        book.add_order(1, "SPY", "S", 2950000, 500, 0)

        session, client, stop = self._make_session(book)
        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        # Enter a buy that crosses (fully executed)
        enter_msg = ENTER_ORDER_FMT.pack(
            b'O', 1, b'B', 100, b'SPY     ', 3000000,
            b'0', b'Y', b'A', b'N', b'N', b'EXEC_THEN_CXL ',
        )
        self._send_and_recv(client, enter_msg, 2)  # Accepted + Executed

        # Try to cancel the fully executed order
        cancel_msg = CANCEL_ORDER_FMT.pack(b'X', 1, 0)
        client.sendall(_frame_message(cancel_msg))
        time.sleep(0.2)
        client.settimeout(0.3)
        try:
            recv_framed_message(client)
            pytest.fail("Should not have received a response for dead order cancel")
        except (socket.timeout, ConnectionError):
            pass

        stop.set()
        client.close()
        t.join(timeout=2.0)


###############################################################################
# OUCHServer start/stop
###############################################################################


class TestOUCHServer:
    """Test OUCHServer lifecycle."""

    def test_start_stop(self):
        book = OrderBook()
        settings = OUCHSettings(host="127.0.0.1", port=0, enabled=True)
        # Use port 0 to let OS assign a free port
        server = OUCHServer(settings, book)
        server.start()
        # Give it a moment to bind
        time.sleep(0.2)
        server.stop()


###############################################################################
# OUCH metrics tracker
###############################################################################


class TestOUCHMetricsTracker:
    """Test OUCH metrics aggregation for GUI-facing dashboards."""

    def test_recent_orders_truncates_to_last_ten(self):
        tracker = OUCHMetricsTracker(recent_orders_limit=10)

        for i in range(1, 13):
            tracker.on_accepted(
                user_ref_num=i,
                symbol="SPY",
                side=b'B',
                quantity=10,
                limit_price_ticks=1_000_000 + i,
                accepted_ts_ns=1_000_000_000 + i,
            )

        snapshot = tracker.get_snapshot()
        recent = snapshot["recent_orders"]

        assert len(recent) == 10
        assert recent[0]["user_ref_num"] == 12
        assert recent[-1]["user_ref_num"] == 3

    def test_realized_pnl_fifo_for_round_trip(self):
        tracker = OUCHMetricsTracker()

        tracker.on_accepted(
            user_ref_num=1,
            symbol="SPY",
            side=b'B',
            quantity=100,
            limit_price_ticks=1_000_000,
            accepted_ts_ns=1_000,
        )
        tracker.on_executed(
            user_ref_num=1,
            executed_qty=100,
            execution_price_ticks=1_000_000,
            execution_ts_ns=2_000,
        )

        tracker.on_accepted(
            user_ref_num=2,
            symbol="SPY",
            side=b'S',
            quantity=100,
            limit_price_ticks=1_005_000,
            accepted_ts_ns=3_000,
        )
        tracker.on_executed(
            user_ref_num=2,
            executed_qty=100,
            execution_price_ticks=1_005_000,
            execution_ts_ns=4_000,
        )

        metrics = tracker.get_snapshot()["metrics"]
        assert metrics["realized_pnl_dollars"] == 50.0
        assert metrics["open_position_shares"] == 0

    def test_ouch_session_updates_tracker(self):
        book = OrderBook()
        book.add_order(1, "SPY", "S", 2_950_000, 500, 0)

        tracker = OUCHMetricsTracker()
        client_sock, server_sock = socket.socketpair()
        stop_event = threading.Event()
        session = OUCHSession(server_sock, ("test", 0), book, stop_event, tracker)

        t = threading.Thread(target=session.run, daemon=True)
        t.start()

        try:
            enter_msg = ENTER_ORDER_FMT.pack(
                b'O', 77, b'B', 100, b'SPY     ', 3_000_000,
                b'0', b'Y', b'A', b'N', b'N', b'GUI_TRACKER   ',
            )
            client_sock.sendall(_frame_message(enter_msg))

            # Accepted then Executed for crossing buy.
            recv_framed_message(client_sock)
            recv_framed_message(client_sock)

            snap = tracker.get_snapshot()
            metrics = snap["metrics"]
            recent = snap["recent_orders"]

            assert metrics["accepted_orders"] == 1
            assert metrics["executed_orders"] == 1
            assert metrics["hit_rate_pct"] == 100.0
            assert len(recent) == 1
            assert recent[0]["user_ref_num"] == 77
            assert recent[0]["status"] == "EXECUTED"
        finally:
            stop_event.set()
            client_sock.close()
            t.join(timeout=2.0)
