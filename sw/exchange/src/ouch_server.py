"""OUCH 5.0 paper trading TCP server.

Accepts Enter Order (O) and Cancel Order (X) messages over TCP,
checks them against the ITCH-driven OrderBook (read-only), and
responds with Accepted (A), Executed (E), and Canceled (C) messages.

Wire format: SoupBinTCP-style 2-byte big-endian length prefix framing.
All numeric fields are binary big-endian per OUCH 5.0 spec.
Prices have 4 implied decimal places (same as ITCH price_ticks).

Thread-safety:
- OUCHServer accept loop and each OUCHSession run in daemon threads.
- OrderBook access is read-only via get_bbo() which acquires its own lock.
- PaperOrder dict is per-session (no cross-thread sharing).
"""
from __future__ import annotations

import datetime
import logging
import socket
import struct
import threading
import time
from dataclasses import dataclass
from typing import Dict, List, Optional

from orderbook import OrderBook

LOGGER = logging.getLogger("ouch_server")


###############################################################################
# Configuration
###############################################################################


@dataclass(frozen=True)
class OUCHSettings:
    """OUCH server configuration with NASDAQ-typical defaults."""
    host: str = "127.0.0.1"
    port: int = 9100
    enabled: bool = False


###############################################################################
# Paper order tracking
###############################################################################


@dataclass
class PaperOrder:
    """A paper order entered via OUCH (not in the ITCH orderbook)."""
    user_ref_num: int
    side: bytes           # b'B', b'S', b'T', or b'E'
    quantity: int         # original quantity
    remaining: int        # shares still live
    symbol: bytes         # 8-byte alpha, space-padded
    price: int            # 4 implied decimal places (8 bytes on wire)
    time_in_force: bytes
    display: bytes
    capacity: bytes
    ise: bytes            # InterMarket Sweep Eligibility
    cross_type: bytes
    cl_ord_id: bytes      # 14-byte alpha
    order_ref_num: int    # server-assigned
    timestamp_ns: int     # when accepted


###############################################################################
# Struct formats (OUCH 5.0 spec)
###############################################################################

# Inbound: Enter Order (O) - 45 bytes minimum
# Type(c1) UserRefNum(I4) Side(c1) Qty(I4) Symbol(8s) Price(Q8)
# TIF(c1) Display(c1) Capacity(c1) ISE(c1) CrossType(c1) ClOrdID(14s)
ENTER_ORDER_FMT = struct.Struct(">cIcI8sQccccc14s")

# Inbound: Cancel Order (X) - 9 bytes minimum
# Type(c1) UserRefNum(I4) Quantity(I4)
CANCEL_ORDER_FMT = struct.Struct(">cII")

# Outbound: Order Accepted (A) - 62 bytes
# Type(c1) Timestamp(Q8) UserRefNum(I4) Side(c1) Qty(I4) Symbol(8s) Price(Q8)
# TIF(c1) Display(c1) OrderRefNum(Q8) Capacity(c1) ISE(c1) CrossType(c1)
# OrderState(c1) ClOrdID(14s)
ACCEPTED_FMT = struct.Struct(">cQIcI8sQccQcccc14s")

# Outbound: Order Canceled (C) - 18 bytes
# Type(c1) Timestamp(Q8) UserRefNum(I4) Quantity(I4) Reason(c1)
CANCELED_FMT = struct.Struct(">cQIIc")

# Outbound: Order Executed (E) - 34 bytes
# Type(c1) Timestamp(Q8) UserRefNum(I4) Qty(I4) Price(Q8)
# LiquidityFlag(c1) MatchNumber(Q8)
EXECUTED_FMT = struct.Struct(">cQIIQcQ")


###############################################################################
# Timestamp helper
###############################################################################


def _nanos_since_midnight() -> int:
    """Return current wall-clock time as nanoseconds since midnight (UTC)."""
    now = datetime.datetime.now(datetime.timezone.utc)
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    delta = now - midnight
    return int(delta.total_seconds() * 1_000_000_000)


###############################################################################
# Message builders (outbound)
###############################################################################


def build_accepted(
    timestamp_ns: int,
    user_ref_num: int,
    side: bytes,
    quantity: int,
    symbol: bytes,
    price: int,
    time_in_force: bytes,
    display: bytes,
    order_ref_num: int,
    capacity: bytes,
    ise: bytes,
    cross_type: bytes,
    order_state: bytes,
    cl_ord_id: bytes,
) -> bytes:
    """Build an Order Accepted (A) outbound message."""
    return ACCEPTED_FMT.pack(
        b'A', timestamp_ns, user_ref_num, side, quantity,
        symbol, price, time_in_force, display,
        order_ref_num, capacity, ise, cross_type,
        order_state, cl_ord_id,
    )


