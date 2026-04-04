# HFT Exchange Module

This module replays NASDAQ ITCH data, filters by ticker, forwards matching messages over UDP, and optionally maintains an internal orderbook with live snapshot visualization.

## Architecture

The system is intentionally split into two processes:

- Process A: `data_forwarder.py`
  - Parses ITCH
  - Filters by ticker
  - Forwards UDP packets
  - Optionally updates orderbook, writes snapshots, runs OUCH paper server
- Process B: `orderbook_viewer.py`
  - Reads snapshot JSON
  - Renders OUCH efficacy metrics, recent order statuses, and top-of-book feeds

This keeps GUI work off the forwarding hot path.

## Setup

```bash
cd /home/qazed/elec491-hft-system/sw/exchange
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Run tests:

```bash
python -m pytest tests/ -q
```

## Main Config

Default config file: `src/forwarder.yaml`

Key sections:

- `itch_file`: path to ITCH binary
- `udp`: destination host/port/session
- `reader`: chunk size, queue size, stats interval
- `tickers`: symbols to forward
- `replay`: optional timestamp pacing config
- `orderbook`: optional orderbook tracking + snapshot settings
- `ouch`: optional paper-trading server settings

Note: Unknown YAML keys are ignored by the parser, so keep this file aligned with supported fields.

## Process A: Forwarder

Basic run:

```bash
python src/data_forwarder.py --config src/forwarder.yaml
```

Orderbook + snapshots:

```bash
python src/data_forwarder.py \
  --config src/forwarder.yaml \
  --orderbook \
  --orderbook-snapshot-path src/orderbook_snapshot.json \
  --orderbook-snapshot-interval 0.25
```

## Process B: Viewer

```bash
python src/orderbook_viewer.py \
  --snapshot-path src/orderbook_snapshot.json \
  --refresh-ms 200
```

Useful viewer options:

- `--history N` (default `600`)

Dashboard highlights:

- Realized gross PnL computed from OUCH executions (FIFO)
- Hit rate from real Accepted/Executed counts
- Latency summary (P50/P95/P99, microseconds)
- Recent OUCH orders table (last 10): side, limit price, status, executed qty/price
- Top-of-book feed graphs: best bid/ask prices and quantities over time

## Replay Mode

Replay can be enabled from config or CLI.

Example (CLI):

```bash
python src/data_forwarder.py \
  --config src/forwarder.yaml \
  --replay \
  --replay-start-time "09:30:00.000000" \
  --replay-speed 2.0
```

## Demo Mode and Debugger

Demo mode forwards only a limited number of **matching forwarded messages**.

- `--demo` sets default limit to 20
- `--max-messages N` overrides that limit
- `--demo-delay SECS` sleeps between forwarded demo messages

### Breakpoints from YAML

Sample file: `src/demo_breakpoints.yaml`

```yaml
breakpoints:
  - 5
  - 10
  - 20
```

Run with debugger and breakpoint config:

```bash
python src/data_forwarder.py \
  --config src/forwarder.yaml \
  --demo \
  --demo-debugger \
  --demo-breakpoints-config src/demo_breakpoints.yaml
```

Inline breakpoints are also supported:

```bash
python src/data_forwarder.py \
  --config src/forwarder.yaml \
  --demo \
  --demo-debugger \
  --demo-breakpoint 10 \
  --demo-breakpoint 25
```

### Debugger Commands

When paused at a breakpoint:

- `n`: step one forwarded message, then pause again
- `c`: continue until next breakpoint
- `q`: stop forwarding and exit gracefully
- `h` or `?`: show help

### Debugger Behavior Details

- Breakpoints are one-shot in a run (hit once when message count matches).
- Breakpoint counting is based on forwarded matching messages, not all parsed ITCH messages.
- `--demo-debugger` requires `--demo`.
- If running in non-interactive mode (no TTY), hitting a breakpoint exits with a clear error.
- When debugger is active:
  - replay pacing sleeps are skipped
  - `--demo-delay` sleeps are skipped

## OUCH Paper Trading

Enable OUCH server:

```bash
python src/data_forwarder.py --config src/forwarder.yaml --ouch
```

Run demo client in another terminal:

```bash
python src/ouch_demo.py --symbol SPY
```

## CLI Reference (Forwarder)

Core options:

- `--config PATH`
- `--log-level {DEBUG,INFO,WARNING,ERROR,CRITICAL}`
- `--demo`
- `--max-messages N`
- `--demo-delay SECS`
- `--demo-debugger`
- `--demo-breakpoints-config PATH`
- `--demo-breakpoint N` (repeatable)
- `--replay`
- `--replay-start-timestamp N`
- `--replay-start-time HH:MM:SS[.fffffffff]`
- `--replay-speed X`
- `--benchmark`
- `--analytics`
- `--analytics-csv PATH`
- `--orderbook`
- `--orderbook-snapshot-path PATH`
- `--orderbook-snapshot-interval S`
- `--ouch`

## Troubleshooting

`ITCH file not found`
- Verify `itch_file` path in `src/forwarder.yaml`.

`No snapshots generated`
- Ensure `--orderbook` is enabled.
- Ensure snapshot path is writable.

`Viewer shows stale data`
- Confirm forwarder is writing snapshots.
- Lower `--refresh-ms` if needed.

`Debugger exits at breakpoint in CI or scripts`
- Use an interactive terminal for debugger mode, or run without `--demo-debugger`.
