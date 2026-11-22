#include "gesture_flash_loader.h"
#include "gesture_platform.h"
#include "model_crc.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HEADER_ADDR 0x00400000u
#define WEIGHTS_FLASH 0x00401000u
#define PARAMS_FLASH 0x0050e000u
#define FLASH_SIZE (PARAMS_FLASH + MODEL_PARAMS_BYTES - HEADER_ADDR)

static uint8_t *flash_image;
static uint8_t weights_ddr[MODEL_WEIGHTS_BYTES];
static uint8_t params_ddr[MODEL_PARAMS_BYTES];
static uint32_t flash_address;
static uint32_t stream_address;
static unsigned write_count;
static unsigned stop_count;
static unsigned service_count;
static int flash_active;
static int flash_timeout;
static int touched_forbidden;

void gesture_return_service(void) { ++service_count; }

static uint32_t crc32_bytes(const uint8_t *bytes, size_t count)
{
    uint32_t crc = 0xffffffffu;
    size_t i;
    for (i = 0; i < count; ++i) {
        unsigned bit;
        crc ^= bytes[i];
        for (bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (uint32_t)-(int32_t)(crc & 1u));
    }
    return ~crc;
}

int gesture_demo_model_is_loaded(void)
{
    return crc32_bytes(weights_ddr, sizeof(weights_ddr)) == MODEL_WEIGHTS_CRC32
        && crc32_bytes(params_ddr, sizeof(params_ddr)) == MODEL_PARAMS_CRC32;
}

uint32_t gesture_mmio_read(uint32_t base, uint32_t offset)
{
    assert(base == GESTURE_FLASH_MODEL_BASE);
    if (offset == FLASH_MODEL_STATUS)
        return flash_active ? FLASH_MODEL_BUSY | (flash_timeout ? 0u : FLASH_MODEL_VALID) : 0u;
    if (offset == FLASH_MODEL_DATA) {
        uint32_t value = (uint32_t)flash_image[stream_address - HEADER_ADDR]
                       | ((uint32_t)flash_image[stream_address - HEADER_ADDR + 1u] << 8)
                       | ((uint32_t)flash_image[stream_address - HEADER_ADDR + 2u] << 16)
                       | ((uint32_t)flash_image[stream_address - HEADER_ADDR + 3u] << 24);
        stream_address += 4u;
        return value;
    }
    assert(0 && "unexpected flash register read");
    return 0;
}

void gesture_mmio_write(uint32_t base, uint32_t offset, uint32_t value)
{
    assert(base == GESTURE_FLASH_MODEL_BASE);
    if (offset == FLASH_MODEL_ADDR) flash_address = value;
    else if (offset == FLASH_MODEL_CTRL && (value & FLASH_MODEL_START)) {
        assert(!flash_active);
        assert(flash_address >= HEADER_ADDR && flash_address + 4u <= HEADER_ADDR + FLASH_SIZE);
        stream_address = flash_address;
        flash_active = 1;
    } else if (offset == FLASH_MODEL_CTRL && (value & FLASH_MODEL_STOP)) {
        flash_active = 0;
        ++stop_count;
    } else assert(0 && "unexpected flash register write");
}

void gesture_ddr_write32(uint32_t address, uint32_t value)
{
    uint8_t *destination;
    unsigned i;
    if (address >= GESTURE_WEIGHTS_DDR
        && address + 4u <= GESTURE_WEIGHTS_DDR + MODEL_WEIGHTS_BYTES) {
        destination = weights_ddr + address - GESTURE_WEIGHTS_DDR;
    } else if (address >= GESTURE_PARAMS_DDR
               && address + 4u <= GESTURE_PARAMS_DDR + MODEL_PARAMS_BYTES) {
        destination = params_ddr + address - GESTURE_PARAMS_DDR;
    } else {
        touched_forbidden = 1;
        assert(0 && "Flash loader wrote outside weights/params DDR windows");
        return;
    }
    for (i = 0; i < 4u; ++i) destination[i] = (uint8_t)(value >> (i * 8u));
    ++write_count;
}

static void put_le32(uint32_t offset, uint32_t value)
{
    flash_image[offset] = (uint8_t)value;
    flash_image[offset + 1u] = (uint8_t)(value >> 8);
    flash_image[offset + 2u] = (uint8_t)(value >> 16);
    flash_image[offset + 3u] = (uint8_t)(value >> 24);
}

static void read_file(const char *path, uint8_t *destination, size_t expected)
{
    FILE *file = fopen(path, "rb");
    assert(file != NULL);
    assert(fread(destination, 1, expected, file) == expected);
    assert(fgetc(file) == EOF);
    fclose(file);
}

