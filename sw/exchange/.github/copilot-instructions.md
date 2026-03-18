# Copilot instructions (capstone)

## What this folder is
- Replays a NASDAQ ITCH 5.0 binary file, filters messages by ticker, and forwards the raw ITCH messages over UDP.
- Optional modes:
  - Internal limit order book tracking (required to correctly filter D/E/X messages that lack ticker fields).
  - Order ID + price analytics reporting/export.
  - OUCH 5.0 paper trading server (accepts Enter/Cancel orders over TCP, matches against the ITCH-driven orderbook read-only).

Key files:
- `src/data_forwarder.py`: ITCH parsing, ticker filtering, bounded queue, UDP sender, CLI.
- `src/orderbook.py`: in-memory limit order book + snapshot/logging helpers.
- `src/ouch_server.py`: OUCH 5.0 paper trading TCP server + message parsers/builders.
- `src/ouch_demo.py`: standalone OUCH demo client for testing paper trading.
- `src/forwarder.yaml`: default runtime config (note: `itch_file` is an absolute path).
- `docs/orderbook.md`: diagrams of the intended message/orderbook flow.
- `tests/`: pytest unit tests for field extraction, orderbook behavior, and OUCH protocol.

## Architecture & data flow (important conventions)
- `ITCHStream` / `PreloadedITCHStream` iterate a file of *length-prefixed* messages: 2-byte big-endian length + 1-byte type + payload (`src/data_forwarder.py`).
- `Message` wraps raw bytes; `msg_type` is `chr(raw[2])` and `payload` is `raw[3:]`.
- Filtering:
  - For A/F and trade-like types (P/Q/I), ticker is extracted directly via `TICKER_EXTRACTORS`.
  - For X/D/E, ticker must be resolved via `order_id` lookup in `OrderBook` (`TickerFilter` returns `False` if no orderbook).
- Forwarding:
  - Messages that pass `TickerFilter.should_forward()` are enqueued into `ByteBufferQueue` (bounded by `reader.max_buffer_mb`).
  - `UDPForwarder` runs in a daemon thread and sends one ITCH message per UDP packet, with a 20-byte ITCH 5.0 header: `struct.pack(">10sQH", session(10), sequence(8), count(2))`.

## OrderBook mode (how it’s actually used)
- When `--orderbook` is enabled, Add Order messages (A/F) are added to the orderbook **before** filtering so later D/E/X messages can resolve tickers by `order_id`.
- D/E/X messages update the orderbook only if they pass the ticker filter.
- Threading model in `src/orderbook.py`: updates are single-threaded (forward loop); the lock is for snapshots/reads (`get_snapshot()`, `get_bbo()`, `get_depth()`), not for write-side synchronization.
- Units:
  - `price_ticks` are $1/10,000 (e.g., $150.00 → 1_500_000).
  - ITCH timestamps are 6-byte nanoseconds since midnight (`extract_itch_timestamp`).

## OUCH paper trading mode
- Enabled via `--ouch` CLI flag or `ouch.enabled: true` in YAML config. Implicitly enables orderbook mode.
- `src/ouch_server.py` contains the TCP server (`OUCHServer`), per-client session handler (`OUCHSession`), message parsers/builders, and `PaperOrder` tracking.
- Wire format: SoupBinTCP-style 2-byte big-endian length prefix framing over TCP.
- All numeric fields are binary big-endian per OUCH 5.0 spec. Prices use 4 implied decimal places (same as ITCH `price_ticks`).
- Message types:
  - **Inbound**: Enter Order (O, 47 bytes), Cancel Order (X, 9 bytes)
  - **Outbound**: Accepted (A, 64 bytes), Executed (E, 36 bytes), Canceled (C, 18 bytes)
- Paper trading logic (read-only orderbook access):
  - Enter Order always produces an Accepted response.
  - If a buy price >= best ask, an Executed response follows at the best ask price. If a sell price <= best bid, Executed at best bid.
  - The ITCH-driven orderbook is **never modified** by OUCH orders.
  - Cancel of a known live order produces Canceled. Cancel of unknown/dead orders is silently ignored (per OUCH spec).
- Threading: `OUCHServer` accept loop + each `OUCHSession` run in daemon threads. OrderBook access is via `get_bbo()` (thread-safe with internal lock). Paper orders are per-session (no cross-thread sharing).

## Developer workflows
- Install deps: `pip install -r requirements.txt` (needs `pyyaml` + `sortedcontainers`).
- Run tests: `pytest` (configured by `pytest.ini`).
- Run forwarder (recommended invocation because imports are flat files in `src/`):
  - `python src/data_forwarder.py --config src/forwarder.yaml --demo`
  - Add orderbook + snapshots: `python src/data_forwarder.py --orderbook --orderbook-snapshot-path /tmp/orderbook.json`
  - Analytics export: `python src/data_forwarder.py --analytics --analytics-csv /tmp/order_ids.csv`
  - OUCH paper trading: `python src/data_forwarder.py --config src/forwarder.yaml --ouch`
  - OUCH demo client (after forwarder is running with --ouch): `python src/ouch_demo.py --symbol SPY`

## Project-specific editing guidelines
- If you change ITCH field offsets/extractors (e.g., `extract_order_id`, `extract_price_ticks`), update/extend `tests/test_extraction.py` with minimal bytearray payloads.
- Keep message parsing hot-path allocation-light: current code uses `memoryview` for payload slices and `readinto()` for chunked reads.
- Avoid turning `src/` into a package unless you also update:
  - `from orderbook import OrderBook` imports,
  - the CLI run pattern (`python src/data_forwarder.py`),
  - tests that `sys.path.insert(.../src)`.
