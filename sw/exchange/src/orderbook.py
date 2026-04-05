"""High-performance limit order book for ITCH feed processing.

Provides O(1) order lookup by ID for cancel/delete/execute operations,
and O(log N) price level operations using sorted containers.

Thread-safety model:
- Updates are single-threaded (called from main parse loop)
- Snapshots are protected by lock for async read access
"""
from __future__ import annotations

import json
import logging
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Deque, Dict, List, Optional, Tuple

from sortedcontainers import SortedDict

LOGGER = logging.getLogger("orderbook")


###############################################################################
# Order representation
###############################################################################


@dataclass(slots=True)
class Order:
    """Single order in the book. Uses __slots__ for memory efficiency."""
    order_id: int
    ticker: str
    side: str  # 'B' (bid/buy) or 'S' (ask/sell)
    price_ticks: int  # Price in 1/10000 dollars
    shares: int  # Remaining quantity
    timestamp_ns: int  # ITCH timestamp (nanoseconds since midnight)


@dataclass
class PriceLevel:
    """Aggregated price level containing multiple orders at the same price."""
    price_ticks: int
    total_shares: int = 0
    order_count: int = 0
    orders: Deque[Order] = field(default_factory=deque)

    def add_order(self, order: Order) -> None:
        """Add an order to this price level."""
        self.orders.append(order)
        self.total_shares += order.shares
        self.order_count += 1

    def remove_order(self, order: Order) -> None:
        """Remove an order from this price level."""
        try:
            self.orders.remove(order)
            self.total_shares -= order.shares
            self.order_count -= 1
        except ValueError:
            LOGGER.warning("Order %s not found in price level %s", order.order_id, self.price_ticks)

    def reduce_shares(self, order: Order, qty: int) -> None:
        """Reduce shares for an order at this price level."""
        reduction = min(qty, order.shares)
        order.shares -= reduction
        self.total_shares -= reduction
        if order.shares <= 0:
            self.remove_order(order)
            # Re-add shares that were double-subtracted in remove_order
            self.total_shares += order.shares  # order.shares is now <= 0

    def is_empty(self) -> bool:
        """Check if this price level has no orders."""
        return self.order_count == 0


###############################################################################
# Order Book
###############################################################################


