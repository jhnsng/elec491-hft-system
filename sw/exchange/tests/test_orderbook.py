"""Tests for the OrderBook implementation."""
import json
import tempfile
from pathlib import Path

import pytest

# Add src to path for imports
import sys
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from orderbook import Order, OrderBook, PriceLevel


class TestOrder:
    """Tests for the Order dataclass."""

    def test_order_creation(self):
        """Test creating an Order with all fields."""
        order = Order(
            order_id=12345,
            ticker="AAPL",
            side="B",
            price_ticks=1500000,  # $150.00
            shares=100,
            timestamp_ns=34200000000000,  # 9:30 AM
        )
        assert order.order_id == 12345
        assert order.ticker == "AAPL"
        assert order.side == "B"
        assert order.price_ticks == 1500000
        assert order.shares == 100
        assert order.timestamp_ns == 34200000000000


class TestPriceLevel:
    """Tests for the PriceLevel class."""

    def test_add_order_to_level(self):
        """Test adding orders to a price level."""
        level = PriceLevel(price_ticks=1500000)
        order1 = Order(1, "AAPL", "B", 1500000, 100, 0)
        order2 = Order(2, "AAPL", "B", 1500000, 200, 0)

        level.add_order(order1)
        assert level.total_shares == 100
        assert level.order_count == 1

        level.add_order(order2)
        assert level.total_shares == 300
        assert level.order_count == 2

    def test_remove_order_from_level(self):
        """Test removing orders from a price level."""
        level = PriceLevel(price_ticks=1500000)
        order1 = Order(1, "AAPL", "B", 1500000, 100, 0)
        order2 = Order(2, "AAPL", "B", 1500000, 200, 0)

        level.add_order(order1)
        level.add_order(order2)
        level.remove_order(order1)

        assert level.total_shares == 200
        assert level.order_count == 1

    def test_reduce_shares(self):
        """Test reducing shares in a price level."""
        level = PriceLevel(price_ticks=1500000)
        order = Order(1, "AAPL", "B", 1500000, 100, 0)
        level.add_order(order)

        level.reduce_shares(order, 30)
        assert order.shares == 70
        assert level.total_shares == 70

    def test_reduce_shares_removes_empty_order(self):
        """Test that reducing all shares removes the order."""
        level = PriceLevel(price_ticks=1500000)
        order = Order(1, "AAPL", "B", 1500000, 100, 0)
        level.add_order(order)

        level.reduce_shares(order, 100)
        assert level.is_empty()
        assert level.order_count == 0


