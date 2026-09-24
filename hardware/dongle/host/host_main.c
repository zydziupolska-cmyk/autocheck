/*
 * Kostka Dynomic OBD uruchomiona na PC: rdzeń firmware + symulator auta, dostęp
 * przez TCP (jak adapter Wi-Fi). Aplikacja łączy się z nim tak samo jak z vLinkerem.
 *
 *   ./dx_host [port]   (0 = wolny port; wypisuje "PORT <n>")
 */
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "elm_core.h"
#include "sim_car.h"

static int client = -1;
static uint32_t bitrate;
static bool listen_only;
static int verbose;

static uint32_t millis(void *ctx) {
    (void)ctx;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

static void do_write(void *ctx, const char *s, size_t n) {
    (void)ctx;
    if (client < 0) return;
    while (n) {
        ssize_t w = send(client, s, n, MSG_NOSIGNAL);
        if (w <= 0) return;
        s += w;
        n -= (size_t)w;
    }
}

static int can_send(void *ctx, const elm_frame_t *f) {
    (void)ctx;
    if (verbose) {
        fprintf(stderr, "TX %0*X", f->ext ? 8 : 3, f->id);
        for (int i = 0; i < f->dlc; i++) fprintf(stderr, " %02X", f->data[i]);
        fprintf(stderr, "\n");
    }
    return sim_car_on_frame(f, millis(NULL), bitrate, listen_only);
}

static int can_config(void *ctx, uint32_t br, bool lo) {
    (void)ctx;
    bitrate = br;
    listen_only = lo;
    return 0;
}

static float battery(void *ctx) {
    (void)ctx;
    return 14.2f;
}

int main(int argc, char **argv) {
    int port = argc > 1 ? atoi(argv[1]) : 35000;
    verbose = getenv("DX_VERBOSE") != NULL;
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(srv, (struct sockaddr *)&a, sizeof a) || listen(srv, 1)) {
        perror("bind");
        return 1;
    }
    socklen_t al = sizeof a;
    getsockname(srv, (struct sockaddr *)&a, &al);
    printf("PORT %d\n", ntohs(a.sin_port));
    fflush(stdout);

    elm_platform_t p = {
        .write = do_write, .can_send = can_send, .can_config = can_config, .millis = millis,
        .battery_volts = battery,
    };
    elm_t *e = calloc(1, sizeof *e);

    for (;;) {
        client = accept(srv, NULL, NULL);
        if (client < 0) continue;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        sim_car_reset();
        bitrate = 0;
        elm_init(e, &p);
        for (;;) {
            struct pollfd pf = {.fd = client, .events = POLLIN};
            int r = poll(&pf, 1, 1);
            if (r > 0) {
                char buf[256];
                ssize_t n = recv(client, buf, sizeof buf, 0);
                if (n <= 0) break;
                for (ssize_t i = 0; i < n; i++) elm_rx_char(e, buf[i]);
            }
            elm_frame_t f;
            while (sim_car_next(&f, millis(NULL), bitrate)) elm_can_rx(e, &f);
            elm_poll(e);
        }
        close(client);
        client = -1;
    }
}
