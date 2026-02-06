#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

#define EXCH_IP   "192.168.1.10"   // laptop IP
#define EXCH_PORT 9000

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

    /* Two 32-bit FIFO-style words */
    uint32_t fifo_words[2];
    fifo_words[0] = htonl(0x44454144);  // "DEAD"
    fifo_words[1] = htonl(0x42454546);  // "BEEF"

    ssize_t sent = send(sock, fifo_words, sizeof(fifo_words), 0);
    if (sent < 0) {
        perror("send");
    } else {
        printf("Sent %zd bytes\n", sent);
    }

    close(sock);
    return 0;
}
