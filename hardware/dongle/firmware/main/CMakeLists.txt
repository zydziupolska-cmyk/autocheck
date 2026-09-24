idf_component_register(
    SRCS "main.c" "can_bus.c" "ble_uart.c"
    INCLUDE_DIRS "."
    REQUIRES elm_core driver esp_adc esp_timer nvs_flash bt
)
