# udp_test_one_itch_msg.py
import sys
import socket

DE1_IP = "192.168.1.123"
DE1_PORT = 12345

# ITCH v5.0 message lengths (bytes), including the 1-byte message type.
MESSAGE_LENGTHS = {
    "S": 12,  # System Event
    "R": 39,  # Stock Directory
    "A": 36,  # Add Order - No MPID Attribution
    "F": 40,  # Add Order - With MPID Attribution
    "E": 31,  # Order Executed
    "C": 36,  # Order Executed With Price
    "X": 23,  # Order Cancel
    "D": 19,  # Order Delete
    "U": 35,  # Order Replace
    "P": 44,  # Trade (Non-Cross)
}

def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <ITCH message type letter>")
        sys.exit(1)

    msg_type = sys.argv[1]
    if len(msg_type) != 1 or msg_type not in MESSAGE_LENGTHS:
        print(f"Error: unsupported ITCH message type '{msg_type}'")
        print(f"Supported types: {', '.join(sorted(MESSAGE_LENGTHS.keys()))}")
        sys.exit(1)

    total_len = MESSAGE_LENGTHS[msg_type]
    payload_len = total_len - 1

    # Dummy payload: 0x01, 0x02, ...
    payload = bytes((i % 256 for i in range(1, payload_len + 1)))
    msg = bytes([ord(msg_type)]) + payload

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.sendto(msg, (DE1_IP, DE1_PORT))
    sock.close()

    print(f"Sent ITCH type '{msg_type}' ({total_len} bytes) to {DE1_IP}:{DE1_PORT}")

if __name__ == "__main__":
    main()
