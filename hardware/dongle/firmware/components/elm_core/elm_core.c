/*
 * Dynomic OBD — interpreter komend zgodny z ELM327 v2.2 i podzbiorem STN.
 *
 * Obsługiwane: komendy AT używane przez aplikacje diagnostyczne (E/L/S/H/CAF/SH/CP/
 * CRA/CF/CM/FCSH/FCSD/FCSM/ST/AT/SP/TP/PB/DP/DPN/RV/I/@1/Z/WS/D/CSM/MA), zapytania OBD
 * z liczbą oczekiwanych odpowiedzi ("010C1"), ISO-TP w obie strony (wysyłanie
 * i odbiór długich wiadomości z ramką sterowania przepływem), surowy CAN
 * (protokół użytkownika B — np. VW TP2.0), STI/STDI, STPX i STMA.
 */
#include "elm_core.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------------- */
/* Wyjście                                                                   */
/* ------------------------------------------------------------------------- */

static int hexval(char c);
static int parse_bytes(const char *s, uint8_t *outb, int max);

static void out(elm_t *e, const char *s) { e->p.write(e->p.ctx, s, strlen(s)); }

static void eol(elm_t *e) { out(e, e->linefeeds ? "\r\n" : "\r"); }

static void out_line(elm_t *e, const char *s) {
    out(e, s);
    eol(e);
    e->any_output = true;
}

static void prompt(elm_t *e) {
    eol(e);
    out(e, ">");
    e->state = ELM_IDLE;
}

static void reply(elm_t *e, const char *s) {
    out_line(e, s);
    prompt(e);
}

static uint32_t now(elm_t *e) { return e->p.millis(e->p.ctx); }

static bool time_reached(uint32_t t, uint32_t deadline) { return (int32_t)(t - deadline) >= 0; }

/* ------------------------------------------------------------------------- */
/* Protokoły                                                                 */
/* ------------------------------------------------------------------------- */

static uint8_t active_protocol(const elm_t *e) { return e->protocol; }

static bool is_ext(const elm_t *e) {
    switch (active_protocol(e)) {
    case 7:
    case 9:
        return true;
    case 0xB:
        return (e->user_b_opts & 0x80) == 0;
    default:
        return false;
    }
}

uint32_t elm_bitrate(const elm_t *e) {
    switch (active_protocol(e)) {
    case 6:
    case 7:
        return 500000;
    case 8:
    case 9:
        return 250000;
    case 0xB:
        return e->user_b_div ? 500000u / e->user_b_div : 500000u;
    default:
        return 0;
    }
}

/* Formatowanie ISO-TP (bajt PCI) — w protokołach 6–9 zawsze, w B zależnie od ATPB. */
static bool isotp_active(const elm_t *e) {
    if (!e->caf) return false;
    if (active_protocol(e) == 0xB) return (e->user_b_opts & 0x07) == 0x01;
    return true;
}

/* Ramki zawsze 8-bajtowe (dopełnione), poza protokołem B ze zmienną długością. */
static bool fixed_dlc(const elm_t *e) {
    if (active_protocol(e) == 0xB) return (e->user_b_opts & 0x40) == 0;
    return true;
}

static uint32_t timeout_ms(const elm_t *e) { return (uint32_t)(e->st ? e->st : 0x32) * 4u; }

static uint32_t tx_header(const elm_t *e) {
    if (is_ext(e)) {
        uint32_t low = e->header_set ? (e->header & 0xFFFFFFu) : 0xDB33F1u;
        return ((uint32_t)e->priority << 24) | low;
    }
    return e->header_set ? (e->header & 0x7FFu) : 0x7DFu;
}

static bool is_obd_header(uint32_t h) { return h == 0x7DF || (h >= 0x7E0 && h <= 0x7E7); }

static int configure_can(elm_t *e, bool listen_only) {
    uint32_t br = elm_bitrate(e);
    if (!br) return -1;
    return e->p.can_config(e->p.ctx, br, listen_only);
}

