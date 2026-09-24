/*
 * Piny prototypu: Seeed Studio XIAO ESP32-C6 + transceiver CAN SN65HVD230.
 * Opis połączeń: hardware/dongle/README.md.
 */
#pragma once

#include "driver/gpio.h"

/* Napięcie akumulatora (pin 16 OBD) przez dzielnik 100k / 22k → D0 (GPIO0, ADC1 kanał 0). */
#define BOARD_VBAT_GPIO GPIO_NUM_0
#define BOARD_VBAT_ADC_CHANNEL ADC_CHANNEL_0
#define BOARD_VBAT_DIVIDER ((100.0f + 22.0f) / 22.0f)

/* CAN: RXD transceivera → D1 (GPIO1 — pin LP, budzi z głębokiego uśpienia),
 *      TXD transceivera ← D3 (GPIO21). */
#define BOARD_CAN_RX_GPIO GPIO_NUM_1
#define BOARD_CAN_TX_GPIO GPIO_NUM_21

/* Rs (tryb) SN65HVD230 → D2 (GPIO2): 0 = praca, 1 = czuwanie (odbiornik nadal budzi). */
#define BOARD_CAN_STANDBY_GPIO GPIO_NUM_2

/* Dioda użytkownika na płytce XIAO (świeci stanem niskim). */
#define BOARD_LED_GPIO GPIO_NUM_15

/* Przełącznik anteny XIAO ESP32-C6: GPIO3 = 0 włącza przełącznik,
 * GPIO14 = 0 antena ceramiczna na płytce, 1 = złącze U.FL. */
#define BOARD_RF_SWITCH_EN_GPIO GPIO_NUM_3
#define BOARD_RF_ANT_SELECT_GPIO GPIO_NUM_14
#define BOARD_USE_EXTERNAL_ANTENNA 0

/* Uśpienie: brak połączenia BLE, cisza na CAN i napięcie jak przy wyłączonym silniku. */
#define SLEEP_IDLE_MS (5u * 60u * 1000u)
#define SLEEP_MAX_VBAT 13.2f /* powyżej: alternator ładuje = silnik pracuje */
