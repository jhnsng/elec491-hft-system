import socket
import sys
import os

# Add the outputs directory to the Python path
current_dir = os.path.dirname(os.path.abspath(__file__))
vectors_dir = os.path.join(current_dir, "..", "..", "gen_test_vectors", "outputs")
sys.path.append(os.path.abspath(vectors_dir))

# Import the auto-generated test vectors
try:
    import netio_vectors
except ImportError:
    print("Error: Could not import netio_vectors.py. Check your directory structure.")
    sys.exit(1)

DE1_IP   = "192.168.1.123"
DE1_PORT = 12345

def main():
    # Check for input argument
    if len(sys.argv) < 2:
        print("Usage: python M3_demo.py <payload_number>")
        print("Example: python M3_demo.py 2")
        sys.exit(1)

    choice = sys.argv[1]
    payload_name = f"PAYLOAD_{choice}"
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # Dynamically fetch the payload from the imported module
    if hasattr(netio_vectors, payload_name):
        data = getattr(netio_vectors, payload_name)
        print(f"Selecting {payload_name} from netio_vectors.py...")
    else:
        print(f"Invalid argument. '{payload_name}' not found in netio_vectors.py.")
        sys.exit(1)

    # Send
    print(f"Sending {len(data)} bytes to {DE1_IP}:{DE1_PORT}")
    print(f"Payload (Hex): {data.hex(' ').upper()}")
    
    sock.sendto(data, (DE1_IP, DE1_PORT))
    
    print("Packet sent successfully.")
    sock.close()

if __name__ == "__main__":
    main()
