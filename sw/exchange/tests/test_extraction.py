"""Tests for data_forwarder extraction functions."""
import pytest

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from data_forwarder import (
    extract_order_id,
    extract_price_ticks,
    extract_side,
    extract_shares,
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
