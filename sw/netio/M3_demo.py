import socket
import sys
import struct
import os

DE1_IP   = "192.168.1.123"
DE1_PORT = 12345

# Add the outputs directory to the Python path
current_dir = os.path.dirname(os.path.abspath(__file__))
vectors_dir = os.path.join(current_dir, "..", "..", "gen_test_vectors", "outputs", "NetIO_Test")
sys.path.append(os.path.abspath(vectors_dir))

# Import the auto-generated test vectors
try:
    import netio_vectors
except ImportError:
    print("Error: Could not import netio_vectors.py. Check your directory structure.")
    sys.exit(1)


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
    payload_name = f"PAYLOAD_{choice}"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # Dynamically fetch the payload from the imported module
    if hasattr(netio_vectors, payload_name):
        payload = getattr(netio_vectors, payload_name)
        print(f"Selecting {payload_name} from netio_vectors.py...")
    else:
        print(f"Invalid argument. '{payload_name}' not found in netio_vectors.py.")
        sys.exit(1)

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