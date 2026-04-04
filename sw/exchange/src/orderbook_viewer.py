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
    parser = argparse.ArgumentParser(description="Live OUCH efficacy dashboard")
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
        "--history",
        type=int,
        default=600,
        help="Max chart points kept for top-of-book feeds (default: 600)",
    )
    return parser.parse_args()


class OuchDashboardViewer:
    def __init__(self, snapshot_path: Path, refresh_ms: int, history: int):
        # Lazy import to keep script import-safe in environments without GUI deps.
        from PyQt6 import QtCore, QtWidgets
        import pyqtgraph as pg

        self.QtCore = QtCore
        self.QtWidgets = QtWidgets
        self.pg = pg

        self.snapshot_path = snapshot_path
        self.refresh_ms = refresh_ms
        self.history = history
        self._start_wall_ts: Optional[float] = None

        self._last_mtime_ns: Optional[int] = None

        self._t_history: List[float] = []
        self._bid_price_history: List[float] = []
        self._ask_price_history: List[float] = []
        self._bid_qty_history: List[float] = []
        self._ask_qty_history: List[float] = []

        self.app = QtWidgets.QApplication(sys.argv)
        self.window = QtWidgets.QMainWindow()
        self.window.setWindowTitle("HFT OUCH Efficacy Dashboard (Process B)")
        self.window.resize(1200, 820)

        root = QtWidgets.QWidget()
        self.window.setCentralWidget(root)
        layout = QtWidgets.QVBoxLayout(root)

        metrics = QtWidgets.QGridLayout()
        self.bid_label = QtWidgets.QLabel("Bid: -")
        self.ask_label = QtWidgets.QLabel("Ask: -")
        self.spread_label = QtWidgets.QLabel("Spread: -")
        self.hit_rate_label = QtWidgets.QLabel("Hit Rate: -")
        self.pnl_label = QtWidgets.QLabel("Realized PnL: -")
        self.latency_label = QtWidgets.QLabel("Latency us (P50/P95/P99): -")
        self.counts_label = QtWidgets.QLabel("Accepted/Executed/Canceled: -")
        self.ts_label = QtWidgets.QLabel("Updated: -")

        for w in (
            self.bid_label,
            self.ask_label,
            self.spread_label,
            self.hit_rate_label,
            self.pnl_label,
            self.latency_label,
            self.counts_label,
            self.ts_label,
        ):
            w.setStyleSheet("font-size: 14px; padding: 4px 8px;")

        metrics.addWidget(self.bid_label, 0, 0)
        metrics.addWidget(self.ask_label, 0, 1)
        metrics.addWidget(self.spread_label, 0, 2)
        metrics.addWidget(self.hit_rate_label, 0, 3)
        metrics.addWidget(self.pnl_label, 1, 0)
        metrics.addWidget(self.latency_label, 1, 1, 1, 2)
        metrics.addWidget(self.counts_label, 1, 3)
        metrics.addWidget(self.ts_label, 2, 0, 1, 4)

        layout.addLayout(metrics)

        plots_splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Vertical)

        self.price_plot = pg.PlotWidget(title="Top of Book Prices")
        self.price_plot.showGrid(x=True, y=True, alpha=0.2)
        self.price_plot.setLabel("left", "Price ($)")
        self.price_plot.setLabel("bottom", "Time (s)")
        self.price_plot.setBackground("#101417")
        self.bid_price_curve = self.price_plot.plot(
            pen=pg.mkPen(color="#1ecb7b", width=2), name="Best Bid"
        )
        self.ask_price_curve = self.price_plot.plot(
            pen=pg.mkPen(color="#ff6b6b", width=2), name="Best Ask"
        )
        plots_splitter.addWidget(self.price_plot)

        self.qty_plot = pg.PlotWidget(title="Top of Book Quantities")
        self.qty_plot.showGrid(x=True, y=True, alpha=0.2)
        self.qty_plot.setLabel("left", "Quantity (shares)")
        self.qty_plot.setLabel("bottom", "Time (s)")
        self.qty_plot.setBackground("#101417")
        self.bid_qty_curve = self.qty_plot.plot(
            pen=pg.mkPen(color="#4cc9f0", width=2), name="Best Bid Qty"
        )
        self.ask_qty_curve = self.qty_plot.plot(
            pen=pg.mkPen(color="#f9c74f", width=2), name="Best Ask Qty"
        )
        plots_splitter.addWidget(self.qty_plot)

        plots_splitter.setSizes([360, 280])
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

    def _update_orderbook_plots(
        self,
        rel_t: float,
        best_bid_dollars: Any,
        best_ask_dollars: Any,
        best_bid_qty: Any,
        best_ask_qty: Any,
    ) -> None:
        self._t_history.append(rel_t)
        self._bid_price_history.append(self._as_float_or_nan(best_bid_dollars))
        self._ask_price_history.append(self._as_float_or_nan(best_ask_dollars))
        self._bid_qty_history.append(self._as_float_or_nan(best_bid_qty))
        self._ask_qty_history.append(self._as_float_or_nan(best_ask_qty))

        if len(self._t_history) > self.history:
            self._t_history = self._t_history[-self.history :]
            self._bid_price_history = self._bid_price_history[-self.history :]
            self._ask_price_history = self._ask_price_history[-self.history :]
            self._bid_qty_history = self._bid_qty_history[-self.history :]
            self._ask_qty_history = self._ask_qty_history[-self.history :]

        self.bid_price_curve.setData(self._t_history, self._bid_price_history)
        self.ask_price_curve.setData(self._t_history, self._ask_price_history)
        self.bid_qty_curve.setData(self._t_history, self._bid_qty_history)
        self.ask_qty_curve.setData(self._t_history, self._ask_qty_history)

        if self._t_history:
            self.price_plot.setXRange(self._t_history[0], self._t_history[-1])
            self.qty_plot.setXRange(self._t_history[0], self._t_history[-1])

    def _format_latency_summary(self, latency: Dict[str, Any]) -> str:
        p50 = latency.get("p50")
        p95 = latency.get("p95")
        p99 = latency.get("p99")
        if p50 is None and p95 is None and p99 is None:
            return "-"
        return f"{p50 if p50 is not None else '-'} / {p95 if p95 is not None else '-'} / {p99 if p99 is not None else '-'}"

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

        self._update_orderbook_plots(rel_t, best_bid, best_ask, best_bid_qty, best_ask_qty)

        hit_rate_pct = metrics.get("hit_rate_pct")
        if isinstance(hit_rate_pct, (int, float)):
            self.hit_rate_label.setText(f"Hit Rate: {float(hit_rate_pct):.2f}%")
        else:
            self.hit_rate_label.setText("Hit Rate: -")

        realized_pnl = metrics.get("realized_pnl_dollars")
        if isinstance(realized_pnl, (int, float)):
            self.pnl_label.setText(f"Realized PnL: ${float(realized_pnl):.2f}")
        else:
            self.pnl_label.setText("Realized PnL: -")

        latency = metrics.get("latency_us") if isinstance(metrics, dict) else {}
        if isinstance(latency, dict):
            self.latency_label.setText(
                f"Latency us (P50/P95/P99): {self._format_latency_summary(latency)}"
            )
        else:
            self.latency_label.setText("Latency us (P50/P95/P99): -")

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
    if args.history <= 0:
        raise SystemExit("--history must be > 0")

    try:
        viewer = OuchDashboardViewer(args.snapshot_path, args.refresh_ms, args.history)
    except ImportError as exc:
        raise SystemExit(
            "GUI dependencies missing. Install with: pip install pyqtgraph PyQt6"
        ) from exc

    raise SystemExit(viewer.run())


if __name__ == "__main__":
    main()
