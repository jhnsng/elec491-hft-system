"""Shared OUCH metrics tracker for GUI-facing runtime snapshots.

This module aggregates OUCH order lifecycle events across all sessions and
produces a thread-safe snapshot containing:
- Last-N order statuses for dashboard tables
- Hit rate and order status counters
- Realized gross PnL using FIFO lot matching from executed trades
- Execution latency summary (p50/p95/p99)
"""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, List, Optional


@dataclass
class _Lot:
    qty: int
    price_ticks: int


@dataclass
class _TrackedOrder:
    user_ref_num: int
    symbol: str
    side: str
    quantity: int
    limit_price_ticks: int
    accepted_ts_ns: int
    status: str = "ACCEPTED"
    executed_qty: int = 0
    execution_price_ticks: Optional[int] = None
    execution_ts_ns: Optional[int] = None
    latency_us: Optional[float] = None


class OUCHMetricsTracker:
    """Aggregate OUCH events and expose a dashboard-friendly snapshot."""

    def __init__(self, recent_orders_limit: int = 10, latency_window: int = 4096):
        if recent_orders_limit <= 0:
            raise ValueError("recent_orders_limit must be > 0")
        if latency_window <= 0:
            raise ValueError("latency_window must be > 0")

        self._lock = threading.Lock()

        self._accepted_orders = 0
        self._executed_orders = 0
        self._canceled_orders = 0

        self._realized_pnl_dollars = 0.0
        self._long_lots: Deque[_Lot] = deque()
        self._short_lots: Deque[_Lot] = deque()

        self._orders: Dict[int, _TrackedOrder] = {}
        self._recent_order_ids: Deque[int] = deque(maxlen=recent_orders_limit)

        self._latencies_us: Deque[float] = deque(maxlen=latency_window)

    def on_accepted(
        self,
        *,
        user_ref_num: int,
        symbol: str,
        side: bytes,
        quantity: int,
        limit_price_ticks: int,
        accepted_ts_ns: int,
    ) -> None:
        with self._lock:
            normalized_side = self._normalize_side(side)
            self._orders[user_ref_num] = _TrackedOrder(
                user_ref_num=user_ref_num,
                symbol=symbol,
                side=normalized_side,
                quantity=quantity,
                limit_price_ticks=limit_price_ticks,
                accepted_ts_ns=accepted_ts_ns,
            )
            self._accepted_orders += 1
            self._touch_recent_unlocked(user_ref_num)

    def on_executed(
        self,
        *,
        user_ref_num: int,
        executed_qty: int,
        execution_price_ticks: int,
        execution_ts_ns: int,
    ) -> None:
        with self._lock:
            order = self._orders.get(user_ref_num)
            if order is None:
                # Keep snapshots robust even if an execution arrives without
                # a tracked accepted event (should be rare).
                order = _TrackedOrder(
                    user_ref_num=user_ref_num,
                    symbol="-",
                    side="UNKNOWN",
                    quantity=executed_qty,
                    limit_price_ticks=execution_price_ticks,
                    accepted_ts_ns=execution_ts_ns,
                )
                self._orders[user_ref_num] = order

            order.status = "EXECUTED"
            order.executed_qty = executed_qty
            order.execution_price_ticks = execution_price_ticks
            order.execution_ts_ns = execution_ts_ns

            if execution_ts_ns >= order.accepted_ts_ns:
                latency_us = (execution_ts_ns - order.accepted_ts_ns) / 1000.0
                order.latency_us = latency_us
                self._latencies_us.append(latency_us)

            self._executed_orders += 1
            self._apply_execution_to_pnl_unlocked(order.side, executed_qty, execution_price_ticks)
            self._touch_recent_unlocked(user_ref_num)

    def on_canceled(
        self,
        *,
        user_ref_num: int,
        canceled_qty: int,
        canceled_ts_ns: int,
    ) -> None:
        with self._lock:
            order = self._orders.get(user_ref_num)
            if order is None:
                return

            order.status = "CANCELED"
            order.execution_ts_ns = canceled_ts_ns
            # Keep executed_qty semantic clear: canceled orders are unfilled.
            order.executed_qty = 0 if order.status == "CANCELED" else order.executed_qty

            self._canceled_orders += 1
            self._touch_recent_unlocked(user_ref_num)

    def get_snapshot(self) -> Dict[str, object]:
        with self._lock:
            recent_orders: List[Dict[str, object]] = []
            for order_id in reversed(self._recent_order_ids):
                order = self._orders.get(order_id)
                if order is None:
                    continue
                recent_orders.append(
                    {
                        "user_ref_num": order.user_ref_num,
                        "timestamp_ns": order.execution_ts_ns or order.accepted_ts_ns,
                        "symbol": order.symbol,
                        "side": order.side,
                        "quantity": order.quantity,
                        "limit_price_ticks": order.limit_price_ticks,
                        "limit_price_dollars": round(order.limit_price_ticks / 10000.0, 4),
                        "status": order.status,
                        "executed_qty": order.executed_qty,
                        "execution_price_ticks": order.execution_price_ticks,
                        "execution_price_dollars": (
                            round(order.execution_price_ticks / 10000.0, 4)
                            if order.execution_price_ticks is not None
                            else None
                        ),
                        "latency_us": round(order.latency_us, 2) if order.latency_us is not None else None,
                    }
                )

            accepted = self._accepted_orders
            executed = self._executed_orders
            canceled = self._canceled_orders
            hit_rate = (executed / accepted * 100.0) if accepted > 0 else 0.0

            return {
                "recent_orders": recent_orders,
                "metrics": {
                    "accepted_orders": accepted,
                    "executed_orders": executed,
                    "canceled_orders": canceled,
                    "hit_rate_pct": round(hit_rate, 2),
                    "realized_pnl_dollars": round(self._realized_pnl_dollars, 2),
                    "open_position_shares": self._open_position_shares_unlocked(),
                    "latency_us": self._latency_summary_unlocked(),
                },
            }

    def _normalize_side(self, side: bytes) -> str:
        side_char = side.decode("ascii", errors="ignore")[:1]
        if side_char == "B":
            return "BUY"
        if side_char in {"S", "T", "E"}:
            return "SELL"
        return "UNKNOWN"

    def _touch_recent_unlocked(self, user_ref_num: int) -> None:
        try:
            self._recent_order_ids.remove(user_ref_num)
        except ValueError:
            pass
        self._recent_order_ids.append(user_ref_num)

    def _apply_execution_to_pnl_unlocked(self, side: str, qty: int, price_ticks: int) -> None:
        if qty <= 0:
            return
        if side == "BUY":
            self._apply_buy_fill_unlocked(qty, price_ticks)
            return
        if side == "SELL":
            self._apply_sell_fill_unlocked(qty, price_ticks)

    def _apply_buy_fill_unlocked(self, qty: int, price_ticks: int) -> None:
        remaining = qty
        while remaining > 0 and self._short_lots:
            lot = self._short_lots[0]
            matched = min(remaining, lot.qty)
            self._realized_pnl_dollars += ((lot.price_ticks - price_ticks) / 10000.0) * matched
            lot.qty -= matched
            remaining -= matched
            if lot.qty == 0:
                self._short_lots.popleft()

        if remaining > 0:
            self._long_lots.append(_Lot(qty=remaining, price_ticks=price_ticks))

    def _apply_sell_fill_unlocked(self, qty: int, price_ticks: int) -> None:
        remaining = qty
        while remaining > 0 and self._long_lots:
            lot = self._long_lots[0]
            matched = min(remaining, lot.qty)
            self._realized_pnl_dollars += ((price_ticks - lot.price_ticks) / 10000.0) * matched
            lot.qty -= matched
            remaining -= matched
            if lot.qty == 0:
                self._long_lots.popleft()

        if remaining > 0:
            self._short_lots.append(_Lot(qty=remaining, price_ticks=price_ticks))

    def _open_position_shares_unlocked(self) -> int:
        long_qty = sum(lot.qty for lot in self._long_lots)
        short_qty = sum(lot.qty for lot in self._short_lots)
        return long_qty - short_qty

    def _latency_summary_unlocked(self) -> Dict[str, Optional[float]]:
        if not self._latencies_us:
            return {"p50": None, "p95": None, "p99": None}

        sorted_lat = sorted(self._latencies_us)
        return {
            "p50": round(self._percentile_from_sorted(sorted_lat, 0.50), 2),
            "p95": round(self._percentile_from_sorted(sorted_lat, 0.95), 2),
            "p99": round(self._percentile_from_sorted(sorted_lat, 0.99), 2),
        }

    def _percentile_from_sorted(self, values: List[float], q: float) -> float:
        if not values:
            return 0.0
        if len(values) == 1:
            return values[0]
        position = q * (len(values) - 1)
        lo = int(position)
        hi = min(lo + 1, len(values) - 1)
        frac = position - lo
        return values[lo] + (values[hi] - values[lo]) * frac
