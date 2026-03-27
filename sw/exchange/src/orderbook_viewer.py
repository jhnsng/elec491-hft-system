#!/usr/bin/env python3
"""Minimal high-performance orderbook snapshot viewer (Process B).

Run this as a separate process from data_forwarder to avoid impacting
forwarding latency/jitter in the hot path.

Example:
  python src/data_forwarder.py --config src/forwarder.yaml --orderbook
  python src/orderbook_viewer.py --snapshot-path src/orderbook_snapshot.json
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Live orderbook snapshot viewer")
    parser.add_argument(
        "--snapshot-path",
        type=Path,
        default=Path(__file__).with_name("orderbook_snapshot.json"),
        help="Path to orderbook snapshot JSON file",
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
        help="Max chart points kept for fallback history mode (default: 600)",
    )
    parser.add_argument(
        "--trend-window",
        type=int,
        default=25,
        help="Smoothing window size for PnL trend graph (default: 25)",
    )
    return parser.parse_args()


class SnapshotViewer:
    def __init__(self, snapshot_path: Path, refresh_ms: int, history: int, trend_window: int):
        # Lazy import to keep script import-safe in environments without GUI deps.
        from PyQt6 import QtCore, QtWidgets
        import pyqtgraph as pg

        self.QtCore = QtCore
        self.QtWidgets = QtWidgets
        self.pg = pg

        self.snapshot_path = snapshot_path
        self.refresh_ms = refresh_ms
        self.history = history
        self.trend_window = trend_window
        self._sample_dt_s = self.refresh_ms / 1000.0
        self._last_snapshot_wall_ts: Optional[float] = None

        self._last_mtime_ns: Optional[int] = None
        self._pnl_history: List[float] = []  # Rolling PnL datapoints
        self._pnl_time_history: List[float] = []
        self._snapshot_buffer: List[float] = []  # Buffer for smoothing snapshots
        self._pnl_trend_time_history: List[float] = []
        self._pnl_trend_history: List[float] = []  # Anchored since viewer start
        self._pnl_anchor: Optional[float] = None
        self._hit_rate_history: List[float] = []
        self._hit_rate_time_history: List[float] = []

        self.app = QtWidgets.QApplication(sys.argv)
        self.window = QtWidgets.QMainWindow()
        self.window.setWindowTitle("HFT Orderbook Viewer (Process B)")
        self.window.resize(1080, 720)

        root = QtWidgets.QWidget()
        self.window.setCentralWidget(root)
        layout = QtWidgets.QVBoxLayout(root)

        metrics = QtWidgets.QHBoxLayout()
        self.bid_label = QtWidgets.QLabel("Bid: -")
        self.ask_label = QtWidgets.QLabel("Ask: -")
        self.spread_label = QtWidgets.QLabel("Spread: -")
        self.pnl_label = QtWidgets.QLabel("PnL: -")
        self.hit_rate_label = QtWidgets.QLabel("Hit Rate: -")
        self.ts_label = QtWidgets.QLabel("Updated: -")

        for w in (
            self.bid_label,
            self.ask_label,
            self.spread_label,
            self.pnl_label,
            self.hit_rate_label,
            self.ts_label,
        ):
            w.setStyleSheet("font-size: 14px; padding: 4px 8px;")
            metrics.addWidget(w)

        layout.addLayout(metrics)

        # Charts in a splitter so user can resize
        splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        
        self.plot = pg.PlotWidget(title="PnL Cumulative")
        self.plot.showGrid(x=True, y=True, alpha=0.2)
        self.plot.setLabel("left", "Cumulative PnL ($)")
        self.plot.setLabel("bottom", "Time (s)")
        self.plot.setBackground("#111418")
        self.curve = self.plot.plot(pen=pg.mkPen(color="#4cc9f0", width=2))
        splitter.addWidget(self.plot)

        self.hist_plot = pg.PlotWidget(title="PnL Distribution")
        self.hist_plot.showGrid(x=True, y=True, alpha=0.2)
        self.hist_plot.setLabel("left", "Frequency")
        self.hist_plot.setLabel("bottom", "PnL Bucket ($)")
        self.hist_plot.setBackground("#111418")
        self.hist_bars = pg.BarGraphItem(x=[], height=[], width=[], brush=pg.mkBrush(color="#06ffa5", alpha=180))
        self.hist_plot.addItem(self.hist_bars)
        splitter.addWidget(self.hist_plot)

        self.hit_plot = pg.PlotWidget(title="Hit Rate Over Time")
        self.hit_plot.showGrid(x=True, y=True, alpha=0.2)
        self.hit_plot.setLabel("left", "Hit Rate (%)")
        self.hit_plot.setLabel("bottom", "Time (s)")
        self.hit_plot.setBackground("#111418")
        self.hit_curve = self.hit_plot.plot(pen=pg.mkPen(color="#ffd166", width=2))
        splitter.addWidget(self.hit_plot)

        splitter.setSizes([450, 450, 350])
        layout.addWidget(splitter)

        self.trend_plot = pg.PlotWidget(title="PnL Trend (Smoothed)")
        self.trend_plot.showGrid(x=True, y=True, alpha=0.2)
        self.trend_plot.setLabel("left", "Smoothed PnL ($)")
        self.trend_plot.setLabel("bottom", "Time (s)")
        self.trend_plot.setBackground("#111418")
        self.trend_curve = self.trend_plot.plot(pen=pg.mkPen(color="#ef476f", width=2))
        layout.addWidget(self.trend_plot)

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

    def _update_histogram(self) -> None:
        """Compute and update PnL distribution histogram."""
        if not self._pnl_history or len(self._pnl_history) < 2:
            return

        import numpy as np
        
        # Compute histogram with 15 bins
        counts, bin_edges = np.histogram(self._pnl_history, bins=15)
        
        # Bin centers for x-axis
        bin_centers = (bin_edges[:-1] + bin_edges[1:]) / 2
        bin_width = bin_edges[1] - bin_edges[0]
        
        # Update bar graph
        self.hist_bars.setOpts(
            x=bin_centers,
            height=counts,
            width=bin_width * 0.95,  # Slight gap between bars
        )
        
        # Auto-range both axes
        self.hist_plot.autoRange()

    def _update_hit_rate_plot(self) -> None:
        """Update hit-rate series and keep a tight y-range for visible deviations."""
        if not self._hit_rate_history or not self._hit_rate_time_history:
            self.hit_curve.setData([], [])
            return

        self.hit_curve.setData(self._hit_rate_time_history, self._hit_rate_history)

        # Keep a moving time window driven by actual retained history.
        self.hit_plot.setXRange(
            self._hit_rate_time_history[0],
            self._hit_rate_time_history[-1],
        )

        min_hr = min(self._hit_rate_history)
        max_hr = max(self._hit_rate_history)
        span = max_hr - min_hr
        if span < 0.5:
            # Avoid a visually flat line when variance is tiny.
            center = (max_hr + min_hr) / 2.0
            self.hit_plot.setYRange(center - 1.0, center + 1.0)
        else:
            pad = max(span * 0.15, 0.25)
            self.hit_plot.setYRange(min_hr - pad, max_hr + pad)

    def _update_pnl_trend_plot(self) -> None:
        """Plot smoothed anchored PnL trend since viewer start."""
        if not self._pnl_trend_history or not self._pnl_trend_time_history:
            self.trend_curve.setData([], [])
            return

        if len(self._pnl_trend_history) < 2:
            self.trend_curve.setData([self._pnl_trend_time_history[0]], [self._pnl_trend_history[0]])
            return

        window = max(2, min(self.trend_window, len(self._pnl_trend_history)))
        smoothed: List[float] = []
        running_sum = 0.0

        for i, v in enumerate(self._pnl_trend_history):
            running_sum += v
            if i >= window:
                running_sum -= self._pnl_trend_history[i - window]
            current_window = min(i + 1, window)
            smoothed.append(running_sum / current_window)

        self.trend_curve.setData(self._pnl_trend_time_history, smoothed)

        latest_t = self._pnl_trend_time_history[-1]
        if latest_t <= 120.0:
            self.trend_plot.setXRange(0.0, 120.0)
        else:
            self.trend_plot.setXRange(latest_t - 120.0, latest_t)

    def _refresh(self) -> None:
        snapshot = self._read_snapshot()
        if snapshot is None:
            return

        bbo = snapshot.get("bbo", {})
        ui = snapshot.get("ui", {})
        pnl = ui.get("pnl_live", {})
        execution_quality = ui.get("execution_quality", {})

        best_bid = bbo.get("best_bid_dollars")
        best_ask = bbo.get("best_ask_dollars")
        spread = bbo.get("spread_dollars")

        self.bid_label.setText(f"Bid: {self._format_price(best_bid)}")
        self.ask_label.setText(f"Ask: {self._format_price(best_ask)}")
        self.spread_label.setText(f"Spread: {self._format_price(spread)}")

        snapshot_ts = snapshot.get("timestamp")
        delta_snapshot_s: Optional[float] = None
        if isinstance(snapshot_ts, (int, float)):
            if self._last_snapshot_wall_ts is not None:
                delta_snapshot_s = max(float(snapshot_ts) - self._last_snapshot_wall_ts, 0.0)
            self._last_snapshot_wall_ts = float(snapshot_ts)

        series = pnl.get("series")
        frame_t: Optional[float] = None
        if isinstance(series, list) and series:
            y = [float(v) for v in series]
            # Keep original cadence by ingesting the full embedded series.
            self._snapshot_buffer.extend(y)
            point_dt = self._sample_dt_s
            if delta_snapshot_s is not None and len(y) > 0:
                point_dt = max(delta_snapshot_s / len(y), 1e-4)
            if self._pnl_time_history:
                t = self._pnl_time_history[-1]
            else:
                t = 0.0
            for _ in y:
                t += point_dt
                self._pnl_time_history.append(t)
            frame_t = t
            if len(self._snapshot_buffer) > self.history:
                self._snapshot_buffer = self._snapshot_buffer[-self.history :]
                self._pnl_time_history = self._pnl_time_history[-self.history :]
            self._pnl_history = self._snapshot_buffer[-self.history :]
        else:
            current = pnl.get("current")
            if isinstance(current, (int, float)):
                self._pnl_history.append(float(current))
                if self._pnl_time_history:
                    t = self._pnl_time_history[-1] + (delta_snapshot_s if delta_snapshot_s is not None else self._sample_dt_s)
                else:
                    t = 0.0
                self._pnl_time_history.append(t)
                frame_t = t
                self._snapshot_buffer.append(float(current))
                if len(self._pnl_history) > self.history:
                    self._pnl_history = self._pnl_history[-self.history :]
                    self._pnl_time_history = self._pnl_time_history[-self.history :]
                if len(self._snapshot_buffer) > self.history * 2:
                    self._snapshot_buffer = self._snapshot_buffer[-self.history * 2 :]

        if frame_t is None:
            if self._pnl_time_history:
                frame_t = self._pnl_time_history[-1]
            elif self._hit_rate_time_history:
                frame_t = self._hit_rate_time_history[-1] + (delta_snapshot_s if delta_snapshot_s is not None else self._sample_dt_s)
            else:
                frame_t = 0.0

        hit_rate_pct = execution_quality.get("hit_rate_pct")
        if isinstance(hit_rate_pct, (int, float)):
            hr = float(hit_rate_pct)
            self.hit_rate_label.setText(f"Hit Rate: {hr:.2f}%")
            self._hit_rate_history.append(hr)
            self._hit_rate_time_history.append(frame_t)
            if len(self._hit_rate_history) > self.history:
                self._hit_rate_history = self._hit_rate_history[-self.history :]
                self._hit_rate_time_history = self._hit_rate_time_history[-self.history :]
        else:
            self.hit_rate_label.setText("Hit Rate: -")

        if self._pnl_history:
            self.curve.setData(self._pnl_time_history, self._pnl_history)
            current_pnl = self._pnl_history[-1]
            self.pnl_label.setText(f"PnL: ${current_pnl:.2f}")

            self.plot.setXRange(self._pnl_time_history[0], self._pnl_time_history[-1])

            # Anchor trend at first observed PnL and persist history since start.
            if self._pnl_anchor is None:
                self._pnl_anchor = current_pnl
            self._pnl_trend_history.append(current_pnl - self._pnl_anchor)
            self._pnl_trend_time_history.append(self._pnl_time_history[-1])

            self._update_histogram()
            self._update_pnl_trend_plot()
        else:
            self.pnl_label.setText("PnL: -")
            self.trend_curve.setData([], [])

        self._update_hit_rate_plot()

        ts = snapshot.get("timestamp")
        if isinstance(ts, (int, float)):
            self.ts_label.setText(time.strftime("Updated: %H:%M:%S", time.localtime(ts)))
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
    if args.trend_window <= 1:
        raise SystemExit("--trend-window must be > 1")

    try:
        viewer = SnapshotViewer(args.snapshot_path, args.refresh_ms, args.history, args.trend_window)
    except ImportError as exc:
        raise SystemExit(
            "GUI dependencies missing. Install with: pip install pyqtgraph PyQt6"
        ) from exc

    raise SystemExit(viewer.run())


if __name__ == "__main__":
    main()
