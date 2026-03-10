import socket
import sys
import time
import struct

DE1_IP   = "192.168.1.123"
DE1_PORT = 12345

# Packet 0: Order ID 1, Side B, Qty 100 (0x64), AAPL, Price ~20.00
PAYLOAD_0 = bytes.fromhex("58 00 01 00 03 00 00 00 00 00 01 00 00 00 00 00 00 00 02 00 00 00 C8")

# Packet 1: Order ID 2, Side B, Qty 200 (0xC8), AAPL, Price 30.20
PAYLOAD_1 = bytes.fromhex("41 00 01 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 02 42 00 00 00 C8 41 41 50 4C 20 20 20 20 00 00 6D C4")

# Packet 2: Add Order ID 1, Side B, Qty 100 (0x64), AAPL, Price ~20.00
PAYLOAD_2 = bytes.fromhex("41 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 01 42 00 00 00 64 41 41 50 4C 20 20 20 20 00 00 6D 60")


def build_moludp64_header(msg_count: int, seq_num: int) -> bytes:
    """
    Build 20-byte MOL-UDP64 style header:
    - 10 bytes: session string (ASCII, padded)
    - 8 bytes: sequence number (big-endian)
    - 2 bytes: message count (big-endian)
    """
    session = b"TESTSESS"  # example session, max 10 bytes
    session_bytes = session.ljust(10, b" ")  # pad to 10 bytes

    # Pack: >10sQH => 10-byte session, 8-byte sequence number, 2-byte msg count
    header = struct.pack(">10sQH", session_bytes, seq_num, msg_count)
    return header

def main():
    if len(sys.argv) < 2:
        print("Usage: python sender.py <0|1|2>")
        sys.exit(1)

    choice = sys.argv[1]
    if choice == "0":
        payload = PAYLOAD_0
        print("Selecting Packet 0...")
    elif choice == "1":
        payload = PAYLOAD_1
        print("Selecting Packet 1...")
    elif choice == "2":
        payload = PAYLOAD_2
        print("Selecting Packet 2...")
    else:
        print("Invalid argument. Use 0, 1, or 2.")
        sys.exit(1)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # Sequence number for each packet
    seq_num = 1
    msg_count = 1  # one ITCH message per UDP packet

    header = build_moludp64_header(msg_count, seq_num)
    len_prefix = struct.pack(">H", len(payload))
    packet = header + len_prefix + payload

    print(f"Sending {len(packet)} bytes to {DE1_IP}:{DE1_PORT}")
    print(f"Header (Hex): {header.hex(' ').upper()}")
    print(f"Payload (Hex): {payload.hex(' ').upper()}")

    sock.sendto(packet, (DE1_IP, DE1_PORT))
    print("Packet sent successfully.")
    sock.close()

if __name__ == "__main__":
    main()