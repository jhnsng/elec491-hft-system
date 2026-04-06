"""Tests for data_forwarder extraction functions."""
import pytest
import tempfile

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

import data_forwarder
from data_forwarder import (
    Message,
    TickerFilter,
    DemoDebugger,
    DemoDebuggerNonInteractive,
    _normalize_demo_breakpoints,
    load_demo_breakpoints,
    _parse_order_id_rewrite_settings,
    _parse_replay_settings,
    SequentialOrderIDMapper,
    extract_order_id,
    extract_replacement_order_id,
    extract_price_ticks,
    extract_replaced_order_id,
    extract_replaced_price_ticks,
    extract_replaced_shares,
    extract_side,
    extract_shares,
    parse_itch_time_24h_to_ns,
    rewrite_order_id_in_raw_message,
)


def _make_message(msg_type: str, payload: bytes) -> Message:
    msg_len = len(payload) + 1
    raw = msg_len.to_bytes(2, "big") + msg_type.encode("ascii") + payload
    return Message(raw)


class _StubOrderBook:
    def __init__(self, ticker: str):
        self._ticker = ticker

    def get_ticker(self, _order_id: int):
        return self._ticker


class TestExtractOrderId:
    """Tests for extract_order_id function."""

    def test_extract_order_id_add_order(self):
        """Test extracting order ID from Add Order (A) message."""
        # Create a minimal payload with order ID at bytes 10-18
        # Order ID = 12345678901234 (big-endian)
        order_id = 12345678901234
        payload = bytearray(35)  # Minimum size for Add Order
        payload[10:18] = order_id.to_bytes(8, "big")
        
        result = extract_order_id("A", memoryview(payload))
        assert result == order_id

    def test_extract_order_id_add_order_mpid(self):
        """Test extracting order ID from Add Order MPID (F) message."""
        order_id = 98765432109876
        payload = bytearray(40)
        payload[10:18] = order_id.to_bytes(8, "big")
        
        result = extract_order_id("F", memoryview(payload))
        assert result == order_id

    def test_extract_order_id_cancel(self):
        """Test extracting order ID from Order Cancel (X) message."""
        order_id = 11111111111111
        payload = bytearray(25)
        payload[10:18] = order_id.to_bytes(8, "big")
        
        result = extract_order_id("X", memoryview(payload))
        assert result == order_id

    def test_extract_order_id_delete(self):
        """Test extracting order ID from Order Delete (D) message."""
        order_id = 22222222222222
        payload = bytearray(20)
        payload[10:18] = order_id.to_bytes(8, "big")
        
        result = extract_order_id("D", memoryview(payload))
        assert result == order_id

    def test_extract_order_id_execute(self):
        """Test extracting order ID from Order Executed (E) message."""
        order_id = 33333333333333
        payload = bytearray(35)
        payload[10:18] = order_id.to_bytes(8, "big")
        
        result = extract_order_id("E", memoryview(payload))
        assert result == order_id

    def test_extract_order_id_execute_with_price(self):
        """Test extracting order ID from Order Executed With Price (C) message."""
        order_id = 44444444444444
        payload = bytearray(36)
        payload[10:18] = order_id.to_bytes(8, "big")

        result = extract_order_id("C", memoryview(payload))
        assert result == order_id

    def test_extract_order_id_replace_original(self):
        """Test extracting original order ID from Order Replace (U) message."""
        order_id = 55555555555555
        payload = bytearray(34)
        payload[10:18] = order_id.to_bytes(8, "big")

        result = extract_order_id("U", memoryview(payload))
        assert result == order_id

    def test_extract_order_id_unsupported_type(self):
        """Test that unsupported message types return None."""
        payload = bytearray(35)
        result = extract_order_id("P", memoryview(payload))  # Trade message
        assert result is None

    def test_extract_order_id_payload_too_short(self):
        """Test that short payload returns None."""
        payload = bytearray(10)  # Too short
        result = extract_order_id("A", memoryview(payload))
        assert result is None


class TestExtractReplacementOrderId:
    """Tests for extraction of replacement order reference in U messages."""

    def test_extract_replacement_order_id_replace(self):
        new_order_id = 66666666666666
        payload = bytearray(34)
        payload[18:26] = new_order_id.to_bytes(8, "big")

        result = extract_replacement_order_id("U", memoryview(payload))
        assert result == new_order_id

    def test_extract_replacement_order_id_non_replace_returns_none(self):
        payload = bytearray(34)
        assert extract_replacement_order_id("A", memoryview(payload)) is None

    def test_extract_replacement_order_id_payload_too_short(self):
        payload = bytearray(20)
        assert extract_replacement_order_id("U", memoryview(payload)) is None


