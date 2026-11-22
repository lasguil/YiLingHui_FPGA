package com.efinity.ti60
import org.junit.Assert.*
import org.junit.Test
class DeviceParametersTest {
    @Test fun manualPauseUsesUiSetInEveryWaveMode() {
        assertArrayEquals(byteArrayOf(6,1),DeviceParameters.payload("pause",1))
        assertArrayEquals(byteArrayOf(6,0),DeviceParameters.payload("pause",0))
        assertEquals(0x2702L,ACommandProtocol.stages(0x27,DeviceParameters.payload("pause",1))[0].second)
    }
    @Test fun rgbAndSaturationKeepUnsignedValues() {
        assertArrayEquals(byteArrayOf(7,200.toByte()),DeviceParameters.payload("sat",200))
        assertArrayEquals(byteArrayOf(8,1),DeviceParameters.payload("keep",1))
        assertArrayEquals(byteArrayOf(9,2),DeviceParameters.payload("keep_range",2))
        for(i in 0..5) assertArrayEquals(byteArrayOf((10+i).toByte(),255.toByte()),DeviceParameters.payload("b$i",255))
        for((field,spec) in DeviceParameters.specs){
            assertThrows(IllegalArgumentException::class.java){DeviceParameters.payload(field,-1)}
            assertThrows(IllegalArgumentException::class.java){DeviceParameters.payload(field,spec.max+1)}
            assertThrows(IllegalArgumentException::class.java){DeviceParameters.payload(field,1.5)}
        }
    }
}