/* Czy odebrana ramka przechodzi przez filtr odbioru. */
static bool accept(const elm_t *e, const elm_frame_t *f, bool monitor) {
    bool ext = is_ext(e);
    bool both = active_protocol(e) == 0xB && (e->user_b_opts & 0x20);
    if (!both && f->ext != ext) return false;
    if (e->cra_set) return (f->id & e->cra_mask) == (e->cra_value & e->cra_mask);
    if (monitor || active_protocol(e) == 0xB) return true;
    if (f->ext) return (f->id & 0x1FFFFF00u) == 0x18DAF100u;
    uint32_t h = tx_header(e);
    if (is_obd_header(h)) return f->id >= 0x7E8 && f->id <= 0x7EF;
    /* Inne adresy (np. moduły VAG 714 → 77E): każda odpowiedź 7xx poza własnym nadawaniem */
    return f->id >= 0x700 && f->id <= 0x7FF && f->id != h;
}

/* ------------------------------------------------------------------------- */
/* Formatowanie ramek                                                        */
/* ------------------------------------------------------------------------- */

static void append_hex(elm_t *e, char *buf, size_t *pos, size_t cap, uint8_t b) {
    if (*pos && e->spaces && *pos + 1 < cap) buf[(*pos)++] = ' ';
    if (*pos + 2 < cap) {
        static const char hx[] = "0123456789ABCDEF";
        buf[(*pos)++] = hx[b >> 4];
        buf[(*pos)++] = hx[b & 0xF];
    }
    buf[*pos] = 0;
}

static void append_header(elm_t *e, char *buf, size_t *pos, size_t cap, const elm_frame_t *f) {
    if (f->ext) {
        for (int i = 3; i >= 0; i--) append_hex(e, buf, pos, cap, (uint8_t)(f->id >> (8 * i)));
    } else {
        *pos += (size_t)snprintf(buf + *pos, cap - *pos, "%03X", (unsigned)(f->id & 0x7FF));
    }
}

/* Linia z nagłówkiem (gdy ATH1) i bajtami [from, to). */
static void print_frame(elm_t *e, const elm_frame_t *f, int from, int to) {
    char buf[64];
    size_t pos = 0;
    buf[0] = 0;
    if (e->headers) append_header(e, buf, &pos, sizeof buf, f);
    if (e->headers && e->dlc_display) {
        if (e->spaces) buf[pos++] = ' ';
        buf[pos++] = (char)('0' + f->dlc);
        buf[pos] = 0;
    }
    for (int i = from; i < to && i < f->dlc; i++) append_hex(e, buf, &pos, sizeof buf, f->data[i]);
    out_line(e, buf);
}

/* ------------------------------------------------------------------------- */
/* Nadawanie                                                                 */
/* ------------------------------------------------------------------------- */

static int send_raw(elm_t *e, uint32_t id, bool ext, const uint8_t *data, uint8_t len, bool pad) {
    elm_frame_t f = {.id = id, .ext = ext, .dlc = len};
    memcpy(f.data, data, len);
    if (pad) {
        for (int i = len; i < 8; i++) f.data[i] = 0x00;
        f.dlc = 8;
    }
    return e->p.can_send(e->p.ctx, &f);
}

/* Ramka sterowania przepływem po odebraniu pierwszej ramki długiej odpowiedzi. */
static void send_flow_control(elm_t *e, const elm_frame_t *ff) {
    uint32_t id;
    uint8_t data[8] = {0x30, 0x00, 0x00};
    uint8_t len = 3;
    if (e->fc_custom) {
        id = e->fc_header;
        memcpy(data, e->fc_data, e->fc_len);
        len = e->fc_len;
    } else if (ff->ext) {
        /* 18DA F1 xx → 18DA xx F1 */
        id = (ff->id & 0xFFFF0000u) | ((ff->id & 0xFFu) << 8) | ((ff->id >> 8) & 0xFFu);
    } else if (ff->id >= 0x7E8 && ff->id <= 0x7EF) {
        id = ff->id - 8;
    } else {
        id = tx_header(e);
    }
    send_raw(e, id, ff->ext, data, len, true);
}

static void finish(elm_t *e) {
    if (!e->any_output) out_line(e, "NO DATA");
    prompt(e);
}

static void fail(elm_t *e, const char *msg) {
    out_line(e, msg);
    prompt(e);
}

