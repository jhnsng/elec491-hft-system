import socket
import struct
import time

DE1_IP   = "192.168.1.123"
DE1_PORT = 12345

def itch_add(order_id, side, quantity, price, seq):
    msg = bytearray(36)
    msg[0] = ord('A')
    msg[1:5] = struct.pack(">I", seq)   # sequence number
    msg[5:11] = b'\x00' * 6
    msg[11:19] = struct.pack(">Q", order_id)
    msg[19]    = ord('S') if side == 'S' else ord('B')
    msg[20:24] = struct.pack(">I", quantity)
    msg[24:32] = b'TEST    '
    msg[32:36] = struct.pack(">I", price)
    return bytes(msg)


def itch_execute(order_id, exec_qty, seq):
    msg = bytearray(31)
    msg[0] = ord('E')
    msg[1:5] = struct.pack(">I", seq)
    msg[5:11] = b'\x00' * 6
    msg[11:19] = struct.pack(">Q", order_id)
    msg[19:23] = struct.pack(">I", exec_qty)
    msg[23:31] = b'\x00' * 8
    return bytes(msg)


def itch_cancel(order_id, cancel_qty, seq):
    msg = bytearray(23)
    msg[0] = ord('X')
    msg[1:5] = struct.pack(">I", seq)
    msg[5:11] = b'\x00' * 6
    msg[11:19] = struct.pack(">Q", order_id)
    msg[19:23] = struct.pack(">I", cancel_qty)
    return bytes(msg)


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    order_id = 123456789
    price    = 402500
    qty      = 100

    total_msgs = 300

    #add = itch_add(order_id, 'B', qty, price)
    #exe = itch_execute(order_id, 40)
    #can = itch_cancel(order_id, 60)

    t0 = time.perf_counter_ns()
    seq = 0

    # Send repeated A→E→X sequences
    for i in range(total_msgs):

        sock.sendto(itch_add(order_id, 'B', qty, price, seq), (DE1_IP, DE1_PORT))
        seq += 1

        sock.sendto(itch_execute(order_id, 40, seq), (DE1_IP, DE1_PORT))
        seq += 1

        sock.sendto(itch_cancel(order_id, 60, seq), (DE1_IP, DE1_PORT))
        seq += 1

        # Optional small delay if needed
        # time.sleep(0.001)

    t1 = time.perf_counter_ns()
    dt_ns = (t1 - t0)
    pkts = total_msgs * 3
    ns_per_pkt = dt_ns / pkts

    print(f"{pkts} packets in {dt_ns} ns "
        f"({ns_per_pkt:.0f} ns/pkt)")

    sock.close()
    print(f"Sent {total_msgs*3} ITCH messages (A→E→X sequences)")

if __name__ == "__main__":
    main()
