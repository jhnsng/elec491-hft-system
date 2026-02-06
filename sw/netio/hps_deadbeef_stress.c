#include <stdio.h>
#include <stdint.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

#define EXCH_IP   "192.168.1.10"   // laptop IP
#define EXCH_PORT 9000

#define NUM_MSGS  1000

int main(void)
{
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    int one = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(EXCH_PORT);

    if (inet_pton(AF_INET, EXCH_IP, &addr.sin_addr) != 1) {
        perror("inet_pton");
        return 1;
    }

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return 1;
    }

    printf("Connected to %s:%d\n", EXCH_IP, EXCH_PORT);

    uint32_t deadbeef[2];
    deadbeef[0] = htonl(0x44454144); // "DEAD"
    deadbeef[1] = htonl(0x42454546); // "BEEF"

    for (int i = 0; i < NUM_MSGS; i++) {
        ssize_t sent = send(sock, deadbeef, sizeof(deadbeef), 0);
        if (sent != sizeof(deadbeef)) {
            perror("send");
            break;
        }
    }

    printf("Sent %d DEADBEEF messages (%d bytes)\n",
           NUM_MSGS, NUM_MSGS * 8);

    close(sock);
    return 0;
}