/* Rozpoczyna wysyłanie zapytania (dane bez PCI). */
static void start_request(elm_t *e, const uint8_t *data, uint16_t len, int expected) {
    e->expected = expected;
    e->responses = 0;
    e->any_output = false;
    memset(e->slots, 0, sizeof e->slots);
    e->tx_id = tx_header(e);
    e->tx_ext = is_ext(e);

    if (!isotp_active(e)) {
        /* Surowa ramka — do 8 bajtów, bez PCI */
        if (len > 8) {
            fail(e, "?");
            return;
        }
        if (send_raw(e, e->tx_id, e->tx_ext, data, (uint8_t)len, fixed_dlc(e)) != 0) {
            fail(e, "CAN ERROR");
            return;
        }
        e->state = ELM_WAIT_RESPONSE;
        e->deadline = now(e) + timeout_ms(e);
        return;
    }

    if (len <= 7) {
        uint8_t buf[8];
        buf[0] = (uint8_t)len;
        memcpy(buf + 1, data, len);
        if (send_raw(e, e->tx_id, e->tx_ext, buf, (uint8_t)(len + 1), fixed_dlc(e)) != 0) {
            fail(e, "CAN ERROR");
            return;
        }
        e->state = ELM_WAIT_RESPONSE;
        e->deadline = now(e) + timeout_ms(e);
        return;
    }

    /* Długie zapytanie: pierwsza ramka, potem czekamy na sterowanie przepływem */
    memcpy(e->tx_buf, data, len);
    e->tx_len = len;
    uint8_t ff[8] = {(uint8_t)(0x10 | (len >> 8)), (uint8_t)(len & 0xFF)};
    memcpy(ff + 2, data, 6);
    e->tx_pos = 6;
    e->tx_sn = 1;
    if (send_raw(e, e->tx_id, e->tx_ext, ff, 8, false) != 0) {
        fail(e, "CAN ERROR");
        return;
    }
    e->state = ELM_TX_WAIT_FC;
    e->deadline = now(e) + 1000;
}

static void send_next_cf(elm_t *e) {
    uint8_t cf[8];
    cf[0] = (uint8_t)(0x20 | (e->tx_sn & 0x0F));
    uint16_t n = e->tx_len - e->tx_pos;
    if (n > 7) n = 7;
    memcpy(cf + 1, e->tx_buf + e->tx_pos, n);
    if (send_raw(e, e->tx_id, e->tx_ext, cf, (uint8_t)(n + 1), fixed_dlc(e)) != 0) {
        fail(e, "CAN ERROR");
        return;
    }
    e->tx_pos += n;
    e->tx_sn++;
    if (e->tx_pos >= e->tx_len) {
        e->state = ELM_WAIT_RESPONSE;
        e->deadline = now(e) + timeout_ms(e);
        return;
    }
    if (e->tx_bs && ++e->tx_bs_count >= e->tx_bs) {
        e->tx_bs_count = 0;
        e->state = ELM_TX_WAIT_FC;
        e->deadline = now(e) + 1000;
        return;
    }
    /* STmin: 0x00–0x7F ms, 0xF1–0xF9 = 100–900 µs (zaokrąglamy do 1 ms) */
    uint32_t gap = e->tx_stmin <= 0x7F ? e->tx_stmin : 1;
    e->tx_next_at = now(e) + gap;
}

/* ------------------------------------------------------------------------- */
/* Odbiór                                                                    */
/* ------------------------------------------------------------------------- */

static elm_rx_slot_t *slot_for(elm_t *e, const elm_frame_t *f, bool create) {
    elm_rx_slot_t *free_slot = NULL;
    for (int i = 0; i < ELM_RX_SLOTS; i++) {
        elm_rx_slot_t *s = &e->slots[i];
        if (s->active && s->id == f->id && s->ext == f->ext) return s;
        if (!s->active && !free_slot) free_slot = s;
    }
    if (!create || !free_slot) return NULL;
    free_slot->active = true;
    free_slot->id = f->id;
    free_slot->ext = f->ext;
    return free_slot;
}

static void count_response(elm_t *e) {
    e->responses++;
    if (e->expected > 0 && e->responses >= e->expected) finish(e);
}

