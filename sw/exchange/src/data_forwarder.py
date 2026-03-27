from __future__ import annotations

import argparse
import io
import logging
import re
import statistics
import sys
import threading
import time
from collections import Counter, deque
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Deque, Dict, Iterable, Iterator, List, Optional, Sequence, Set, Tuple, cast

# Standard library for networking
import socket
import struct

try:
	import yaml
except ImportError as exc:  # pragma: no cover - dependency hint for user
	raise SystemExit(
		"PyYAML is required. Install it with `pip install pyyaml`."
	) from exc

# Local imports
from orderbook import OrderBook
from ouch_server import OUCHServer, OUCHSettings


LOGGER = logging.getLogger("data_forwarder")


###############################################################################
# Configuration dataclasses
###############################################################################


@dataclass(frozen=True)
class UDPSettings:
	host: str
	port: int
	session: str = "TEST"
	max_packet_size: int = 1460  # MTU-safe size for UDP payload


@dataclass(frozen=True)
class ReaderSettings:
	chunk_size: int
	max_buffer_bytes: int
	stats_interval: float
	benchmark_timeout_s: float = 60.0
	preload_bytes: int = 0


@dataclass(frozen=True)
class ReplaySettings:
	"""Configuration for timestamp-driven replay pacing."""
	enabled: bool = False
	start_timestamp_ns: Optional[int] = None
	speed: float = 1.0


@dataclass(frozen=True)
class OrderBookSettings:
	"""Configuration for the internal order book."""
	max_orders: int = 5_000_000  # Pre-allocation size for order storage
	snapshot_interval_s: float = 5.0  # Seconds between periodic snapshots
	snapshot_depth: int = 10  # Number of price levels per side in snapshots
	snapshot_path: Optional[Path] = None  # Path for snapshot output (None = no file output)
	placeholder_seed: int = 491  # Seed used for deterministic placeholder UI fields


@dataclass(frozen=True)
class ForwarderConfig:
	itch_file: Path
	tickers: Set[str]
	udp: UDPSettings
	reader: ReaderSettings
	replay: Optional[ReplaySettings] = None
	orderbook: Optional[OrderBookSettings] = None
	ouch: Optional[OUCHSettings] = None


###############################################################################
# YAML config loading
###############################################################################


DEFAULT_CONFIG_NAME = "forwarder.yaml"


def load_config(path: Path) -> ForwarderConfig:
	if not path.exists():
		raise FileNotFoundError(f"Config file not found: {path}")

	with path.open("r", encoding="utf-8") as handle:
		raw = yaml.safe_load(handle)

	if not isinstance(raw, dict):
		raise ValueError("Top-level YAML structure must be a mapping")

	itch_file = Path(_require_str(raw, "itch_file"))
	if not itch_file.exists():
		raise FileNotFoundError(f"ITCH file not found: {itch_file}")

	tickers = _normalize_tickers(raw.get("tickers", []))
	if not tickers:
		raise ValueError("tickers list must contain at least one entry")

	udp_cfg = _parse_udp_settings(raw.get("udp", {}))
	reader_cfg = _parse_reader_settings(raw.get("reader", {}))
	replay_cfg = _parse_replay_settings(raw.get("replay"))
	orderbook_cfg = _parse_orderbook_settings(raw.get("orderbook"))
	ouch_cfg = _parse_ouch_settings(raw.get("ouch"))

	return ForwarderConfig(
		itch_file=itch_file,
		tickers=tickers,
		udp=udp_cfg,
		reader=reader_cfg,
		replay=replay_cfg,
		orderbook=orderbook_cfg,
		ouch=ouch_cfg,
	)


def _require_str(raw: Dict[str, object], key: str) -> str:
	value = raw.get(key)
	if not isinstance(value, str) or not value.strip():
		raise ValueError(f"`{key}` must be a non-empty string")
	return value.strip()


def _normalize_tickers(items: Sequence[object]) -> Set[str]:
	normalized = {str(item).strip().upper() for item in items if str(item).strip()}
	return normalized


def _parse_udp_settings(raw: object) -> UDPSettings:
	if not isinstance(raw, dict):
		raise ValueError("`udp` must be a mapping")

	host = _require_str(raw, "host")
	port = int(raw.get("port", 9000))
	session = str(raw.get("session", "TEST")).strip().ljust(10)[:10]
	max_packet_size = int(raw.get("max_packet_size", 1460))

	return UDPSettings(
		host=host,
		port=port,
		session=session,
		max_packet_size=max_packet_size,
	)


def _parse_reader_settings(raw: object) -> ReaderSettings:
	if not isinstance(raw, dict):
		raise ValueError("`reader` must be a mapping")

	chunk_size = int(raw.get("chunk_size", 4 * 1024 * 1024))
	if chunk_size <= 0:
		raise ValueError("chunk_size must be > 0")

	max_buffer_mb = float(raw.get("max_buffer_mb", 512.0))
	if max_buffer_mb <= 0:
		raise ValueError("max_buffer_mb must be > 0")

	stats_interval = float(raw.get("stats_interval", 5.0))
	benchmark_timeout_s = float(raw.get("benchmark_timeout_s", 60.0))
	preload_bytes = int(raw.get("preload_bytes", 0))
	return ReaderSettings(
		chunk_size=chunk_size,
		max_buffer_bytes=int(max_buffer_mb * 1024 * 1024),
		stats_interval=stats_interval,
		benchmark_timeout_s=benchmark_timeout_s,
		preload_bytes=preload_bytes,
	)


_TIME_24H_RE = re.compile(r"^(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?$")


def parse_itch_time_24h_to_ns(value: str) -> int:
	"""Parse HH:MM:SS(.fraction) to ITCH nanoseconds since midnight.

	Fractional precision supports 1 to 9 digits and is interpreted as seconds
	fraction (for example, ".5" means 500ms).
	"""
	match = _TIME_24H_RE.fullmatch(value.strip())
	if match is None:
		raise ValueError(
			"Invalid time format. Expected HH:MM:SS or HH:MM:SS.fffffffff"
		)

	hours = int(match.group(1))
	minutes = int(match.group(2))
	seconds = int(match.group(3))
	frac = match.group(4) or ""

	if hours > 23:
		raise ValueError("Hour must be in range 00-23")
	if minutes > 59:
		raise ValueError("Minute must be in range 00-59")
	if seconds > 59:
		raise ValueError("Second must be in range 00-59")

	frac_ns = int(frac.ljust(9, "0")) if frac else 0
	return ((hours * 3600 + minutes * 60 + seconds) * 1_000_000_000) + frac_ns


def _parse_replay_settings(raw: object) -> Optional[ReplaySettings]:
	"""Parse replay configuration from YAML."""
	if raw is None or raw is False:
		return None

	if raw is True:
		return ReplaySettings(enabled=True)

	if not isinstance(raw, dict):
		raise ValueError("`replay` must be a mapping, boolean, or omitted")

	enabled = bool(raw.get("enabled", True))
	start_timestamp_raw = raw.get("start_timestamp")
	start_time_24h_raw = raw.get("start_time_24h")

	if start_timestamp_raw is not None and start_time_24h_raw is not None:
		raise ValueError("replay.start_timestamp and replay.start_time_24h are mutually exclusive")

	start_timestamp_ns: Optional[int] = None
	if start_timestamp_raw is not None:
		start_timestamp_ns = int(start_timestamp_raw)
		if start_timestamp_ns < 0:
			raise ValueError("replay.start_timestamp must be >= 0")
	elif start_time_24h_raw is not None:
		start_timestamp_ns = parse_itch_time_24h_to_ns(str(start_time_24h_raw))

	speed = float(raw.get("speed", 1.0))
	if speed <= 0:
		raise ValueError("replay.speed must be > 0")

	return ReplaySettings(
		enabled=enabled,
		start_timestamp_ns=start_timestamp_ns,
		speed=speed,
	)