static void reset_case(void)
{
    memset(flash_image, 0xff, FLASH_SIZE);
    memset(weights_ddr, 0, sizeof(weights_ddr));
    memset(params_ddr, 0, sizeof(params_ddr));
    flash_address = stream_address = 0;
    write_count = stop_count = service_count = 0;
    flash_active = flash_timeout = touched_forbidden = 0;
}

static void write_header(void)
{
    put_le32(0x000000u, 0x31444d47u);
    put_le32(0x000004u, 1u);
    put_le32(0x000008u, MODEL_WEIGHTS_BYTES);
    put_le32(0x00000cu, MODEL_PARAMS_BYTES);
    put_le32(0x000010u, MODEL_WEIGHTS_CRC32);
    put_le32(0x000014u, MODEL_PARAMS_CRC32);
}

int main(int argc, char **argv)
{
    uint8_t *weights, *params;
    assert(argc == 3);
    flash_image = (uint8_t *)malloc(FLASH_SIZE);
    weights = (uint8_t *)malloc(MODEL_WEIGHTS_BYTES);
    params = (uint8_t *)malloc(MODEL_PARAMS_BYTES);
    assert(flash_image && weights && params);
    read_file(argv[1], weights, MODEL_WEIGHTS_BYTES);
    read_file(argv[2], params, MODEL_PARAMS_BYTES);

    reset_case();
    assert(gesture_flash_try_load() == GESTURE_FLASH_BOOT_NO_HEADER);
    assert(write_count == 0 && !flash_active && stop_count == 1 && !touched_forbidden);

    reset_case();
    flash_timeout = 1;
    assert(gesture_flash_try_load() == GESTURE_FLASH_BOOT_IO_ERROR);
    assert(write_count == 0 && !flash_active && stop_count == 1 && !touched_forbidden);

    reset_case();
    write_header();
    put_le32(0x000004u, 2u);
    assert(gesture_flash_try_load() == GESTURE_FLASH_BOOT_NO_HEADER);
    assert(write_count == 0 && !flash_active && stop_count == 1);

    reset_case();
    write_header();
    memcpy(flash_image + WEIGHTS_FLASH - HEADER_ADDR, weights, MODEL_WEIGHTS_BYTES);
    memcpy(flash_image + PARAMS_FLASH - HEADER_ADDR, params, MODEL_PARAMS_BYTES);
    assert(gesture_flash_try_load() == GESTURE_FLASH_BOOT_OK);
    assert(write_count == MODEL_WEIGHTS_BYTES / 4u + MODEL_PARAMS_BYTES / 4u);
    assert(!flash_active && stop_count == 3 && !touched_forbidden);
    assert(memcmp(weights_ddr, weights, MODEL_WEIGHTS_BYTES) == 0);
    assert(memcmp(params_ddr, params, MODEL_PARAMS_BYTES) == 0);
    assert(service_count != 0);

    reset_case();
    write_header();
    memcpy(flash_image + WEIGHTS_FLASH - HEADER_ADDR, weights, MODEL_WEIGHTS_BYTES);
    memcpy(flash_image + PARAMS_FLASH - HEADER_ADDR, params, MODEL_PARAMS_BYTES);
    flash_image[WEIGHTS_FLASH - HEADER_ADDR + 127u] ^= 1u;
    assert(gesture_flash_try_load() == GESTURE_FLASH_BOOT_BAD_CRC);
    assert(write_count == MODEL_WEIGHTS_BYTES / 4u + MODEL_PARAMS_BYTES / 4u);
    assert(!flash_active && stop_count == 3 && !touched_forbidden);

    reset_case();
    write_header();
    memcpy(flash_image + WEIGHTS_FLASH - HEADER_ADDR, weights, MODEL_WEIGHTS_BYTES);
    memcpy(flash_image + PARAMS_FLASH - HEADER_ADDR, params, MODEL_PARAMS_BYTES);
    flash_image[PARAMS_FLASH - HEADER_ADDR + MODEL_PARAMS_BYTES - 1u] ^= 1u;
    assert(gesture_flash_try_load() == GESTURE_FLASH_BOOT_BAD_CRC);
    assert(write_count == MODEL_WEIGHTS_BYTES / 4u + MODEL_PARAMS_BYTES / 4u);
    assert(!flash_active && stop_count == 3 && !touched_forbidden);

    free(params);
    free(weights);
    free(flash_image);
    puts("Flash model loader contract PASS");
    return 0;
}
