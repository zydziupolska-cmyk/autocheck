/*
 * Dynomic OBD — firmware prototypu kostki (Seeed XIAO ESP32-C6).
 *
 * Zadania:
 *   - core: interpreter ELM327/STN (elm_core), jedyne miejsce, które go wywołuje,
 *   - can_rx: odbiór ramek z TWAI → kolejka zdarzeń,
 *   - NimBLE (host): zapis aplikacji → kolejka zdarzeń.
 */
#include <string.h>

#include "ble_uart.h"
#include "board.h"
#include "can_bus.h"
#include "elm_core.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_log.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "nvs_flash.h"

static const char *TAG = "dx";

typedef enum { EV_CHARS, EV_FRAME } ev_type_t;

typedef struct {
    ev_type_t type;
    union {
        struct {
            uint8_t len;
            char data[32];
        } chars;
        elm_frame_t frame;
    };
} event_t;

static QueueHandle_t events;
static elm_t elm;

/* ------------------------------------------------------------------ */
/* Napięcie akumulatora                                               */
/* ------------------------------------------------------------------ */

static adc_oneshot_unit_handle_t adc;
static adc_cali_handle_t adc_cali;
static bool adc_cali_ok;

static void vbat_init(void) {
    adc_oneshot_unit_init_cfg_t u = {.unit_id = ADC_UNIT_1};
    ESP_ERROR_CHECK(adc_oneshot_new_unit(&u, &adc));
    adc_oneshot_chan_cfg_t c = {.atten = ADC_ATTEN_DB_12, .bitwidth = ADC_BITWIDTH_DEFAULT};
    ESP_ERROR_CHECK(adc_oneshot_config_channel(adc, BOARD_VBAT_ADC_CHANNEL, &c));
    adc_cali_curve_fitting_config_t cc = {
        .unit_id = ADC_UNIT_1, .chan = BOARD_VBAT_ADC_CHANNEL, .atten = ADC_ATTEN_DB_12,
        .bitwidth = ADC_BITWIDTH_DEFAULT};
    adc_cali_ok = adc_cali_create_scheme_curve_fitting(&cc, &adc_cali) == ESP_OK;
}

static float vbat_read(void) {
    int sum = 0, n = 0;
    for (int i = 0; i < 8; i++) {
        int raw, mv;
        if (adc_oneshot_read(adc, BOARD_VBAT_ADC_CHANNEL, &raw) != ESP_OK) continue;
        if (adc_cali_ok && adc_cali_raw_to_voltage(adc_cali, raw, &mv) == ESP_OK) {
            sum += mv;
            n++;
        }
    }
    if (!n) return -1;
    return (float)sum / (float)n / 1000.0f * BOARD_VBAT_DIVIDER;
}

/* ------------------------------------------------------------------ */
/* Platforma dla elm_core                                             */
/* ------------------------------------------------------------------ */

static void p_write(void *ctx, const char *s, size_t n) { ble_uart_write(s, n); }
static int p_can_send(void *ctx, const elm_frame_t *f) { return can_bus_send(f); }
static int p_can_config(void *ctx, uint32_t br, bool lo) { return can_bus_config(br, lo); }
static uint32_t p_millis(void *ctx) { return (uint32_t)(esp_timer_get_time() / 1000); }
static float p_vbat(void *ctx) { return vbat_read(); }

/* ------------------------------------------------------------------ */
/* Zadania                                                            */
/* ------------------------------------------------------------------ */

static void on_ble_rx(const uint8_t *data, size_t len) {
    while (len) {
        event_t ev = {.type = EV_CHARS};
        ev.chars.len = (uint8_t)(len < sizeof ev.chars.data ? len : sizeof ev.chars.data);
        memcpy(ev.chars.data, data, ev.chars.len);
        xQueueSend(events, &ev, pdMS_TO_TICKS(50));
        data += ev.chars.len;
        len -= ev.chars.len;
    }
}

static void can_rx_task(void *arg) {
    event_t ev = {.type = EV_FRAME};
    for (;;) {
        if (can_bus_receive(&ev.frame, 10)) xQueueSend(events, &ev, pdMS_TO_TICKS(5));
    }
}

static void maybe_sleep(uint32_t now_ms, uint32_t *idle_since) {
    bool busy = ble_uart_connected() || now_ms - can_bus_last_rx_ms() < 2000;
    if (busy || elm.state != ELM_IDLE) {
        *idle_since = now_ms;
        return;
    }
    if (now_ms - *idle_since < SLEEP_IDLE_MS) return;
    float v = vbat_read();
    if (v > SLEEP_MAX_VBAT) {
        *idle_since = now_ms; /* silnik pracuje — nie śpimy */
        return;
    }
    ESP_LOGI(TAG, "uśpienie (%.1f V); budzi ruch na CAN", (double)v);
    can_bus_standby();
    /* Transceiver w czuwaniu przekazuje ruch na RXD: stan niski budzi procesor.
     * GPIO2 to pin LP — gpio_hold_en utrzymuje stan także w głębokim uśpieniu. */
    gpio_hold_en(BOARD_CAN_STANDBY_GPIO);
    esp_sleep_enable_ext1_wakeup_io(1ULL << BOARD_CAN_RX_GPIO, ESP_EXT1_WAKEUP_ANY_LOW);
    gpio_set_level(BOARD_LED_GPIO, 1);
    esp_deep_sleep_start();
}

static void core_task(void *arg) {
    elm_platform_t p = {.write = p_write, .can_send = p_can_send, .can_config = p_can_config,
                        .millis = p_millis, .battery_volts = p_vbat};
    elm_init(&elm, &p);
    uint32_t idle_since = p_millis(NULL);
    bool was_connected = false;
    for (;;) {
        event_t ev;
        if (xQueueReceive(events, &ev, pdMS_TO_TICKS(1)) == pdTRUE) {
            if (ev.type == EV_CHARS) {
                for (int i = 0; i < ev.chars.len; i++) elm_rx_char(&elm, ev.chars.data[i]);
            } else {
                elm_can_rx(&elm, &ev.frame);
            }
        }
        elm_poll(&elm);
        ble_uart_flush();

        bool connected = ble_uart_connected();
        if (connected != was_connected) {
            gpio_set_level(BOARD_LED_GPIO, connected ? 0 : 1);
            if (connected) elm_init(&elm, &p); /* nowa sesja = stan jak po włączeniu ELM */
            was_connected = connected;
        }
        maybe_sleep(p_millis(NULL), &idle_since);
    }
}

void app_main(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }
    gpio_hold_dis(BOARD_CAN_STANDBY_GPIO);

    gpio_config_t out = {
        .pin_bit_mask = (1ULL << BOARD_LED_GPIO) | (1ULL << BOARD_RF_SWITCH_EN_GPIO) | (1ULL << BOARD_RF_ANT_SELECT_GPIO),
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_config(&out);
    gpio_set_level(BOARD_LED_GPIO, 1);
    gpio_set_level(BOARD_RF_SWITCH_EN_GPIO, 0);
    gpio_set_level(BOARD_RF_ANT_SELECT_GPIO, BOARD_USE_EXTERNAL_ANTENNA);

    vbat_init();
    can_bus_init();
    events = xQueueCreate(128, sizeof(event_t));
    ble_uart_init(DX_DEVICE_NAME, on_ble_rx);

    ESP_LOGI(TAG, "Dynomic OBD %s, akumulator %.1f V", DX_FW_VERSION, (double)vbat_read());
    xTaskCreate(can_rx_task, "can_rx", 4096, NULL, 6, NULL);
    xTaskCreate(core_task, "core", 8192, NULL, 5, NULL);
}