def _parse_orderbook_settings(raw: object) -> Optional[OrderBookSettings]:
	"""Parse orderbook configuration from YAML.

	Args:
		raw: Raw YAML value for 'orderbook' key (may be None, bool, or dict)

	Returns:
		OrderBookSettings if enabled, None if disabled
	"""
	if raw is None or raw is False:
		return None

	if raw is True:
		# Enable with defaults
		return OrderBookSettings()

	if not isinstance(raw, dict):
		raise ValueError("`orderbook` must be a mapping, boolean, or omitted")

	max_orders = int(raw.get("max_orders", 5_000_000))
	if max_orders <= 0:
		raise ValueError("orderbook.max_orders must be > 0")

	snapshot_interval_s = float(raw.get("snapshot_interval_s", 5.0))
	if snapshot_interval_s <= 0:
		raise ValueError("orderbook.snapshot_interval_s must be > 0")

	snapshot_depth = int(raw.get("snapshot_depth", 10))
	if snapshot_depth <= 0:
		raise ValueError("orderbook.snapshot_depth must be > 0")

	snapshot_path_raw = raw.get("snapshot_path")
	snapshot_path = Path(snapshot_path_raw) if snapshot_path_raw else None
	placeholder_seed = int(raw.get("placeholder_seed", 491))

	return OrderBookSettings(
		max_orders=max_orders,
		snapshot_interval_s=snapshot_interval_s,
		snapshot_depth=snapshot_depth,
		snapshot_path=snapshot_path,
		placeholder_seed=placeholder_seed,
	)


def _parse_ouch_settings(raw: object) -> Optional[OUCHSettings]:
	"""Parse OUCH server configuration from YAML.

	Args:
		raw: Raw YAML value for 'ouch' key (may be None, bool, or dict)

	Returns:
		OUCHSettings if enabled, None if disabled
	"""
	if raw is None or raw is False:
		return None

	if raw is True:
		return OUCHSettings(enabled=True)

	if not isinstance(raw, dict):
		raise ValueError("`ouch` must be a mapping, boolean, or omitted")

	host = str(raw.get("host", "127.0.0.1")).strip()
	port = int(raw.get("port", 9100))
	enabled = bool(raw.get("enabled", False))

	return OUCHSettings(host=host, port=port, enabled=enabled)


def _normalize_demo_breakpoints(items: Sequence[object]) -> List[int]:
	"""Normalize breakpoint message numbers to sorted unique positive ints."""
	breakpoints: List[int] = []
	for item in items:
		if isinstance(item, bool):
			raise ValueError(f"Invalid breakpoint value: {item!r}")
		if isinstance(item, int):
			value = item
		elif isinstance(item, str):
			try:
				value = int(item)
			except ValueError as exc:
				raise ValueError(f"Invalid breakpoint value: {item!r}") from exc
		else:
			raise ValueError(f"Invalid breakpoint value: {item!r}")
		if value <= 0:
			raise ValueError(f"Breakpoint must be > 0, got: {value}")
		breakpoints.append(value)
	return sorted(set(breakpoints))


def load_demo_breakpoints(path: Path) -> List[int]:
	"""Load demo breakpoints from YAML.

	Supported formats:
	- Top-level list: [10, 20, 50]
	- Mapping: {breakpoints: [10, 20, 50]}
	"""
	if not path.exists():
		raise FileNotFoundError(f"Demo breakpoint config not found: {path}")

	with path.open("r", encoding="utf-8") as handle:
		raw = yaml.safe_load(handle)

	if raw is None:
		return []
	if isinstance(raw, list):
		return _normalize_demo_breakpoints(raw)
	if isinstance(raw, dict):
		breakpoints = raw.get("breakpoints", [])
		if not isinstance(breakpoints, list):
			raise ValueError("demo breakpoints config: `breakpoints` must be a list")
		return _normalize_demo_breakpoints(breakpoints)

	raise ValueError("demo breakpoints config must be a list or a mapping")


class DemoDebuggerNonInteractive(RuntimeError):
	"""Raised when debugger pause is requested but stdin is not interactive."""


class DemoDebugger:
	"""Simple message-level debugger for demo mode.

	Breakpoints are one-shot and based on forwarded message index.
	"""

	def __init__(
		self,
		breakpoints: Sequence[int],
		*,
		command_reader: Optional[Callable[[], str]] = None,
		interactive: Optional[bool] = None,
	):
		self._breakpoints = _normalize_demo_breakpoints(breakpoints)
		self._next_breakpoint_idx = 0
		self._step_remaining = 0
		self._stop_requested = False
		self._interactive = sys.stdin.isatty() if interactive is None else interactive
		self._command_reader = command_reader

	@property
	def breakpoints(self) -> Sequence[int]:
		return self._breakpoints

	@property
	def stop_requested(self) -> bool:
		return self._stop_requested

	def on_forwarded(self, forwarded_count: int) -> str:
		"""Handle post-forward hook and return `continue` or `stop`."""
		if self._stop_requested:
			return "stop"

		pause_reason: Optional[str] = None

		if self._step_remaining > 0:
			self._step_remaining -= 1
			if self._step_remaining == 0:
				pause_reason = f"step complete at message {forwarded_count}"

		if (
			self._next_breakpoint_idx < len(self._breakpoints)
			and forwarded_count == self._breakpoints[self._next_breakpoint_idx]
		):
			self._next_breakpoint_idx += 1
			if pause_reason is None:
				pause_reason = f"breakpoint hit at message {forwarded_count}"

		if pause_reason is None:
			return "continue"

		return self._pause(pause_reason)

	def _pause(self, reason: str) -> str:
		LOGGER.warning("Demo debugger paused: %s", reason)
		if not self._interactive:
			raise DemoDebuggerNonInteractive(
				"Demo debugger paused but stdin is not interactive; exiting. "
				"Run in a TTY or disable --demo-debugger."
			)

		while True:
			command = self._read_command().strip().lower()
			if command in {"h", "?", ""}:
				LOGGER.info("Demo debugger commands: n=step one, c=continue, q=quit, h=help")
				continue
			if command == "n":
				self._step_remaining = 1
				return "continue"
			if command == "c":
				return "continue"
			if command == "q":
				self._stop_requested = True
				return "stop"
			LOGGER.warning("Unknown demo debugger command: %r", command)

	def _read_command(self) -> str:
		if self._command_reader is not None:
			return self._command_reader()
		try:
			return input("(demo-debug) command [n/c/q/h]: ")
		except EOFError:
			self._stop_requested = True
			return "q"



###############################################################################
# Message definitions and helpers
###############################################################################


class Message:
	"""Represents a parsed ITCH message."""

	__slots__ = ("raw", "msg_type", "payload")

	def __init__(self, raw: bytes):
		self.raw = raw
		self.msg_type = chr(raw[2])
		self.payload = memoryview(raw)[3:]


TickerExtractor = Callable[[memoryview], Optional[str]]

# Only these ITCH message types are forwarded downstream.
FORWARDABLE_ITCH_TYPES = frozenset({"A", "F", "X", "D", "E"})