class TestExtractPriceTicks:
    """Tests for extract_price_ticks function."""

    def test_extract_price_add_order(self):
        """Test extracting price from Add Order (A) message."""
        # Price = $150.00 = 1500000 ticks (in 1/10000 dollars)
        price_ticks = 1500000
        payload = bytearray(36)
        payload[31:35] = price_ticks.to_bytes(4, "big")
        
        result = extract_price_ticks("A", memoryview(payload))
        assert result == price_ticks

    def test_extract_price_add_order_mpid(self):
        """Test extracting price from Add Order MPID (F) message."""
        price_ticks = 2000000  # $200.00
        payload = bytearray(40)
        payload[31:35] = price_ticks.to_bytes(4, "big")
        
        result = extract_price_ticks("F", memoryview(payload))
        assert result == price_ticks

    def test_extract_price_executed_with_price(self):
        """Test extracting execution price from Order Executed With Price (C)."""
        price_ticks = 1754321
        payload = bytearray(35)
        payload[31:35] = price_ticks.to_bytes(4, "big")

        result = extract_price_ticks("C", memoryview(payload))
        assert result == price_ticks

    def test_extract_price_replace(self):
        """Test extracting replacement price from Order Replace (U)."""
        price_ticks = 1999900
        payload = bytearray(34)
        payload[30:34] = price_ticks.to_bytes(4, "big")

        result = extract_price_ticks("U", memoryview(payload))
        assert result == price_ticks

    def test_extract_price_unsupported_type(self):
        """Test that unsupported message types return None."""
        payload = bytearray(40)
        result = extract_price_ticks("X", memoryview(payload))  # Cancel
        assert result is None

    def test_extract_price_payload_too_short(self):
        """Test that short payload returns None."""
        payload = bytearray(30)  # Too short
        result = extract_price_ticks("A", memoryview(payload))
        assert result is None


class TestExtractSide:
    """Tests for extract_side function."""

    def test_extract_side_buy(self):
        """Test extracting buy side from Add Order."""
        payload = bytearray(35)
        payload[18] = ord("B")
        
        result = extract_side("A", memoryview(payload))
        assert result == "B"

    def test_extract_side_sell(self):
        """Test extracting sell side from Add Order."""
        payload = bytearray(35)
        payload[18] = ord("S")
        
        result = extract_side("A", memoryview(payload))
        assert result == "S"

    def test_extract_side_add_order_mpid(self):
        """Test extracting side from Add Order MPID."""
        payload = bytearray(40)
        payload[18] = ord("B")
        
        result = extract_side("F", memoryview(payload))
        assert result == "B"

    def test_extract_side_unsupported_type(self):
        """Test that unsupported message types return None."""
        payload = bytearray(35)
        payload[18] = ord("B")
        
        result = extract_side("X", memoryview(payload))  # Cancel doesn't have side
        assert result is None

    def test_extract_side_payload_too_short(self):
        """Test that short payload returns None."""
        payload = bytearray(15)
        result = extract_side("A", memoryview(payload))
        assert result is None


class TestExtractShares:
    """Tests for extract_shares function."""

    def test_extract_shares_add_order(self):
        """Test extracting shares from Add Order (A) message."""
        shares = 500
        payload = bytearray(35)
        payload[19:23] = shares.to_bytes(4, "big")
        
        result = extract_shares("A", memoryview(payload))
        assert result == shares

    def test_extract_shares_add_order_mpid(self):
        """Test extracting shares from Add Order MPID (F) message."""
        shares = 1000
        payload = bytearray(40)
        payload[19:23] = shares.to_bytes(4, "big")
        
        result = extract_shares("F", memoryview(payload))
        assert result == shares

    def test_extract_shares_cancel(self):
        """Test extracting cancelled shares from Order Cancel (X) message."""
        cancelled_shares = 200
        payload = bytearray(25)
        payload[18:22] = cancelled_shares.to_bytes(4, "big")
        
        result = extract_shares("X", memoryview(payload))
        assert result == cancelled_shares

    def test_extract_shares_execute(self):
        """Test extracting executed shares from Order Executed (E) message."""
        executed_shares = 150
        payload = bytearray(35)
        payload[18:22] = executed_shares.to_bytes(4, "big")
        
        result = extract_shares("E", memoryview(payload))
        assert result == executed_shares

    def test_extract_shares_execute_with_price(self):
        """Test extracting executed shares from Order Executed With Price (C)."""
        executed_shares = 175
        payload = bytearray(36)
        payload[18:22] = executed_shares.to_bytes(4, "big")

        result = extract_shares("C", memoryview(payload))
        assert result == executed_shares

    def test_extract_shares_replace_new_total(self):
        """Test extracting new total shares from Order Replace (U)."""
        new_total_shares = 250
        payload = bytearray(34)
        payload[26:30] = new_total_shares.to_bytes(4, "big")

        result = extract_shares("U", memoryview(payload))
        assert result == new_total_shares
    def test_extract_shares_delete_returns_none(self):
        """Test that Order Delete (D) returns None (no shares field)."""
        payload = bytearray(20)
        result = extract_shares("D", memoryview(payload))
        assert result is None

    def test_extract_shares_payload_too_short_add(self):
        """Test that short payload for Add Order returns None."""
        payload = bytearray(20)
        result = extract_shares("A", memoryview(payload))
        assert result is None

    def test_extract_shares_payload_too_short_cancel(self):
        """Test that short payload for Cancel returns None."""
        payload = bytearray(15)
        result = extract_shares("X", memoryview(payload))
        assert result is None


