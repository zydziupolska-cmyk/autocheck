/* Symulator auta na magistrali CAN — do testów firmware kostki na PC. */
#ifndef SIM_CAR_H
#define SIM_CAR_H

#include "elm_core.h"

/* Ramka nadana przez tester (kostkę). Zwraca 0, gdy ktoś na magistrali ją potwierdził. */
int sim_car_on_frame(const elm_frame_t *f, uint32_t now_ms, uint32_t bitrate, bool listen_only);

/* Zwraca kolejną ramkę od auta, której czas nadejścia minął (1) albo 0. */
int sim_car_next(elm_frame_t *out, uint32_t now_ms, uint32_t bitrate);

/* Liczba ramek pominiętych przez auto (błędna prędkość / ID). */
void sim_car_reset(void);

#endif
