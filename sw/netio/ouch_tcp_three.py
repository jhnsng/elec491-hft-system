import socket
import time

FPGA_IP = "192.168.1.123"   # HPS IP
PORT = 12345                 # OUCH ingress port


def build_ouch_message(msg_type: str) -> bytearray:
    """Build a dummy OUCH message of the specified type ('A', 'C', 'E')"""
    msg = bytearray()
    msg.append(ord(msg_type))

    if msg_type == 'A':
        # 'A' Order Accepted = 62 bytes
        for i in range(61):
            msg.append(i & 0xFF)
    elif msg_type == 'C':
        # 'C' Order Canceled = 18 bytes
        for i in range(17):
            msg.append(i & 0xFF)
    elif msg_type == 'E':
        # 'E' Order Executed = 34 bytes
        for i in range(33):
            msg.append(i & 0xFF)
    else:
        raise ValueError(f"Unknown OUCH type {msg_type}")

    return msg


def main():
    # Create back-to-back sequence
    messages = [
        build_ouch_message('A'),
        build_ouch_message('C'),
        build_ouch_message('E')
    ]

    # Concatenate all messages into a single TCP payload
    payload = bytearray()
    for m in messages:
        payload.extend(m)

    print(f"Prepared back-to-back messages, total bytes = {len(payload)}")

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    print("Connecting to FPGA...")
    s.connect((FPGA_IP, PORT))
    print("Connected")

    # Send all messages in a single sendall() call
    s.sendall(payload)
    print("Back-to-back messages sent")

    s.close()


if __name__ == "__main__":
    main()