import socket

LISTEN_IP   = "0.0.0.0"
LISTEN_PORT = 9000

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((LISTEN_IP, LISTEN_PORT))
srv.listen(1)

print(f"Listening on {LISTEN_PORT}...")
conn, addr = srv.accept()
print(f"Connection from {addr}")

data = conn.recv(1024)
print("Received bytes:", len(data))
print("HEX  :", data.hex())
print("ASCII:", data.decode('ascii', errors='replace'))

conn.close()
srv.close()
