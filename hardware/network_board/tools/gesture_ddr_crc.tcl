proc gesture_crc32_update {crc byte} {
    set crc [expr {$crc ^ ($byte & 0xff)}]
    for {set bit 0} {$bit < 8} {incr bit} {
        if {$crc & 1} {
            set crc [expr {($crc >> 1) ^ 0xedb88320}]
        } else {
            set crc [expr {$crc >> 1}]
        }
    }
    return [expr {$crc & 0xffffffff}]
}

proc gesture_crc32_values {bytes} {
    set crc 0xffffffff
    foreach byte $bytes {
        set crc [gesture_crc32_update $crc $byte]
    }
    return [expr {$crc ^ 0xffffffff}]
}

proc gesture_crc32_ddr {address bytes} {
    if {($bytes & 3) != 0} {
        error "CRC readback length must be word aligned"
    }
    set crc 0xffffffff
    set total_words [expr {$bytes / 4}]
    set done_words 0
    while {$done_words < $total_words} {
        set remaining_words [expr {$total_words - $done_words}]
        if {$remaining_words > 512} {
            set batch_words 512
        } else {
            set batch_words $remaining_words
        }
        set batch_addr [expr {$address + 4 * $done_words}]
        set words [fpga_spinal.cpu0 read_memory $batch_addr 32 $batch_words]
        if {[llength $words] != $batch_words} {
            error "DDR readback returned a short word batch"
        }
        foreach word $words {
            for {set lane 0} {$lane < 4} {incr lane} {
                set byte [expr {($word >> (8 * $lane)) & 0xff}]
                set crc [gesture_crc32_update $crc $byte]
            }
        }
        incr done_words $batch_words
    }
    return [expr {$crc ^ 0xffffffff}]
}