static void handle_response_frame(elm_t *e, const elm_frame_t *f) {
    e->deadline = now(e) + timeout_ms(e);

    if (!isotp_active(e)) {
        print_frame(e, f, 0, f->dlc);
        count_response(e);
        return;
    }
    if (f->dlc == 0) return;
    uint8_t pci = f->data[0] >> 4;
    switch (pci) {
    case 0x0: { /* pojedyncza ramka */
        int len = f->data[0] & 0x0F;
        if (len == 0 || len > f->dlc - 1) return;
        print_frame(e, f, e->headers ? 0 : 1, 1 + len);
        count_response(e);
        break;
    }
    case 0x1: { /* pierwsza ramka */
        if (f->dlc < 8) return;
        send_flow_control(e, f);
        elm_rx_slot_t *s = slot_for(e, f, true);
        if (!s) return;
        s->length = (uint16_t)(((f->data[0] & 0x0F) << 8) | f->data[1]);
        s->received = 6;
        s->next_sn = 1;
        if (e->headers) {
            print_frame(e, f, 0, 8);
        } else {
            char len_line[8];
            snprintf(len_line, sizeof len_line, "%03X", s->length);
            out_line(e, len_line);
            char buf[48];
            size_t pos = (size_t)snprintf(buf, sizeof buf, "0:");
            for (int i = 2; i < 8; i++) append_hex(e, buf, &pos, sizeof buf, f->data[i]);
            out_line(e, buf);
        }
        break;
    }
    case 0x2: { /* ramka kolejna */
        elm_rx_slot_t *s = slot_for(e, f, false);
        if (e->headers) {
            print_frame(e, f, 0, f->dlc);
        } else if (s) {
            char buf[48];
            size_t pos = (size_t)snprintf(buf, sizeof buf, "%X:", f->data[0] & 0x0F);
            int remaining = s->length - s->received;
            int n = remaining < 7 ? remaining : 7;
            for (int i = 1; i <= n && i < f->dlc; i++) append_hex(e, buf, &pos, sizeof buf, f->data[i]);
            out_line(e, buf);
        }
        if (s) {
            s->received += 7;
            if (s->received >= s->length) {
                s->active = false;
                count_response(e);
            }
        }
        break;
    }
    default:
        break; /* sterowanie przepływem od ECU w trakcie odbioru — pomijamy */
    }
}

/* ------------------------------------------------------------------------- */
/* Automatyczny wybór protokołu                                              */
/* ------------------------------------------------------------------------- */

static const uint8_t search_order[] = {6, 8, 7, 9};

/*
 * Jak w ELM327: każdy kandydat jest sprawdzany właściwym zapytaniem użytkownika
 * (adresem funkcyjnym). Pierwsza pasująca odpowiedź ustala protokół i jest już
 * częścią wyniku — nic nie jest wysyłane dwa razy.
 */
static void search_try(elm_t *e) {
    uint8_t req[8];
    uint16_t len = 0;
    const char *hex = e->pending_cmd;
    size_t n = strlen(hex);
    int expected = 0;
    char buf[ELM_LINE_MAX];
    strncpy(buf, hex, sizeof buf - 1);
    buf[sizeof buf - 1] = 0;
    if (n % 2) {
        expected = hexval(buf[n - 1]);
        buf[n - 1] = 0;
    }
    uint8_t bytes[ELM_LINE_MAX / 2];
    int bl = parse_bytes(buf, bytes, (int)sizeof bytes);
    if (bl <= 0 || bl > 7) {
        /* Długie zapytanie — sprawdzamy protokół zwykłym 0100 */
        bytes[0] = 0x01;
        bytes[1] = 0x00;
        bl = 2;
    }
    req[0] = (uint8_t)bl;
    memcpy(req + 1, bytes, (size_t)bl);
    len = (uint16_t)(bl + 1);

    while (e->search_idx < sizeof search_order) {
        e->protocol = search_order[e->search_idx];
        if (configure_can(e, false) == 0) {
            uint32_t id = e->header_set ? tx_header(e) : (is_ext(e) ? 0x18DB33F1u : 0x7DFu);
            if (send_raw(e, id, is_ext(e), req, (uint8_t)len, true) == 0) {
                e->expected = expected;
                e->responses = 0;
                memset(e->slots, 0, sizeof e->slots);
                e->deadline = now(e) + 300;
                return;
            }
        }
        e->search_idx++;
    }
    /* Nic nie odpowiedziało */
    e->protocol = 0;
    e->protocol_found = false;
    fail(e, "UNABLE TO CONNECT");
}

static void run_obd(elm_t *e, const char *cmd);

/* ------------------------------------------------------------------------- */
/* Parsowanie                                                                */
/* ------------------------------------------------------------------------- */

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static bool is_hex_str(const char *s) {
    if (!*s) return false;
    for (; *s; s++)
        if (hexval(*s) < 0) return false;
    return true;
}

static bool parse_hex_u32(const char *s, uint32_t *out_v) {
    if (!is_hex_str(s) || strlen(s) > 8) return false;
    *out_v = (uint32_t)strtoul(s, NULL, 16);
    return true;
}