class TestExtractSharesLargeValues:
    """Tests for extract_shares with large values."""

    def test_extract_shares_max_value(self):
        """Test extracting maximum possible shares (4 bytes)."""
        max_shares = 2**32 - 1  # 4,294,967,295
        payload = bytearray(35)
        payload[19:23] = max_shares.to_bytes(4, "big")
        
        result = extract_shares("A", memoryview(payload))
        assert result == max_shares

    def test_extract_shares_zero(self):
        """Test extracting zero shares."""
        payload = bytearray(35)
        payload[19:23] = (0).to_bytes(4, "big")
        
        result = extract_shares("A", memoryview(payload))
        assert result == 0


class TestExtractReplaceFields:
    """Tests for replace-message extraction helpers."""

    def test_extract_replaced_order_id(self):
        new_order_id = 66666666666666
        payload = bytearray(34)
        payload[18:26] = new_order_id.to_bytes(8, "big")

        result = extract_replaced_order_id(memoryview(payload))
        assert result == new_order_id

    def test_extract_replaced_shares(self):
        shares = 1234
        payload = bytearray(34)
        payload[26:30] = shares.to_bytes(4, "big")

        result = extract_replaced_shares(memoryview(payload))
        assert result == shares

    def test_extract_replaced_price_ticks(self):
        price_ticks = 2_999_500
        payload = bytearray(34)
        payload[30:34] = price_ticks.to_bytes(4, "big")

        result = extract_replaced_price_ticks(memoryview(payload))
        assert result == price_ticks


class TestParseITCHTime24h:
    """Tests for HH:MM:SS(.fraction) to ITCH ns conversion."""

    def test_parse_whole_seconds(self):
        assert parse_itch_time_24h_to_ns("00:00:01") == 1_000_000_000

    def test_parse_microseconds(self):
        assert parse_itch_time_24h_to_ns("09:30:00.123456") == 34_200_123_456_000

    def test_parse_nanoseconds_precision(self):
        assert parse_itch_time_24h_to_ns("12:34:56.123456789") == 45_296_123_456_789

    @pytest.mark.parametrize(
        "value",
        [
            "24:00:00",
            "09:60:00",
            "09:30:60",
            "09:30",
            "bad",
        ],
    )
    def test_parse_invalid_values(self, value):
        with pytest.raises(ValueError):
            parse_itch_time_24h_to_ns(value)


class TestParseReplaySettings:
    """Tests for replay YAML config parsing."""

    def test_parse_replay_true(self):
        settings = _parse_replay_settings(True)
        assert settings is not None
        assert settings.enabled is True
        assert settings.start_timestamp_ns is None
        assert settings.speed == 1.0

    def test_parse_replay_start_time(self):
        settings = _parse_replay_settings({
            "enabled": True,
            "start_time_24h": "09:30:00.000000",
            "speed": 2.0,
        })
        assert settings is not None
        assert settings.enabled is True
        assert settings.start_timestamp_ns == 34_200_000_000_000
        assert settings.speed == 2.0

    def test_parse_replay_mutually_exclusive_start_fields(self):
        with pytest.raises(ValueError):
            _parse_replay_settings(
                {
                    "start_timestamp": 123,
                    "start_time_24h": "00:00:01",
                }
            )

    def test_parse_replay_invalid_speed(self):
        with pytest.raises(ValueError):
            _parse_replay_settings({"speed": 0})


