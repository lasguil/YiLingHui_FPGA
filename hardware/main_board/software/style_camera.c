#include "style_system.h"
#include "style_camera.h"
#include "camera_sensor_table.h"

#ifndef STYLE_CAMERA_HOST_TEST
extern void style_camera_wait_service(void);
#define CAMERA_WAIT_SERVICE() style_camera_wait_service()
#else
#define CAMERA_WAIT_SERVICE() ((void)0)
#endif

#define GPIO UINT32_C(0xf8015000)
#define GPIO_OUT 4u
#define GPIO_OE  8u
#define GPIO_SCL (1u << 1)
#define GPIO_SDA (1u << 2)
#define CAMERA_ADDR_WRITE 0x60u
#define I2C_HALF_US 5u
#define I2C_STRETCH_US 1000u
#ifndef I2C_TRANSACTION_US
#define I2C_TRANSACTION_US 50000u
#endif
#define MODE_STOP_US 40000u
#define MODE_GUARD_US 200u
#define EXPOSURE_MIN 4u
#define EXPOSURE_MAX 2389u

enum { AE_HOLD=0, AE_DOWN=1, AE_UP=2, AE_FAST_DOWN=3 };
static uint32_t gpio_oe_shadow=0x1u; /* LED0; camera lines are released by default. */
static uint32_t camera_control_shadow;
static uint32_t last_ae_toggle;
static unsigned active_mode=VIDEO_480_30;
static unsigned exposure=EXPOSURE_MAX;
static unsigned settle_frames=3;
static unsigned dark_pending;
static unsigned camera_fault;
static uint8_t active_vflip;

static uint32_t camera_cycles_to_us(uint32_t hi,uint32_t lo)
{
    /* (hi*2^32 + lo)/100, reduced modulo 2^32 without 64-bit division. */
    uint32_t tail=(hi/100u)*96u+((hi%100u)*96u+lo%100u)/100u;
    return hi*UINT32_C(42949672)+lo/100u+tail;
}
static int camera_time_before(uint32_t now,uint32_t deadline)
{
    return (int32_t)(now-deadline)<0;
}
/* All camera deadlines are at most 50 ms. A wrapping 32-bit microsecond
 * clock with signed-difference comparisons is therefore sufficient for the
 * longest 100 ms wait (and far below the 2^31 us comparison limit). Avoid
 * a 64-bit divide here: it otherwise pulls a large software divider into the
 * 16 KiB OCR firmware image. */