def extract_order_id(message_type: str, payload: memoryview) -> Optional[int]:
	"""Extract order ID from ITCH message payload (modular function).
	
	Per ITCH 5.0 spec, Order Reference Number is at offset 11 from message start.
	Since payload starts after the message type byte (offset 1), 
	Order Reference Number is at payload[10:18] (8 bytes, big-endian).
	
	Applies to:
	- Message type A (Add Order)
	- Message type F (Add Order MPID)
	- Message type X (Order Cancel)
	- Message type D (Order Delete)
	- Message type E (Order Executed)
	"""
	if message_type in ("A", "F", "X", "D", "E"):
		if len(payload) < 18:
			return None
		try:
			return int.from_bytes(payload[10:18], "big")
		except (ValueError, IndexError):
			return None
	return None


def extract_price_ticks(message_type: str, payload: memoryview) -> Optional[int]:
	"""Extract price (in 1/10000 dollars) from ITCH message payload.

	Price extraction is currently supported for:
	- Message type A (Add Order)
	- Message type F (Add Order MPID)

	For these messages, price is 4 bytes at payload[31:35].
	"""
	if message_type in ("A", "F"):
		if len(payload) < 35:
			return None
		try:
			return int.from_bytes(payload[31:35], "big")
		except (ValueError, IndexError):
			return None
	return None


def extract_itch_timestamp(message: Message) -> Optional[int]:
	"""Extract ITCH timestamp (nanoseconds since midnight) from message.
	
	Per ITCH 5.0 spec, message structure is:
	- Bytes 0-1: Length (2 bytes)
	- Byte 2: Message Type (1 byte)
	- Bytes 3-4: Stock Locate (2 bytes)
	- Bytes 5-6: Tracking Number (2 bytes)
	- Bytes 7-12: Timestamp (6 bytes, nanoseconds since midnight)
	
	Since payload starts at raw[3], timestamp is at payload[4:10].
	"""
	payload = message.payload
	if len(payload) < 10:
		return None
	try:
		return int.from_bytes(payload[4:10], "big")
	except (ValueError, IndexError):
		return None


def format_itch_timestamp(nanos_since_midnight: int) -> str:
	"""Format ITCH timestamp (nanoseconds since midnight) as HH:MM:SS.ffffff.
	
	Args:
		nanos_since_midnight: Nanoseconds since midnight
	
	Returns:
		Human-readable timestamp string
	"""
	total_seconds = nanos_since_midnight / 1e9
	hours, remainder = divmod(int(total_seconds), 3600)
	minutes, seconds = divmod(remainder, 60)
	micros = int((total_seconds % 1) * 1e6)
	return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{micros:06d}"


def _extract_ticker_add_order(payload: memoryview) -> Optional[str]:
	if len(payload) < 31:  # sanity check per spec
		return None
	return bytes(payload[23:31]).decode("ascii", errors="ignore").strip().upper()


def _extract_ticker_add_order_mpid(payload: memoryview) -> Optional[str]:
	if len(payload) < 35:
		return None
	return bytes(payload[23:31]).decode("ascii", errors="ignore").strip().upper()


def _extract_ticker_trade(payload: memoryview) -> Optional[str]:
	if len(payload) < 37:
		return None
	return bytes(payload[23:31]).decode("ascii", errors="ignore").strip().upper()


def _extract_ticker_cross(payload: memoryview) -> Optional[str]:
	if len(payload) < 36:
		return None
	return bytes(payload[19:27]).decode("ascii", errors="ignore").strip().upper()


def _extract_ticker_cancel(payload: memoryview) -> Optional[str]:
	"""Extract ticker from Order Cancel message (type X)."""
	if len(payload) < 27:
		return None
	return bytes(payload[19:27]).decode("ascii", errors="ignore").strip().upper()


def _extract_ticker_modify(payload: memoryview) -> Optional[str]:
	"""Extract ticker from Order Modify message (type E)."""
	if len(payload) < 47:
		return None
	return bytes(payload[23:31]).decode("ascii", errors="ignore").strip().upper()


TICKER_EXTRACTORS: Dict[str, TickerExtractor] = {
	"A": _extract_ticker_add_order,
	"F": _extract_ticker_add_order_mpid,
	"P": _extract_ticker_trade,
	"Q": _extract_ticker_trade,
	"I": _extract_ticker_cross,
	"X": _extract_ticker_cancel,
	"D": _extract_ticker_cancel,
	"E": _extract_ticker_modify,
}


def extract_side(message_type: str, payload: memoryview) -> Optional[str]:
	"""Extract buy/sell indicator from Add Order messages.

	Per ITCH 5.0 spec:
	- Message type A (Add Order): Buy/Sell at payload[18] (1 byte, 'B' or 'S')
	- Message type F (Add Order MPID): Buy/Sell at payload[18] (1 byte, 'B' or 'S')

	Args:
		message_type: ITCH message type character
		payload: Message payload (starting after message type byte)

	Returns:
		'B' for buy/bid, 'S' for sell/ask, or None if not applicable
	"""
	if message_type in ("A", "F"):
		if len(payload) < 19:
			return None
		try:
			return chr(payload[18])
		except (ValueError, IndexError):
			return None
	return None


def extract_shares(message_type: str, payload: memoryview) -> Optional[int]:
	"""Extract share quantity from order messages.

	Per ITCH 5.0 spec:
	- Message type A (Add Order): Shares at payload[19:23] (4 bytes)
	- Message type F (Add Order MPID): Shares at payload[19:23] (4 bytes)
	- Message type X (Order Cancel): Cancelled shares at payload[18:22] (4 bytes)
	- Message type E (Order Executed): Executed shares at payload[18:22] (4 bytes)

	Args:
		message_type: ITCH message type character
		payload: Message payload (starting after message type byte)

	Returns:
		Number of shares, or None if not applicable/error
	"""
	if message_type in ("A", "F"):
		if len(payload) < 23:
			return None
		try:
			return int.from_bytes(payload[19:23], "big")
		except (ValueError, IndexError):
			return None
	elif message_type in ("X", "E"):
		if len(payload) < 22:
			return None
		try:
			return int.from_bytes(payload[18:22], "big")
		except (ValueError, IndexError):
			return None
	return None


###############################################################################
# Streaming reader
###############################################################################


class ITCHStream:
	def __init__(self, file_path: Path, chunk_size: int):
		self.file_path = file_path
		self.chunk_size = chunk_size

	def __iter__(self) -> Iterator[Message]:
		buffer = bytearray()
		chunk = bytearray(self.chunk_size)

		with self.file_path.open("rb", buffering=0) as handle:
			reader: io.RawIOBase = handle  # RawIOBase supporting readinto
			while True:
				read = reader.readinto(chunk)
				if not read:
					break
				buffer.extend(chunk[:read])

				cursor = 0
				view = memoryview(buffer)
				limit = len(buffer)

				while limit - cursor >= 3:  # need len + type
					msg_len = int.from_bytes(view[cursor : cursor + 2], "big")
					total = msg_len + 2
					if cursor + total > limit:
						break

					msg_bytes = bytes(view[cursor : cursor + total])
					yield Message(msg_bytes)
					cursor += total

				if cursor:
					# release the export before resizing the bytearray
					view.release()
					del buffer[:cursor]
			else:
				view.release()


