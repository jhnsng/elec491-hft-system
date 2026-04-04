#!/usr/bin/env python3
"""OUCH 5.0 demo client for paper trading against the ITCH-driven orderbook.

Usage (two terminals):

  Terminal 1 – start the forwarder with OUCH enabled:
    python src/data_forwarder.py --config src/forwarder.yaml --ouch

  Terminal 2 – run this demo after ITCH data starts flowing:
    python src/ouch_demo.py --symbol SPY
"""
from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ouch_server import (
    ACCEPTED_FMT,
    CANCELED_FMT,
    CANCEL_ORDER_FMT,
    ENTER_ORDER_FMT,
    EXECUTED_FMT,
    _frame_message,
    recv_framed_message,
)


def _price_str(price_ticks: int) -> str:
    """Format price_ticks (4 implied decimals) as $X.XXXX."""
    return f"${price_ticks / 10000:.4f}"


def _hex_dump(data: bytes) -> str:
    """Format bytes as an uppercase, space-separated hex string."""
    return " ".join(f"{b:02X}" for b in data)


def _safe_symbol(symbol_bytes: bytes) -> str:
    """Decode OUCH symbol field to printable ASCII for terminal display.

    OUCH symbols are fixed-width 8-byte alpha fields that are typically
    space-padded. Some tooling can emit non-ASCII bytes; render those as '.'
    so logs remain readable and deterministic.
    """
    trimmed = symbol_bytes.rstrip(b" \x00")
    return "".join(chr(b) if 32 <= b <= 126 else "." for b in trimmed)


def _decode_response(data: bytes) -> str:
    """Decode an OUCH outbound message into a human-readable string."""
    msg_type = chr(data[0])
    hex_str = _hex_dump(data)

    if msg_type == "A":
        fields = ACCEPTED_FMT.unpack(data)
        side = fields[3].decode("ascii", errors="replace")
        symbol = _safe_symbol(fields[5])
        state = fields[13].decode("ascii", errors="replace")
        return (
            f"  ACCEPTED  UserRef={fields[2]}  Side={side}  "
            f"Qty={fields[4]}  Symbol={symbol}  "
            f"Price={_price_str(fields[6])}  OrderRef={fields[9]}  "
            f"State={state}  HEX={hex_str}"
        )

    if msg_type == "E":
        fields = EXECUTED_FMT.unpack(data)
        liquidity = fields[5].decode("ascii", errors="replace")
        return (
            f"  EXECUTED  UserRef={fields[2]}  Qty={fields[3]}  "
            f"Price={_price_str(fields[4])}  Liquidity={liquidity}  "
            f"MatchNum={fields[6]}  HEX={hex_str}"
        )

    if msg_type == "C":
        fields = CANCELED_FMT.unpack(data)
        reason = fields[4].decode("ascii", errors="replace")
        return (
            f"  CANCELED  UserRef={fields[2]}  CxlQty={fields[3]}  "
            f"Reason={reason}  HEX={hex_str}"
        )

    return f"  UNKNOWN type={msg_type!r} len={len(data)}  HEX={hex_str}"


def _recv_responses(sock: socket.socket, expected: int, timeout: float = 2.0) -> list:
    """Receive up to `expected` framed responses within timeout."""
    responses = []
    sock.settimeout(timeout)
    for _ in range(expected):
        try:
            resp = recv_framed_message(sock)
            responses.append(resp)
        except (socket.timeout, ConnectionError):
            break
    return responses


def _send_enter_order(
    sock: socket.socket,
    user_ref: int,
    side: bytes,
    qty: int,
    symbol: str,
    price: int,
) -> None:
    """Send an Enter Order (O) message."""
    symbol_bytes = symbol.encode("ascii").ljust(8)[:8]
    msg = ENTER_ORDER_FMT.pack(
        b"O",
        user_ref,
        side,
        qty,
        symbol_bytes,
        price,
        b"0",  # time_in_force: day
        b"Y",  # display
        b"A",  # capacity: agency
        b"N",  # ISE
        b"N",  # cross_type
        b"DEMO_CLIENT   ",  # cl_ord_id (14 bytes)
    )
    sock.sendall(_frame_message(msg))