class TestParseOrderIDRewriteSettings:
    def test_parse_none_returns_none(self):
        assert _parse_order_id_rewrite_settings(None) is None

    def test_parse_true_enables_with_default_start(self):
        settings = _parse_order_id_rewrite_settings(True)
        assert settings is not None
        assert settings.enabled is True
        assert settings.start_id == 1

    def test_parse_mapping(self):
        settings = _parse_order_id_rewrite_settings({"enabled": True, "start_id": 42})
        assert settings is not None
        assert settings.enabled is True
        assert settings.start_id == 42

    def test_parse_invalid_start_id(self):
        with pytest.raises(ValueError):
            _parse_order_id_rewrite_settings({"enabled": True, "start_id": 0})


class TestOrderIDRewriteHelpers:
    def test_mapper_assigns_sequential_ids(self):
        mapper = SequentialOrderIDMapper(start_id=10)
        assert mapper.map_add(1001) == 10
        assert mapper.map_add(1002) == 11
        assert mapper.map_add(1001) == 10
        assert mapper.get_mapped(1002) == 11

    def test_rewrite_order_id_in_raw_message(self):
        payload = bytearray(35)
        payload[10:18] = (123).to_bytes(8, "big")
        msg = _make_message("A", bytes(payload))

        rewritten = rewrite_order_id_in_raw_message(msg.raw, "A", 999)
        assert rewritten is not None

        rewritten_msg = Message(rewritten)
        rewritten_id = extract_order_id(rewritten_msg.msg_type, rewritten_msg.payload)
        assert rewritten_id == 999

    def test_mapper_replace_carries_mapping(self):
        mapper = SequentialOrderIDMapper(start_id=100)
        assert mapper.map_add(1001) == 100

        assert mapper.replace(1001, 2001) is True
        assert mapper.get_mapped(1001) is None
        assert mapper.get_mapped(2001) == 100

    def test_rewrite_order_id_in_raw_message_replace(self):
        msg = _make_replace_message(
            original_order_id=123,
            new_order_id=456,
            timestamp_ns=100,
        )

        rewritten = rewrite_order_id_in_raw_message(
            msg.raw,
            "U",
            new_order_id=1001,
            replacement_order_id=1002,
        )
        assert rewritten is not None

        original_id, new_id = _extract_replace_order_ids(rewritten)
        assert original_id == 1001
        assert new_id == 1002


class TestForwardableITCHTypes:
    def test_should_forward_supported_add_order(self):
        payload = bytearray(35)
        payload[23:31] = b"AAPL    "
        msg = _make_message("A", bytes(payload))

        filt = TickerFilter({"AAPL"})
        assert filt.should_forward(msg) is True

    def test_should_not_forward_unsupported_trade_message(self):
        payload = bytearray(37)
        payload[23:31] = b"AAPL    "
        msg = _make_message("P", bytes(payload))

        filt = TickerFilter({"AAPL"})
        assert filt.should_forward(msg) is False

    def test_should_forward_supported_cancel_with_orderbook_resolution(self):
        payload = bytearray(27)
        payload[10:18] = (123).to_bytes(8, "big")
        msg = _make_message("X", bytes(payload))

        filt = TickerFilter({"AAPL"}, orderbook=_StubOrderBook("AAPL"))
        assert filt.should_forward(msg) is True

    def test_should_forward_execute_with_price_with_orderbook_resolution(self):
        payload = bytearray(35)
        payload[10:18] = (123).to_bytes(8, "big")
        msg = _make_message("C", bytes(payload))

        filt = TickerFilter({"AAPL"}, orderbook=_StubOrderBook("AAPL"))
        assert filt.should_forward(msg) is True

    def test_should_forward_replace_with_orderbook_resolution(self):
        payload = bytearray(34)
        payload[10:18] = (123).to_bytes(8, "big")
        payload[18:26] = (456).to_bytes(8, "big")
        msg = _make_message("U", bytes(payload))

        filt = TickerFilter({"AAPL"}, orderbook=_StubOrderBook("AAPL"))
        assert filt.should_forward(msg) is True


class TestITCHStreamDiagnostics:
    def test_warns_on_incomplete_trailing_message(self, tmp_path, caplog):
        complete = _make_add_order_message(order_id=1, ticker="AAPL", timestamp_ns=1).raw
        truncated = _make_add_order_message(order_id=2, ticker="AAPL", timestamp_ns=2).raw[:8]
        stream_path = tmp_path / "truncated.itch"
        stream_path.write_bytes(complete + truncated)

        caplog.set_level("WARNING", logger="data_forwarder")
        parsed = list(data_forwarder.ITCHStream(stream_path, chunk_size=16))

        assert len(parsed) == 1
        assert "incomplete message" in caplog.text
        assert "truncated.itch" in caplog.text


