# Kostka Dynomic OBD na PC (rdzeń firmware + symulator auta) — do testów z aplikacją.
CORE = ../firmware/components/elm_core
CFLAGS ?= -std=c11 -O1 -g -Wall -Wextra -Wno-unused-parameter
build/dx_host: host_main.c sim_car.c sim_car.h $(CORE)/elm_core.c $(CORE)/include/elm_core.h
	@mkdir -p build
	$(CC) $(CFLAGS) -I$(CORE)/include -o $@ host_main.c sim_car.c $(CORE)/elm_core.c

clean:
	rm -rf build
.PHONY: clean
