# Serial console for doomacracy over the USB-Blaster: the 16550 at
# 0xF000_1000 (Linux ttyS0, earlycon) talks to this script through the
# Virtual JTAG instance, IR = 3 (rtl/jtag_console.vhd). Board output goes to
# stdout, stdin goes to the board.
#
#   quartus_stp -t tools/jtag_console.tcl [-raw]
#
# Without -raw the terminal stays in line mode: a line is sent when you
# press Enter (as a carriage return, like a serial terminal), and a line
# containing only "~." quits. With -raw (Unix only, uses stty) every key is
# sent at once and Ctrl-] quits. Quitting sends a detach frame; if the
# script is killed instead, the board notices after about 0.67 s without
# scans and stops waiting for it.
#
# Frame: one 80-bit DR scan, least significant bit first. To the board:
# [3:0] byte count m (0..8), [4] attach, [5] detach, [79:16] bytes. From the
# board: [3:0] byte count n, [7:4] 0xA, [12:8] RX read pointer (bytes the
# board has taken, mod 32), [13] attached, [79:16] bytes. The board's RX
# FIFO holds 16 bytes; the script keeps at most 16 unread bytes in flight
# by counting what it sent against the read pointer.
#
# DOOMACRACY_JTAG_DRYRUN=FILE runs without hardware (works in a plain
# tclsh): every scan is written to FILE as "80 <hex>" (the same format as
# jtag_flash.tcl), and a fake board answers, printing the bytes of
# DOOMACRACY_JTAG_FAKE_OUT (a file, optional) and taking every byte at once.
# The dry run stops when stdin reaches EOF and both directions are idle.
#
# Written for Tcl 8.4, which is what Quartus 8.1 ships.

if {[info exists quartus(args)]} { set args $quartus(args) } else { set args $argv }
set raw 0
foreach a $args {
    if {$a eq "-raw"} { set raw 1 } else {
        puts stderr "usage: quartus_stp -t jtag_console.tcl \[-raw\]"
        exit 1
    }
}

set dry ""
if {[info exists env(DOOMACRACY_JTAG_DRYRUN)]} { set dry $env(DOOMACRACY_JTAG_DRYRUN) }

# ---------------------------------------------------------------- transport

# fake board for the dry run
set fake_out ""
set fake_pos 0
set fake_rp 0
proc fake_scan {hex} {
    global fake_out fake_pos fake_rp dryf
    puts $dryf "80 $hex"
    scan [string range $hex 18 19] %x h
    set m [expr {$h & 15}]
    set fake_rp [expr {($fake_rp + $m) & 31}]
    set n [expr {[string length $fake_out] - $fake_pos}]
    if {$n > 8} { set n 8 }
    set out ""
    for {set i 7} {$i >= 0} {incr i -1} {
        if {$i < $n} {
            scan [string index $fake_out [expr {$fake_pos + $i}]] %c c
            append out [format %02x $c]
        } else {
            append out "00"
        }
    }
    incr fake_pos $n
    append out [format %02x [expr {0x20 | $fake_rp}]] [format %02x [expr {0xA0 | $n}]]
    return $out
}

proc scan80 {hex} {
    global dry
    if {$dry ne ""} { return [fake_scan $hex] }
    return [device_virtual_dr_shift -instance_index 0 -length 80 -dr_value $hex -value_in_hex]
}

if {$dry ne ""} {
    set dryf [open $dry w]
    if {[info exists env(DOOMACRACY_JTAG_FAKE_OUT)]} {
        set f [open $env(DOOMACRACY_JTAG_FAKE_OUT) r]
        fconfigure $f -translation binary
        set fake_out [read $f]
        close $f
    }
} else {
    set hw ""
    foreach h [get_hardware_names] {
        if {[string match "*USB-Blaster*" $h]} { set hw $h; break }
    }
    if {$hw eq ""} { puts stderr "no USB-Blaster found"; exit 1 }
    set dev [lindex [get_device_names -hardware_name $hw] 0]
    puts stderr "jtag_console: $hw, $dev (quit with ~. on a line of its own, or Ctrl-] with -raw)"
    open_device -hardware_name $hw -device_name $dev
    device_lock -timeout 10000
    device_virtual_ir_shift -instance_index 0 -ir_value 3 -no_captured_ir_value
}

# ---------------------------------------------------------------- terminal

fconfigure stdout -translation binary -buffering none
fconfigure stdin -blocking 0 -translation binary
if {$raw} { catch {exec stty raw -echo <@stdin} }

proc restore_tty {} {
    global raw
    if {$raw} { catch {exec stty sane <@stdin} }
}

# ---------------------------------------------------------------- main loop

set pending ""     ;# typed bytes not yet sent
set sent 0         ;# bytes sent, mod 32
set brp 0          ;# board RX read pointer from the latest frame
set quit 0
set eof_in 0
set linebuf ""
set warned 0

proc frame {m bytes flags} {
    # bytes: list of codes, m of them valid
    set hex ""
    for {set i 7} {$i >= 0} {incr i -1} {
        if {$i < $m} { append hex [format %02x [lindex $bytes $i]] } else { append hex "00" }
    }
    append hex "00" [format %02x [expr {$m | $flags}]]
    return $hex
}

while {1} {
    # keyboard
    if {!$eof_in} {
        set in [read stdin]
        if {[eof stdin]} { set eof_in 1 }
        foreach ch [split $in ""] {
            scan $ch %c c
            if {$raw} {
                if {$c == 29} { set quit 1; break }
                append pending $ch
            } else {
                if {$c == 10} {
                    if {$linebuf eq "~."} { set quit 1; break }
                    append pending $linebuf "\r"
                    set linebuf ""
                } else {
                    append linebuf $ch
                }
            }
        }
    }

    # what fits: at most 8 a scan, at most 16 not yet taken by the board
    set credit [expr {16 - (($sent - $brp) & 31)}]
    set m [string length $pending]
    if {$m > 8} { set m 8 }
    if {$m > $credit} { set m $credit }
    if {$m < 0} { set m 0 }
    set codes {}
    for {set i 0} {$i < $m} {incr i} {
        scan [string index $pending $i] %c c
        lappend codes $c
    }
    if {$quit} { set flags 0x20 } else { set flags 0x10 }
    set r [scan80 [frame $m $codes $flags]]
    set pending [string range $pending $m end]
    set sent [expr {($sent + $m) & 31}]

    # board output
    set r [string range "00000000000000000000$r" end-19 end]
    scan [string range $r 18 19] %x h0
    scan [string range $r 16 17] %x h1
    if {($h0 >> 4) != 10} {
        if {!$warned} { puts stderr "\njtag_console: no console on IR 3 (frame $r)"; set warned 1 }
        set n 0
    } else {
        set n [expr {$h0 & 15}]
        if {$n > 8} { set n 8 }
        set brp [expr {$h1 & 31}]
    }
    set out ""
    for {set i 0} {$i < $n} {incr i} {
        set p [expr {(7 - $i) * 2}]         ;# byte i is bits 16+8i .. 23+8i
        scan [string range $r $p [expr {$p + 1}]] %x c
        append out [format %c $c]
    }
    if {$out ne ""} { puts -nonewline $out }

    if {$quit} { break }
    if {$dry ne "" && $eof_in && $pending eq "" && $n == 0} { break }
    # poll at once while anything moves, otherwise rest a little
    if {$n == 0 && $m == 0} { after 20 }
}

restore_tty
if {$dry ne ""} {
    close $dryf
} else {
    device_virtual_ir_shift -instance_index 0 -ir_value 0 -no_captured_ir_value
    device_unlock
    close_device
}
exit 0
