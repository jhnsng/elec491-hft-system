import socket

LISTEN_IP   = "0.0.0.0"
LISTEN_PORT = 9000

def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTEN_IP, LISTEN_PORT))
    srv.listen(1)

    print(f"Listening on {LISTEN_PORT}...")
    conn, addr = srv.accept()
    print(f"Connection from {addr}")

    while True:
        data = conn.recv(4096)
        if not data:
            print("Connection closed")
            break

        print(f"\nReceived {len(data)} bytes:")
        print("HEX :", data.hex())
        try:
            print("ASCII:", data.decode('ascii', errors='replace'))
        except:
            pass

    conn.close()
    srv.close()

if __name__ == "__main__":
    main()
