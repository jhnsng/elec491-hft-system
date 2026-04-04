"""Tests for OUCH demo response formatting."""
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from ouch_demo import _decode_response
from ouch_server import build_accepted, build_canceled, build_executed


def _expected_hex(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


def test_decode_response_accepted_sanitizes_symbol_and_prints_hex():
    msg = build_accepted(
        timestamp_ns=1,
        user_ref_num=42,
        side=b"B",
        quantity=100,
        symbol=b"SPY\xF0\x9F\x98\x80 ",
        price=1_234_500,
        time_in_force=b"0",
        display=b"Y",
        order_ref_num=99,
        capacity=b"A",
        ise=b"N",
        cross_type=b"N",
        order_state=b"L",
        cl_ord_id=b"TEST_CLORDID__",
    )

    decoded = _decode_response(msg)
    assert "ACCEPTED" in decoded
    assert "Symbol=SPY...." in decoded
    assert f"HEX={_expected_hex(msg)}" in decoded


def test_decode_response_executed_and_canceled_print_hex():
    exec_msg = build_executed(
        timestamp_ns=2,
        user_ref_num=42,
        executed_quantity=10,
        price=1_200_000,
        liquidity_flag=b"R",
        match_number=123,
    )
    cancel_msg = build_canceled(
        timestamp_ns=3,
        user_ref_num=42,
        canceled_quantity=90,
        reason=b"U",
    )

    exec_decoded = _decode_response(exec_msg)
    cancel_decoded = _decode_response(cancel_msg)

    assert "EXECUTED" in exec_decoded
    assert f"HEX={_expected_hex(exec_msg)}" in exec_decoded
    assert "CANCELED" in cancel_decoded
    assert f"HEX={_expected_hex(cancel_msg)}" in cancel_decoded