static uint32_t now_us(void)
{
#ifdef STYLE_CAMERA_HOST_TEST
    extern uint64_t camera_test_now_us(void);
    return (uint32_t)camera_test_now_us();
#else
    volatile uint32_t *const mtime=(volatile uint32_t *)(uintptr_t)UINT32_C(0xf8b0bff8);
    uint32_t hi0,lo,hi1;
    do {
        hi0=mtime[1]; lo=mtime[0]; hi1=mtime[1];
    } while(hi0!=hi1);
    return camera_cycles_to_us(hi0,lo);
#endif
}
static void delay_us(uint32_t amount)
{
#ifdef STYLE_CAMERA_HOST_TEST
    extern void camera_test_delay_us(uint32_t);
    camera_test_delay_us(amount);
#else
    uint32_t deadline=now_us()+amount;
    while(camera_time_before(now_us(),deadline)) CAMERA_WAIT_SERVICE();
#endif
}
static unsigned gpio_sample(void)
{
    uint32_t v=style_read(GPIO,0);
    return ((v&GPIO_SCL)?1u:0u) | ((v&GPIO_SDA)?2u:0u);
}
static void drive_low(uint32_t mask,int low)
{
    if(low)gpio_oe_shadow|=mask;else gpio_oe_shadow&=~mask;
    /* Keep bus data bits zero while preserving the LED output latch. */
    uint32_t out=style_read(GPIO,GPIO_OUT)&~(GPIO_SCL|GPIO_SDA);
    style_write(GPIO,GPIO_OUT,out);
    style_write(GPIO,GPIO_OE,gpio_oe_shadow);
}
static int deadline_live(uint32_t deadline)
{
    return camera_time_before(now_us(),deadline);
}
static int wait_scl_high(uint32_t deadline)
{
    uint32_t stretch_deadline=now_us()+I2C_STRETCH_US;
    if((int32_t)(stretch_deadline-deadline)>0)stretch_deadline=deadline;
    while(!(gpio_sample()&1u)){
        CAMERA_WAIT_SERVICE();
        if(!camera_time_before(now_us(),stretch_deadline))return 0;
    }
    return 1;
}
static int bus_recover(uint32_t deadline)
{
    if(!deadline_live(deadline))return 0;
    drive_low(GPIO_SDA,0);drive_low(GPIO_SCL,0);
    if(!wait_scl_high(deadline))return 0;
    if(gpio_sample()&2u)return 1;
    for(unsigned i=0;i<9 && !(gpio_sample()&2u);i++){
        if(!deadline_live(deadline))return 0;
        drive_low(GPIO_SCL,1);delay_us(I2C_HALF_US);
        drive_low(GPIO_SCL,0);
        if(!wait_scl_high(deadline))return 0;
        delay_us(I2C_HALF_US);
    }
    /* A STOP after the recovery pulses releases a slave that was mid-byte. */
    drive_low(GPIO_SDA,1);delay_us(I2C_HALF_US);
    drive_low(GPIO_SCL,0);
    if(!wait_scl_high(deadline))return 0;
    delay_us(I2C_HALF_US);drive_low(GPIO_SDA,0);delay_us(I2C_HALF_US);
    return (gpio_sample()&2u)!=0;
}
static int i2c_start(uint32_t deadline)
{
    for(unsigned attempt=0;attempt<2 && deadline_live(deadline);attempt++){
        drive_low(GPIO_SDA,0);drive_low(GPIO_SCL,0);
        if(!wait_scl_high(deadline))return 0;
        delay_us(I2C_HALF_US);if(!deadline_live(deadline))return 0;
        if(!(gpio_sample()&2u)){
            if(attempt||!bus_recover(deadline))return 0;
            continue;
        }
        drive_low(GPIO_SDA,1);delay_us(I2C_HALF_US);
        if(!deadline_live(deadline))return 0;
        drive_low(GPIO_SCL,1);return 1;
    }
    return 0;
}
static int i2c_stop(uint32_t deadline)
{
    drive_low(GPIO_SDA,1);delay_us(I2C_HALF_US);drive_low(GPIO_SCL,0);
    if(!deadline_live(deadline)||!wait_scl_high(deadline)){
        drive_low(GPIO_SCL,0);drive_low(GPIO_SDA,0);return 0;
    }
    delay_us(I2C_HALF_US);drive_low(GPIO_SDA,0);delay_us(I2C_HALF_US);
    int released=(gpio_sample()&2u)!=0;
    if(!released){drive_low(GPIO_SCL,0);drive_low(GPIO_SDA,0);}
    return released&&deadline_live(deadline);
}
static int i2c_write_byte(uint8_t value,uint32_t deadline)
{
    for(unsigned bit=0;bit<8;bit++){
        if(!deadline_live(deadline))return 0;
        drive_low(GPIO_SDA,(value&0x80u)==0);delay_us(I2C_HALF_US);
        if(!deadline_live(deadline))return 0;
        drive_low(GPIO_SCL,0);
        if(!wait_scl_high(deadline))return 0;
        delay_us(I2C_HALF_US);if(!deadline_live(deadline))return 0;
        drive_low(GPIO_SCL,1);value<<=1;
    }
    drive_low(GPIO_SDA,0);delay_us(I2C_HALF_US);drive_low(GPIO_SCL,0);
    if(!wait_scl_high(deadline))return 0;
    delay_us(I2C_HALF_US);if(!deadline_live(deadline))return 0;
    int ack=(gpio_sample()&2u)==0;drive_low(GPIO_SCL,1);
    return ack;
}
static int i2c_write(uint16_t address,uint8_t value)
{
#ifdef STYLE_CAMERA_HOST_TEST
    extern int camera_test_i2c_write(uint16_t,uint8_t);
    return camera_test_i2c_write(address,value);
#else
    uint32_t deadline=now_us()+I2C_TRANSACTION_US;
    int ok=i2c_start(deadline);
    if(ok)ok=i2c_write_byte(CAMERA_ADDR_WRITE,deadline);
    if(ok)ok=i2c_write_byte((uint8_t)(address>>8),deadline);
    if(ok)ok=i2c_write_byte((uint8_t)address,deadline);
    if(ok)ok=i2c_write_byte(value,deadline);
    int stopped=i2c_stop(deadline);
    if(!deadline_live(deadline))ok=0;
    drive_low(GPIO_SCL,0);drive_low(GPIO_SDA,0);
    return ok&&stopped;
#endif
}
static void publish_control(unsigned ready,unsigned rx,unsigned capture,
                            unsigned switching,unsigned mode,unsigned fault)
{
    camera_control_shadow=(ready?CAM_CONTROL_READY:0u) |
        (capture?CAM_CONTROL_CAPTURE:0u) | (rx?CAM_CONTROL_RX:0u) |
        (fault?CAM_CONTROL_FAULT:0u) | (switching?CAM_CONTROL_SWITCHING:0u) |
        ((mode&3u)<<CAM_CONTROL_MODE_SHIFT) | ((active_vflip && CAMERA_VFLIP_BAYER_XOR)?CAM_CONTROL_BAYER_Y_XOR:0u);
    style_write(CAMERA_CSR_BASE,CAM_CSR_CONTROL,camera_control_shadow);
}
static int wait_status(uint32_t mask,unsigned value,uint32_t timeout_us)
{
    uint32_t deadline=now_us()+timeout_us;
    for(;;){
        uint32_t s=style_read(CAMERA_CSR_BASE,CAM_CSR_STATUS);
        if(s&CAM_STATUS_FAULT)return 0;
        if((s&mask)==value)return 1;
        CAMERA_WAIT_SERVICE();
        if(!camera_time_before(now_us(),deadline))return 0;
    }
}
static int request_blank_capture(unsigned capture,unsigned mode)
{
    uint32_t before=style_read(CAMERA_CSR_BASE,CAM_CSR_STATUS)&CAM_STATUS_BOUNDARY_ACK;
    publish_control(1,1,capture,1,mode,0);
    if(!wait_status(CAM_STATUS_BOUNDARY_ACK,before^CAM_STATUS_BOUNDARY_ACK,100000u))return 0;
    return wait_status(CAM_STATUS_CAPTURE_ACK,capture?CAM_STATUS_CAPTURE_ACK:0u,10000u);
}
static void fail_camera(void)
{
    camera_fault=1;
    drive_low(GPIO_SCL,0);drive_low(GPIO_SDA,0);
    publish_control(0,0,0,0,active_mode,1);
    /* Best-effort stop is bounded even if the bus has become stuck. */
    (void)i2c_write(0x0100,0x00);
    drive_low(GPIO_SCL,0);drive_low(GPIO_SDA,0);
}
static int guarded_write(uint16_t address,uint8_t value)
{
    if(i2c_write(address,value))return 1;
    return 0;
}
static int write_exposure(unsigned target)
{
    int ok=guarded_write(0x3812,0x00);
    if(ok)ok=guarded_write(0x3e01,(uint8_t)(target>>4));
    if(ok)ok=guarded_write(0x3e02,(uint8_t)((target&15u)<<4));
    /* Always attempt the group release after the hold attempt, even on NACK. */
    int released=guarded_write(0x3812,0x30);
    if(!ok||!released)return 0;
    exposure=target;settle_frames=3;dark_pending=0;
    return 1;
}
static unsigned mode_is_60(unsigned mode) { return mode==VIDEO_480_60; }
static int switch_mode(unsigned mode,unsigned new_flip)
{
    unsigned new_60=mode_is_60(mode),old_60=mode_is_60(active_mode);
    new_flip=!!new_flip;
    if(new_60==old_60 && new_flip==active_vflip){
        if(!request_blank_capture(1,mode))return 0;
        active_mode=mode;
        publish_control(1,1,1,0,active_mode,0);
        return 1;
    }
    /* This is a fresh edge request; CSR commits only on the next VS falling edge. */
    if(!request_blank_capture(0,active_mode))return 0;
    if(!guarded_write(0x0100,0x00))return 0;
    delay_us(MODE_STOP_US);
    publish_control(1,0,0,1,active_mode,0);
    if(!wait_status(CAM_STATUS_RX_ACK,0,10000u))return 0;
    if(new_60!=old_60){
        unsigned target=new_60 ? (exposure>EXPOSURE_MAX/2u?EXPOSURE_MAX:exposure*2u) :
                                 (exposure<8u?EXPOSURE_MIN:exposure/2u);
        if(!guarded_write(0x320c,new_60?0x06:0x0d))return 0;
        if(!guarded_write(0x320d,new_60?0xd6:0xac))return 0;
        if(!write_exposure(target))return 0;
    }
    if(new_flip!=active_vflip){
        if(!guarded_write(0x3221,new_flip?0x60u:0x00u))return 0;
        active_vflip=(uint8_t)new_flip;
    }
    /* Match RESET_GUARD: publish mode first with RX closed, then wait 200 us. */
    active_mode=mode;
    publish_control(1,0,0,1,active_mode,0);
    delay_us(MODE_GUARD_US);
    publish_control(1,1,0,1,active_mode,0);
    if(!wait_status(CAM_STATUS_RX_ACK,CAM_STATUS_RX_ACK,10000u))return 0;
    delay_us(MODE_GUARD_US);
    /* Sensor is still stopped, so capture may be armed immediately. */
    publish_control(1,1,1,1,active_mode,0);
    if(!wait_status(CAM_STATUS_CAPTURE_ACK,CAM_STATUS_CAPTURE_ACK,10000u))return 0;
    if(!guarded_write(0x0100,0x01))return 0;
    publish_control(1,1,1,0,active_mode,0);
    return 1;
}
void camera_init(void)
{
    active_vflip=0;
    gpio_oe_shadow=0x1u;
    style_write(GPIO,GPIO_OUT,style_read(GPIO,GPIO_OUT)&~(GPIO_SCL|GPIO_SDA));
    style_write(GPIO,GPIO_OE,gpio_oe_shadow);
    if(!bus_recover(now_us()+I2C_TRANSACTION_US)){fail_camera();return;}
    /* Keep the final stream-on entry until both receive and capture gates ack. */
    for(unsigned i=0;i<174;i++){
        if(!i2c_write(camera_init_address[i],camera_init_value[i])){
            fail_camera();return;
        }
    }
    if(!i2c_write(0x3221,0x00)){fail_camera();return;}
    publish_control(1,1,0,0,active_mode,0);
    if(!wait_status(CAM_STATUS_RX_ACK,CAM_STATUS_RX_ACK,10000u)){
        fail_camera();return;
    }
    delay_us(MODE_GUARD_US);
    publish_control(1,1,1,0,active_mode,0);
    if(!wait_status(CAM_STATUS_CAPTURE_ACK,CAM_STATUS_CAPTURE_ACK,10000u)){
        fail_camera();return;
    }
    delay_us(MODE_GUARD_US);
    if(!i2c_write(camera_init_address[174],camera_init_value[174])){
        fail_camera();return;
    }
    last_ae_toggle=style_read(CAMERA_CSR_BASE,CAM_CSR_EVENT)&1u;
    exposure=EXPOSURE_MAX;settle_frames=3;dark_pending=0;
}
void camera_service(unsigned requested_flip)
{
    requested_flip=!!requested_flip;
    if(camera_fault)return;
    uint32_t requested=style_read(STYLE_CONTROL_BASE,SYS_MODE_REQUEST)&3u;
    if(requested!=active_mode||requested_flip!=active_vflip){
        if(!switch_mode(requested,requested_flip)){fail_camera();return;}
        return;
    }
    uint32_t event=style_read(CAMERA_CSR_BASE,CAM_CSR_EVENT);
    unsigned toggle=event&1u,action=(event>>1)&3u;
    if(toggle==last_ae_toggle)return;
    last_ae_toggle=toggle;
    if(settle_frames){settle_frames--;return;}
    if(action==AE_HOLD){dark_pending=0;return;}
    if(action==AE_UP&&!dark_pending){dark_pending=1;return;}
    dark_pending=0;
    unsigned step=exposure>>(action==AE_DOWN?3u:2u);
    if(step==0)step=1;
    unsigned target;
    if(action==AE_UP){target=exposure+step;if(target>EXPOSURE_MAX)target=EXPOSURE_MAX;}
    else target=exposure<=step+EXPOSURE_MIN?EXPOSURE_MIN:exposure-step;
    if(target!=exposure&&!write_exposure(target))fail_camera();
}
unsigned camera_faulted(void) { return camera_fault; }
