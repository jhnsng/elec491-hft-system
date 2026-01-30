import socket
import random
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
    payload = bytes((i % 256 for i in range(1, payload_len + 1)))
    return bytes([ord(msg_type)]) + payload

def stress_test_itch(num_messages=50):
    """Send a stress test of ITCH messages to DE1-SoC."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    # Only use A, E, X messages for stress test
    stress_types = ["A", "E", "X"]

    for i in range(num_messages):
        msg_type = random.choice(stress_types)  # Randomly pick a type
        msg = build_itch_message(msg_type)
        sock.sendto(msg, (DE1_IP, DE1_PORT))
        print(f"{i+1}/{num_messages}: Sent ITCH '{msg_type}' ({len(msg)} bytes)")
        # Optional: tiny delay if needed
        # time.sleep(0.001)  # Uncomment to slow down slightly for readability/debugging

    sock.close()
    print(f"Stress test complete: {num_messages} ITCH messages sent.")

if __name__ == "__main__":
    stress_test_itch(num_messages=50)
