/*
 * Kanał szeregowy przez Bluetooth LE (NimBLE), jak w adapterach ELM327 BLE:
 * usługa FFF0, charakterystyka FFF1 (powiadomienia: kostka → aplikacja)
 * i FFF2 (zapis: aplikacja → kostka).
 */
#include "ble_uart.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ble";

static ble_uart_rx_cb_t rx_cb;
static uint16_t conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t notify_handle;
static bool notify_enabled;
static uint8_t own_addr_type;

/* Bufor wyjściowy (kostka → aplikacja) */
#define TX_BUF 8192
static uint8_t txbuf[TX_BUF];
static size_t tx_head, tx_tail; /* pierścień */
static SemaphoreHandle_t tx_lock;
static uint32_t dropped;

static int gatt_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint8_t buf[256];
        uint16_t len = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof buf, &len) == 0 && rx_cb) rx_cb(buf, len);
        return 0;
    }
    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) return 0;
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(0xFFF0),
        .characteristics =
            (struct ble_gatt_chr_def[]){
                {
                    .uuid = BLE_UUID16_DECLARE(0xFFF1),
                    .access_cb = gatt_access,
                    .val_handle = &notify_handle,
                    .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ,
                },
                {
                    .uuid = BLE_UUID16_DECLARE(0xFFF2),
                    .access_cb = gatt_access,
                    .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                },
                {0},
            },
    },
    {0},
};

static void advertise(void);

static int gap_event(struct ble_gap_event *ev, void *arg) {
    switch (ev->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status == 0) {
            conn_handle = ev->connect.conn_handle;
            ESP_LOGI(TAG, "połączono");
        } else {
            advertise();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "rozłączono");
        conn_handle = BLE_HS_CONN_HANDLE_NONE;
        notify_enabled = false;
        advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (ev->subscribe.attr_handle == notify_handle) notify_enabled = ev->subscribe.cur_notify;
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;
    default:
        break;
    }
    return 0;
}

static void advertise(void) {
    struct ble_hs_adv_fields f = {0};
    f.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    const char *name = ble_svc_gap_device_name();
    f.name = (uint8_t *)name;
    f.name_len = (uint8_t)strlen(name);
    f.name_is_complete = 1;
    ble_uuid16_t svc = BLE_UUID16_INIT(0xFFF0);
    f.uuids16 = &svc;
    f.num_uuids16 = 1;
    f.uuids16_is_complete = 1;
    if (ble_gap_adv_set_fields(&f) != 0) return;
    struct ble_gap_adv_params p = {.conn_mode = BLE_GAP_CONN_MODE_UND, .disc_mode = BLE_GAP_DISC_MODE_GEN};
    ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER, &p, gap_event, NULL);
}

static void on_sync(void) {
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &own_addr_type);
    advertise();
}

static void host_task(void *param) {
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void ble_uart_init(const char *device_name, ble_uart_rx_cb_t cb) {
    rx_cb = cb;
    tx_lock = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(services));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(services));
    ble_svc_gap_device_name_set(device_name);
    nimble_port_freertos_init(host_task);
}

bool ble_uart_connected(void) { return conn_handle != BLE_HS_CONN_HANDLE_NONE; }

void ble_uart_write(const char *s, size_t n) {
    if (!ble_uart_connected()) return;
    xSemaphoreTake(tx_lock, portMAX_DELAY);
    for (size_t i = 0; i < n; i++) {
        size_t next = (tx_head + 1) % TX_BUF;
        if (next == tx_tail) {
            dropped++; /* aplikacja nie nadąża — gubimy (np. podsłuch przy dużym ruchu) */
            break;
        }
        txbuf[tx_head] = (uint8_t)s[i];
        tx_head = next;
    }
    xSemaphoreGive(tx_lock);
}

void ble_uart_flush(void) {
    if (!ble_uart_connected() || !notify_enabled) {
        tx_head = tx_tail = 0;
        return;
    }
    uint16_t mtu = ble_att_mtu(conn_handle);
    size_t chunk_max = mtu > 3 ? mtu - 3 : 20;
    for (;;) {
        xSemaphoreTake(tx_lock, portMAX_DELAY);
        size_t avail = (tx_head + TX_BUF - tx_tail) % TX_BUF;
        if (!avail) {
            xSemaphoreGive(tx_lock);
            return;
        }
        uint8_t chunk[512];
        size_t n = avail < chunk_max ? avail : chunk_max;
        if (n > sizeof chunk) n = sizeof chunk;
        for (size_t i = 0; i < n; i++) chunk[i] = txbuf[(tx_tail + i) % TX_BUF];
        xSemaphoreGive(tx_lock);

        struct os_mbuf *om = ble_hs_mbuf_from_flat(chunk, (uint16_t)n);
        if (!om) return; /* brak pamięci — spróbujemy przy następnym wywołaniu */
        if (ble_gatts_notify_custom(conn_handle, notify_handle, om) != 0) return;

        xSemaphoreTake(tx_lock, portMAX_DELAY);
        tx_tail = (tx_tail + n) % TX_BUF;
        xSemaphoreGive(tx_lock);
    }
}