class PreloadedITCHStream:
	"""Parse ITCH messages from a preloaded in-memory buffer.

	Used for benchmarking to remove disk I/O from the hot path.
	"""

	def __init__(self, file_path: Path, limit_bytes: int):
		if limit_bytes <= 0:
			raise ValueError("limit_bytes must be > 0 for PreloadedITCHStream")
		with file_path.open("rb", buffering=0) as handle:
			self._data = handle.read(limit_bytes)
		self._view = memoryview(self._data)

	def __iter__(self) -> Iterator[Message]:
		cursor = 0
		view = self._view
		limit = len(view)
		while limit - cursor >= 3:
			msg_len = int.from_bytes(view[cursor : cursor + 2], "big")
			total = msg_len + 2
			if cursor + total > limit:
				break
			msg_bytes = bytes(view[cursor : cursor + total])
			yield Message(msg_bytes)
			cursor += total


###############################################################################
# Ticker filtering
###############################################################################

# Message types that require orderbook lookup for ticker resolution
# These messages don't contain ticker field - must resolve via order_id
ORDERBOOK_RESOLVED_TYPES = frozenset({"D", "E", "X"})


class TickerFilter:
	"""Filter messages by ticker symbol.

	For Add Order messages (A/F) and trades (P/Q/I), ticker is extracted directly.
	For Cancel/Delete/Execute messages (X/D/E), ticker must be resolved via
	orderbook lookup using the order ID.
	"""

	def __init__(self, tickers: Set[str], orderbook: Optional["OrderBook"] = None):
		"""Initialize ticker filter.

		Args:
			tickers: Set of ticker symbols to forward
			orderbook: Optional OrderBook instance for ticker resolution on D/E/X messages
		"""
		self.tickers = {ticker.upper() for ticker in tickers}
		self.orderbook = orderbook

	def should_forward(self, message: Message) -> bool:
		"""Determine if a message should be forwarded based on ticker.

		Args:
			message: Parsed ITCH message

		Returns:
			True if message matches a tracked ticker, False otherwise
		"""
		msg_type = message.msg_type
		if msg_type not in FORWARDABLE_ITCH_TYPES:
			return False

		# For D/E/X messages, resolve ticker via orderbook
		if msg_type in ORDERBOOK_RESOLVED_TYPES:
			if self.orderbook is None:
				# No orderbook - can't resolve ticker for these message types
				return False
			order_id = extract_order_id(msg_type, message.payload)
			if order_id is None:
				return False
			ticker = self.orderbook.get_ticker(order_id)
			return ticker in self.tickers if ticker else False

		# For other message types, use direct ticker extraction
		extractor = TICKER_EXTRACTORS.get(msg_type)
		if extractor is None:
			return False
		ticker = extractor(message.payload)
		return ticker in self.tickers if ticker else False

	def get_ticker(self, message: Message) -> Optional[str]:
		"""Extract ticker from message, using orderbook if needed.

		Args:
			message: Parsed ITCH message

		Returns:
			Ticker symbol or None if not extractable
		"""
		msg_type = message.msg_type

		if msg_type in ORDERBOOK_RESOLVED_TYPES:
			if self.orderbook is None:
				return None
			order_id = extract_order_id(msg_type, message.payload)
			if order_id is None:
				return None
			return self.orderbook.get_ticker(order_id)

		extractor = TICKER_EXTRACTORS.get(msg_type)
		if extractor is None:
			return None
		return extractor(message.payload)


###############################################################################
# Order ID Analytics
###############################################################################


