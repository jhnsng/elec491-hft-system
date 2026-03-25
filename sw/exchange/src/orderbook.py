"""High-performance limit order book for ITCH feed processing.

Provides O(1) order lookup by ID for cancel/delete/execute operations,
and O(log N) price level operations using sorted containers.

Thread-safety model:
- Updates are single-threaded (called from main parse loop)
- Snapshots are protected by lock for async read access
"""
from __future__ import annotations

import json
import random
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

    The orderbook also provides ticker resolution for messages (D/E/X)
    that don't contain ticker fields.
    """

    def __init__(
        self,
        max_orders: int = 5_000_000,
        snapshot_depth: int = 10,
        placeholder_seed: int = 491,
    ):
        """Initialize the order book.

        Args:
            max_orders: Pre-allocation hint for expected order capacity
            snapshot_depth: Number of price levels to include in snapshots
        """
        self._max_orders = max_orders
        self._snapshot_depth = snapshot_depth
        self._placeholder_seed = int(placeholder_seed)
        self._snapshot_sequence = 0

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
        self._prev_mid_price_dollars: Optional[float] = None
        self._hit_rate_state_pct: float = 62.0

    def _build_ui_payload_unlocked(
        self,
        best_bid: Optional[int],
        best_ask: Optional[int],
        spread: Optional[int],
    ) -> Dict:
        """Build a UI-oriented payload with deterministic placeholders.

        The generator is seed-based so dashboards can render stable sample data
        while live fields are not yet populated.
        """
        self._snapshot_sequence += 1
        rng = random.Random((self._placeholder_seed * 1_000_003) + self._snapshot_sequence)

        # Real mid price if available, else deterministic placeholder.
        mid_price_dollars: float
        mid_price_placeholder = False
        if best_bid is not None and best_ask is not None:
            mid_price_dollars = (best_bid + best_ask) / 20000.0
        else:
            mid_price_dollars = rng.uniform(95.0, 205.0)
            mid_price_placeholder = True

        prev_mid = self._prev_mid_price_dollars
        if prev_mid is None or prev_mid <= 0:
            price_swing_bps = 0.0
        else:
            price_swing_bps = ((mid_price_dollars - prev_mid) / prev_mid) * 10_000.0
        self._prev_mid_price_dollars = mid_price_dollars

        spread_ticks = spread if spread is not None else rng.randint(1, 12)
        spread_placeholder = spread is None

        inventory_shares = rng.randint(-2500, 2500)
        latency_us = round(rng.uniform(35.0, 220.0), 2)

        # 60-point seeded PnL sparkline: small positive drift with occasional loss swings.
        # Generates realistic P&L that averages small profit with volatile dips.
        pnl_series: List[float] = []
        pnl_value = rng.uniform(50.0, 150.0)  # Start modestly positive
        for i in range(60):
            # 90% of the time: small profitable steps (-15 to +25, biased up)
            if rng.random() < 0.90:
                step = rng.uniform(-15.0, 25.0)
            else:
                # 10% of the time: moderate loss swings for realism
                step = rng.uniform(-100.0, -30.0)
            pnl_value += step
            pnl_series.append(round(pnl_value, 2))

        # Placeholder execution quality metrics: hit vs expired/cancelled.
        # Hit-rate deviations are linked to price swings/volatility so the
        # over-time chart shows stress periods during sharp moves.
        orders_placed = rng.randint(900, 1600)
        swing_penalty = min(abs(price_swing_bps) * 0.05, 5.5)
        spread_penalty = max(spread_ticks - 4, 0) * 0.12
        mean_revert = (61.0 - self._hit_rate_state_pct) * 0.18
        # Stronger base noise so hit-rate movement is visibly jagged.
        noise = rng.uniform(-5.5, 5.5)

        abs_swing_bps = abs(price_swing_bps)
        if abs_swing_bps >= 25.0:
            # During sharp moves, fills can collapse as quotes get stale.
            # Force a visible "tank" into 30-40% for demo realism.
            stressed = rng.uniform(30.0, 40.0) + rng.uniform(-4.0, 4.0)
            self._hit_rate_state_pct = min(max(stressed, 24.0), 48.0)
        else:
            shock = 0.0
            if abs_swing_bps > 12.0 and rng.random() < 0.45:
                shock = rng.uniform(-8.0, -1.5)
            elif abs_swing_bps < 8.0:
                shock = rng.uniform(0.5, 2.2)

            self._hit_rate_state_pct += mean_revert + noise + shock - swing_penalty - spread_penalty

            # Softly compress the high end to avoid a hard visual cutoff.
            if self._hit_rate_state_pct > 62.0:
                excess = self._hit_rate_state_pct - 62.0
                self._hit_rate_state_pct = 62.0 + (excess * 0.35)

            self._hit_rate_state_pct = min(max(self._hit_rate_state_pct, 22.0), 78.0)
        hit_rate_pct = self._hit_rate_state_pct
        orders_hit = int(round(orders_placed * (hit_rate_pct / 100.0)))
        orders_expired_cancelled = max(orders_placed - orders_hit, 0)

        placeholders: Dict[str, int | float] = {}
        if best_bid is None:
            placeholders["best_bid_ticks"] = rng.randint(950000, 2050000)
        if best_ask is None:
            bid_placeholder = placeholders.get("best_bid_ticks")
            if isinstance(bid_placeholder, int):
                bid_fallback = bid_placeholder
            else:
                bid_fallback = best_bid if best_bid is not None else 1000000
            placeholders["best_ask_ticks"] = bid_fallback + rng.randint(1, 20)
        if mid_price_placeholder:
            placeholders["mid_price_dollars"] = round(mid_price_dollars, 4)
        if spread_placeholder:
            placeholders["spread_ticks"] = spread_ticks

        return {
            "seed": self._placeholder_seed,
            "snapshot_sequence": self._snapshot_sequence,
            "mid_price_dollars": round(mid_price_dollars, 4),
            "spread_ticks": spread_ticks,
            "inventory_shares": inventory_shares,
            "latency_us": latency_us,
            "pnl_live": {
                "is_placeholder": True,
                "series": pnl_series,
                "current": pnl_series[-1] if pnl_series else 0.0,
            },
            "execution_quality": {
                "is_placeholder": True,
                "orders_placed": orders_placed,
                "orders_hit": orders_hit,
                "orders_expired_cancelled": orders_expired_cancelled,
                "hit_rate_pct": round((orders_hit / max(orders_placed, 1)) * 100.0, 2),
                "price_swing_bps": round(price_swing_bps, 2),
            },
            "placeholders": placeholders,
        }

    # -------------------------------------------------------------------------
    # Ticker resolution (for D/E/X messages that lack ticker field)
    # -------------------------------------------------------------------------

    def get_ticker(self, order_id: int) -> Optional[str]:
        """Resolve ticker symbol from order ID.

        Used by TickerFilter for messages (D/E/X) that don't contain ticker.

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
            ui_payload = self._build_ui_payload_unlocked(best_bid, best_ask, spread)

            return {
                "timestamp": time.time(),
                "itch_timestamp_ns": self._last_timestamp_ns,
                "bbo": {
                    "best_bid_ticks": best_bid,
                    "best_bid_dollars": best_bid / 10000.0 if best_bid else None,
                    "best_ask_ticks": best_ask,
                    "best_ask_dollars": best_ask / 10000.0 if best_ask else None,
                    "spread_ticks": spread,
                    "spread_dollars": spread / 10000.0 if spread else None,
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
                "ui": ui_payload,
            }

    # -------------------------------------------------------------------------
    # Snapshot persistence
    # -------------------------------------------------------------------------

    def save_snapshot(self, path: Path) -> None:
        """Save order book snapshot to JSON file.

        Args:
            path: Output file path
        """
        snapshot = self.get_snapshot()
        with path.open("w", encoding="utf-8") as f:
            json.dump(snapshot, f, indent=2)
        LOGGER.info("Saved orderbook snapshot to %s", path)

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