def build_canceled(
    timestamp_ns: int,
    user_ref_num: int,
    canceled_quantity: int,
    reason: bytes,
) -> bytes:
    """Build an Order Canceled (C) outbound message."""
    return CANCELED_FMT.pack(
        b'C', timestamp_ns, user_ref_num, canceled_quantity, reason,
    )


def build_executed(
    timestamp_ns: int,
    user_ref_num: int,
    executed_quantity: int,
    price: int,
    liquidity_flag: bytes,
    match_number: int,
) -> bytes:
    """Build an Order Executed (E) outbound message."""
    return EXECUTED_FMT.pack(
        b'E', timestamp_ns, user_ref_num, executed_quantity,
        price, liquidity_flag, match_number,
    )


###############################################################################
# Message parsers (inbound)
###############################################################################


def parse_enter_order(data: bytes) -> dict:
    """Parse an Enter Order (O) message.

    Args:
        data: Raw message bytes (must start with b'O', >= 45 bytes)

    Returns:
        Dict of parsed fields

    Raises:
        ValueError: If message too short or wrong type
    """
    if len(data) < ENTER_ORDER_FMT.size:
        raise ValueError(
            f"Enter Order too short: {len(data)} < {ENTER_ORDER_FMT.size}"
        )
    (
        msg_type, user_ref_num, side, quantity, symbol, price,
        tif, display, capacity, ise, cross_type, cl_ord_id,
    ) = ENTER_ORDER_FMT.unpack_from(data, 0)

    if msg_type != b'O':
        raise ValueError(f"Expected type O, got {msg_type!r}")

    return {
        "user_ref_num": user_ref_num,
        "side": side,
        "quantity": quantity,
        "symbol": symbol,
        "price": price,
        "time_in_force": tif,
        "display": display,
        "capacity": capacity,
        "ise": ise,
        "cross_type": cross_type,
        "cl_ord_id": cl_ord_id,
    }


def parse_cancel_order(data: bytes) -> dict:
    """Parse a Cancel Order (X) message.

    Per OUCH 5.0 spec, Quantity is the new intended order size.
    Quantity=0 means cancel all remaining shares.

    Args:
        data: Raw message bytes (must start with b'X', >= 9 bytes)

    Returns:
        Dict with user_ref_num and quantity

    Raises:
        ValueError: If message too short or wrong type
    """
    if len(data) < CANCEL_ORDER_FMT.size:
        raise ValueError(
            f"Cancel Order too short: {len(data)} < {CANCEL_ORDER_FMT.size}"
        )
    msg_type, user_ref_num, quantity = CANCEL_ORDER_FMT.unpack_from(data, 0)
    if msg_type != b'X':
        raise ValueError(f"Expected type X, got {msg_type!r}")

    return {
        "user_ref_num": user_ref_num,
        "quantity": quantity,
    }


###############################################################################
# SoupBinTCP framing
###############################################################################

_LEN_PREFIX = struct.Struct(">H")


def _frame_message(payload: bytes) -> bytes:
    """Wrap an OUCH message in a SoupBinTCP-style frame (2-byte length prefix)."""
    return _LEN_PREFIX.pack(len(payload)) + payload


def _recv_exactly(sock: socket.socket, n: int) -> bytes:
    """Read exactly n bytes from a socket.

    Raises:
        ConnectionError: If socket closes before n bytes received
    """
    chunks: List[bytes] = []
    remaining = n
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("Socket closed before all bytes received")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def recv_framed_message(sock: socket.socket) -> bytes:
    """Read one SoupBinTCP-framed OUCH message from the socket.

    Returns:
        The payload bytes (without the 2-byte length prefix)

    Raises:
        ConnectionError: If client disconnects or sends zero-length frame
    """
    len_bytes = _recv_exactly(sock, 2)
    payload_len = _LEN_PREFIX.unpack(len_bytes)[0]
    if payload_len == 0:
        raise ConnectionError("Zero-length frame received")
    return _recv_exactly(sock, payload_len)


###############################################################################
# OUCH session (one per TCP client)
###############################################################################


