import socket

LISTEN_IP   = "0.0.0.0"
LISTEN_PORT = 9000

PATTERN = b"DEADBEEF"
pat_len = len(PATTERN)

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((LISTEN_IP, LISTEN_PORT))
srv.listen(1)

print(f"Listening on {LISTEN_PORT}...")
conn, addr = srv.accept()
print(f"Connection from {addr}")

buffer = b""
count  = 0

while True:
    data = conn.recv(4096)
    if not data:
        break

    buffer += data

    # Scan for complete patterns
    while True:
        idx = buffer.find(PATTERN)
        if idx == -1:
            break
        count += 1
        buffer = buffer[idx + pat_len:]

print(f"Total DEADBEEF messages received: {count}")

conn.close()
srv.close()