class TestDemoBreakpoints:
    """Tests for demo breakpoint parsing helpers."""

    def test_normalize_demo_breakpoints_sorted_unique(self):
        assert _normalize_demo_breakpoints([10, 2, 10, "5"]) == [2, 5, 10]

    def test_normalize_demo_breakpoints_reject_non_positive(self):
        with pytest.raises(ValueError):
            _normalize_demo_breakpoints([0, 5])

    def test_load_demo_breakpoints_mapping(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as handle:
            handle.write("breakpoints:\n  - 8\n  - 3\n  - 8\n")
            path = Path(handle.name)

        try:
            assert load_demo_breakpoints(path) == [3, 8]
        finally:
            path.unlink()

    def test_load_demo_breakpoints_top_level_list(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as handle:
            handle.write("- 4\n- 2\n")
            path = Path(handle.name)

        try:
            assert load_demo_breakpoints(path) == [2, 4]
        finally:
            path.unlink()


class TestDemoDebugger:
    """Tests for demo debugger pause/step/continue controls."""

    def test_breakpoint_continue_command(self):
        commands = iter(["c"])
        debugger = DemoDebugger([2], command_reader=lambda: next(commands), interactive=True)

        assert debugger.on_forwarded(1) == "continue"
        assert debugger.on_forwarded(2) == "continue"
        assert debugger.stop_requested is False

    def test_step_one_then_pause_again(self):
        commands = iter(["n", "c"])
        debugger = DemoDebugger([1], command_reader=lambda: next(commands), interactive=True)

        assert debugger.on_forwarded(1) == "continue"  # pause at breakpoint, command=n
        assert debugger.on_forwarded(2) == "continue"  # pause after one step, command=c
        assert debugger.stop_requested is False

    def test_quit_command_requests_stop(self):
        commands = iter(["q"])
        debugger = DemoDebugger([1], command_reader=lambda: next(commands), interactive=True)

        assert debugger.on_forwarded(1) == "stop"
        assert debugger.stop_requested is True

    def test_non_interactive_breakpoint_raises(self):
        debugger = DemoDebugger([1], command_reader=lambda: "c", interactive=False)

        with pytest.raises(DemoDebuggerNonInteractive):
            debugger.on_forwarded(1)


class _RecordingOrderBook:
    last_instance = None

    def __init__(self, *args, **kwargs):
        del args, kwargs
        type(self).last_instance = self
        self._ticker_by_order_id = {}
        self.added_order_ids = []
        self.cancelled_order_ids = []
        self.deleted_order_ids = []
        self.executed_order_ids = []
        self.replaced_order_ids = []

    def get_ticker(self, order_id: int):
        return self._ticker_by_order_id.get(order_id)

    def has_order(self, order_id: int) -> bool:
        return order_id in self._ticker_by_order_id

    def add_order(
        self,
        order_id: int,
        ticker: str,
        side: str,
        price_ticks: int,
        shares: int,
        timestamp_ns: int,
    ) -> bool:
        del side, price_ticks, shares, timestamp_ns
        self.added_order_ids.append(order_id)
        self._ticker_by_order_id[order_id] = ticker
        return True

    def cancel_shares(self, order_id: int, cancelled_shares: int, timestamp_ns: int) -> bool:
        del cancelled_shares, timestamp_ns
        self.cancelled_order_ids.append(order_id)
        self._ticker_by_order_id.pop(order_id, None)
        return True

    def delete_order(self, order_id: int, timestamp_ns: int) -> bool:
        del timestamp_ns
        self.deleted_order_ids.append(order_id)
        self._ticker_by_order_id.pop(order_id, None)
        return True

    def execute_shares(self, order_id: int, executed_shares: int, timestamp_ns: int) -> bool:
        del executed_shares, timestamp_ns
        self.executed_order_ids.append(order_id)
        self._ticker_by_order_id.pop(order_id, None)
        return True

    def replace_order(
        self,
        original_order_id: int,
        new_order_id: int,
        shares: int,
        price_ticks: int,
        timestamp_ns: int,
    ) -> bool:
        del shares, price_ticks, timestamp_ns
        self.replaced_order_ids.append((original_order_id, new_order_id))
        ticker = self._ticker_by_order_id.pop(original_order_id, None)
        if ticker is not None:
            self._ticker_by_order_id[new_order_id] = ticker
        return True

    def log_summary(self, logger) -> None:
        del logger


class TestForwardLoopStopReason:
    def test_logs_input_exhausted_reason(self, monkeypatch, caplog):
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _NoopUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(()))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
        )

        caplog.set_level("INFO", logger="data_forwarder")
        data_forwarder.forward(cfg)

        assert "Forward loop completed: reason=input_exhausted" in caplog.text


