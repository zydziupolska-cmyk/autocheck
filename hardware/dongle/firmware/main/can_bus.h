#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "elm_core.h"

void can_bus_init(void);
int can_bus_config(uint32_t bitrate, bool listen_only);
int can_bus_send(const elm_frame_t *f);
bool can_bus_receive(elm_frame_t *f, uint32_t timeout_ms);
uint32_t can_bus_last_rx_ms(void);
/* Wyłącza kontroler i przełącza transceiver w czuwanie (przed uśpieniem). */
void can_bus_standby(void);
