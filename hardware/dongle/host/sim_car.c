/*
 * Symulator auta (VW Touran 1T 2.0 TDI) na poziomie ramek CAN 11-bit 500 kb/s:
 *  - silnik 7E0/7E8: OBD Mode 01/03/09, UDS 22 (VIN, doładowanie), wieloramkowe
 *    odpowiedzi ISO-TP z czekaniem na ramkę sterowania przepływem,
 *  - skrzynia 7E1/7E9: odpowiada na 0100,
 *  - moduł silnika przez VW TP2.0 (adres 01, kanał 740/300): KWP 10 89, 1A 9B, 18, 21,
 *  - ruch w tle: ramka 280 co 10 ms (widoczna tylko w podsłuchu).
 */
#include "sim_car.h"

#include <string.h>

#define QMAX 256
typedef struct {
    elm_frame_t f;
    uint32_t at;
} queued_t;

static queued_t q[QMAX];
static int qn;
static uint32_t last_bg;
static uint8_t bg_counter;

static void enqueue(uint32_t id, const uint8_t *data, uint8_t len, uint32_t at) {
    if (qn >= QMAX) return;
    queued_t *x = &q[qn++];
    memset(x, 0, sizeof *x);
    x->f.id = id;
    x->f.ext = false;
    x->f.dlc = len;
    memcpy(x->f.data, data, len);
    x->at = at;
}

static const char VIN[] = "WVGZZZ1TZFW011407";

/* ---------------- ISO-TP po stronie sterownika ---------------- */

typedef struct {
    uint32_t tx_id;       /* odpowiedź ECU (np. 7E8) */
    uint8_t buf[512];
    int len, pos;
    uint8_t sn;
    bool waiting_fc;
} isotp_tx_t;

static isotp_tx_t eng = {.tx_id = 0x7E8};

static void isotp_send(isotp_tx_t *t, const uint8_t *msg, int len, uint32_t now) {
    if (len <= 7) {
        uint8_t d[8] = {(uint8_t)len};
        memcpy(d + 1, msg, len);
        for (int i = len + 1; i < 8; i++) d[i] = 0xAA;
        enqueue(t->tx_id, d, 8, now + 2);
        return;
    }
    memcpy(t->buf, msg, len);
    t->len = len;
    uint8_t d[8] = {(uint8_t)(0x10 | (len >> 8)), (uint8_t)(len & 0xFF)};
    memcpy(d + 2, msg, 6);
    t->pos = 6;
    t->sn = 1;
    t->waiting_fc = true;
    enqueue(t->tx_id, d, 8, now + 2);
}

static void isotp_on_fc(isotp_tx_t *t, uint32_t now) {
    if (!t->waiting_fc) return;
    t->waiting_fc = false;
    uint32_t at = now + 1;
    while (t->pos < t->len) {
        uint8_t d[8];
        d[0] = (uint8_t)(0x20 | (t->sn++ & 0x0F));
        int n = t->len - t->pos;
        if (n > 7) n = 7;
        memcpy(d + 1, t->buf + t->pos, n);
        for (int i = n + 1; i < 8; i++) d[i] = 0xAA;
        t->pos += n;
        enqueue(t->tx_id, d, 8, at++);
    }
}

/* ---------------- Silnik (OBD / UDS) ---------------- */

static uint32_t t_start;

static double rpm_now(uint32_t now) {
    /* Obroty „pływają” 800–2600, żeby odczyty się zmieniały */
    uint32_t phase = (now - t_start) % 4000;
    return 800.0 + (phase < 2000 ? phase : 4000 - phase) * 0.9;
}

static int pid_data(uint8_t pid, uint32_t now, uint8_t *out) {
    switch (pid) {
    case 0x00: /* 01-20: 05 0B 0C 0D 20 */
        out[0] = 0x08; out[1] = 0x38; out[2] = 0x00; out[3] = 0x01;
        return 4;
    case 0x20: /* 21-40: 33 40 */
        out[0] = 0x00; out[1] = 0x00; out[2] = 0x20; out[3] = 0x01;
        return 4;
    case 0x40: /* 41-60: 60 */
        out[0] = 0x00; out[1] = 0x00; out[2] = 0x00; out[3] = 0x01;
        return 4;
    case 0x60: /* 61-80: 70 */
        out[0] = 0x00; out[1] = 0x01; out[2] = 0x00; out[3] = 0x00;
        return 4;
    case 0x05:
        out[0] = 90 + 40;
        return 1;
    case 0x0B: {
        double rpm = rpm_now(now);
        out[0] = (uint8_t)(100 + (rpm - 800) / 20);
        return 1;
    }
    case 0x0C: {
        unsigned v = (unsigned)(rpm_now(now) * 4);
        out[0] = (uint8_t)(v >> 8); out[1] = (uint8_t)v;
        return 2;
    }
    case 0x0D:
        out[0] = 42;
        return 1;
    case 0x33:
        out[0] = 99;
        return 1;
    case 0x70: { /* doładowanie A: zadane i rzeczywiste, 1/32 kPa */
        double actual = 100 + (rpm_now(now) - 800) / 20;
        unsigned tgt = (unsigned)((actual + 15) * 32), act = (unsigned)(actual * 32);
        out[0] = 0x03;
        out[1] = (uint8_t)(tgt >> 8); out[2] = (uint8_t)tgt;
        out[3] = (uint8_t)(act >> 8); out[4] = (uint8_t)act;
        memset(out + 5, 0, 5);
        return 10;
    }
    default:
        return -1;
    }
}