class _NoopUDPForwarder:
    def __init__(self, _settings, queue):
        self._queue = queue

    def start(self) -> None:
        return None

    def stop(self, *, drain: bool = True) -> None:
        del drain
        self._queue.close()


class _QueueClosingUDPForwarder:
    def __init__(self, _settings, queue):
        self._queue = queue

    def start(self) -> None:
        self._queue.close()

    def stop(self, *, drain: bool = True) -> None:
        del drain


class _CapturingUDPForwarder:
    last_instance = None

    def __init__(self, _settings, queue):
        type(self).last_instance = self
        self._queue = queue
        self.sent_messages = []

    def start(self) -> None:
        return None

    def stop(self, *, drain: bool = True) -> None:
        self._queue.close()
        if not drain:
            return
        while True:
            try:
                self.sent_messages.append(self._queue.get())
            except data_forwarder.QueueClosed:
                break


class _AlwaysTickerOrderBook:
    def __init__(self, *args, **kwargs):
        del args, kwargs

    def get_ticker(self, _order_id: int):
        return "AAPL"

    def add_order(
        self,
        order_id: int,
        ticker: str,
        side: str,
        price_ticks: int,
        shares: int,
        timestamp_ns: int,
    ) -> bool:
        del order_id, ticker, side, price_ticks, shares, timestamp_ns
        return True

    def cancel_shares(self, order_id: int, cancelled_shares: int, timestamp_ns: int) -> bool:
        del order_id, cancelled_shares, timestamp_ns
        return True

    def delete_order(self, order_id: int, timestamp_ns: int) -> bool:
        del order_id, timestamp_ns
        return True

    def execute_shares(self, order_id: int, executed_shares: int, timestamp_ns: int) -> bool:
        del order_id, executed_shares, timestamp_ns
        return True

    def replace_order(
        self,
        original_order_id: int,
        new_order_id: int,
        shares: int,
        price_ticks: int,
        timestamp_ns: int,
    ) -> bool:
        del original_order_id, new_order_id, shares, price_ticks, timestamp_ns
        return True

    def has_order(self, order_id: int) -> bool:
        del order_id
        return False

    def log_summary(self, logger) -> None:
        del logger


def _make_add_order_message(order_id: int, ticker: str, timestamp_ns: int) -> Message:
    payload = bytearray(35)
    payload[4:10] = timestamp_ns.to_bytes(6, "big")
    payload[10:18] = order_id.to_bytes(8, "big")
    payload[18] = ord("B")
    payload[19:23] = (100).to_bytes(4, "big")
    payload[23:31] = ticker.encode("ascii").ljust(8, b" ")
    payload[31:35] = (1_000_000).to_bytes(4, "big")
    return _make_message("A", bytes(payload))


def _make_cancel_message(order_id: int, timestamp_ns: int) -> Message:
    payload = bytearray(22)
    payload[4:10] = timestamp_ns.to_bytes(6, "big")
    payload[10:18] = order_id.to_bytes(8, "big")
    payload[18:22] = (10).to_bytes(4, "big")
    return _make_message("X", bytes(payload))


def _make_delete_message(order_id: int, timestamp_ns: int) -> Message:
    payload = bytearray(18)
    payload[4:10] = timestamp_ns.to_bytes(6, "big")
    payload[10:18] = order_id.to_bytes(8, "big")
    return _make_message("D", bytes(payload))


def _make_execute_message(order_id: int, timestamp_ns: int, shares: int = 10) -> Message:
    payload = bytearray(30)
    payload[4:10] = timestamp_ns.to_bytes(6, "big")
    payload[10:18] = order_id.to_bytes(8, "big")
    payload[18:22] = shares.to_bytes(4, "big")
    return _make_message("E", bytes(payload))


def _make_execute_with_price_message(
    order_id: int,
    timestamp_ns: int,
    shares: int = 10,
    price_ticks: int = 1_000_100,
) -> Message:
    payload = bytearray(35)
    payload[4:10] = timestamp_ns.to_bytes(6, "big")
    payload[10:18] = order_id.to_bytes(8, "big")
    payload[18:22] = shares.to_bytes(4, "big")
    payload[23:31] = (999).to_bytes(8, "big")  # match number
    payload[31 - 1] = ord("Y")  # printable at payload[30]
    payload[31:35] = price_ticks.to_bytes(4, "big")
    return _make_message("C", bytes(payload))


