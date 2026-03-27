"""Tests for data_forwarder extraction functions."""
import pytest
import tempfile

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from data_forwarder import (
    DemoDebugger,
    DemoDebuggerNonInteractive,
    _normalize_demo_breakpoints,
    load_demo_breakpoints,
    _parse_replay_settings,
    extract_order_id,
    extract_price_ticks,
    extract_side,
    extract_shares,
    parse_itch_time_24h_to_ns,
)


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