static void engine_request(const uint8_t *req, int len, uint32_t now, bool functional) {
    uint8_t resp[128];
    int n = 0;
    if (req[0] == 0x01 && len >= 2) {
        resp[n++] = 0x41;
        for (int i = 1; i < len && i <= 6; i++) {
            uint8_t tmp[16];
            int k = pid_data(req[i], now, tmp);
            if (k < 0) continue;
            resp[n++] = req[i];
            memcpy(resp + n, tmp, k);
            n += k;
        }
        if (n == 1) {
            if (functional) return; /* na zapytanie funkcyjne ECU milczy */
            resp[0] = 0x7F; resp[1] = 0x01; resp[2] = 0x12; n = 3;
        }
    } else if (req[0] == 0x09 && len >= 2 && req[1] == 0x02) {
        resp[n++] = 0x49; resp[n++] = 0x02; resp[n++] = 0x01;
        memcpy(resp + n, VIN, 17);
        n += 17;
    } else if (req[0] == 0x09 && len >= 2 && req[1] == 0x00) {
        uint8_t r[] = {0x49, 0x00, 0x55, 0x40, 0x00, 0x00};
        memcpy(resp, r, sizeof r);
        n = sizeof r;
    } else if (req[0] == 0x03) {
        uint8_t r[] = {0x43, 0x01, 0x02, 0x99}; /* P0299 */
        memcpy(resp, r, sizeof r);
        n = sizeof r;
    } else if (req[0] == 0x07) {
        resp[n++] = 0x47; resp[n++] = 0x00;
    } else if (req[0] == 0x22 && len >= 3) {
        uint16_t did = (uint16_t)((req[1] << 8) | req[2]);
        resp[n++] = 0x62; resp[n++] = req[1]; resp[n++] = req[2];
        if (did == 0xF190) {
            memcpy(resp + n, VIN, 17);
            n += 17;
        } else if (did == 0x202A) {
            unsigned hpa = (unsigned)((100 + (rpm_now(now) - 800) / 20) * 10);
            resp[n++] = (uint8_t)(hpa >> 8); resp[n++] = (uint8_t)hpa;
        } else {
            n = 0;
            resp[n++] = 0x7F; resp[n++] = 0x22; resp[n++] = 0x31;
        }
    } else {
        if (functional) return;
        resp[n++] = 0x7F; resp[n++] = req[0]; resp[n++] = 0x11;
    }
    isotp_send(&eng, resp, n, now);
}

/* ---------------- TP2.0 (moduł silnika, adres 01) ---------------- */

static struct {
    bool open;
    uint8_t rx[256];
    int rx_len, rx_need;
    uint8_t tx_seq;
} tp;

static void tp_send_msg(const uint8_t *msg, int len, uint32_t now) {
    uint8_t payload[260];
    payload[0] = (uint8_t)(len >> 8);
    payload[1] = (uint8_t)len;
    memcpy(payload + 2, msg, len);
    int total = len + 2;
    uint32_t at = now + 2;
    for (int i = 0; i < total; i += 7) {
        int n = total - i < 7 ? total - i : 7;
        bool last = i + 7 >= total;
        uint8_t d[8];
        d[0] = (uint8_t)((last ? 0x10 : 0x20) | (tp.tx_seq++ & 0x0F));
        memcpy(d + 1, payload + i, n);
        enqueue(0x300, d, (uint8_t)(n + 1), at++);
    }
}

static void tp_kwp(const uint8_t *m, int len, uint32_t now) {
    if (len >= 2 && m[0] == 0x10) {
        uint8_t r[] = {0x50, m[1]};
        tp_send_msg(r, 2, now);
    } else if (len >= 2 && m[0] == 0x1A) {
        const char *id = "03L906023PJ  R4 2,0L EDC G000SG  5201";
        uint8_t r[64] = {0x5A, m[1]};
        int n = 2 + (int)strlen(id);
        memcpy(r + 2, id, strlen(id));
        tp_send_msg(r, n, now);
    } else if (len >= 1 && m[0] == 0x18) {
        uint8_t r[] = {0x58, 0x01, 0x41, 0xAB, 0x23}; /* 16811 = P0427? kod testowy */
        tp_send_msg(r, sizeof r, now);
    } else if (len >= 2 && m[0] == 0x21) {
        /* Blok 011: obroty 1280, temp. 90°C, (formuła, NW, MW) ×4 */
        uint8_t r[] = {0x61, m[1], 0x01, 0xC8, 0x20, 0x05, 0x0A, 0xBE, 0x01, 0xC8, 0x20, 0x05, 0x0A, 0xBE};
        tp_send_msg(r, sizeof r, now);
    } else {
        uint8_t r[] = {0x7F, m[0], 0x11};
        tp_send_msg(r, 3, now);
    }
}

