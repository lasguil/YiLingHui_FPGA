#include "gesture_flash_loader.h"
#include "gesture_platform.h"
#include "model_crc.h"

#define FLASH_HEADER_ADDR       0x00400000u
#define FLASH_WEIGHTS_ADDR      0x00401000u
#define FLASH_PARAMS_ADDR       0x0050e000u
#define FLASH_HEADER_MAGIC      0x31444d47u
#define FLASH_HEADER_VERSION    1u
#ifndef FLASH_WORD_TIMEOUT_SPINS
#define FLASH_WORD_TIMEOUT_SPINS 1000000u
#endif

static void flash_stop(void)
{
    gesture_mmio_write(GESTURE_FLASH_MODEL_BASE, FLASH_MODEL_CTRL, FLASH_MODEL_STOP);
}

static int flash_start(uint32_t address)
{
    uint32_t status;
    gesture_mmio_write(GESTURE_FLASH_MODEL_BASE, FLASH_MODEL_ADDR, address);
    gesture_mmio_write(GESTURE_FLASH_MODEL_BASE, FLASH_MODEL_CTRL, FLASH_MODEL_START);
    status = gesture_mmio_read(GESTURE_FLASH_MODEL_BASE, FLASH_MODEL_STATUS);
    return (status & FLASH_MODEL_FAULT) ? -1 : 0;
}

static int flash_read_word(uint32_t *value)
{
    uint32_t left = FLASH_WORD_TIMEOUT_SPINS;
    while (left--) {
        uint32_t status = gesture_mmio_read(GESTURE_FLASH_MODEL_BASE, FLASH_MODEL_STATUS);
        if (status & FLASH_MODEL_FAULT) return -1;
        if (status & FLASH_MODEL_VALID) {
            *value = gesture_mmio_read(GESTURE_FLASH_MODEL_BASE, FLASH_MODEL_DATA);
            return 0;
        }
        if ((left & 255u) == 0u) gesture_return_service();
    }
    return -1;
}

static int load_region(uint32_t flash_address, uint32_t ddr_address, uint32_t bytes)
{
    uint32_t offset;
    if ((bytes & 3u) != 0u || flash_start(flash_address) != 0) {
        flash_stop();
        return GESTURE_FLASH_BOOT_IO_ERROR;
    }
    for (offset = 0; offset < bytes; offset += 4u) {
        uint32_t word;
        if (flash_read_word(&word) != 0) {
            flash_stop();
            return GESTURE_FLASH_BOOT_IO_ERROR;
        }
        gesture_ddr_write32(ddr_address + offset, word);
        if ((offset & 1023u) == 1020u) gesture_return_service();
    }
    flash_stop();
    return GESTURE_FLASH_BOOT_OK;
}

int gesture_flash_try_load(void)
{
    uint32_t header[6];
    unsigned index;
    int result;

    if (flash_start(FLASH_HEADER_ADDR) != 0) {
        flash_stop();
        return GESTURE_FLASH_BOOT_IO_ERROR;
    }
    for (index = 0; index < 6u; ++index) {
        if (flash_read_word(&header[index]) != 0) {
            flash_stop();
            return GESTURE_FLASH_BOOT_IO_ERROR;
        }
    }
    flash_stop();

    if (header[0] != FLASH_HEADER_MAGIC || header[1] != FLASH_HEADER_VERSION
        || header[2] != MODEL_WEIGHTS_BYTES || header[3] != MODEL_PARAMS_BYTES
        || header[4] != MODEL_WEIGHTS_CRC32 || header[5] != MODEL_PARAMS_CRC32)
        return GESTURE_FLASH_BOOT_NO_HEADER;

    result = load_region(FLASH_WEIGHTS_ADDR, GESTURE_WEIGHTS_DDR, MODEL_WEIGHTS_BYTES);
    if (result != GESTURE_FLASH_BOOT_OK) return result;
    result = load_region(FLASH_PARAMS_ADDR, GESTURE_PARAMS_DDR, MODEL_PARAMS_BYTES);
    if (result != GESTURE_FLASH_BOOT_OK) return result;
    return gesture_demo_model_is_loaded()
        ? GESTURE_FLASH_BOOT_OK : GESTURE_FLASH_BOOT_BAD_CRC;
}