class OUCHSession:
    """Handle one OUCH TCP client connection.

    Each session has its own paper order dict and monotonic counters.
    OrderBook access is read-only via get_bbo().
    """

    def __init__(
        self,
        conn: socket.socket,
        addr: tuple,
        orderbook: OrderBook,
        stop_event: threading.Event,
    ):
        self._conn = conn
        self._addr = addr
        self._orderbook = orderbook
        self._stop_event = stop_event

        self._paper_orders: Dict[int, PaperOrder] = {}
        self._next_order_ref_num = 1
        self._next_match_number = 1

        self._orders_accepted = 0
        self._orders_executed = 0
        self._orders_canceled = 0

    def run(self) -> None:
        """Main client loop: read framed messages, dispatch by type."""
        LOGGER.info("OUCH client connected: %s", self._addr)
        try:
            while not self._stop_event.is_set():
                data = recv_framed_message(self._conn)
                if not data:
                    break
                msg_type = chr(data[0])
                if msg_type == "O":
                    self._handle_enter_order(data)
                elif msg_type == "X":
                    self._handle_cancel_order(data)
                else:
                    LOGGER.warning(
                        "Unknown OUCH message type %r from %s, ignoring",
                        msg_type, self._addr,
                    )
        except ConnectionError:
            LOGGER.info("OUCH client disconnected: %s", self._addr)
        except Exception:
            LOGGER.exception("Unexpected error in OUCH session %s", self._addr)
        finally:
            self._conn.close()
            LOGGER.info(
                "OUCH session %s ended: accepted=%d executed=%d canceled=%d",
                self._addr,
                self._orders_accepted,
                self._orders_executed,
                self._orders_canceled,
            )

    def _send(self, payload: bytes) -> None:
        """Send a SoupBinTCP-framed message to the client."""
        self._conn.sendall(_frame_message(payload))

    def _alloc_order_ref_num(self) -> int:
        ref = self._next_order_ref_num
        self._next_order_ref_num += 1
        return ref

    def _alloc_match_number(self) -> int:
        num = self._next_match_number
        self._next_match_number += 1
        return num

    def _handle_enter_order(self, data: bytes) -> None:
        """Parse Enter Order, send Accepted, check for BBO cross, send Executed."""
        try:
            fields = parse_enter_order(data)
        except ValueError as exc:
            LOGGER.warning("Malformed Enter Order from %s: %s", self._addr, exc)
            return

        ts = _nanos_since_midnight()
        order_ref_num = self._alloc_order_ref_num()
        user_ref_num = fields["user_ref_num"]
        side = fields["side"]
        quantity = fields["quantity"]
        symbol = fields["symbol"]
        price = fields["price"]

        paper_order = PaperOrder(
            user_ref_num=user_ref_num,
            side=side,
            quantity=quantity,
            remaining=quantity,
            symbol=symbol,
            price=price,
            time_in_force=fields["time_in_force"],
            display=fields["display"],
            capacity=fields["capacity"],
            ise=fields["ise"],
            cross_type=fields["cross_type"],
            cl_ord_id=fields["cl_ord_id"],
            order_ref_num=order_ref_num,
            timestamp_ns=ts,
        )
        self._paper_orders[user_ref_num] = paper_order

        # Always ACK with Accepted
        accepted_msg = build_accepted(
            timestamp_ns=ts,
            user_ref_num=user_ref_num,
            side=side,
            quantity=quantity,
            symbol=symbol,
            price=price,
            time_in_force=fields["time_in_force"],
            display=fields["display"],
            order_ref_num=order_ref_num,
            capacity=fields["capacity"],
            ise=fields["ise"],
            cross_type=fields["cross_type"],
            order_state=b'L',
            cl_ord_id=fields["cl_ord_id"],
        )
        self._send(accepted_msg)
        self._orders_accepted += 1

        symbol_str = symbol.decode("ascii", errors="ignore").strip()
        LOGGER.info(
            "OUCH Accepted: UserRefNum=%d Symbol=%s Side=%s Qty=%d "
            "Price=%.4f OrderRefNum=%d",
            user_ref_num, symbol_str, side.decode(), quantity,
            price / 10000.0, order_ref_num,
        )

        # Check for BBO cross (read-only orderbook access)
        best_bid, best_ask = self._orderbook.get_bbo()
        exec_price: Optional[int] = None

        if side == b'B' and best_ask is not None and price >= best_ask:
            exec_price = best_ask
        elif side in (b'S', b'T', b'E') and best_bid is not None and price <= best_bid:
            exec_price = best_bid

        if exec_price is not None:
            match_number = self._alloc_match_number()
            exec_ts = _nanos_since_midnight()
            executed_msg = build_executed(
                timestamp_ns=exec_ts,
                user_ref_num=user_ref_num,
                executed_quantity=quantity,
                price=exec_price,
                liquidity_flag=b'R',
                match_number=match_number,
            )
            self._send(executed_msg)
            paper_order.remaining = 0
            self._orders_executed += 1

            LOGGER.info(
                "OUCH Executed: UserRefNum=%d Qty=%d ExecPrice=%.4f "
                "MatchNum=%d (BBO: bid=%s ask=%s)",
                user_ref_num, quantity, exec_price / 10000.0, match_number,
                f"${best_bid / 10000.0:.4f}" if best_bid else "None",
                f"${best_ask / 10000.0:.4f}" if best_ask else "None",
            )

    def _handle_cancel_order(self, data: bytes) -> None:
        """Parse Cancel Order, send Canceled if order exists, else ignore."""
        try:
            fields = parse_cancel_order(data)
        except ValueError as exc:
            LOGGER.warning("Malformed Cancel Order from %s: %s", self._addr, exc)
            return

        user_ref_num = fields["user_ref_num"]
        paper_order = self._paper_orders.get(user_ref_num)

        if paper_order is None or paper_order.remaining <= 0:
            LOGGER.debug(
                "OUCH Cancel ignored: UserRefNum=%d not found or already dead",
                user_ref_num,
            )
            return

        canceled_qty = paper_order.remaining
        paper_order.remaining = 0

        ts = _nanos_since_midnight()
        canceled_msg = build_canceled(
            timestamp_ns=ts,
            user_ref_num=user_ref_num,
            canceled_quantity=canceled_qty,
            reason=b'U',
        )
        self._send(canceled_msg)
        self._orders_canceled += 1

        symbol_str = paper_order.symbol.decode("ascii", errors="ignore").strip()
        LOGGER.info(
            "OUCH Canceled: UserRefNum=%d Symbol=%s CanceledQty=%d Reason=U",
            user_ref_num, symbol_str, canceled_qty,
        )


