import sys
import socket
import time

DE1_IP = "192.168.1.123"
DE1_PORT = 12345

# ITCH v5.0 message lengths (bytes), including the 1-byte message type.
MESSAGE_LENGTHS = {
    "S": 12,   # System Event
    "R": 39,   # Stock Directory
    "A": 36,   # Add Order - No MPID Attribution
    "F": 40,   # Add Order - With MPID Attribution
    "E": 31,   # Order Executed
    "C": 36,   # Order Executed With Price
    "X": 23,   # Order Cancel
    "D": 19,   # Order Delete
    "U": 35,   # Order Replace
    "P": 44,   # Trade (Non-Cross)
}

def build_itch_message(msg_type):
    total_len = MESSAGE_LENGTHS[msg_type]
    payload_len = total_len - 1

    # Dummy payload: 0x01, 0x02, ...
    payload = bytes((i % 256 for i in range(1, payload_len + 1)))
    return bytes([ord(msg_type)]) + payload

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <ITCH type 1> [ITCH type 2] [ITCH type 3] ...")
        print(f"Supported types: {', '.join(sorted(MESSAGE_LENGTHS.keys()))}")
        sys.exit(1)

    msg_types = sys.argv[1:]

    for t in msg_types:
        if len(t) != 1 or t not in MESSAGE_LENGTHS:
            print(f"Error: unsupported ITCH message type '{t}'")
            sys.exit(1)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    for t in msg_types:
        msg = build_itch_message(t)
        sock.sendto(msg, (DE1_IP, DE1_PORT))
        print(f"Sent ITCH '{t}' ({len(msg)} bytes)")

        # Optional: tiny delay for readability/debugging
        # Comment this out if you want them *really* back-to-back
        # time.sleep(0.001)

    sock.close()
    print("Done.")

if __name__ == "__main__":
    main()
