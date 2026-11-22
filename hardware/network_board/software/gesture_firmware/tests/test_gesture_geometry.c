#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../src/gesture_fw.c"
static int reference_open_palm(const int32_t *x, const int32_t *y, uint32_t *width_q8)
{
    uint64_t widest = distance_q8(x[5], y[5], x[17], y[17]);
    uint64_t chain[4], direct[4];
    int32_t vx[4], vy[4];
    uint32_t spread_sum_q8 = 0;
    int i, straight = 1, spread, thumb = 0;
    if (widest < 4u * Q8) return 0;
    for (i = 0; i < 4; ++i) {
        chain[i] = distance_q8(x[finger_roots[i]], y[finger_roots[i]],
                               x[finger_mid1[i]], y[finger_mid1[i]])
                 + distance_q8(x[finger_mid1[i]], y[finger_mid1[i]],
                               x[finger_mid2[i]], y[finger_mid2[i]])
                 + distance_q8(x[finger_mid2[i]], y[finger_mid2[i]],
                               x[finger_tips[i]], y[finger_tips[i]]);
        direct[i] = distance_q8(x[finger_roots[i]], y[finger_roots[i]],
                                x[finger_tips[i]], y[finger_tips[i]]);
        vx[i] = x[finger_tips[i]] - x[finger_roots[i]];
        vy[i] = y[finger_tips[i]] - y[finger_roots[i]];
        if (direct[i] == 0 || chain[i] * PALM_STRAIGHT_NUM >= direct[i] * PALM_STRAIGHT_DEN)
            straight = 0;
    }
    for (i = 0; i < 3; ++i) {
        int64_t dot = (int64_t)vx[i] * vx[i + 1] + (int64_t)vy[i] * vy[i + 1];
        int64_t cross_signed = (int64_t)vx[i] * vy[i + 1] - (int64_t)vy[i] * vx[i + 1];
        uint64_t cross = cross_signed < 0 ? (uint64_t)(-cross_signed) : (uint64_t)cross_signed;
        spread_sum_q8 += angle_q8(cross, dot);
    }
    spread = spread_sum_q8 > 3u * PALM_SPREAD_MIN_AVG_Q8;
    thumb = distance_q8(x[4], y[4], x[5], y[5]) * PALM_THUMB_NUM
          > widest * PALM_THUMB_DEN;
    *width_q8 = (uint32_t)widest;
    return straight && spread && thumb;
}


static uint32_t rng=1;
static uint32_t random_u32(void) { rng=rng*1664525u+1013904223u;return rng; }
int main(void)
{
    int32_t x[21]={0},y[21]={0}; uint32_t w1,w2;
    /* palm=100px, index span=50px, three perfectly straight fingers. */
    x[5]=100*256; y[5]=200*256; x[8]=100*256; y[8]=150*256;
    for(unsigned i=1;i<4;i++) {
        unsigned r=5+4*i;
        for(unsigned j=0;j<4;j++){x[r+j]=(100+33*i)*256;y[r+j]=(200-30*j)*256;}
    }
    x[17]=200*256; x[18]=x[19]=x[20]=x[17];
    x[4]=x[8]; y[4]=y[8]; assert(ok_gesture(x,y));
    x[4]=x[8]+45*256; assert(!ok_gesture(x,y));
    x[4]--; assert(ok_gesture(x,y)); x[4]=x[8];
    y[4]=y[8]=175*256; assert(!ok_gesture(x,y));
    y[4]--;y[8]--;assert(ok_gesture(x,y));
    y[4]=y[8]=150*256;
    y[9]=200*256;y[10]=135*256;y[11]=150*256;y[12]=100*256;
    assert(!ok_gesture(x,y));y[10]=136*256;assert(ok_gesture(x,y));
    x[17]=x[5]+4*256-1;assert(!ok_gesture(x,y));
    for(unsigned n=0;n<10000;n++) {
        for(unsigned i=0;i<21;i++) {
            x[i]=(int32_t)(random_u32()%(1024u*256u))-128*256;
            y[i]=(int32_t)(random_u32()%(1024u*256u))-128*256;
        }
        w1=w2=0;
        assert(open_palm(x,y,&w1)==reference_open_palm(x,y,&w2));assert(w1==w2);
    }
    puts("PASS: exact OK threshold boundaries and 10000 palm geometry equivalence cases");
    return 0;
}