/* Bajty z ciągu hex; zwraca liczbę bajtów albo -1. */
static int parse_bytes(const char *s, uint8_t *outb, int max) {
    size_t n = strlen(s);
    if (n % 2) return -1;
    int count = 0;
    for (size_t i = 0; i < n; i += 2) {
        int hi = hexval(s[i]), lo = hexval(s[i + 1]);
        if (hi < 0 || lo < 0 || count >= max) return -1;
        outb[count++] = (uint8_t)((hi << 4) | lo);
    }
    return count;
}

/* Filtr z cyframi X (np. "7XX", "18DAF1XX"). */
static bool parse_filter(const char *s, uint32_t *value, uint32_t *mask) {
    size_t n = strlen(s);
    if (n != 3 && n != 8) return false;
    uint32_t v = 0, m = 0;
    for (size_t i = 0; i < n; i++) {
        v <<= 4;
        m <<= 4;
        if (s[i] == 'X') continue;
        int h = hexval(s[i]);
        if (h < 0) return false;
        v |= (uint32_t)h;
        m |= 0xF;
    }
    if (n == 3) m &= 0x7FF;
    *value = v;
    *mask = m;
    return true;
}

/* ------------------------------------------------------------------------- */
/* Komendy                                                                   */
/* ------------------------------------------------------------------------- */

static void set_defaults(elm_t *e) {
    e->echo = true;
    e->linefeeds = false;
    e->spaces = true;
    e->headers = false;
    e->caf = true;
    e->dlc_display = false;
    e->protocol = 0;
    e->protocol_auto = false;
    e->protocol_found = false;
    e->user_b_opts = 0xC0;
    e->user_b_div = 0x01;
    e->st = 0x32;
    e->header_set = false;
    e->priority = 0x18;
    e->cra_set = false;
    e->fc_custom = false;
    e->fc_len = 3;
    e->fc_data[0] = 0x30;
    e->fc_data[1] = 0x00;
    e->fc_data[2] = 0x00;
    e->silent_monitor = true;
}

static const char *protocol_name(uint8_t p) {
    switch (p) {
    case 6:
        return "ISO 15765-4 (CAN 11/500)";
    case 7:
        return "ISO 15765-4 (CAN 29/500)";
    case 8:
        return "ISO 15765-4 (CAN 11/250)";
    case 9:
        return "ISO 15765-4 (CAN 29/250)";
    case 0xB:
        return "USER1 (CAN 11/500)";
    default:
        return "AUTO";
    }
}

static void set_protocol(elm_t *e, const char *arg) {
    if (arg[0] == 'A') arg++; /* SPA6 = automatyczny z preferencją 6 */
    int p = hexval(arg[0]);
    if (p < 0 || arg[1]) {
        reply(e, "?");
        return;
    }
    if (p == 0) {
        e->protocol = 0;
        e->protocol_found = false;
        e->protocol_auto = false;
    } else if ((p >= 6 && p <= 9) || p == 0xB) {
        e->protocol = (uint8_t)p;
        e->protocol_found = true;
        e->protocol_auto = false;
        configure_can(e, false);
    } else {
        /* K-Line / J1850 — ta kostka ich nie ma */
        reply(e, "?");
        return;
    }
    reply(e, "OK");
}

static void start_monitor(elm_t *e) {
    if (!e->protocol_found) {
        if (e->protocol == 0) e->protocol = 6; /* bez wyszukiwania: domyślnie CAN 11/500 */
        e->protocol_found = true;
    }
    configure_can(e, e->silent_monitor);
    e->state = ELM_MONITOR;
    e->any_output = false;
}

