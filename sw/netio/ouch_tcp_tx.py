import socket
import time

FPGA_IP = "192.168.1.123"
PORT = 12345

def build_message():
    msg = bytearray()

    msg.append(ord('C'))   # message type

    # remaining bytes
    for i in range(17):    # total = 18 bytes
        msg.append(i & 0xFF)

    return msg


def main():

    msg = build_message()

    print("Prepared message:")
    print(list(msg))

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    print("Connecting to FPGA...")
    s.connect((FPGA_IP, PORT))

    print("Connected")

    s.sendall(msg)

    print("Message sent")

    s.close()


if __name__ == "__main__":
    main()