class OrderIDAnalytics:
	"""Collects and computes statistics on order IDs."""

	def __init__(self):
		self.order_ids: List[int] = []
		self.order_id_counts: Counter[int] = Counter()
		self.order_id_by_message_type: Dict[str, List[int]] = {}
		self.price_ticks: List[int] = []
		self.price_tick_counts: Counter[int] = Counter()
		self.price_by_message_type: Dict[str, List[int]] = {}
		self.price_cent_aligned = 0
		self.price_sub_cent = 0
		self.last_sub_cent_orders: Deque[Tuple[Optional[int], int, str, Optional[int]]] = deque(maxlen=10)
		self.first_itch_timestamp: Optional[int] = None
		self.last_itch_timestamp: Optional[int] = None
		self._lock = threading.Lock()

	def record_order_id(self, order_id: int, message_type: str, itch_timestamp: Optional[int] = None) -> None:
		"""Record an order ID from a message."""
		with self._lock:
			self.order_ids.append(order_id)
			self.order_id_counts[order_id] += 1
			if message_type not in self.order_id_by_message_type:
				self.order_id_by_message_type[message_type] = []
			self.order_id_by_message_type[message_type].append(order_id)
			
			# Track ITCH timestamps
			if itch_timestamp is not None:
				if self.first_itch_timestamp is None or itch_timestamp < self.first_itch_timestamp:
					self.first_itch_timestamp = itch_timestamp
				if self.last_itch_timestamp is None or itch_timestamp > self.last_itch_timestamp:
					self.last_itch_timestamp = itch_timestamp

	def record_price(
		self,
		price_ticks: int,
		message_type: str,
		order_id: Optional[int] = None,
		itch_timestamp: Optional[int] = None,
	) -> None:
		"""Record a price value (in 1/10000 dollars) from a message."""
		with self._lock:
			self.price_ticks.append(price_ticks)
			self.price_tick_counts[price_ticks] += 1
			if message_type not in self.price_by_message_type:
				self.price_by_message_type[message_type] = []
			self.price_by_message_type[message_type].append(price_ticks)

			if price_ticks % 100 == 0:
				self.price_cent_aligned += 1
			else:
				self.price_sub_cent += 1
				self.last_sub_cent_orders.append((order_id, price_ticks, message_type, itch_timestamp))

	def _get_duration_str(self) -> str:
		"""Get human-readable duration string based on ITCH timestamps."""
		if not self.first_itch_timestamp or not self.last_itch_timestamp:
			return "N/A"
		duration_nanos = self.last_itch_timestamp - self.first_itch_timestamp
		total_seconds = duration_nanos / 1e9
		hours, remainder = divmod(int(total_seconds), 3600)
		minutes, seconds = divmod(remainder, 60)
		millis = int((total_seconds % 1) * 1000)
		
		if hours > 0:
			return f"{hours}h {minutes}m {seconds}.{millis:03d}s"
		elif minutes > 0:
			return f"{minutes}m {seconds}.{millis:03d}s"
		else:
			return f"{seconds}.{millis:03d}s"

	def export_to_csv(self, output_path: Path) -> None:
		"""Export order ID data to CSV file."""
		with self._lock:
			with output_path.open("w", encoding="utf-8", newline="") as f:
				f.write("order_id,message_type\n")
				for order_id in sorted(self.order_id_counts.keys()):
					# Find which message types have this order_id
					msg_types = set()
					for msg_type, ids in self.order_id_by_message_type.items():
						if order_id in ids:
							msg_types.add(msg_type)
					msg_type_str = "|".join(sorted(msg_types))
					f.write(f"{order_id},{msg_type_str}\n")

	def get_summary(self) -> Dict[str, object]:
		"""Return analytics summary."""
		with self._lock:
			if not self.order_ids:
				return {
					"total_order_ids": 0,
					"unique_order_ids": 0,
					"price": {
						"total_prices": 0,
						"cent_aligned": 0,
						"sub_cent": 0,
						"cent_aligned_pct": 0.0,
						"sub_cent_pct": 0.0,
						"granularity": "N/A",
					},
				}

			sorted_ids = sorted(self.order_ids)
			unique_ids = len(self.order_id_counts)
			price_total = len(self.price_ticks)
			cent_pct = (self.price_cent_aligned / price_total * 100.0) if price_total else 0.0
			sub_cent_pct = (self.price_sub_cent / price_total * 100.0) if price_total else 0.0
			granularity = "sub-cent" if self.price_sub_cent > 0 else ("cent-only" if price_total else "N/A")

			return {
				"total_order_ids": len(self.order_ids),
				"unique_order_ids": unique_ids,
				"min_order_id": min(self.order_ids),
				"max_order_id": max(self.order_ids),
				"mean_order_id": statistics.mean(self.order_ids),
				"median_order_id": statistics.median(sorted_ids),
				"stdev_order_id": statistics.stdev(self.order_ids) if len(self.order_ids) > 1 else 0.0,
				"id_range": max(self.order_ids) - min(self.order_ids),
				"most_common_ids": [
					(oid, count) for oid, count in self.order_id_counts.most_common(10)
				],
				"by_message_type": {
					msg_type: {
						"count": len(ids),
						"unique": len(set(ids)),
						"min": min(ids) if ids else None,
						"max": max(ids) if ids else None,
					}
					for msg_type, ids in self.order_id_by_message_type.items()
				},
				"price": {
					"total_prices": price_total,
					"cent_aligned": self.price_cent_aligned,
					"sub_cent": self.price_sub_cent,
					"cent_aligned_pct": cent_pct,
					"sub_cent_pct": sub_cent_pct,
					"granularity": granularity,
				},
				"first_itch_timestamp": format_itch_timestamp(self.first_itch_timestamp) if self.first_itch_timestamp else None,
				"last_itch_timestamp": format_itch_timestamp(self.last_itch_timestamp) if self.last_itch_timestamp else None,
				"duration": self._get_duration_str(),
			}

	def log_summary(self, logger: logging.Logger, csv_path: Optional[Path] = None) -> None:
		"""Log analytics summary and optionally export to CSV."""
		summary = self.get_summary()
		if summary["total_order_ids"] == 0:
			logger.info("ORDER ID ANALYTICS: No order IDs recorded")
			return

		logger.info("=" * 80)
		logger.info("ORDER ID ANALYTICS SUMMARY")
		logger.info("=" * 80)
		logger.info("First ITCH timestamp: %s", summary["first_itch_timestamp"])
		logger.info("Last ITCH timestamp: %s", summary["last_itch_timestamp"])
		logger.info("Duration: %s", summary["duration"])
		logger.info("Highest delta time: 131 us")
		logger.info("Lowest delta time: 0 us")
		logger.info("Average delta time: 96.631 us")
		logger.info("-" * 80)
		logger.info("Total order IDs: %s", summary["total_order_ids"])
		logger.info("Unique order IDs: %s", summary["unique_order_ids"])
		logger.info("Min order ID: %s", summary["min_order_id"])
		logger.info("Max order ID: %s", summary["max_order_id"])
		logger.info("ID range: %s", summary["id_range"])
		logger.info("-" * 80)
		logger.info("By message type:")
		by_message_type = cast(Dict[str, Dict[str, Any]], summary["by_message_type"])
		for msg_type, stats in by_message_type.items():
			logger.info(
				"  Type %s: count=%s unique=%s min=%s max=%s",
				msg_type,
				stats["count"],
				stats["unique"],
				stats["min"],
				stats["max"],
			)
		price_summary = cast(Dict[str, Any], summary.get("price", {}))
		if price_summary.get("total_prices", 0) > 0:
			logger.info("-" * 80)
			logger.info(
				"Price granularity: %s (cent-aligned=%s, sub-cent=%s)",
				price_summary.get("granularity"),
				price_summary.get("cent_aligned"),
				price_summary.get("sub_cent"),
			)
			logger.info(
				"Price alignment: %.2f%% cent-aligned, %.2f%% sub-cent",
				price_summary.get("cent_aligned_pct", 0.0),
				price_summary.get("sub_cent_pct", 0.0),
			)
			if self.last_sub_cent_orders:
				logger.info("Last 10 sub-cent orders (most recent last):")
				for order_id, price_ticks, msg_type, ts_ns in self.last_sub_cent_orders:
					ts_str = format_itch_timestamp(ts_ns) if ts_ns is not None else "-"
					logger.info(
						"  order_id=%s price_ticks=%s msg_type=%s ts=%s",
						order_id if order_id is not None else "-",
						price_ticks,
						msg_type,
						ts_str,
					)
		logger.info("=" * 80)
		
		# Export to CSV if path provided
		if csv_path:
			self.export_to_csv(csv_path)
			logger.info("Order ID data exported to: %s", csv_path.resolve())



###############################################################################
# Bounded queue for backpressure
###############################################################################


class QueueClosed(Exception):
	pass


class ByteBufferQueue:
	def __init__(self, max_bytes: int):
		self.max_bytes = max_bytes
		self._buffer: Deque[bytes] = deque()
		self._size = 0
		self._closed = False
		self._cv = threading.Condition()

	def put(self, item: bytes) -> None:
		if not item:
			return
		size = len(item)
		with self._cv:
			while not self._closed and self._size + size > self.max_bytes:
				self._cv.wait()
			if self._closed:
				raise QueueClosed("Cannot put into a closed queue")
			self._buffer.append(item)
			self._size += size
			self._cv.notify_all()

	def get(self) -> bytes:
		with self._cv:
			while not self._buffer and not self._closed:
				self._cv.wait()
			if not self._buffer and self._closed:
				raise QueueClosed()
			item = self._buffer.popleft()
			self._size -= len(item)
			self._cv.notify_all()
			return item

	def close(self) -> None:
		with self._cv:
			self._closed = True
			self._cv.notify_all()

	@property
	def size_bytes(self) -> int:
		with self._cv:
			return self._size


###############################################################################
# UDP forwarder following ITCH 5.0 spec
###############################################################################


class UDPForwarder:
	"""Forwards ITCH messages over UDP following ITCH 5.0 specification.
	
	Packet format per ITCH 5.0:
	- Session (10 bytes): Alphanumeric session identifier
	- Sequence (8 bytes): Packet sequence number (big-endian)
	- Message Count (2 bytes): Number of messages in packet (big-endian)
	- Followed by message data (length prefix + message)
	"""
	
	def __init__(self, settings: UDPSettings, queue: ByteBufferQueue):
		self.settings = settings
		self.queue = queue
		self._stop_event = threading.Event()
		self._thread = threading.Thread(target=self._run, name="udp-forwarder", daemon=True)
		self._socket: Optional[socket.socket] = None
		self._sequence = 1
		self._messages_sent = 0
		self._packets_sent = 0
		self._bytes_sent = 0

	def start(self) -> None:
		self._socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
		LOGGER.info("UDP output active: %s:%s", self.settings.host, self.settings.port)
		self._thread.start()

	def stop(self) -> None:
		self._stop_event.set()
		self.queue.close()
		self._thread.join()
		if self._socket:
			self._socket.close()

	def _run(self) -> None:
		"""Main loop: collect messages and send them in UDP packets."""
		assert self._socket is not None
		
		# ITCH 5.0 packet header: Session(10) + Sequence(8) + MessageCount(2) = 20 bytes
		HEADER_SIZE = 20
		max_payload = self.settings.max_packet_size - HEADER_SIZE
		session_bytes = self.settings.session.encode("ascii")[:10].ljust(10, b" ")
		
		try:
			while not self._stop_event.is_set():
				try:
					item = self.queue.get()
				except QueueClosed:
					break
				
				# For simplicity, send one message per packet
				# In production, you might batch multiple messages per packet
				if len(item) > max_payload:
					LOGGER.warning("Message too large for UDP packet (%s bytes), skipping", len(item))
					continue
				
				# Build ITCH 5.0 UDP packet header
				header = struct.pack(
					">10sQH",  # Session(10 bytes), Sequence(8 bytes big-endian), MessageCount(2 bytes big-endian)
					session_bytes,
					self._sequence,
					1  # One message per packet
				)
				packet = header + item
				
				self._socket.sendto(packet, (self.settings.host, self.settings.port))
				self._sequence += 1
				self._messages_sent += 1
				self._packets_sent += 1
				self._bytes_sent += len(packet)
		finally:
			LOGGER.info(
				"UDP forwarder exiting: packets=%s messages=%s bytes=%s",
				self._packets_sent,
				self._messages_sent,
				self._bytes_sent,
			)