static void at_command(elm_t *e, const char *c) {
    /* c: komenda bez "AT", wielkimi literami, bez spacji */
    if (!*c) return reply(e, "OK");
    if (!strcmp(c, "Z") || !strcmp(c, "WS")) {
        set_defaults(e);
        eol(e);
        eol(e);
        out(e, ELM_VERSION_STRING);
        eol(e);
        prompt(e);
        return;
    }
    if (!strcmp(c, "D")) {
        set_defaults(e);
        return reply(e, "OK");
    }
    if (!strcmp(c, "I")) return reply(e, ELM_VERSION_STRING);
    if (!strcmp(c, "@1")) return reply(e, DX_DEVICE_NAME);
    if (!strcmp(c, "RV")) {
        float v = e->p.battery_volts ? e->p.battery_volts(e->p.ctx) : -1;
        if (v < 0) return reply(e, "?");
        char b[16];
        snprintf(b, sizeof b, "%.1fV", (double)v);
        return reply(e, b);
    }
    if (!strcmp(c, "DP")) {
        char b[48];
        if (e->protocol == 0 && !e->protocol_found) return reply(e, "AUTO");
        snprintf(b, sizeof b, "%s%s", e->protocol_auto ? "AUTO, " : "", protocol_name(e->protocol));
        return reply(e, b);
    }
    if (!strcmp(c, "DPN")) {
        char b[4];
        if (e->protocol == 0 && !e->protocol_found) return reply(e, "0");
        snprintf(b, sizeof b, "%s%X", e->protocol_auto ? "A" : "", e->protocol);
        return reply(e, b);
    }
    if (!strcmp(c, "MA")) {
        start_monitor(e); /* z bieżącym filtrem ATCRA, jeśli ustawiony */
        return;
    }

    /* Przełączniki 0/1 */
    struct {
        const char *name;
        bool *flag;
    } flags[] = {
        {"E", &e->echo},   {"L", &e->linefeeds}, {"S", &e->spaces},         {"H", &e->headers},
        {"CAF", &e->caf},  {"D", &e->dlc_display}, {"CSM", &e->silent_monitor},
    };
    for (size_t i = 0; i < sizeof flags / sizeof flags[0]; i++) {
        size_t n = strlen(flags[i].name);
        if (!strncmp(c, flags[i].name, n) && (c[n] == '0' || c[n] == '1') && !c[n + 1]) {
            *flags[i].flag = c[n] == '1';
            return reply(e, "OK");
        }
    }

    if (!strncmp(c, "SP", 2) || !strncmp(c, "TP", 2)) return set_protocol(e, c + 2);
    if (!strncmp(c, "SH", 2)) {
        uint32_t v;
        size_t n = strlen(c + 2);
        if ((n != 3 && n != 6 && n != 8) || !parse_hex_u32(c + 2, &v)) return reply(e, "?");
        if (n == 8) {
            e->priority = (uint8_t)(v >> 24);
            v &= 0xFFFFFFu;
        }
        e->header = v;
        e->header_set = true;
        return reply(e, "OK");
    }
    if (!strncmp(c, "CP", 2)) {
        uint32_t v;
        if (strlen(c + 2) != 2 || !parse_hex_u32(c + 2, &v)) return reply(e, "?");
        e->priority = (uint8_t)v;
        return reply(e, "OK");
    }
    if (!strncmp(c, "CRA", 3)) {
        if (!c[3]) {
            e->cra_set = false;
            return reply(e, "OK");
        }
        if (!parse_filter(c + 3, &e->cra_value, &e->cra_mask)) return reply(e, "?");
        e->cra_set = true;
        return reply(e, "OK");
    }
    if (!strncmp(c, "CF", 2) || !strncmp(c, "CM", 2)) {
        uint32_t v;
        size_t n = strlen(c + 2);
        if ((n != 3 && n != 8) || !parse_hex_u32(c + 2, &v)) return reply(e, "?");
        if (!e->cra_set) {
            e->cra_value = 0;
            e->cra_mask = n == 3 ? 0x7FF : 0x1FFFFFFF;
        }
        if (c[1] == 'F') e->cra_value = v;
        else e->cra_mask = v;
        e->cra_set = true;
        return reply(e, "OK");
    }
    if (!strncmp(c, "FCSH", 4)) {
        uint32_t v;
        size_t n = strlen(c + 4);
        if ((n != 3 && n != 8) || !parse_hex_u32(c + 4, &v)) return reply(e, "?");
        e->fc_header = v;
        return reply(e, "OK");
    }
    if (!strncmp(c, "FCSD", 4)) {
        int n = parse_bytes(c + 4, e->fc_data, 5);
        if (n <= 0) return reply(e, "?");
        e->fc_len = (uint8_t)n;
        return reply(e, "OK");
    }
    if (!strncmp(c, "FCSM", 4) && (c[4] == '0' || c[4] == '1') && !c[5]) {
        e->fc_custom = c[4] == '1';
        return reply(e, "OK");
    }
    if (!strncmp(c, "ST", 2)) {
        uint32_t v;
        if (strlen(c + 2) != 2 || !parse_hex_u32(c + 2, &v)) return reply(e, "?");
        e->st = (uint8_t)v;
        return reply(e, "OK");
    }
    if (!strncmp(c, "PB", 2)) {
        uint8_t b[2];
        if (parse_bytes(c + 2, b, 2) != 2) return reply(e, "?");
        e->user_b_opts = b[0];
        e->user_b_div = b[1] ? b[1] : 1;
        return reply(e, "OK");
    }
    /* Akceptowane bez skutków: adaptacyjny czas, długie wiadomości, pamięć, itp. */
    if ((!strncmp(c, "AT", 2) && strlen(c) == 3) || !strcmp(c, "AL") || !strcmp(c, "NL") || !strncmp(c, "M", 1) ||
        !strncmp(c, "V", 1) || !strcmp(c, "PC") || !strncmp(c, "CEA", 3) || !strcmp(c, "BI") ||
        !strncmp(c, "IB", 2) || !strncmp(c, "SW", 2)) {
        return reply(e, "OK");
    }
    reply(e, "?");
}

