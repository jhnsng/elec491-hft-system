#!/usr/bin/env python3
"""OUCH-centric exchange dashboard viewer (Process B).

Run this as a separate process from data_forwarder to avoid impacting
forwarding latency/jitter in the hot path.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Live HFT Trading System Dashboard Viewer")
    parser.add_argument(
        "--snapshot-path",
        type=Path,
        default=Path(__file__).with_name("orderbook_snapshot.json"),
        help="Path to runtime snapshot JSON file",
    )
    parser.add_argument(
        "--refresh-ms",
        type=int,
        default=200,
        help="Refresh interval in milliseconds (default: 200)",
    )
    parser.add_argument(
        "--history-seconds",
        type=int,
        default=120,
        help="Max time window kept for time-series panels in seconds (default: 120)",
    )
    return parser.parse_args()


class OuchDashboardViewer:
    def __init__(self, snapshot_path: Path, refresh_ms: int, history_seconds: int):
        # Lazy import to keep script import-safe in environments without GUI deps.
        from PyQt6 import QtCore, QtWidgets
        import pyqtgraph as pg

        self.QtCore = QtCore
        self.QtWidgets = QtWidgets
        self.pg = pg

        self.snapshot_path = snapshot_path
        self.refresh_ms = refresh_ms
        self.history_seconds = history_seconds
        self._start_wall_ts: Optional[float] = None

        self._last_mtime_ns: Optional[int] = None

        self._t_history: List[float] = []
        self._bid_price_history: List[float] = []
        self._ask_price_history: List[float] = []
        self._pnl_time_history: List[float] = []
        self._hit_rate_time_history: List[float] = []
        self._pnl_history: List[float] = []
        self._hit_rate_history: List[float] = []
        self._last_depth_prices: List[float] = []

        self.app = QtWidgets.QApplication(sys.argv)
        self.window = QtWidgets.QMainWindow()
        self.window.setWindowTitle("HFT Trading System LiveStats")
        self.window.resize(1200, 820)

        root = QtWidgets.QWidget()
        self.window.setCentralWidget(root)
        layout = QtWidgets.QVBoxLayout(root)

        metrics = QtWidgets.QGridLayout()
        self.bid_label = QtWidgets.QLabel("Bid: -")
        self.ask_label = QtWidgets.QLabel("Ask: -")
        self.spread_label = QtWidgets.QLabel("Spread: -")
        self.hit_rate_label = QtWidgets.QLabel("Board Hit Rate: -")
        self.pnl_label = QtWidgets.QLabel("Realized PnL: -")
        self.counts_label = QtWidgets.QLabel("Accepted/Executed/Canceled: -")
        self.ts_label = QtWidgets.QLabel("Updated: -")

        for w in (
            self.bid_label,
            self.ask_label,
            self.spread_label,
            self.hit_rate_label,
            self.pnl_label,
            self.counts_label,
            self.ts_label,
        ):
            w.setStyleSheet("font-size: 14px; padding: 4px 8px;")

        metrics.addWidget(self.bid_label, 0, 0)
        metrics.addWidget(self.ask_label, 0, 1)
        metrics.addWidget(self.spread_label, 0, 2)
        metrics.addWidget(self.hit_rate_label, 0, 3)
        metrics.addWidget(self.pnl_label, 1, 0)
        metrics.addWidget(self.counts_label, 1, 1, 1, 2)
        metrics.addWidget(self.ts_label, 1, 3)

        layout.addLayout(metrics)

        plots_splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)

        market_splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)

        self.volume_profile_plot = pg.PlotWidget(title="Price by Volume")
        self.volume_profile_plot.showGrid(x=True, y=True, alpha=0.2)
        self.volume_profile_plot.setLabel("left", "Price ($)")
        self.volume_profile_plot.setLabel("bottom", "Volume (shares)")
        self.volume_profile_plot.setBackground("#101417")
        self.volume_profile_plot.getViewBox().setMouseEnabled(x=False, y=False)
        self.bid_profile_bars = pg.BarGraphItem(
            x0=[],
            x1=[],
            y=[],
            height=[],
            brush=pg.mkBrush(30, 203, 123, 190),
            pen=pg.mkPen(color="#1ecb7b", width=1),
        )
        self.ask_profile_bars = pg.BarGraphItem(
            x0=[],
            x1=[],
            y=[],
            height=[],
            brush=pg.mkBrush(255, 107, 107, 190),
            pen=pg.mkPen(color="#ff6b6b", width=1),
        )
        self.volume_profile_plot.addItem(self.bid_profile_bars)
        self.volume_profile_plot.addItem(self.ask_profile_bars)
        market_splitter.addWidget(self.volume_profile_plot)

        self.best_price_plot = pg.PlotWidget(title="Best Bid / Ask Over Time")
        self.best_price_plot.showGrid(x=True, y=True, alpha=0.2)
        self.best_price_plot.setLabel("left", "Price ($)")
        self.best_price_plot.setLabel("bottom", "Time (s)")
        self.best_price_plot.setBackground("#101417")
        self.best_bid_curve = self.best_price_plot.plot(
            pen=pg.mkPen(color="#1ecb7b", width=2), name="Best Bid"
        )
        self.best_ask_curve = self.best_price_plot.plot(
            pen=pg.mkPen(color="#ff6b6b", width=2), name="Best Ask"
        )
        market_splitter.addWidget(self.best_price_plot)

        self.volume_profile_plot.setYLink(self.best_price_plot)
        market_splitter.setSizes([330, 870])
        plots_splitter.addWidget(market_splitter)

        perf_splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)

        self.pnl_plot = pg.PlotWidget(title="Realized PnL Over Time")
        self.pnl_plot.showGrid(x=True, y=True, alpha=0.2)
        self.pnl_plot.setLabel("left", "PnL ($)")
        self.pnl_plot.setLabel("bottom", "Time (s)")
        self.pnl_plot.setBackground("#101417")
        self.pnl_curve = self.pnl_plot.plot(
            pen=pg.mkPen(color="#ef476f", width=2),
            name="Realized PnL",
        )
        perf_splitter.addWidget(self.pnl_plot)

        self.hit_rate_plot = pg.PlotWidget(title="Board Hit Rate Over Time")
        self.hit_rate_plot.showGrid(x=True, y=True, alpha=0.2)
        self.hit_rate_plot.setLabel("left", "Hit Rate (%)")
        self.hit_rate_plot.setLabel("bottom", "Time (s)")
        self.hit_rate_plot.setBackground("#101417")
        self.hit_rate_curve = self.hit_rate_plot.plot(
            pen=pg.mkPen(color="#ffd166", width=2),
            name="Board Hit Rate",
        )
        perf_splitter.addWidget(self.hit_rate_plot)

        perf_splitter.setSizes([560, 560])
        plots_splitter.addWidget(perf_splitter)

        plots_splitter.setSizes([300, 280])
        layout.addWidget(plots_splitter)

        self.recent_orders_label = QtWidgets.QLabel("Recent OUCH Orders (last 10)")
        self.recent_orders_label.setStyleSheet("font-size: 14px; font-weight: 600; padding: 6px 8px;")
        layout.addWidget(self.recent_orders_label)

        self.orders_table = QtWidgets.QTableWidget(10, 8)
        self.orders_table.setHorizontalHeaderLabels(
            [
                "Time",
                "Symbol",
                "Side",
                "Qty",
                "Limit Px",
                "Status",
                "Exec Qty",
                "Exec Px",
            ]
        )
        self.orders_table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.orders_table.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.NoSelection)
        self.orders_table.setFocusPolicy(QtCore.Qt.FocusPolicy.NoFocus)
        self.orders_table.verticalHeader().setVisible(False)
        self.orders_table.horizontalHeader().setStretchLastSection(True)
        self.orders_table.setAlternatingRowColors(True)
        layout.addWidget(self.orders_table)

        self.status = QtWidgets.QLabel("Waiting for snapshot file...")
        self.status.setStyleSheet("font-size: 12px; color: #bcc3cf; padding: 4px 8px;")
        layout.addWidget(self.status)

        self.timer = QtCore.QTimer()
        self.timer.timeout.connect(self._refresh)
        self.timer.start(self.refresh_ms)

    def _read_snapshot(self) -> Optional[Dict[str, Any]]:
        if not self.snapshot_path.exists():
            self.status.setText(f"Snapshot missing: {self.snapshot_path}")
            return None

        try:
            stat = self.snapshot_path.stat()
            if self._last_mtime_ns is not None and stat.st_mtime_ns == self._last_mtime_ns:
                return None
            self._last_mtime_ns = stat.st_mtime_ns

            with self.snapshot_path.open("r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as exc:
            self.status.setText(f"Failed to read snapshot: {exc}")
            return None

    def _format_price(self, price: Any) -> str:
        if price is None:
            return "-"
        try:
            return f"${float(price):.4f}"
        except (TypeError, ValueError):
            return "-"

    def _format_ns_since_midnight(self, ts_ns: Any) -> str:
        if not isinstance(ts_ns, int):
            return "-"
        if ts_ns < 0:
            return "-"
        total_seconds, nanos = divmod(ts_ns, 1_000_000_000)
        hours, rem = divmod(total_seconds, 3600)
        minutes, seconds = divmod(rem, 60)
        millis = nanos // 1_000_000
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{millis:03d}"

    def _as_float_or_nan(self, value: Any) -> float:
        if value is None:
            return float("nan")
        try:
            return float(value)
        except (TypeError, ValueError):
            return float("nan")

    def _set_table_item(self, row: int, col: int, value: str) -> None:
        item = self.QtWidgets.QTableWidgetItem(value)
        self.orders_table.setItem(row, col, item)

    def _update_recent_orders(self, orders: List[Dict[str, Any]]) -> None:
        row_count = max(10, len(orders))
        self.orders_table.setRowCount(row_count)

        for row in range(row_count):
            if row < len(orders):
                entry = orders[row]
                self._set_table_item(row, 0, self._format_ns_since_midnight(entry.get("timestamp_ns")))
                self._set_table_item(row, 1, str(entry.get("symbol", "-")))
                self._set_table_item(row, 2, str(entry.get("side", "-")))
                self._set_table_item(row, 3, str(entry.get("quantity", "-")))
                self._set_table_item(row, 4, self._format_price(entry.get("limit_price_dollars")))
                self._set_table_item(row, 5, str(entry.get("status", "-")))

                exec_qty = entry.get("executed_qty")
                self._set_table_item(row, 6, str(exec_qty) if exec_qty is not None else "-")
                self._set_table_item(row, 7, self._format_price(entry.get("execution_price_dollars")))
            else:
                for col in range(8):
                    self._set_table_item(row, col, "")

    def _update_best_price_plot(
        self,
        rel_t: float,
        best_bid_dollars: Any,
        best_ask_dollars: Any,
    ) -> None:
        self._t_history.append(rel_t)
        self._bid_price_history.append(self._as_float_or_nan(best_bid_dollars))
        self._ask_price_history.append(self._as_float_or_nan(best_ask_dollars))

        cutoff = rel_t - self.history_seconds
        while self._t_history and self._t_history[0] < cutoff:
            self._t_history.pop(0)
            self._bid_price_history.pop(0)
            self._ask_price_history.pop(0)

        self.best_bid_curve.setData(self._t_history, self._bid_price_history)
        self.best_ask_curve.setData(self._t_history, self._ask_price_history)

        if self._t_history:
            self.best_price_plot.setXRange(self._t_history[0], self._t_history[-1])

        line_prices = [v for v in self._bid_price_history + self._ask_price_history if not math.isnan(v)]
        price_values = line_prices + self._last_depth_prices
        if price_values:
            p_min = min(price_values)
            p_max = max(price_values)
            pad = max((p_max - p_min) * 0.08, 0.01)
            self.best_price_plot.setYRange(p_min - pad, p_max + pad)

    def _update_price_volume_plot(self, depth: Any) -> None:
        if not isinstance(depth, dict):
            self._last_depth_prices = []
            return

        bid_levels = depth.get("bids", [])
        ask_levels = depth.get("asks", [])
        if not isinstance(bid_levels, list):
            bid_levels = []
        if not isinstance(ask_levels, list):
            ask_levels = []

        bid_prices: List[float] = []
        bid_volumes: List[float] = []
        ask_prices: List[float] = []
        ask_volumes: List[float] = []

        for level in bid_levels:
            if not isinstance(level, dict):
                continue
            price = self._as_float_or_nan(level.get("price_dollars"))
            volume = self._as_float_or_nan(level.get("total_shares"))
            if math.isnan(price) or math.isnan(volume):
                continue
            bid_prices.append(price)
            bid_volumes.append(max(0.0, volume))

        for level in ask_levels:
            if not isinstance(level, dict):
                continue
            price = self._as_float_or_nan(level.get("price_dollars"))
            volume = self._as_float_or_nan(level.get("total_shares"))
            if math.isnan(price) or math.isnan(volume):
                continue
            ask_prices.append(price)
            ask_volumes.append(max(0.0, volume))

        all_prices = bid_prices + ask_prices
        if not all_prices:
            self._last_depth_prices = []
            self.bid_profile_bars.setOpts(x0=[], x1=[], y=[], height=[])
            self.ask_profile_bars.setOpts(x0=[], x1=[], y=[], height=[])
            return

        self._last_depth_prices = all_prices

        sorted_prices = sorted(set(all_prices))
        if len(sorted_prices) >= 2:
            price_step = min(
                max(sorted_prices[i + 1] - sorted_prices[i], 1e-6)
                for i in range(len(sorted_prices) - 1)
            )
        else:
            price_step = max(sorted_prices[0] * 0.0002, 0.01)

        bar_height = max(price_step * 0.75, 0.002)
        offset = bar_height * 0.55

        bid_y = [p - offset for p in bid_prices]
        ask_y = [p + offset for p in ask_prices]

        self.bid_profile_bars.setOpts(
            x0=[0.0] * len(bid_prices),
            x1=bid_volumes,
            y=bid_y,
            height=[bar_height] * len(bid_prices),
        )
        self.ask_profile_bars.setOpts(
            x0=[0.0] * len(ask_prices),
            x1=ask_volumes,
            y=ask_y,
            height=[bar_height] * len(ask_prices),
        )

        max_volume = max(bid_volumes + ask_volumes + [1.0])
        self.volume_profile_plot.setXRange(0.0, max_volume * 1.12)

    def _update_performance_plot(self, realized_pnl: Any, hit_rate_pct: Any) -> None:
        rel_t = self._t_history[-1] if self._t_history else 0.0

        if isinstance(realized_pnl, (int, float)):
            self._pnl_time_history.append(rel_t)
            self._pnl_history.append(float(realized_pnl))
        else:
            self._pnl_time_history.append(rel_t)
            self._pnl_history.append(float("nan"))

        if isinstance(hit_rate_pct, (int, float)):
            self._hit_rate_time_history.append(rel_t)
            self._hit_rate_history.append(float(hit_rate_pct))
        else:
            self._hit_rate_time_history.append(rel_t)
            self._hit_rate_history.append(float("nan"))

        cutoff = rel_t - self.history_seconds
        while self._pnl_time_history and self._pnl_time_history[0] < cutoff:
            self._pnl_time_history.pop(0)
            self._pnl_history.pop(0)
        while self._hit_rate_time_history and self._hit_rate_time_history[0] < cutoff:
            self._hit_rate_time_history.pop(0)
            self._hit_rate_history.pop(0)

        self.pnl_curve.setData(self._pnl_time_history, self._pnl_history)
        self.hit_rate_curve.setData(self._hit_rate_time_history, self._hit_rate_history)

        if self._pnl_time_history:
            self.pnl_plot.setXRange(self._pnl_time_history[0], self._pnl_time_history[-1])
        if self._hit_rate_time_history:
            self.hit_rate_plot.setXRange(self._hit_rate_time_history[0], self._hit_rate_time_history[-1])

        pnl_values = [v for v in self._pnl_history if not math.isnan(v)]
        if pnl_values:
            pnl_min = min(pnl_values)
            pnl_max = max(pnl_values)
            pnl_pad = max((pnl_max - pnl_min) * 0.12, 0.5)
            self.pnl_plot.setYRange(pnl_min - pnl_pad, pnl_max + pnl_pad)

        hit_values = [v for v in self._hit_rate_history if not math.isnan(v)]
        if hit_values:
            hr_min = min(hit_values)
            hr_max = max(hit_values)
            hr_span = max(hr_max - hr_min, 8.0)
            hr_center = (hr_min + hr_max) / 2.0
            lo = max(0.0, hr_center - hr_span * 0.6)
            hi = min(100.0, hr_center + hr_span * 0.6)
            self.hit_rate_plot.setYRange(lo, hi)
        else:
            self.hit_rate_plot.setYRange(0.0, 100.0)

    def _refresh(self) -> None:
        snapshot = self._read_snapshot()
        if snapshot is None:
            return

        bbo = snapshot.get("bbo", {})
        ouch = snapshot.get("ouch", {})
        metrics = ouch.get("metrics", {}) if isinstance(ouch, dict) else {}
        recent_orders = ouch.get("recent_orders", []) if isinstance(ouch, dict) else []

        best_bid = bbo.get("best_bid_dollars")
        best_ask = bbo.get("best_ask_dollars")
        spread = bbo.get("spread_dollars")
        best_bid_qty = bbo.get("best_bid_qty")
        best_ask_qty = bbo.get("best_ask_qty")

        bid_qty_txt = str(best_bid_qty) if isinstance(best_bid_qty, (int, float)) and not math.isnan(float(best_bid_qty)) else "-"
        ask_qty_txt = str(best_ask_qty) if isinstance(best_ask_qty, (int, float)) and not math.isnan(float(best_ask_qty)) else "-"
        self.bid_label.setText(f"Bid: {self._format_price(best_bid)} (qty {bid_qty_txt})")
        self.ask_label.setText(f"Ask: {self._format_price(best_ask)} (qty {ask_qty_txt})")
        self.spread_label.setText(f"Spread: {self._format_price(spread)}")

        snapshot_ts = snapshot.get("timestamp")
        if isinstance(snapshot_ts, (int, float)):
            if self._start_wall_ts is None:
                self._start_wall_ts = float(snapshot_ts)
            rel_t = max(float(snapshot_ts) - self._start_wall_ts, 0.0)
        elif self._t_history:
            rel_t = self._t_history[-1] + (self.refresh_ms / 1000.0)
        else:
            rel_t = 0.0

        self._update_price_volume_plot(snapshot.get("depth"))
        self._update_best_price_plot(rel_t, best_bid, best_ask)

        hit_rate_pct = metrics.get("hit_rate_pct")
        if isinstance(hit_rate_pct, (int, float)):
            self.hit_rate_label.setText(f"Board Hit Rate: {float(hit_rate_pct):.2f}%")
        else:
            self.hit_rate_label.setText("Board Hit Rate: -")

        realized_pnl = metrics.get("realized_pnl_dollars")
        if isinstance(realized_pnl, (int, float)):
            self.pnl_label.setText(f"Realized PnL: ${float(realized_pnl):.2f}")
        else:
            self.pnl_label.setText("Realized PnL: -")

        self._update_performance_plot(realized_pnl, hit_rate_pct)

        accepted = metrics.get("accepted_orders") if isinstance(metrics, dict) else None
        executed = metrics.get("executed_orders") if isinstance(metrics, dict) else None
        canceled = metrics.get("canceled_orders") if isinstance(metrics, dict) else None
        if all(isinstance(v, int) for v in (accepted, executed, canceled)):
            self.counts_label.setText(
                f"Accepted/Executed/Canceled: {accepted}/{executed}/{canceled}"
            )
        else:
            self.counts_label.setText("Accepted/Executed/Canceled: -")

        if isinstance(recent_orders, list):
            self._update_recent_orders(recent_orders[:10])
        else:
            self._update_recent_orders([])

        ts = snapshot.get("timestamp")
        if isinstance(ts, (int, float)):
            self.ts_label.setText(time.strftime("Updated: %H:%M:%S", time.localtime(ts)))
            age_s = max(time.time() - float(ts), 0.0)
            if age_s > max(2.0, self.refresh_ms / 1000.0 * 3.0):
                self.status.setText(f"Snapshot stale ({age_s:.2f}s old): {self.snapshot_path}")
            else:
                self.status.setText(f"Watching {self.snapshot_path}")
        else:
            self.ts_label.setText("Updated: -")
            self.status.setText(f"Watching {self.snapshot_path}")

    def run(self) -> int:
        self.window.show()
        return self.app.exec()


def main() -> None:
    args = _parse_args()
    if args.refresh_ms <= 0:
        raise SystemExit("--refresh-ms must be > 0")
    if args.history_seconds <= 0:
        raise SystemExit("--history-seconds must be > 0")

    try:
        viewer = OuchDashboardViewer(args.snapshot_path, args.refresh_ms, args.history_seconds)
    except ImportError as exc:
        raise SystemExit(
            "GUI dependencies missing. Install with: pip install pyqtgraph PyQt6"
        ) from exc

    raise SystemExit(viewer.run())


if __name__ == "__main__":
    main()
