# The simple udp test sends "hello" using nc on the PC side and echos it
# Expected DE1 output:
#Listening on UDP port 12345...
#Received 6 bytes from 192.168.1.10:60181
#Data: 68 65 6c 6c 6f 0a

import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"hello\n", ("192.168.1.123", 12345))
print("sent")