def _send_cancel_order(sock: socket.socket, user_ref: int, qty: int = 0) -> None:
    """Send a Cancel Order (X) message. qty=0 means cancel all remaining."""
    msg = CANCEL_ORDER_FMT.pack(b"X", user_ref, qty)
    sock.sendall(_frame_message(msg))


def run_demo(host: str, port: int, symbol: str, delay: float = 0.5) -> None:
    """Run a 5-step OUCH demo sequence."""
    print(f"Connecting to OUCH server at {host}:{port} ...")
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.connect((host, port))
    except ConnectionRefusedError:
        print(
            f"ERROR: Could not connect to {host}:{port}.\n"
            "Make sure the forwarder is running with --ouch enabled:\n"
            "  python src/data_forwarder.py --config src/forwarder.yaml --ouch"
        )
        return
    print(f"Connected. Running demo for symbol={symbol}\n")

    # Scenario 1: Buy at a very high price (should cross ask -> Accepted + Executed)
    print("=" * 60)
    print("1. BUY 100 shares at $999.99 (expect: Accepted + Executed)")
    print("=" * 60)
    _send_enter_order(sock, user_ref=1, side=b"B", qty=100, symbol=symbol, price=9999900)
    time.sleep(delay)
    for resp in _recv_responses(sock, 2):
        print(_decode_response(resp))
    print()

    # Scenario 2: Sell at a very low price (should cross bid -> Accepted + Executed)
    print("=" * 60)
    print("2. SELL 50 shares at $0.01 (expect: Accepted + Executed)")
    print("=" * 60)
    _send_enter_order(sock, user_ref=2, side=b"S", qty=50, symbol=symbol, price=100)
    time.sleep(delay)
    for resp in _recv_responses(sock, 2):
        print(_decode_response(resp))
    print()

    # Scenario 3: Buy at a very low price (no cross -> Accepted only)
    print("=" * 60)
    print("3. BUY 200 shares at $0.01 (expect: Accepted only, no cross)")
    print("=" * 60)
    _send_enter_order(sock, user_ref=3, side=b"B", qty=200, symbol=symbol, price=100)
    time.sleep(delay)
    for resp in _recv_responses(sock, 1):
        print(_decode_response(resp))
    # Verify no extra message
    extra = _recv_responses(sock, 1, timeout=0.5)
    if extra:
        print("  (unexpected extra response)")
        for r in extra:
            print(_decode_response(r))
    print()

    # Scenario 4: Cancel order #3 (expect: Canceled)
    print("=" * 60)
    print("4. CANCEL order #3 (expect: Canceled)")
    print("=" * 60)
    _send_cancel_order(sock, user_ref=3)
    time.sleep(delay)
    for resp in _recv_responses(sock, 1):
        print(_decode_response(resp))
    print()

    # Scenario 5: Cancel non-existent order (expect: silently ignored)
    print("=" * 60)
    print("5. CANCEL order #999 (expect: silently ignored, no response)")
    print("=" * 60)
    _send_cancel_order(sock, user_ref=999)
    time.sleep(delay)
    responses = _recv_responses(sock, 1, timeout=0.5)
    if responses:
        print("  (unexpected response!)")
        for r in responses:
            print(_decode_response(r))
    else:
        print("  (no response - correct, cancel of unknown order silently ignored)")
    print()

    print("=" * 60)
    print("Demo complete.")
    print("=" * 60)
    sock.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="OUCH 5.0 paper trading demo client")
    parser.add_argument("--host", default="127.0.0.1", help="OUCH server host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=9100, help="OUCH server port (default: 9100)")
    parser.add_argument("--symbol", default="SPY", help="Symbol to trade (default: SPY)")
    parser.add_argument("--delay", type=float, default=0.5,
                        help="Seconds between scenarios (default: 0.5)")
    args = parser.parse_args()
    run_demo(args.host, args.port, args.symbol.upper(), delay=args.delay)


if __name__ == "__main__":
    main()
