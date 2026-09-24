/* Magistrala CAN przez kontroler TWAI ESP32-C6. */
#include "can_bus.h"

#include <string.h>

#include "board.h"
#include "driver/twai.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

static const char *TAG = "can";

static bool installed;
static uint32_t cur_bitrate;
static bool cur_listen_only;
static volatile uint32_t last_rx_ms;
/* Chroni instalację/deinstalację sterownika przed równoczesnym odbiorem w innym zadaniu. */
static SemaphoreHandle_t bus_lock;

void can_bus_init(void) {
    bus_lock = xSemaphoreCreateMutex();
    gpio_config_t io = {.pin_bit_mask = 1ULL << BOARD_CAN_STANDBY_GPIO, .mode = GPIO_MODE_OUTPUT};
    gpio_config(&io);
    gpio_set_level(BOARD_CAN_STANDBY_GPIO, 1);
}

static bool timing_for(uint32_t bitrate, twai_timing_config_t *t) {
    switch (bitrate) {
    case 1000000: { twai_timing_config_t x = TWAI_TIMING_CONFIG_1MBITS(); *t = x; return true; }
    case 500000: { twai_timing_config_t x = TWAI_TIMING_CONFIG_500KBITS(); *t = x; return true; }
    case 250000: { twai_timing_config_t x = TWAI_TIMING_CONFIG_250KBITS(); *t = x; return true; }
    case 125000: { twai_timing_config_t x = TWAI_TIMING_CONFIG_125KBITS(); *t = x; return true; }
    case 100000: { twai_timing_config_t x = TWAI_TIMING_CONFIG_100KBITS(); *t = x; return true; }
    case 50000: { twai_timing_config_t x = TWAI_TIMING_CONFIG_50KBITS(); *t = x; return true; }
    default: return false;
    }
}

static int config_locked(uint32_t bitrate, bool listen_only) {
    if (installed && bitrate == cur_bitrate && listen_only == cur_listen_only) return 0;
    twai_timing_config_t timing;
    if (!timing_for(bitrate, &timing)) return -1;
    if (installed) {
        twai_stop();
        twai_driver_uninstall();
        installed = false;
    }
    twai_general_config_t g = TWAI_GENERAL_CONFIG_DEFAULT(BOARD_CAN_TX_GPIO, BOARD_CAN_RX_GPIO,
                                                          listen_only ? TWAI_MODE_LISTEN_ONLY : TWAI_MODE_NORMAL);
    g.rx_queue_len = 64;
    g.tx_queue_len = 8;
    g.alerts_enabled = TWAI_ALERT_TX_SUCCESS | TWAI_ALERT_TX_FAILED | TWAI_ALERT_BUS_ERROR | TWAI_ALERT_BUS_OFF |
                       TWAI_ALERT_ERR_PASS;
    twai_filter_config_t f = TWAI_FILTER_CONFIG_ACCEPT_ALL();
    if (twai_driver_install(&g, &timing, &f) != ESP_OK) return -1;
    if (twai_start() != ESP_OK) {
        twai_driver_uninstall();
        return -1;
    }
    /* Transceiver w tryb pracy */
    gpio_set_level(BOARD_CAN_STANDBY_GPIO, 0);
    installed = true;
    cur_bitrate = bitrate;
    cur_listen_only = listen_only;
    ESP_LOGI(TAG, "CAN %lu b/s%s", (unsigned long)bitrate, listen_only ? " (cichy nasłuch)" : "");
    return 0;
}

int can_bus_config(uint32_t bitrate, bool listen_only) {
    xSemaphoreTake(bus_lock, portMAX_DELAY);
    int r = config_locked(bitrate, listen_only);
    xSemaphoreGive(bus_lock);
    return r;
}

int can_bus_send(const elm_frame_t *f) {
    if (!installed || cur_listen_only) return -1;
    twai_message_t m = {0};
    m.identifier = f->id;
    m.extd = f->ext;
    m.data_length_code = f->dlc;
    memcpy(m.data, f->data, f->dlc);
    uint32_t alerts;
    twai_read_alerts(&alerts, 0); /* wyczyść stare */
    if (twai_transmit(&m, pdMS_TO_TICKS(20)) != ESP_OK) return -1;
    /* Czekamy na potwierdzenie: bez ACK (zła prędkość, brak auta) — błąd, jak w ELM */
    TickType_t until = xTaskGetTickCount() + pdMS_TO_TICKS(25);
    while (xTaskGetTickCount() < until) {
        if (twai_read_alerts(&alerts, pdMS_TO_TICKS(5)) != ESP_OK) continue;
        if (alerts & TWAI_ALERT_TX_SUCCESS) return 0;
        if (alerts & (TWAI_ALERT_TX_FAILED | TWAI_ALERT_BUS_ERROR | TWAI_ALERT_BUS_OFF | TWAI_ALERT_ERR_PASS)) break;
    }
    twai_clear_transmit_queue();
    twai_status_info_t st;
    if (twai_get_status_info(&st) == ESP_OK && st.state != TWAI_STATE_RUNNING) {
        /* Bus-off lub błąd — reinstalacja przywraca kontroler */
        xSemaphoreTake(bus_lock, portMAX_DELAY);
        uint32_t br = cur_bitrate;
        bool lo = cur_listen_only;
        installed = false;
        twai_stop();
        twai_driver_uninstall();
        config_locked(br, lo);
        xSemaphoreGive(bus_lock);
    }
    return -1;
}

bool can_bus_receive(elm_frame_t *f, uint32_t timeout_ms) {
    xSemaphoreTake(bus_lock, portMAX_DELAY);
    if (!installed) {
        xSemaphoreGive(bus_lock);
        vTaskDelay(pdMS_TO_TICKS(timeout_ms ? timeout_ms : 1));
        return false;
    }
    twai_message_t m;
    esp_err_t err = twai_receive(&m, pdMS_TO_TICKS(timeout_ms));
    xSemaphoreGive(bus_lock);
    if (err != ESP_OK) return false;
    if (m.rtr) return false;
    f->id = m.identifier;
    f->ext = m.extd;
    f->dlc = m.data_length_code > 8 ? 8 : m.data_length_code;
    memcpy(f->data, m.data, f->dlc);
    last_rx_ms = (uint32_t)(xTaskGetTickCount() * portTICK_PERIOD_MS);
    return true;
}

uint32_t can_bus_last_rx_ms(void) { return last_rx_ms; }

void can_bus_standby(void) {
    xSemaphoreTake(bus_lock, portMAX_DELAY);
    if (installed) {
        twai_stop();
        twai_driver_uninstall();
        installed = false;
    }
    gpio_set_level(BOARD_CAN_STANDBY_GPIO, 1);
    xSemaphoreGive(bus_lock);
}
