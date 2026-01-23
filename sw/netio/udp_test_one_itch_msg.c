#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define LISTEN_PORT 12345
#define MAX_MSG_SIZE 512

struct itch_msg_def {
    char type;
    int length; // total length including type byte
};

// Small ITCH v5.0 length table
static const struct itch_msg_def itch_table[] = {
    { 'S', 12 },
    { 'R', 39 },
    { 'A', 36 },
    { 'F', 40 },
    { 'E', 31 },
    { 'C', 36 },
    { 'X', 23 },
    { 'D', 19 },
    { 'U', 35 },
    { 'P', 44 },
};

static int get_itch_msg_length(unsigned char type)
{
    size_t count = sizeof(itch_table) / sizeof(itch_table[0]);
    for (size_t i = 0; i < count; i++) {
        if (itch_table[i].type == (char)type)
            return itch_table[i].length;
    }
    return -1;
}

int main(void)
{
    int sock;
    struct sockaddr_in local_addr;
    struct sockaddr_in sender_addr;
    socklen_t sender_len = sizeof(sender_addr);

    unsigned char buf[MAX_MSG_SIZE];

    sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family = AF_INET;
    local_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    local_addr.sin_port = htons(LISTEN_PORT);

    if (bind(sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        perror("bind");
        close(sock);
        return 1;
    }

    FILE *log = fopen("udp_one_itch_msg.log", "w");
    if (!log) {
        perror("fopen");
        close(sock);
        return 1;
    }

    printf("Listening for ITCH UDP packets on port %d...\n", LISTEN_PORT);

    while (1) {
        ssize_t n = recvfrom(sock,
                             buf,
                             sizeof(buf),
                             0,
                             (struct sockaddr *)&sender_addr,
                             &sender_len);
        if (n < 0) {
            perror("recvfrom");
            break;
        }

        if (n < 1) {
            fprintf(log, "Received empty UDP packet\n");
            continue;
        }

        unsigned char msg_type = buf[0];
        int expected_len = get_itch_msg_length(msg_type);

        if (expected_len < 0) {
            fprintf(log,
                    "Unknown ITCH message type '%c' (0x%02X), received %zd bytes\n",
                    (msg_type >= 32 && msg_type < 127) ? msg_type : '.',
                    msg_type,
                    n);
            fflush(log);
            continue;
        }

        fprintf(log, "Message type: '%c' (0x%02X)\n", msg_type, msg_type);
        fprintf(log, "Expected length: %d bytes\n", expected_len);
        fprintf(log, "Actually received: %zd bytes\n", n);

        if (n != expected_len) {
            fprintf(log,
                    "WARNING: length mismatch (expected %d, got %zd)\n",
                    expected_len, n);
        }

        fprintf(log, "Data (hex):\n");
        for (ssize_t i = 0; i < n; i++) {
            fprintf(log, "%02X ", buf[i]);
        }
        fprintf(log, "\n\n");
        fflush(log);

        printf("Received ITCH type '%c', %zd bytes\n", msg_type, n);
    }

    fclose(log);
    close(sock);
    return 0;
}