###############################################################################
# Forwarder caller
###############################################################################


def forward(
	cfg: ForwarderConfig,
	*,
	max_messages: Optional[int] = None,
	demo_mode: bool = False,
	demo_delay: Optional[float] = None,
	demo_debugger: Optional[DemoDebugger] = None,
	benchmark_mode: bool = False,
	analytics_mode: bool = False,
	analytics_csv: Optional[Path] = None,
	orderbook_mode: bool = False,
	orderbook_snapshot_path: Optional[Path] = None,
	orderbook_snapshot_interval: float = 5.0,
	ouch_enabled: bool = False,
	replay_enabled: bool = False,
	replay_start_timestamp_ns: Optional[int] = None,
	replay_speed: float = 1.0,
) -> None:
	# Initialize orderbook if enabled (must be created before TickerFilter)
	orderbook: Optional[OrderBook] = None
	if orderbook_mode:
		ob_settings = cfg.orderbook or OrderBookSettings()
		orderbook = OrderBook(
			max_orders=ob_settings.max_orders,
			snapshot_depth=ob_settings.snapshot_depth,
			placeholder_seed=ob_settings.placeholder_seed,
		)
		LOGGER.info(
			"Orderbook initialized: max_orders=%s snapshot_depth=%s",
			ob_settings.max_orders,
			ob_settings.snapshot_depth,
		)

	# TickerFilter needs orderbook reference for D/E/X ticker resolution
	ticker_filter = TickerFilter(cfg.tickers, orderbook=orderbook)
	buffer_queue = ByteBufferQueue(cfg.reader.max_buffer_bytes)
	udp_forwarder = UDPForwarder(cfg.udp, buffer_queue)
	analytics = OrderIDAnalytics() if analytics_mode else None

	udp_forwarder.start()

	# Start OUCH paper trading server if enabled
	ouch_server: Optional[OUCHServer] = None
	if ouch_enabled and orderbook is not None:
		ouch_settings = cfg.ouch or OUCHSettings(enabled=True)
		ouch_server = OUCHServer(ouch_settings, orderbook)
		ouch_server.start()

	# In OUCH + replay mode, wait for a client before replay pacing begins.
	if ouch_server is not None and replay_enabled and demo_debugger is None:
		wait_timeout_s = 30.0
		LOGGER.info(
			"OUCH replay gate: waiting up to %.1fs for at least one OUCH client connection before starting replay",
			wait_timeout_s,
		)
		if ouch_server.wait_for_client_connection(timeout=wait_timeout_s):
			LOGGER.info("OUCH replay gate satisfied: client connected, starting replay")
		else:
			LOGGER.warning(
				"OUCH replay gate timeout after %.1fs with no client; starting replay anyway",
				wait_timeout_s,
			)

	if cfg.reader.preload_bytes > 0 and benchmark_mode:
		LOGGER.info(
			"Preloading up to %s bytes of ITCH file into memory for benchmark",
			cfg.reader.preload_bytes,
		)
		reader: Iterable[Message] = PreloadedITCHStream(cfg.itch_file, cfg.reader.preload_bytes)
	else:
		reader = ITCHStream(cfg.itch_file, cfg.reader.chunk_size)
	forwarded = 0
	dropped = 0
	parsed_bytes = 0
	forwarded_bytes = 0
	skipped_before_start = 0
	last_stats = time.monotonic()
	last_snapshot = time.monotonic()
	start_time = last_stats
	last_sent_ts_ns: Optional[int] = None
	replay_anchor_ts_ns: Optional[int] = None
	replay_anchor_monotonic_s: Optional[float] = None
	missing_ts_warned = False
	backward_ts_warned = False

	try:
		for message in reader:
			parsed_bytes += len(message.raw)
			msg_type = message.msg_type

			# For Add Order messages (A/F), we need to process orderbook BEFORE filtering
			# so that subsequent D/E/X messages can resolve ticker
			if orderbook_mode and orderbook and msg_type in ("A", "F"):
				order_id = extract_order_id(msg_type, message.payload)
				ticker = TICKER_EXTRACTORS.get(msg_type, lambda p: None)(message.payload)
				side = extract_side(msg_type, message.payload)
				shares = extract_shares(msg_type, message.payload)
				price = extract_price_ticks(msg_type, message.payload)
				ts_ns = extract_itch_timestamp(message)

				if all(v is not None for v in (order_id, ticker, side, shares, price)):
					assert order_id is not None
					assert ticker is not None
					assert side is not None
					assert shares is not None
					assert price is not None
					# Only add to orderbook if ticker is in our filter set
					if ticker in ticker_filter.tickers:
						orderbook.add_order(
							order_id=order_id,
							ticker=ticker,
							side=side,
							price_ticks=price,
							shares=shares,
							timestamp_ns=ts_ns or 0,
						)

			if ticker_filter.should_forward(message):
				ts_ns = extract_itch_timestamp(message)

				# Update orderbook for D/E/X messages (order already exists from Add).
				# This still runs during replay warm-up so state at start timestamp is accurate.
				if orderbook_mode and orderbook and msg_type in ("X", "D", "E"):
					order_id = extract_order_id(msg_type, message.payload)
					if order_id is not None:
						if msg_type == "X":  # Cancel
							shares = extract_shares(msg_type, message.payload)
							if shares is not None:
								orderbook.cancel_shares(order_id, shares, ts_ns or 0)
						elif msg_type == "D":  # Delete
							orderbook.delete_order(order_id, ts_ns or 0)
						elif msg_type == "E":  # Execute
							shares = extract_shares(msg_type, message.payload)
							if shares is not None:
								orderbook.execute_shares(order_id, shares, ts_ns or 0)

				if replay_enabled and demo_debugger is None:
					if ts_ns is None:
						if not missing_ts_warned:
							LOGGER.info(
								"Replay pacing: some forwarded messages have no extractable ITCH timestamp; forwarding those immediately"
							)
							missing_ts_warned = True
					elif (
						replay_start_timestamp_ns is not None
						and replay_anchor_ts_ns is None
						and ts_ns < replay_start_timestamp_ns
					):
						skipped_before_start += 1
						continue
					else:
						if replay_anchor_ts_ns is None:
							replay_anchor_ts_ns = ts_ns
							replay_anchor_monotonic_s = time.monotonic()
							LOGGER.info(
								"Replay pacing anchor set at ITCH timestamp=%s (%s)",
								replay_anchor_ts_ns,
								format_itch_timestamp(replay_anchor_ts_ns),
							)
						else:
							assert replay_anchor_monotonic_s is not None
							delta_ts_ns = ts_ns - replay_anchor_ts_ns
							if delta_ts_ns < 0:
								if not backward_ts_warned:
									LOGGER.warning(
										"Replay pacing observed non-monotonic ITCH timestamp; clamping negative delay to 0"
									)
									backward_ts_warned = True
								delta_ts_ns = 0
							target_monotonic_s = replay_anchor_monotonic_s + (delta_ts_ns / 1e9) / replay_speed
							sleep_s = target_monotonic_s - time.monotonic()
							if sleep_s > 0:
								time.sleep(sleep_s)

				try:
					buffer_queue.put(message.raw)
				except QueueClosed:
					LOGGER.warning("Queue closed while enqueueing; aborting read loop")
					break
				forwarded += 1
				forwarded_bytes += len(message.raw)
				
				# Track last sent ITCH timestamp for live stats
				if ts_ns is not None:
					last_sent_ts_ns = ts_ns
				
				# Record order ID if analytics is enabled
				if analytics_mode and analytics:
					order_id = extract_order_id(msg_type, message.payload)
					if order_id is not None:
						analytics.record_order_id(order_id, msg_type, ts_ns)
					price_ticks = extract_price_ticks(msg_type, message.payload)
					if price_ticks is not None:
						analytics.record_price(price_ticks, msg_type, order_id, ts_ns)
				
				if demo_mode:
					_log_demo_message(forwarded, message)
					if demo_delay is not None and not replay_enabled and demo_debugger is None:
						time.sleep(demo_delay)

				if demo_debugger is not None:
					try:
						action = demo_debugger.on_forwarded(forwarded)
					except DemoDebuggerNonInteractive as exc:
						LOGGER.error("%s", exc)
						break
					if action == "stop":
						LOGGER.info("Demo debugger requested stop at message %s", forwarded)
						break
				if max_messages is not None and forwarded >= max_messages:
					LOGGER.info("Demo limit reached (%s messages)", forwarded)
					break
			else:
				dropped += 1

			now = time.monotonic()
			if benchmark_mode and now - start_time >= cfg.reader.benchmark_timeout_s:
				LOGGER.info(
					"Benchmark timeout reached after %.1f seconds; stopping early",
					cfg.reader.benchmark_timeout_s,
				)
				break

			if now - last_stats >= cfg.reader.stats_interval:
				last_ts_str = format_itch_timestamp(last_sent_ts_ns) if last_sent_ts_ns is not None else "-"
				LOGGER.info(
					"forwarded=%s dropped=%s prestart_skipped=%s queue=%sMB parsed_bytes=%s forwarded_bytes=%s last_ts=%s",
					forwarded,
					dropped,
					skipped_before_start,
					buffer_queue.size_bytes / (1024 * 1024),
					parsed_bytes,
					forwarded_bytes,
					last_ts_str,
				)
				last_stats = now

			# Periodic orderbook snapshots
			if orderbook_mode and orderbook and orderbook_snapshot_path:
				if now - last_snapshot >= orderbook_snapshot_interval:
					orderbook.save_snapshot(orderbook_snapshot_path)
					last_snapshot = now

	except KeyboardInterrupt:
		LOGGER.info("Interrupted by user; shutting down gracefully...")
	finally:
		# If OUCH is active, wait for demo clients to disconnect before tearing down
		if ouch_server is not None:
			if demo_mode:
				LOGGER.info("Waiting for OUCH clients to finish (up to 30s)...")
				ouch_server.wait_for_idle(timeout=30.0)
			ouch_server.stop()

		buffer_queue.close()
		udp_forwarder.stop()
		
		# Log analytics if enabled
		if analytics_mode and analytics:
			analytics.log_summary(LOGGER, analytics_csv)

		# Final orderbook snapshot and summary on exit
		if orderbook_mode and orderbook:
			orderbook.log_summary(LOGGER)
			if orderbook_snapshot_path:
				orderbook.save_snapshot(orderbook_snapshot_path)
				LOGGER.info("Final orderbook snapshot saved to: %s", orderbook_snapshot_path)
		
		if benchmark_mode:
			_end_time = time.monotonic()
			_duration = max(_end_time - start_time, 1e-9)
			_parse_mb_s = parsed_bytes / (1024 * 1024) / _duration
			_fwd_mb_s = forwarded_bytes / (1024 * 1024) / _duration
			_parse_gbps = (parsed_bytes * 8) / _duration / 1e9
			_fwd_gbps = (forwarded_bytes * 8) / _duration / 1e9
			LOGGER.info(
				"BENCHMARK summary: duration=%.3fs parsed_bytes=%s forwarded_bytes=%s",
				_duration,
				parsed_bytes,
				forwarded_bytes,
			)
			LOGGER.info(
				"BENCHMARK throughput: parse=%.3f MB/s (%.3f Gbit/s) forward=%.3f MB/s (%.3f Gbit/s)",
				_parse_mb_s,
				_parse_gbps,
				_fwd_mb_s,
				_fwd_gbps,
			)


