# Write a flash image to the DE1 over the USB-Blaster, through doomacracy's
# JTAG loader (see sw/boot/boot.c). The board must be running doomacracy's
# .sof with SW9 up and KEY0 pressed once (HEX shows 1000).
#
#   quartus_stp -t tools/jtag_flash.tcl build/flash.bin [words_per_scan]
#
# Stream: "JTAG" magic, word count, the image words, their 32-bit sum. Words
# go out in long DR scans with IR = 1, least significant bit first, so a
# scan's value is the chunk's bytes reversed and read as one big hex number.
#
# DOOMACRACY_JTAG_DRYRUN=FILE writes the scans to FILE instead (works in a
# plain tclsh), which is how the bit order is tested without a board.
#
# Written for Tcl 8.4, which is what Quartus 8.1 ships.

if {[info exists quartus(args)]} { set args $quartus(args) } else { set args $argv }
if {[llength $args] < 1} {
    puts "usage: quartus_stp -t jtag_flash.tcl FLASH.bin \[words_per_scan\]"
    exit 1
}
set path [lindex $args 0]
# The board drains the receive FIFO far faster than the cable fills it, so
# big scans are safe and save per-call overhead in quartus_stp.
set chunk_words 2048
if {[llength $args] > 1} { set chunk_words [lindex $args 1] }

set f [open $path r]
fconfigure $f -translation binary
set image [read $f]
close $f
while {[string length $image] % 4} { append image "\xff" }
set n [expr {[string length $image] / 4}]

binary scan $image i* words
set sum 0
foreach w $words { set sum [expr {($sum + $w) & 0xFFFFFFFF}] }
set stream "[binary format ii 0x4A544147 $n]$image[binary format i $sum]"
set total [string length $stream]
puts [format "image %s: %d bytes, sum %08x" $path [expr {$n * 4}] $sum]

set dry ""
if {[info exists env(DOOMACRACY_JTAG_DRYRUN)]} { set dry $env(DOOMACRACY_JTAG_DRYRUN) }

if {$dry ne ""} {
    set out [open $dry w]
} else {
    set hw ""
    foreach h [get_hardware_names] {
        if {[string match "*USB-Blaster*" $h]} { set hw $h; break }
    }
    if {$hw eq ""} { puts "no USB-Blaster found"; exit 1 }
    set dev [lindex [get_device_names -hardware_name $hw] 0]
    puts "using $hw, $dev"
    open_device -hardware_name $hw -device_name $dev
    device_lock -timeout 10000
    device_virtual_ir_shift -instance_index 0 -ir_value 1 -no_captured_ir_value
}

set step [expr {$chunk_words * 4}]
set start [clock clicks -milliseconds]
set next_report 0
for {set pos 0} {$pos < $total} {incr pos $step} {
    set piece [string range $stream $pos [expr {$pos + $step - 1}]]
    # last word first, each as 8 hex digits: the whole scan as one number
    binary scan $piece i* pw
    set hex ""
    for {set k [expr {[llength $pw] - 1}]} {$k >= 0} {incr k -1} {
        append hex [format %08x [expr {[lindex $pw $k] & 0xFFFFFFFF}]]
    }
    set bits [expr {[string length $piece] * 8}]
    if {$dry ne ""} {
        puts $out "$bits $hex"
    } else {
        device_virtual_dr_shift -instance_index 0 -length $bits -dr_value $hex -value_in_hex -no_captured_dr_value
    }
    if {$pos >= $next_report} {
        puts [format "  %3d%%  %d KB" [expr {100 * $pos / $total}] [expr {$pos / 1024}]]
        set next_report [expr {$pos + $total / 20}]
    }
}
set secs [expr {([clock clicks -milliseconds] - $start) / 1000.0}]
puts [format "sent %d words in %.1f s" [expr {$total / 4}] $secs]

if {$dry ne ""} {
    close $out
    exit 0
}

# read back what the board counted: {overflow, words received}
device_virtual_ir_shift -instance_index 0 -ir_value 2 -no_captured_ir_value
set st [device_virtual_dr_shift -instance_index 0 -length 32 -value_in_hex]
device_virtual_ir_shift -instance_index 0 -ir_value 0 -no_captured_ir_value
device_unlock
close_device
scan $st %x status
set got [expr {$status & 0x7FFFFFFF}]
set ovf [expr {($status >> 31) & 1}]
puts [format "board received %d of %d words%s" $got [expr {$total / 4}] [expr {$ovf ? ", OVERFLOW (try fewer words per scan)" : ""}]]
if {$got != $total / 4 || $ovf} { exit 1 }
puts "now watch HEX: 2xx0 erasing and 3xx0 programming each changed 64 KB region, then 600d (LEDR = regions rewritten)"
puts "(with SW8 up as well, a Linux image boots straight from RAM instead and the flash is left alone)"