static void tp_frame(const elm_frame_t *f, uint32_t now) {
    if (!f->dlc) return;
    uint8_t b0 = f->data[0];
    if (b0 == 0xA0 || b0 == 0xA3) {
        uint8_t r[] = {0xA1, 0x0F, 0x8A, 0xFF, 0x4A, 0xFF};
        enqueue(0x300, r, 6, now + 2);
        return;
    }
    if (b0 == 0xA8) {
        tp.open = false;
        return;
    }
    if ((b0 & 0xF0) == 0xB0) return; /* ACK od testera */
    uint8_t op = b0 >> 4, seq = b0 & 0x0F;
    if (op > 3) return;
    const uint8_t *body = f->data + 1;
    int blen = f->dlc - 1;
    if (tp.rx_need == 0) {
        if (blen < 2) return;
        tp.rx_need = (body[0] << 8) | body[1];
        tp.rx_len = 0;
        body += 2;
        blen -= 2;
    }
    memcpy(tp.rx + tp.rx_len, body, blen);
    tp.rx_len += blen;
    if (!(op & 0x2)) {
        uint8_t ack = (uint8_t)(0xB0 | ((seq + 1) & 0x0F));
        enqueue(0x300, &ack, 1, now + 1);
    }
    if (op & 0x1) {
        int n = tp.rx_len < tp.rx_need ? tp.rx_len : tp.rx_need;
        tp.rx_need = 0;
        tp_kwp(tp.rx, n, now + 1);
    }
}

/* ---------------- API ---------------- */

void sim_car_reset(void) {
    qn = 0;
    memset(&tp, 0, sizeof tp);
    eng.waiting_fc = false;
    t_start = 0;
    last_bg = 0;
}

int sim_car_on_frame(const elm_frame_t *f, uint32_t now, uint32_t bitrate, bool listen_only) {
    if (listen_only) return -1;       /* w trybie cichym kontroler nie nadaje */
    if (bitrate != 500000) return -1; /* zła prędkość = błędy, brak ACK */
    if (f->ext) return 0;             /* 29-bit: potwierdzone, ale nikt nie odpowiada */
    if (!t_start) t_start = now;

    if (f->id == 0x7DF || f->id == 0x7E0) {
        uint8_t pci = f->data[0] >> 4;
        if (pci == 0x0) {
            int len = f->data[0] & 0x0F;
            engine_request(f->data + 1, len, now, f->id == 0x7DF);
            /* Skrzynia odpowiada tylko na funkcyjne 0100 */
            if (f->id == 0x7DF && len >= 2 && f->data[1] == 0x01 && f->data[2] == 0x00) {
                uint8_t d[8] = {0x06, 0x41, 0x00, 0x80, 0x00, 0x00, 0x01, 0xAA};
                enqueue(0x7E9, d, 8, now + 4);
            }
        } else if (pci == 0x3 && f->id == 0x7E0) {
            isotp_on_fc(&eng, now);
        }
        return 0;
    }
    if (f->id == 0x200 && f->dlc >= 7 && f->data[0] == 0x01 && f->data[1] == 0xC0) {
        uint8_t r[] = {0x00, 0xD0, 0x00, 0x03, 0x40, 0x07, 0x01};
        tp.open = true;
        tp.tx_seq = 0;
        tp.rx_need = 0;
        enqueue(0x201, r, 7, now + 2);
        return 0;
    }
    if (f->id == 0x740 && tp.open) {
        tp_frame(f, now);
        return 0;
    }
    return 0;
}

int sim_car_next(elm_frame_t *out, uint32_t now, uint32_t bitrate) {
    /* Ruch w tle (np. dane z zestawu wskaźników) */
    if (bitrate == 500000 && now - last_bg >= 10) {
        last_bg = now;
        uint8_t d[8] = {0x49, 0x0E, 0x00, 0x00, 0x0E, 0x00, 0x1B, bg_counter++};
        enqueue(0x280, d, 8, now);
    }
    int best = -1;
    for (int i = 0; i < qn; i++) {
        if ((int32_t)(now - q[i].at) >= 0 && (best < 0 || (int32_t)(q[i].at - q[best].at) < 0)) best = i;
    }
    if (best < 0) return 0;
    *out = q[best].f;
    q[best] = q[--qn];
    return bitrate == 500000;
}