/* STPX: klucze H: (nagłówek), D: (dane), R: (liczba odpowiedzi), T: (limit ms). */
static void stpx(elm_t *e, const char *args) {
    char buf[ELM_LINE_MAX];
    strncpy(buf, args, sizeof buf - 1);
    buf[sizeof buf - 1] = 0;
    const char *data = NULL;
    int responses = 0;
    uint32_t header = 0;
    bool has_header = false;
    int t_ms = 0;
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        if (strlen(tok) < 3 || tok[1] != ':') return reply(e, "?");
        const char *v = tok + 2;
        switch (tok[0]) {
        case 'D':
            data = v;
            break;
        case 'R':
            responses = atoi(v);
            break;
        case 'H':
            if (!parse_hex_u32(v, &header)) return reply(e, "?");
            has_header = true;
            break;
        case 'T':
            t_ms = atoi(v);
            break;
        default:
            return reply(e, "?");
        }
    }
    if (!data) return reply(e, "?");
    static uint8_t bytes[ELM_ISOTP_MAX];
    int n = parse_bytes(data, bytes, (int)sizeof bytes);
    if (n <= 0) return reply(e, "?");
    if (has_header) {
        e->header = header & 0xFFFFFFu;
        e->header_set = true;
    }
    if (t_ms > 0) e->st = (uint8_t)((t_ms + 3) / 4 > 255 ? 255 : (t_ms + 3) / 4);
    if (!e->protocol_found) return reply(e, "?");
    start_request(e, bytes, (uint16_t)n, responses);
}

static void st_command(elm_t *e, const char *c) {
    if (!strcmp(c, "I")) return reply(e, "DX1 v" DX_FW_VERSION);
    if (!strcmp(c, "DI")) return reply(e, DX_DEVICE_NAME " (prototyp XIAO ESP32-C6)");
    if (!strcmp(c, "MA")) {
        start_monitor(e);
        return;
    }
    if (!strncmp(c, "PX", 2)) return stpx(e, c + 2);
    reply(e, "?");
}

static void run_obd(elm_t *e, const char *cmd) {
    size_t n = strlen(cmd);
    int expected = 0;
    char hex[ELM_LINE_MAX];
    strncpy(hex, cmd, sizeof hex - 1);
    hex[sizeof hex - 1] = 0;
    if (n % 2) {
        /* Ostatnia cyfra = liczba oczekiwanych odpowiedzi (np. "010C1") */
        expected = hexval(hex[n - 1]);
        hex[n - 1] = 0;
    }
    uint8_t bytes[ELM_LINE_MAX / 2];
    int len = parse_bytes(hex, bytes, (int)sizeof bytes);
    if (len <= 0) return reply(e, "?");

    if (!e->protocol_found) {
        strncpy(e->pending_cmd, cmd, sizeof e->pending_cmd - 1);
        e->pending_cmd[sizeof e->pending_cmd - 1] = 0;
        out_line(e, "SEARCHING...");
        e->state = ELM_SEARCH;
        e->search_idx = 0;
        search_try(e);
        return;
    }
    start_request(e, bytes, (uint16_t)len, expected);
}