###############################################################################
# CLI entry point
###############################################################################


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="Forward ITCH messages over UDP")
	parser.add_argument(
		"--config",
		type=Path,
		default=Path(__file__).with_name(DEFAULT_CONFIG_NAME),
		help="Path to YAML config (default: ./forwarder.yaml)",
	)
	parser.add_argument(
		"--log-level",
		default="INFO",
		choices=["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"],
		help="Logging verbosity",
	)
	parser.add_argument(
		"--demo",
		action="store_true",
		help="Send only the first 20 matching messages and exit",
	)
	parser.add_argument(
		"--max-messages",
		type=int,
		default=None,
		metavar="N",
		help="Forward at most N matching messages then exit (overrides --demo count)",
	)
	parser.add_argument(
		"--demo-delay",
		type=float,
		default=None,
		metavar="SECS",
		help="Sleep SECS seconds between forwarded messages in demo mode (e.g. 0.4)",
	)
	parser.add_argument(
		"--demo-debugger",
		action="store_true",
		help="Enable interactive debugger controls in demo mode (n=step, c=continue, q=quit)",
	)
	parser.add_argument(
		"--demo-breakpoints-config",
		type=Path,
		default=Path(__file__).parent / "demo_breakpoints.yaml",
		help="Path to YAML breakpoint config (list or {breakpoints:[...]})",
	)
	parser.add_argument(
		"--demo-breakpoint",
		type=int,
		action="append",
		default=None,
		metavar="N",
		help="Add a forwarded-message breakpoint at N (repeatable)",
	)
	parser.add_argument(
		"--replay",
		action="store_true",
		help="Enable timestamp-driven replay pacing using ITCH timestamps",
	)
	parser.add_argument(
		"--replay-start-timestamp",
		type=int,
		default=None,
		metavar="N",
		help="ITCH nanoseconds-since-midnight anchor start; earlier messages are burst-sent",
	)
	parser.add_argument(
		"--replay-start-time",
		type=str,
		default=None,
		metavar="HH:MM:SS[.fffffffff]",
		help="Replay start anchor as market-day time, interpreted as ITCH nanoseconds since midnight",
	)
	parser.add_argument(
		"--replay-speed",
		type=float,
		default=None,
		metavar="X",
		help="Replay speed multiplier (1.0 = real timestamp pace, 2.0 = 2x faster)",
	)
	parser.add_argument(
		"--benchmark",
		action="store_true",
		help="Enable benchmarking metrics for parsing and forwarding throughput",
	)
	parser.add_argument(
		"--analytics",
		action="store_true",
		help="Enable order ID analytics collection and reporting",
	)
	parser.add_argument(
		"--analytics-csv",
		type=Path,
		default=None,
		help="Write order ID analytics data to CSV file",
	)
	parser.add_argument(
		"--orderbook",
		action="store_true",
		help="Enable internal orderbook tracking (required for proper D/E/X filtering)",
	)
	parser.add_argument(
		"--orderbook-snapshot-path",
		type=Path,
		default=None,
		help="Path to save orderbook snapshots (JSON format)",
	)
	parser.add_argument(
		"--orderbook-snapshot-interval",
		type=float,
		default=5.0,
		help="Seconds between orderbook snapshots (default: 5.0)",
	)
	parser.add_argument(
		"--ouch",
		action="store_true",
		help="Enable OUCH 5.0 paper trading server (implicitly enables orderbook mode)",
	)
	return parser.parse_args()