###############################################################################
# OUCH TCP server
###############################################################################


class OUCHServer:
    """TCP accept loop for the OUCH paper trading server.

    Threading model:
    - The accept loop runs in a daemon thread.
    - Each client spawns its own daemon thread running OUCHSession.run().
    - All threads share a single stop_event for coordinated shutdown.
    """

    def __init__(self, settings: OUCHSettings, orderbook: OrderBook):
        self._settings = settings
        self._orderbook = orderbook
        self._stop_event = threading.Event()
        self._server_socket: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._client_threads: List[threading.Thread] = []

    def start(self) -> None:
        """Bind, listen, and start the accept loop thread."""
        self._server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server_socket.settimeout(1.0)
        self._server_socket.bind((self._settings.host, self._settings.port))
        self._server_socket.listen(5)
        LOGGER.info(
            "OUCH paper trading server listening on %s:%d",
            self._settings.host, self._settings.port,
        )
        self._thread = threading.Thread(
            target=self._accept_loop, name="ouch-accept", daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        """Signal all threads to stop and wait for them."""
        self._stop_event.set()
        if self._server_socket:
            self._server_socket.close()
        if self._thread:
            self._thread.join(timeout=5.0)
        for t in self._client_threads:
            t.join(timeout=2.0)
        LOGGER.info("OUCH server stopped")

    def wait_for_idle(self, timeout: float = 30.0) -> None:
        """Block until all client threads have finished or *timeout* expires.

        Used by ``--demo`` mode to keep the OUCH server alive while the demo
        client finishes its scenarios, before starting the teardown sequence.
        """
        deadline = time.monotonic() + timeout
        for t in list(self._client_threads):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                LOGGER.warning("wait_for_idle timeout; %d client(s) still active",
                               sum(1 for th in self._client_threads if th.is_alive()))
                return
            t.join(timeout=remaining)
        LOGGER.info("All OUCH clients disconnected")

    def wait_for_client_connection(self, timeout: float = 30.0) -> bool:
        """Wait for at least one OUCH client connection.

        Returns True if a client is connected before timeout, otherwise False.
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and not self._stop_event.is_set():
            if any(t.is_alive() for t in self._client_threads):
                return True
            time.sleep(0.1)
        return any(t.is_alive() for t in self._client_threads)

    def _accept_loop(self) -> None:
        """Accept incoming TCP connections, spawn session threads."""
        assert self._server_socket is not None
        while not self._stop_event.is_set():
            try:
                conn, addr = self._server_socket.accept()
            except socket.timeout:
                continue
            except OSError:
                if self._stop_event.is_set():
                    break
                LOGGER.exception("Accept loop error")
                break

            session = OUCHSession(conn, addr, self._orderbook, self._stop_event)
            t = threading.Thread(
                target=session.run,
                name=f"ouch-client-{addr}",
                daemon=True,
            )
            self._client_threads.append(t)
            t.start()