static void execute(elm_t *e, char *raw) {
    /* Normalizacja: bez spacji, wielkie litery */
    char cmd[ELM_LINE_MAX];
    size_t k = 0;
    for (size_t i = 0; raw[i] && k < sizeof cmd - 1; i++) {
        char ch = raw[i];
        if (ch == ' ' || ch == '\t') continue;
        cmd[k++] = (char)toupper((unsigned char)ch);
    }
    cmd[k] = 0;

    if (!k) {
        /* Sam CR = powtórz ostatnią komendę */
        if (!e->last_cmd[0]) return prompt(e);
        strncpy(cmd, e->last_cmd, sizeof cmd);
    } else {
        strncpy(e->last_cmd, cmd, sizeof e->last_cmd - 1);
        e->last_cmd[sizeof e->last_cmd - 1] = 0;
    }

    if (e->echo) {
        out(e, raw);
        eol(e);
    }
    e->any_output = false;

    if (!strncmp(cmd, "AT", 2)) return at_command(e, cmd + 2);
    if (!strncmp(cmd, "ST", 2)) return st_command(e, cmd + 2);
    if (is_hex_str(cmd)) return run_obd(e, cmd);
    reply(e, "?");
}

/* ------------------------------------------------------------------------- */
/* API                                                                       */
/* ------------------------------------------------------------------------- */

void elm_init(elm_t *e, const elm_platform_t *platform) {
    memset(e, 0, sizeof *e);
    e->p = *platform;
    set_defaults(e);
    e->state = ELM_IDLE;
    /* Komunikat startowy jak w ELM327 */
    eol(e);
    out(e, ELM_VERSION_STRING);
    eol(e);
    prompt(e);
}

static void stop_by_user(elm_t *e) {
    if (e->state == ELM_MONITOR) configure_can(e, false);
    e->line_len = 0;
    out_line(e, "STOPPED");
    prompt(e);
}

void elm_rx_char(elm_t *e, char c) {
    if (e->state != ELM_IDLE) {
        /* Dowolny znak przerywa zapytanie lub podsłuch */
        stop_by_user(e);
        return;
    }
    if (c == '\n' || c == 0) return;
    if (c == '\r') {
        e->line[e->line_len] = 0;
        e->line_len = 0;
        execute(e, e->line);
        return;
    }
    if (e->line_len < ELM_LINE_MAX - 1) {
        e->line[e->line_len++] = c;
    } else {
        e->line_len = 0;
        reply(e, "?");
    }
}

void elm_can_rx(elm_t *e, const elm_frame_t *f) {
    switch (e->state) {
    case ELM_MONITOR:
        if (accept(e, f, true)) {
            if (isotp_active(e) && !e->headers && f->dlc) {
                print_frame(e, f, 1, f->dlc);
            } else {
                print_frame(e, f, 0, f->dlc);
            }
        }
        break;
    case ELM_SEARCH:
        if (f->ext == is_ext(e) && accept(e, f, false)) {
            e->protocol_found = true;
            e->protocol_auto = true;
            e->state = ELM_WAIT_RESPONSE;
            handle_response_frame(e, f);
        }
        break;
    case ELM_TX_WAIT_FC:
        if (accept(e, f, false) && f->dlc >= 3 && (f->data[0] >> 4) == 0x3) {
            uint8_t fs = f->data[0] & 0x0F;
            if (fs == 0) {
                e->tx_bs = f->data[1];
                e->tx_bs_count = 0;
                e->tx_stmin = f->data[2];
                e->state = ELM_TX_CF;
                e->tx_next_at = now(e);
            } else if (fs == 1) {
                e->deadline = now(e) + 1000; /* czekaj */
            } else {
                fail(e, "CAN ERROR");
            }
        }
        break;
    case ELM_WAIT_RESPONSE:
        if (accept(e, f, false)) handle_response_frame(e, f);
        break;
    default:
        break;
    }
}

void elm_poll(elm_t *e) {
    uint32_t t = now(e);
    switch (e->state) {
    case ELM_WAIT_RESPONSE:
        if (time_reached(t, e->deadline)) finish(e);
        break;
    case ELM_TX_WAIT_FC:
        if (time_reached(t, e->deadline)) fail(e, "FC RX TIMEOUT");
        break;
    case ELM_TX_CF:
        if (time_reached(t, e->tx_next_at)) send_next_cf(e);
        break;
    case ELM_SEARCH:
        if (time_reached(t, e->deadline)) {
            e->search_idx++;
            search_try(e);
        }
        break;
    default:
        break;
    }
}