def _make_replace_message(
    original_order_id: int,
    new_order_id: int,
    timestamp_ns: int,
    shares: int = 75,
    price_ticks: int = 1_010_000,
) -> Message:
    payload = bytearray(34)
    payload[4:10] = timestamp_ns.to_bytes(6, "big")
    payload[10:18] = original_order_id.to_bytes(8, "big")
    payload[18:26] = new_order_id.to_bytes(8, "big")
    payload[26:30] = shares.to_bytes(4, "big")
    payload[30:34] = price_ticks.to_bytes(4, "big")
    return _make_message("U", bytes(payload))


def _extract_message_order_id(raw_message: bytes) -> int:
    parsed = Message(raw_message)
    order_id = extract_order_id(parsed.msg_type, parsed.payload)
    assert order_id is not None
    return order_id


def _extract_replace_order_ids(raw_message: bytes) -> tuple[int, int]:
    parsed = Message(raw_message)
    assert parsed.msg_type == "U"
    original_id = extract_order_id(parsed.msg_type, parsed.payload)
    new_id = extract_replacement_order_id(parsed.msg_type, parsed.payload)
    assert original_id is not None
    assert new_id is not None
    return original_id, new_id


class TestReplayFastForward:
    def test_does_not_update_orderbook_while_skipping_to_start(self, monkeypatch):
        messages = [
            _make_add_order_message(order_id=1, ticker="AAPL", timestamp_ns=100),
            _make_cancel_message(order_id=1, timestamp_ns=120),
            _make_add_order_message(order_id=2, ticker="AAPL", timestamp_ns=200),
        ]

        monkeypatch.setattr(data_forwarder, "OrderBook", _RecordingOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _NoopUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
        )

        data_forwarder.forward(
            cfg,
            orderbook_mode=True,
            replay_enabled=True,
            replay_start_timestamp_ns=200,
            max_messages=1,
        )

        orderbook = _RecordingOrderBook.last_instance
        assert orderbook is not None
        assert orderbook.added_order_ids == [2]
        assert orderbook.cancelled_order_ids == []
        assert orderbook.deleted_order_ids == []
        assert orderbook.executed_order_ids == []


class TestOrderBookCommitSafety:
    def test_add_order_committed_only_after_enqueue(self, monkeypatch):
        messages = [_make_add_order_message(order_id=42, ticker="AAPL", timestamp_ns=100)]

        monkeypatch.setattr(data_forwarder, "OrderBook", _RecordingOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _QueueClosingUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
        )

        data_forwarder.forward(cfg, orderbook_mode=True)

        orderbook = _RecordingOrderBook.last_instance
        assert orderbook is not None
        assert orderbook.added_order_ids == []
        assert orderbook.has_order(42) is False


