// The simple udp test sends "hello" using nc on the PC side and echos it
// Expected DE1 output:
//Listening on UDP port 12345...
//Received 6 bytes from 192.168.1.10:60181
//Data: 68 65 6c 6c 6f 0a
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define LISTEN_PORT 12345
#define BUF_SIZE 2048

int main(void)
{
    int sock;
    struct sockaddr_in local_addr;
    struct sockaddr_in sender_addr;
    socklen_t sender_len = sizeof(sender_addr);
    uint8_t buf[BUF_SIZE];

    /* 1. Create UDP socket */
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        exit(1);
    }

    /* 2. Bind socket to port */
    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family = AF_INET;
    local_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    local_addr.sin_port = htons(LISTEN_PORT);

    if (bind(sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        perror("bind");
        close(sock);
        exit(1);
    }

    printf("Listening on UDP port %d...\n", LISTEN_PORT);

    /* 3. Receive loop */
    while (1) {
        ssize_t n = recvfrom(sock,
                             buf,
                             BUF_SIZE,
                             0,
                             (struct sockaddr *)&sender_addr,
                             &sender_len);
        if (n < 0) {
            perror("recvfrom");
            break;
        }

        /* Print sender info */
        char sender_ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET,
                  &sender_addr.sin_addr,
                  sender_ip,
                  sizeof(sender_ip));

        printf("Received %zd bytes from %s:%d\n",
               n,
               sender_ip,
               ntohs(sender_addr.sin_port));

        /* Print first up to 16 bytes */
        printf("Data: ");
        for (int i = 0; i < n && i < 16; i++) {
            printf("%02x ", buf[i]);
        }
        printf("\n\n");
    }

    close(sock);
    return 0;
}