class TestOrderBook:
    """Tests for the OrderBook class."""

    def test_add_order(self):
        """Test adding an order to the book."""
        book = OrderBook()
        result = book.add_order(
            order_id=1,
            ticker="AAPL",
            side="B",
            price_ticks=1500000,
            shares=100,
            timestamp_ns=0,
        )
        assert result is True
        assert book.has_order(1)
        assert book.get_ticker(1) == "AAPL"

    def test_add_duplicate_order_rejected(self):
        """Test that duplicate order IDs are rejected."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        result = book.add_order(1, "AAPL", "B", 1500000, 200, 0)
        assert result is False

    def test_get_ticker_returns_none_for_unknown(self):
        """Test that get_ticker returns None for unknown orders."""
        book = OrderBook()
        assert book.get_ticker(999) is None

    def test_cancel_shares(self):
        """Test cancelling shares from an order."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        
        result = book.cancel_shares(1, 30, 1000)
        assert result is True
        
        # Order should still exist with reduced shares
        assert book.has_order(1)

    def test_cancel_all_shares_removes_order(self):
        """Test that cancelling all shares removes the order."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        
        book.cancel_shares(1, 100, 1000)
        assert not book.has_order(1)

    def test_delete_order(self):
        """Test deleting an order entirely."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        
        result = book.delete_order(1, 1000)
        assert result is True
        assert not book.has_order(1)

    def test_delete_unknown_order(self):
        """Test deleting an unknown order returns False."""
        book = OrderBook()
        result = book.delete_order(999, 1000)
        assert result is False

    def test_execute_shares(self):
        """Test executing shares from an order."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        
        result = book.execute_shares(1, 50, 1000)
        assert result is True
        assert book.has_order(1)

    def test_execute_all_shares_removes_order(self):
        """Test that executing all shares removes the order."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        
        book.execute_shares(1, 100, 1000)
        assert not book.has_order(1)

    def test_replace_order_updates_price_and_id(self):
        """Replace should move order to new ID and new price while preserving side/ticker."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)

        replaced = book.replace_order(
            original_order_id=1,
            new_order_id=2,
            shares=80,
            price_ticks=1510000,
            timestamp_ns=1000,
        )

        assert replaced is True
        assert not book.has_order(1)
        assert book.has_order(2)
        assert book.get_ticker(2) == "AAPL"

        best_bid, best_ask = book.get_bbo()
        assert best_bid == 1510000
        assert best_ask is None

        snapshot = book.get_snapshot()
        assert snapshot["statistics"]["replaces"] == 1

    def test_get_bbo_empty_book(self):
        """Test BBO on empty book returns None for both."""
        book = OrderBook()
        best_bid, best_ask = book.get_bbo()
        assert best_bid is None
        assert best_ask is None

    def test_get_bbo_with_orders(self):
        """Test BBO with bid and ask orders."""
        book = OrderBook()
        # Add bids
        book.add_order(1, "AAPL", "B", 1490000, 100, 0)  # $149.00
        book.add_order(2, "AAPL", "B", 1500000, 100, 0)  # $150.00 (best bid)
        # Add asks
        book.add_order(3, "AAPL", "S", 1510000, 100, 0)  # $151.00 (best ask)
        book.add_order(4, "AAPL", "S", 1520000, 100, 0)  # $152.00

        best_bid, best_ask = book.get_bbo()
        assert best_bid == 1500000
        assert best_ask == 1510000

    def test_get_depth(self):
        """Test getting depth of book."""
        book = OrderBook()
        # Add multiple bid levels
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        book.add_order(2, "AAPL", "B", 1490000, 200, 0)
        book.add_order(3, "AAPL", "B", 1480000, 150, 0)
        # Add multiple ask levels
        book.add_order(4, "AAPL", "S", 1510000, 100, 0)
        book.add_order(5, "AAPL", "S", 1520000, 200, 0)

        depth = book.get_depth(levels=2)
        
        assert len(depth["bids"]) == 2
        assert len(depth["asks"]) == 2
        
        # Best bid should be first
        assert depth["bids"][0]["price_ticks"] == 1500000
        assert depth["bids"][1]["price_ticks"] == 1490000
        
        # Best ask should be first
        assert depth["asks"][0]["price_ticks"] == 1510000
        assert depth["asks"][1]["price_ticks"] == 1520000

    def test_get_snapshot(self):
        """Test getting a full snapshot."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        book.add_order(2, "AAPL", "S", 1510000, 100, 0)

        snapshot = book.get_snapshot()
        
        assert "timestamp" in snapshot
        assert "bbo" in snapshot
        assert "depth" in snapshot
        assert "statistics" in snapshot
        assert "ui" not in snapshot

        assert snapshot["bbo"]["best_bid_qty"] == 100
        assert snapshot["bbo"]["best_ask_qty"] == 100
        
        assert snapshot["statistics"]["adds"] == 2
        assert snapshot["statistics"]["total_orders"] == 2

    def test_snapshot_without_orders_has_null_bbo(self):
        """Snapshot should not fabricate BBO values when book is empty."""
        book = OrderBook()
        snap = book.get_snapshot()

        bbo = snap["bbo"]
        assert bbo["best_bid_ticks"] is None
        assert bbo["best_ask_ticks"] is None
        assert bbo["best_bid_qty"] is None
        assert bbo["best_ask_qty"] is None
        assert bbo["spread_ticks"] is None
        assert bbo["spread_dollars"] is None

    def test_save_snapshot(self):
        """Test saving snapshot to file."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)

        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            path = Path(f.name)

        try:
            book.save_snapshot(path)
            
            with path.open() as f:
                data = json.load(f)
            
            assert data["statistics"]["adds"] == 1
            assert data["bbo"]["best_bid_ticks"] == 1500000
        finally:
            path.unlink()

    def test_price_level_cleanup_on_cancel(self):
        """Test that empty price levels are cleaned up after cancel."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        
        # Cancel all shares
        book.cancel_shares(1, 100, 1000)
        
        # Verify price level is removed
        assert len(book._bids) == 0

    def test_multiple_orders_same_price(self):
        """Test multiple orders at the same price level."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        book.add_order(2, "AAPL", "B", 1500000, 200, 0)
        book.add_order(3, "AAPL", "B", 1500000, 150, 0)

        # Should be one price level with total shares
        depth = book.get_depth(levels=10)
        assert len(depth["bids"]) == 1
        assert depth["bids"][0]["total_shares"] == 450
        assert depth["bids"][0]["order_count"] == 3

    def test_statistics_tracking(self):
        """Test that statistics are tracked correctly."""
        book = OrderBook()
        
        # Add orders
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        book.add_order(2, "AAPL", "S", 1510000, 100, 0)
        
        # Cancel partial
        book.cancel_shares(1, 30, 1000)
        
        # Execute partial
        book.execute_shares(2, 50, 2000)
        
        # Delete remaining
        book.delete_order(1, 3000)

        snapshot = book.get_snapshot()
        stats = snapshot["statistics"]
        
        assert stats["adds"] == 2
        assert stats["cancels"] == 1
        assert stats["executes"] == 1
        assert stats["deletes"] == 1


class TestOrderBookTickerResolution:
    """Tests for orderbook ticker resolution feature."""

    def test_ticker_resolution_for_tracked_order(self):
        """Test that ticker can be resolved for tracked orders."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        
        assert book.get_ticker(1) == "AAPL"

    def test_ticker_resolution_after_partial_cancel(self):
        """Test ticker can still be resolved after partial cancel."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        book.cancel_shares(1, 30, 1000)
        
        # Order still exists
        assert book.get_ticker(1) == "AAPL"

    def test_ticker_resolution_after_full_cancel(self):
        """Test ticker returns None after order fully cancelled."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        book.cancel_shares(1, 100, 1000)
        
        # Order removed
        assert book.get_ticker(1) is None

    def test_ticker_resolution_after_delete(self):
        """Test ticker returns None after order deleted."""
        book = OrderBook()
        book.add_order(1, "AAPL", "B", 1500000, 100, 0)
        book.delete_order(1, 1000)
        
        assert book.get_ticker(1) is None
