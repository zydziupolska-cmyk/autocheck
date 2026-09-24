#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*ble_uart_rx_cb_t)(const uint8_t *data, size_t len);

void ble_uart_init(const char *device_name, ble_uart_rx_cb_t cb);
bool ble_uart_connected(void);
/* Dopisuje tekst do bufora wyjściowego (wysyłany w ble_uart_flush). */
void ble_uart_write(const char *s, size_t n);
/* Wysyła zaległe dane powiadomieniami (w kawałkach MTU - 3). */
void ble_uart_flush(void);
