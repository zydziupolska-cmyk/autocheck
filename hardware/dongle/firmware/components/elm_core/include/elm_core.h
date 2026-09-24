/*
 * Dynomic OBD — rdzeń interpretera komend zgodnego z ELM327 / STN.
 *
 * Kod przenośny (bez zależności od ESP-IDF): ta sama logika działa na ESP32-C6
 * i w symulatorze na PC, na którym testujemy ją razem z aplikacją.
 *
 * Model pracy: sterowany zdarzeniami, bez blokowania.
 *   - elm_rx_char()  — znak od aplikacji (BLE / TCP),
 *   - elm_can_rx()   — ramka odebrana z magistrali CAN,
 *   - elm_poll()     — wywoływane co ~1 ms (limity czasu, wysyłanie ramek CF).
 * Wszystkie wywołania muszą pochodzić z jednego wątku/zadania.
 */
#ifndef ELM_CORE_H
#define ELM_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ELM_VERSION_STRING "ELM327 v2.2"
#define DX_DEVICE_NAME "Dynomic OBD"
#define DX_FW_VERSION "0.1.0"

typedef struct {
    uint32_t id;
    bool ext;     /* identyfikator 29-bit */
    uint8_t dlc;
    uint8_t data[8];
} elm_frame_t;

typedef struct {
    void *ctx;
    /* Wysyła tekst do aplikacji. */
    void (*write)(void *ctx, const char *s, size_t n);
    /* Nadaje ramkę na CAN. 0 = OK, inna wartość = błąd (brak potwierdzenia, bus-off). */
    int (*can_send)(void *ctx, const elm_frame_t *f);
    /* Ustawia prędkość magistrali i tryb (listen_only = cichy nasłuch, bez ACK). 0 = OK. */
    int (*can_config)(void *ctx, uint32_t bitrate, bool listen_only);
    uint32_t (*millis)(void *ctx);
    /* Napięcie akumulatora z pinu 16 OBD [V]; < 0 gdy brak pomiaru. */
    float (*battery_volts)(void *ctx);
} elm_platform_t;

#define ELM_LINE_MAX 128
#define ELM_ISOTP_MAX 4095

typedef enum {
    ELM_IDLE = 0,
    ELM_WAIT_RESPONSE, /* zapytanie wysłane, zbieramy odpowiedzi */
    ELM_TX_WAIT_FC,    /* wysłano pierwszą ramkę długiego zapytania, czekamy na FC */
    ELM_TX_CF,         /* wysyłamy kolejne ramki długiego zapytania */
    ELM_SEARCH,        /* automatyczny wybór protokołu */
    ELM_MONITOR,       /* ATMA / STMA */
} elm_state_t;

/* Stan składania wieloramkowej odpowiedzi (ISO-TP) od jednego sterownika. */
typedef struct {
    bool active;
    uint32_t id;
    bool ext;
    uint16_t length;
    uint16_t received;
    uint8_t next_sn;
} elm_rx_slot_t;

#define ELM_RX_SLOTS 8

typedef struct {
    elm_platform_t p;

    /* Ustawienia (AT) */
    bool echo, linefeeds, spaces, headers, caf, dlc_display;
    uint8_t protocol;      /* 0 = auto, 6..9 = CAN, 0xB = użytkownika B */
    bool protocol_auto;    /* protokół wybrany automatycznie (ATDPN "A6") */
    bool protocol_found;
    uint8_t user_b_opts;   /* ATPB: bajt opcji */
    uint8_t user_b_div;    /* ATPB: dzielnik prędkości (500 / div kbps) */
    uint8_t st;            /* ATST: limit czasu × 4 ms */
    uint32_t header;       /* ATSH / ATCP */
    bool header_set;
    uint8_t priority;      /* ATCP (29-bit) */
    bool cra_set;
    uint32_t cra_value, cra_mask; /* ATCRA z cyframi X, ATCF/ATCM */
    bool fc_custom;        /* ATFCSM1 */
    uint32_t fc_header;
    uint8_t fc_data[8];
    uint8_t fc_len;
    bool silent_monitor;   /* ATCSM */

    /* Bieżąca komenda */
    char line[ELM_LINE_MAX];
    size_t line_len;
    char last_cmd[ELM_LINE_MAX];

    elm_state_t state;
    uint32_t deadline;
    int expected;          /* oczekiwana liczba odpowiedzi (0 = do limitu czasu) */
    int responses;
    bool any_output;
    bool mon_restricted;   /* STMA/ATMA z filtrem */

    /* Wysyłanie długiego zapytania */
    uint8_t tx_buf[ELM_ISOTP_MAX];
    uint16_t tx_len, tx_pos;
    uint8_t tx_sn, tx_bs, tx_bs_count, tx_stmin;
    uint32_t tx_next_at;
    uint32_t tx_id;
    bool tx_ext;

    /* Odbiór długich odpowiedzi (dla formatu bez nagłówków) */
    elm_rx_slot_t slots[ELM_RX_SLOTS];

    /* Automatyczny wybór protokołu */
    uint8_t search_idx;
    char pending_cmd[ELM_LINE_MAX];
} elm_t;

void elm_init(elm_t *e, const elm_platform_t *platform);
void elm_rx_char(elm_t *e, char c);
void elm_can_rx(elm_t *e, const elm_frame_t *f);
void elm_poll(elm_t *e);

/* Prędkość bieżącego protokołu CAN (0 gdy nieaktywny). */
uint32_t elm_bitrate(const elm_t *e);

#ifdef __cplusplus
}
#endif

#endif