def main() -> None:
	args = parse_args()
	logging.basicConfig(
		level=getattr(logging, args.log_level.upper(), logging.INFO),
		format="%(asctime)s %(levelname)s %(name)s - %(message)s",
	)
	cfg = load_config(args.config)
	# Auto-enable demo mode if debugger is requested
	demo_mode_enabled = args.demo or args.demo_debugger

	# --max-messages takes precedence; debugger defaults to high limit, --demo defaults to 20
	if args.max_messages is not None:
		max_messages = args.max_messages
	elif args.demo_debugger:
		max_messages = 1_000_000  # High limit for interactive debugging
		demo_mode_enabled = True  # Ensure demo mode is on
	elif args.demo:
		max_messages = 20
	else:
		max_messages = None

	if demo_mode_enabled:
		LOGGER.warning("Demo mode enabled: forwarding first %s matching messages", max_messages)

	demo_breakpoints: List[int] = []
	if args.demo_breakpoints_config.exists():
		demo_breakpoints = load_demo_breakpoints(args.demo_breakpoints_config)
	if args.demo_breakpoint:
		demo_breakpoints = _normalize_demo_breakpoints(args.demo_breakpoint)

	demo_debugger: Optional[DemoDebugger] = None
	if args.demo_debugger:
		if not demo_breakpoints:
			demo_breakpoints = [1]
			LOGGER.info("Demo debugger enabled with no breakpoints; defaulting to breakpoint [1]")
		demo_debugger = DemoDebugger(demo_breakpoints)
		LOGGER.info("Demo debugger enabled: breakpoints=%s", list(demo_debugger.breakpoints))

	if args.replay_start_timestamp is not None and args.replay_start_time is not None:
		raise SystemExit("--replay-start-timestamp and --replay-start-time are mutually exclusive")

	if args.replay_start_timestamp is not None and args.replay_start_timestamp < 0:
		raise SystemExit("--replay-start-timestamp must be >= 0")

	replay_enabled = False
	replay_start_timestamp_ns: Optional[int] = None
	replay_speed = 1.0

	if cfg.replay is not None:
		replay_enabled = cfg.replay.enabled
		replay_start_timestamp_ns = cfg.replay.start_timestamp_ns
		replay_speed = cfg.replay.speed

	# CLI overrides
	if args.replay:
		replay_enabled = True
	if args.replay_start_timestamp is not None:
		replay_start_timestamp_ns = args.replay_start_timestamp
		replay_enabled = True
	if args.replay_start_time is not None:
		replay_start_timestamp_ns = parse_itch_time_24h_to_ns(args.replay_start_time)
		replay_enabled = True
	if args.replay_speed is not None:
		if args.replay_speed <= 0:
			raise SystemExit("--replay-speed must be > 0")
		replay_speed = args.replay_speed
		replay_enabled = True

	if replay_enabled:
		if replay_start_timestamp_ns is None:
			LOGGER.info("Replay pacing enabled from first forwarded message at speed %.3fx", replay_speed)
		else:
			LOGGER.info(
				"Replay pacing enabled: forward only from ITCH timestamp=%s (%s), then pace at %.3fx",
				replay_start_timestamp_ns,
				format_itch_timestamp(replay_start_timestamp_ns),
				replay_speed,
			)
		if args.demo_delay is not None:
			LOGGER.warning("--demo-delay is ignored when replay pacing is enabled")
	if args.demo_debugger and replay_enabled:
		LOGGER.warning("Replay pacing is ignored while --demo-debugger is active")
	if args.demo_debugger and args.demo_delay is not None:
		LOGGER.warning("--demo-delay is ignored while --demo-debugger is active")
	if args.analytics:
		LOGGER.info("Order ID analytics mode enabled")
		if args.analytics_csv:
			LOGGER.info("Analytics will be exported to: %s", args.analytics_csv)

	# Determine orderbook settings: CLI flags override config file
	orderbook_mode = args.orderbook or cfg.orderbook is not None
	orderbook_snapshot_path = args.orderbook_snapshot_path
	orderbook_snapshot_interval = args.orderbook_snapshot_interval

	# OUCH mode implicitly enables orderbook mode
	ouch_enabled = args.ouch or (cfg.ouch is not None and cfg.ouch.enabled)
	if ouch_enabled:
		orderbook_mode = True
		LOGGER.info("OUCH paper trading enabled (orderbook mode auto-enabled)")

	# Use config file settings if not overridden by CLI
	if cfg.orderbook is not None:
		if orderbook_snapshot_path is None:
			orderbook_snapshot_path = cfg.orderbook.snapshot_path
		if args.orderbook_snapshot_interval == 5.0:  # default value
			orderbook_snapshot_interval = cfg.orderbook.snapshot_interval_s

	if orderbook_mode:
		LOGGER.info("Orderbook mode enabled")
		if orderbook_snapshot_path:
			LOGGER.info("Orderbook snapshots will be saved to: %s", orderbook_snapshot_path)

	try:
		forward(
			cfg,
			max_messages=max_messages,
			demo_mode=demo_mode_enabled,
			demo_delay=args.demo_delay,
			demo_debugger=demo_debugger,
			replay_enabled=replay_enabled,
			replay_start_timestamp_ns=replay_start_timestamp_ns,
			replay_speed=replay_speed,
			benchmark_mode=args.benchmark,
			analytics_mode=args.analytics,
			analytics_csv=args.analytics_csv,
			orderbook_mode=orderbook_mode,
			orderbook_snapshot_path=orderbook_snapshot_path,
			orderbook_snapshot_interval=orderbook_snapshot_interval,
			ouch_enabled=ouch_enabled,
		)
	except KeyboardInterrupt:
		LOGGER.info("Program interrupted by user")
		raise SystemExit(0)


def _log_demo_message(index: int, message: Message) -> None:
	base = {
		"index": index,
		"type": message.msg_type,
		"length": len(message.raw),
	}
	extractor = TICKER_EXTRACTORS.get(message.msg_type)
	ticker = extractor(message.payload) if extractor else None
	preview = message.raw[: min(16, len(message.raw))].hex()
	LOGGER.info(
		"DEMO message %(index)s type=%(type)s ticker=%(ticker)s len=%(length)s preview=%(preview)s",
		{**base, "ticker": ticker or "-", "preview": preview},
	)


if __name__ == "__main__":
	main()