class OrderBook:
    """Limit order book with dual indexing for fast operations.

    Structure:
    - _orders: Dict[int, Order] for O(1) lookup by order ID
    - _bids: SortedDict[int, PriceLevel] sorted ascending (best bid = max key)
    - _asks: SortedDict[int, PriceLevel] sorted ascending (best ask = min key)

    The orderbook also provides ticker resolution for messages (C/D/E/U/X)
    that don't contain ticker fields.
    """

    def __init__(
        self,
        max_orders: int = 5_000_000,
        snapshot_depth: int = 10,
    ):
        """Initialize the order book.

        Args:
            max_orders: Pre-allocation hint for expected order capacity
            snapshot_depth: Number of price levels to include in snapshots
        """
        self._max_orders = max_orders
        self._snapshot_depth = snapshot_depth

        # Primary index: order_id -> Order (pre-sized dict)
        self._orders: Dict[int, Order] = {}

        # Price level indices using SortedDict for O(log N) operations
        # Bids: highest price is best (use negative key for natural max-first iteration)
        # Asks: lowest price is best (natural min-first iteration)
        self._bids: SortedDict = SortedDict()
        self._asks: SortedDict = SortedDict()

        # Statistics
        self._adds = 0
        self._cancels = 0
        self._deletes = 0
        self._executes = 0
        self._unknown_order_ids = 0

        # Snapshot state
        self._lock = threading.Lock()
        self._last_snapshot_time = 0.0
        self._last_timestamp_ns: Optional[int] = None

    # -------------------------------------------------------------------------
    # Ticker resolution (for C/D/E/U/X messages that lack ticker field)
    # -------------------------------------------------------------------------

    def get_ticker(self, order_id: int) -> Optional[str]:
        """Resolve ticker symbol from order ID.

        Used by TickerFilter for messages (C/D/E/U/X) that don't contain ticker.

        Args:
            order_id: The order reference number

        Returns:
            Ticker symbol if order exists, None otherwise
        """
        order = self._orders.get(order_id)
        return order.ticker if order else None

    def has_order(self, order_id: int) -> bool:
        """Check if an order ID exists in the book."""
        return order_id in self._orders

    # -------------------------------------------------------------------------
    # Order operations
    # -------------------------------------------------------------------------

    def add_order(
        self,
        order_id: int,
        ticker: str,
        side: str,
        price_ticks: int,
        shares: int,
        timestamp_ns: int,
    ) -> bool:
        """Add a new order to the book.

        Args:
            order_id: Unique order reference number
            ticker: Stock symbol
            side: 'B' for bid/buy, 'S' for ask/sell
            price_ticks: Price in 1/10000 dollars
            shares: Order quantity
            timestamp_ns: ITCH timestamp

        Returns:
            True if order was added, False if order_id already exists
        """
        if order_id in self._orders:
            LOGGER.debug("Duplicate order ID %s, ignoring", order_id)
            return False

        order = Order(
            order_id=order_id,
            ticker=ticker,
            side=side,
            price_ticks=price_ticks,
            shares=shares,
            timestamp_ns=timestamp_ns,
        )

        self._orders[order_id] = order
        self._add_to_price_level(order)
        self._adds += 1
        self._last_timestamp_ns = timestamp_ns
        return True

    def cancel_shares(self, order_id: int, cancelled_shares: int, timestamp_ns: int) -> bool:
        """Cancel (reduce) shares from an existing order.

        Args:
            order_id: Order reference number
            cancelled_shares: Number of shares to cancel
            timestamp_ns: ITCH timestamp

        Returns:
            True if order was found and updated, False otherwise
        """
        order = self._orders.get(order_id)
        if order is None:
            self._unknown_order_ids += 1
            return False

        price_level = self._get_price_level(order.side, order.price_ticks)
        if price_level is None:
            LOGGER.warning("Price level not found for order %s", order_id)
            self._unknown_order_ids += 1
            return False

        old_shares = order.shares
        price_level.reduce_shares(order, cancelled_shares)

        # If order fully cancelled, remove from orders dict
        if order.shares <= 0:
            del self._orders[order_id]

        # Clean up empty price level
        if price_level.is_empty():
            self._remove_price_level(order.side, order.price_ticks)

        self._cancels += 1
        self._last_timestamp_ns = timestamp_ns
        return True

    def delete_order(self, order_id: int, timestamp_ns: int) -> bool:
        """Delete an order entirely from the book.

        Args:
            order_id: Order reference number
            timestamp_ns: ITCH timestamp

        Returns:
            True if order was found and deleted, False otherwise
        """
        order = self._orders.get(order_id)
        if order is None:
            self._unknown_order_ids += 1
            return False

        price_level = self._get_price_level(order.side, order.price_ticks)
        if price_level:
            price_level.remove_order(order)
            if price_level.is_empty():
                self._remove_price_level(order.side, order.price_ticks)

        del self._orders[order_id]
        self._deletes += 1
        self._last_timestamp_ns = timestamp_ns
        return True

    def execute_shares(self, order_id: int, executed_shares: int, timestamp_ns: int) -> bool:
        """Execute (fill) shares from an existing order.

        Args:
            order_id: Order reference number
            executed_shares: Number of shares executed
            timestamp_ns: ITCH timestamp

        Returns:
            True if order was found and updated, False otherwise
        """
        order = self._orders.get(order_id)
        if order is None:
            self._unknown_order_ids += 1
            return False

        price_level = self._get_price_level(order.side, order.price_ticks)
        if price_level is None:
            LOGGER.warning("Price level not found for order %s", order_id)
            self._unknown_order_ids += 1
            return False

        price_level.reduce_shares(order, executed_shares)

        # If order fully executed, remove from orders dict
        if order.shares <= 0:
            del self._orders[order_id]

        # Clean up empty price level
        if price_level.is_empty():
            self._remove_price_level(order.side, order.price_ticks)

        self._executes += 1
        self._last_timestamp_ns = timestamp_ns
        return True

    def replace_order(
        self,
        original_order_id: int,
        new_order_id: int,
        shares: int,
        price_ticks: int,
        timestamp_ns: int,
    ) -> bool:
        """Cancel-replace an existing order with a new order reference number.

        Per ITCH U semantics, side/ticker attribution remains unchanged from the
        original order. Only order reference number, shares, and price are
        updated.

        Args:
            original_order_id: Existing order ID to replace
            new_order_id: Replacement order ID from ITCH U message
            shares: New total displayed shares for replacement order
            price_ticks: New display price for replacement order
            timestamp_ns: ITCH timestamp

        Returns:
            True if replace succeeded, False otherwise
        """
        original_order = self._orders.get(original_order_id)
        if original_order is None:
            self._unknown_order_ids += 1
            return False

        if new_order_id != original_order_id and new_order_id in self._orders:
            LOGGER.debug(
                "Duplicate replacement order ID %s for original %s, ignoring",
                new_order_id,
                original_order_id,
            )
            return False

        side = original_order.side
        ticker = original_order.ticker

        old_level = self._get_price_level(side, original_order.price_ticks)
        if old_level is not None:
            old_level.remove_order(original_order)
            if old_level.is_empty():
                self._remove_price_level(side, original_order.price_ticks)

        del self._orders[original_order_id]

        replacement_order = Order(
            order_id=new_order_id,
            ticker=ticker,
            side=side,
            price_ticks=price_ticks,
            shares=shares,
            timestamp_ns=timestamp_ns,
        )
        self._orders[new_order_id] = replacement_order
        self._add_to_price_level(replacement_order)

        # Replace is effectively one delete and one add in book state.
        self._deletes += 1
        self._adds += 1
        self._last_timestamp_ns = timestamp_ns
        return True

    # -------------------------------------------------------------------------
    # Price level helpers
    # -------------------------------------------------------------------------

    def _get_price_level(self, side: str, price_ticks: int) -> Optional[PriceLevel]:
        """Get the price level for a given side and price."""
        book = self._bids if side == "B" else self._asks
        return book.get(price_ticks)

    def _add_to_price_level(self, order: Order) -> None:
        """Add order to appropriate price level, creating if needed."""
        book = self._bids if order.side == "B" else self._asks
        price_ticks = order.price_ticks

        if price_ticks not in book:
            book[price_ticks] = PriceLevel(price_ticks=price_ticks)

        book[price_ticks].add_order(order)

    def _remove_price_level(self, side: str, price_ticks: int) -> None:
        """Remove an empty price level from the book."""
        book = self._bids if side == "B" else self._asks
        if price_ticks in book:
            del book[price_ticks]

    # -------------------------------------------------------------------------
    # BBO and depth queries (thread-safe for async reads)
    # -------------------------------------------------------------------------

    def get_bbo(self) -> Tuple[Optional[int], Optional[int]]:
        """Get best bid and best ask prices.

        Returns:
            Tuple of (best_bid_price, best_ask_price), either may be None
        """
        with self._lock:
            best_bid = self._bids.keys()[-1] if self._bids else None
            best_ask = self._asks.keys()[0] if self._asks else None
            return (best_bid, best_ask)

    def _get_depth_unlocked(self, levels: int) -> Dict[str, List[Dict]]:
        """Get depth without acquiring lock (for internal use when lock is held)."""
        # Bids: highest price first (reverse iteration)
        bid_levels = []
        for price_ticks in reversed(self._bids.keys()):
            if len(bid_levels) >= levels:
                break
            pl = self._bids[price_ticks]
            bid_levels.append({
                "price_ticks": price_ticks,
                "price_dollars": price_ticks / 10000.0,
                "total_shares": pl.total_shares,
                "order_count": pl.order_count,
            })

        # Asks: lowest price first (forward iteration)
        ask_levels = []
        for price_ticks in self._asks.keys():
            if len(ask_levels) >= levels:
                break
            pl = self._asks[price_ticks]
            ask_levels.append({
                "price_ticks": price_ticks,
                "price_dollars": price_ticks / 10000.0,
                "total_shares": pl.total_shares,
                "order_count": pl.order_count,
            })

        return {"bids": bid_levels, "asks": ask_levels}

    def get_depth(self, levels: int = 10) -> Dict[str, List[Dict]]:
        """Get top N price levels for each side.

        Args:
            levels: Number of price levels to return per side

        Returns:
            Dict with 'bids' and 'asks' lists of price level info
        """
        with self._lock:
            return self._get_depth_unlocked(levels)

    def get_snapshot(self) -> Dict:
        """Get full order book snapshot for logging/persistence.

        Returns:
            Dict containing BBO, depth, statistics, and metadata
        """
        with self._lock:
            best_bid, best_ask = None, None
            if self._bids:
                best_bid = self._bids.keys()[-1]
            if self._asks:
                best_ask = self._asks.keys()[0]

            spread = None
            if best_bid is not None and best_ask is not None:
                spread = best_ask - best_bid

            depth = self._get_depth_unlocked(self._snapshot_depth)
            best_bid_qty = depth["bids"][0]["total_shares"] if depth["bids"] else None
            best_ask_qty = depth["asks"][0]["total_shares"] if depth["asks"] else None

            return {
                "timestamp": time.time(),
                "itch_timestamp_ns": self._last_timestamp_ns,
                "bbo": {
                    "best_bid_ticks": best_bid,
                    "best_bid_dollars": best_bid / 10000.0 if best_bid is not None else None,
                    "best_bid_qty": best_bid_qty,
                    "best_ask_ticks": best_ask,
                    "best_ask_dollars": best_ask / 10000.0 if best_ask is not None else None,
                    "best_ask_qty": best_ask_qty,
                    "spread_ticks": spread,
                    "spread_dollars": spread / 10000.0 if spread is not None else None,
                },
                "depth": depth,
                "statistics": {
                    "total_orders": len(self._orders),
                    "bid_levels": len(self._bids),
                    "ask_levels": len(self._asks),
                    "adds": self._adds,
                    "cancels": self._cancels,
                    "deletes": self._deletes,
                    "executes": self._executes,
                    "unknown_order_ids": self._unknown_order_ids,
                },
            }

    # -------------------------------------------------------------------------
    # Snapshot persistence
    # -------------------------------------------------------------------------

    def save_snapshot(self, path: Path, extra: Optional[Dict] = None) -> None:
        """Save order book snapshot to JSON file.

        Args:
            path: Output file path
            extra: Optional extra top-level fields to merge into snapshot
        """
        snapshot = self.get_snapshot()
        if extra:
            snapshot.update(extra)
        with path.open("w", encoding="utf-8") as f:
            json.dump(snapshot, f, indent=2)

    def maybe_save_snapshot(self, path: Path, interval_s: float) -> bool:
        """Save snapshot if interval has elapsed since last save.

        Args:
            path: Output file path
            interval_s: Minimum seconds between snapshots

        Returns:
            True if snapshot was saved, False otherwise
        """
        now = time.monotonic()
        if now - self._last_snapshot_time >= interval_s:
            self.save_snapshot(path)
            self._last_snapshot_time = now
            return True
        return False

    def log_summary(self, logger: logging.Logger) -> None:
        """Log order book summary statistics."""
        snapshot = self.get_snapshot()
        stats = snapshot["statistics"]
        bbo = snapshot["bbo"]

        logger.info("=" * 80)
        logger.info("ORDER BOOK SUMMARY")
        logger.info("=" * 80)
        logger.info(
            "BBO: bid=$%.4f ask=$%.4f spread=$%.4f",
            bbo["best_bid_dollars"] or 0,
            bbo["best_ask_dollars"] or 0,
            bbo["spread_dollars"] or 0,
        )
        logger.info(
            "Levels: %d bid levels, %d ask levels",
            stats["bid_levels"],
            stats["ask_levels"],
        )
        logger.info("Active orders: %d", stats["total_orders"])
        logger.info(
            "Operations: adds=%d cancels=%d deletes=%d executes=%d",
            stats["adds"],
            stats["cancels"],
            stats["deletes"],
            stats["executes"],
        )
        if stats["unknown_order_ids"] > 0:
            logger.warning("Unknown order IDs (untracked tickers): %d", stats["unknown_order_ids"])
        logger.info("=" * 80)
