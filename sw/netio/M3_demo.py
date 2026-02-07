import socket
import sys

DE1_IP   = "192.168.1.123"
DE1_PORT = 12345

# Pre-defined ITCH 'Add Order' messages (36 bytes)
# Packet 0: Order ID 1, Side B, Qty 100 (0x64), AAPL, Price ~20.00
PAYLOAD_0 = bytes.fromhex("58 00 01 00 03 00 00 00 00 00 01 00 00 00 00 00 00 00 02 00 00 00 C8")

# Packet 1: Order ID 2, Side B, Qty 200 (0xC8), AAPL, Price 30.20
PAYLOAD_1 = bytes.fromhex("41 00 01 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 02 42 00 00 00 C8 41 41 50 4C 20 20 20 20 00 00 6D C4")

# Packet 2: Add Order ID 1, Side B, Qty 100 (0x64), AAPL, Price ~20.00
PAYLOAD_2 = bytes.fromhex("41 00 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 01 42 00 00 00 64 41 41 50 4C 20 20 20 20 00 00 6D 60")

def main():
    # Check for input argument
    if len(sys.argv) < 2:
        print("Usage: python sender.py <0|1|2>")
        sys.exit(1)

    choice = sys.argv[1]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    # Select payload based on argument
    if choice == "0":
        data = PAYLOAD_0
        print(f"Selecting Packet 0 (Cancel Order)...")
    elif choice == "1":
        data = PAYLOAD_1
        print(f"Selecting Packet 1 (Add Order - Better Price)...")
    elif choice == "2":
        data = PAYLOAD_2
        print(f"Selecting Packet 2 (Add Order - Worse Price)...")
    else:
        print("Invalid argument. Please run with 0, 1, or 2.")
        sys.exit(1)

    # Send
    print(f"Sending {len(data)} bytes to {DE1_IP}:{DE1_PORT}")
    print(f"Payload (Hex): {data.hex(' ').upper()}")
    
    sock.sendto(data, (DE1_IP, DE1_PORT))
    
    print("Packet sent successfully.")
    sock.close()

if __name__ == "__main__":
    main()