class TestOrderIDRewriteForwarding:
    def test_rewrites_add_and_related_cancel_execute(self, monkeypatch):
        messages = [
            _make_add_order_message(order_id=101, ticker="AAPL", timestamp_ns=100),
            _make_cancel_message(order_id=101, timestamp_ns=110),
            _make_add_order_message(order_id=202, ticker="AAPL", timestamp_ns=120),
            _make_execute_message(order_id=202, timestamp_ns=130, shares=50),
        ]

        monkeypatch.setattr(data_forwarder, "OrderBook", _RecordingOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _CapturingUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
            order_id_rewrite=data_forwarder.OrderIDRewriteSettings(enabled=True, start_id=1),
        )

        data_forwarder.forward(cfg, orderbook_mode=True)

        forwarder = _CapturingUDPForwarder.last_instance
        assert forwarder is not None

        outbound_ids = [_extract_message_order_id(raw) for raw in forwarder.sent_messages]
        assert outbound_ids == [1, 1, 2, 2]

    def test_rewrites_delete_and_reuses_new_id_on_readded_order(self, monkeypatch):
        messages = [
            _make_add_order_message(order_id=303, ticker="AAPL", timestamp_ns=100),
            _make_delete_message(order_id=303, timestamp_ns=110),
            _make_add_order_message(order_id=303, ticker="AAPL", timestamp_ns=120),
        ]

        monkeypatch.setattr(data_forwarder, "OrderBook", _RecordingOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _CapturingUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
            order_id_rewrite=data_forwarder.OrderIDRewriteSettings(enabled=True, start_id=1),
        )

        data_forwarder.forward(cfg, orderbook_mode=True)

        forwarder = _CapturingUDPForwarder.last_instance
        assert forwarder is not None

        outbound_ids = [_extract_message_order_id(raw) for raw in forwarder.sent_messages]
        assert outbound_ids == [1, 1, 2]

    def test_rewrites_execute_with_price(self, monkeypatch):
        messages = [
            _make_add_order_message(order_id=501, ticker="AAPL", timestamp_ns=100),
            _make_execute_with_price_message(order_id=501, timestamp_ns=110, shares=25),
        ]

        monkeypatch.setattr(data_forwarder, "OrderBook", _RecordingOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _CapturingUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
            order_id_rewrite=data_forwarder.OrderIDRewriteSettings(enabled=True, start_id=1),
        )

        data_forwarder.forward(cfg, orderbook_mode=True)

        forwarder = _CapturingUDPForwarder.last_instance
        assert forwarder is not None

        outbound_ids = [_extract_message_order_id(raw) for raw in forwarder.sent_messages]
        assert outbound_ids == [1, 1]

    def test_rewrites_replace_and_followup_cancel(self, monkeypatch):
        messages = [
            _make_add_order_message(order_id=601, ticker="AAPL", timestamp_ns=100),
            _make_replace_message(original_order_id=601, new_order_id=602, timestamp_ns=110),
            _make_cancel_message(order_id=602, timestamp_ns=120),
        ]

        monkeypatch.setattr(data_forwarder, "OrderBook", _RecordingOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _CapturingUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
            order_id_rewrite=data_forwarder.OrderIDRewriteSettings(enabled=True, start_id=1),
        )

        data_forwarder.forward(cfg, orderbook_mode=True)

        forwarder = _CapturingUDPForwarder.last_instance
        assert forwarder is not None
        assert len(forwarder.sent_messages) == 3

        assert _extract_message_order_id(forwarder.sent_messages[0]) == 1
        assert _extract_replace_order_ids(forwarder.sent_messages[1]) == (1, 2)
        assert _extract_message_order_id(forwarder.sent_messages[2]) == 2

    def test_drops_xde_without_prior_mapping(self, monkeypatch, caplog):
        messages = [_make_cancel_message(order_id=404, timestamp_ns=100)]

        monkeypatch.setattr(data_forwarder, "OrderBook", _AlwaysTickerOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _CapturingUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
            order_id_rewrite=data_forwarder.OrderIDRewriteSettings(enabled=True, start_id=1),
        )

        caplog.set_level("WARNING", logger="data_forwarder")
        data_forwarder.forward(cfg, orderbook_mode=True)

        forwarder = _CapturingUDPForwarder.last_instance
        assert forwarder is not None
        assert forwarder.sent_messages == []
        assert "no mapped forwarded ID" in caplog.text

    def test_dropped_rewrite_does_not_mutate_local_orderbook(self, monkeypatch, caplog):
        messages = [
            _make_add_order_message(order_id=701, ticker="AAPL", timestamp_ns=100),
            _make_cancel_message(order_id=701, timestamp_ns=110),
        ]

        class _DropResolvedMapper:
            def __init__(self, start_id: int = 1):
                self._next_id = start_id

            def map_add(self, original_order_id: int) -> int:
                del original_order_id
                mapped = self._next_id
                self._next_id += 1
                return mapped

            def get_mapped(self, original_order_id: int):
                del original_order_id
                return None

            def discard(self, original_order_id: int) -> None:
                del original_order_id

        monkeypatch.setattr(data_forwarder, "OrderBook", _RecordingOrderBook)
        monkeypatch.setattr(data_forwarder, "UDPForwarder", _CapturingUDPForwarder)
        monkeypatch.setattr(data_forwarder, "ITCHStream", lambda *_args, **_kwargs: iter(messages))
        monkeypatch.setattr(data_forwarder, "SequentialOrderIDMapper", _DropResolvedMapper)

        cfg = data_forwarder.ForwarderConfig(
            itch_file=Path("/tmp/unused.itch"),
            tickers={"AAPL"},
            udp=data_forwarder.UDPSettings(host="127.0.0.1", port=9999),
            reader=data_forwarder.ReaderSettings(
                chunk_size=1024,
                max_buffer_bytes=1024 * 1024,
                stats_interval=9999.0,
            ),
            order_id_rewrite=data_forwarder.OrderIDRewriteSettings(enabled=True, start_id=1),
        )

        caplog.set_level("WARNING", logger="data_forwarder")
        data_forwarder.forward(cfg, orderbook_mode=True)

        forwarder = _CapturingUDPForwarder.last_instance
        assert forwarder is not None
        assert len(forwarder.sent_messages) == 1
        assert _extract_message_order_id(forwarder.sent_messages[0]) == 1
        assert "no mapped forwarded ID" in caplog.text

        orderbook = _RecordingOrderBook.last_instance
        assert orderbook is not None
        assert orderbook.added_order_ids == [701]
        assert orderbook.cancelled_order_ids == []
        assert orderbook.has_order(701)
