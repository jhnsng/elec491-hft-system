import socket
import random

FPGA_IP = "192.168.1.123"
PORT = 12345

NUM_MESSAGES = 1000


def build_ouch_message(msg_type: str) -> bytearray:
    msg = bytearray()
    msg.append(ord(msg_type))

    if msg_type == 'A':
        for i in range(61):
            msg.append(i & 0xFF)
    elif msg_type == 'C':
        for i in range(17):
            msg.append(i & 0xFF)
    elif msg_type == 'E':
        for i in range(33):
            msg.append(i & 0xFF)
    else:
        raise ValueError("Invalid OUCH type")

    return msg


def main():

    payload = bytearray()

    count_A = 0
    count_C = 0
    count_E = 0

    types = ['A', 'C', 'E']

    for _ in range(NUM_MESSAGES):

        t = random.choice(types)

        if t == 'A':
            count_A += 1
        elif t == 'C':
            count_C += 1
        elif t == 'E':
            count_E += 1

        payload.extend(build_ouch_message(t))

    print("Prepared OUCH burst")
    print("Total messages:", NUM_MESSAGES)
    print("A:", count_A, "C:", count_C, "E:", count_E)
    print("Total payload bytes:", len(payload))

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

    print("Connecting to FPGA...")
    s.connect((FPGA_IP, PORT))
    print("Connected")

    s.sendall(payload)

    print("Burst sent")

    s.close()


if __name__ == "__main__":
    main()