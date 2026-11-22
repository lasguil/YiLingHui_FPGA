#ifndef GESTURE_FLASH_LOADER_H
#define GESTURE_FLASH_LOADER_H

enum gesture_flash_boot_result {
    GESTURE_FLASH_BOOT_OK = 0,
    GESTURE_FLASH_BOOT_NO_HEADER = 1,
    GESTURE_FLASH_BOOT_IO_ERROR = 2,
    GESTURE_FLASH_BOOT_BAD_CRC = 3
};

int gesture_flash_try_load(void);
int gesture_demo_model_is_loaded(void);

#endif
