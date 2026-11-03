# Program the Arty A7-100T with the generated GEMV bitstream.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../..]]

set bitstream_file [file join \
    $project_root \
    build \
    bitstream \
    gemv_board.bit]

if {![file exists $bitstream_file]} {
    error "Bitstream not found: $bitstream_file\nRun build_bitstream.tcl first."
}

puts "============================================================"
puts "Programming Arty A7-100T"
puts "Bitstream: $bitstream_file"
puts "============================================================"

open_hw_manager
connect_hw_server
open_hw_target

set selected_device ""

foreach candidate [get_hw_devices] {
    set device_name [get_property NAME $candidate]
    set device_part [get_property PART $candidate]

    puts "Detected device: $device_name, part: $device_part"

    if {
        [string match -nocase "*xc7a100t*" $device_name] ||
        [string match -nocase "*xc7a100t*" $device_part]
    } {
        set selected_device $candidate
        break
    }
}

if {$selected_device eq ""} {
    puts "Available hardware devices: [get_hw_devices]"
    error "Arty A7-100T XC7A100T device not found."
}

current_hw_device $selected_device
refresh_hw_device $selected_device

set_property PROGRAM.FILE $bitstream_file $selected_device

puts "Programming device: $selected_device"
program_hw_devices $selected_device
refresh_hw_device $selected_device

puts "============================================================"
puts "FPGA PROGRAMMING COMPLETED SUCCESSFULLY"
puts "Device   : $selected_device"
puts "Bitstream: $bitstream_file"
puts "============================================================"

close_hw_target
disconnect_hw_server
close_hw_manager
exit
