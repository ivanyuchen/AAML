# Portable Arty A7-100T GEMV board project creation script.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../..]]

set reference_dir [file join $project_root BOARD reference]
set rtl_dir       [file join $reference_dir rtl]
set ip_dir        [file join $reference_dir ip]
set xdc_file      [file join $reference_dir constraints arty_a7_100t.xdc]

set build_dir     [file join $project_root build vivado]
set report_dir    [file join $project_root build reports]

set project_name  "gemv_board"
set top_module    "TPU_top"
set fpga_part     "xc7a100tcsg324-1"

file mkdir $build_dir
file mkdir $report_dir

puts "============================================================"
puts "Creating Arty A7-100T GEMV board project"
puts "Project root : $project_root"
puts "Build dir    : $build_dir"
puts "RTL dir      : $rtl_dir"
puts "IP dir       : $ip_dir"
puts "XDC          : $xdc_file"
puts "FPGA part    : $fpga_part"
puts "Top module   : $top_module"
puts "============================================================"

if {![file isdirectory $rtl_dir]} {
    error "RTL directory not found: $rtl_dir"
}

if {![file isdirectory $ip_dir]} {
    error "IP directory not found: $ip_dir"
}

if {![file exists $xdc_file]} {
    error "XDC file not found: $xdc_file"
}

set rtl_files [glob -nocomplain [file join $rtl_dir *.v]]

if {[llength $rtl_files] == 0} {
    error "No Verilog files found in: $rtl_dir"
}

# Memories are inferred from board_bram.v; arithmetic is ordinary RTL.
set ip_files [list [file join $ip_dir clk_wiz_0 clk_wiz_0.xci]]

if {[llength $ip_files] == 0} {
    error "No XCI files found in: $ip_dir"
}

create_project -force $project_name $build_dir -part $fpga_part

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property source_mgmt_mode All [current_project]

puts "Adding RTL files:"

foreach rtl_file $rtl_files {
    puts "  $rtl_file"
    add_files -norecurse $rtl_file
}

puts "Adding IP files:"

foreach ip_file $ip_files {
    puts "  $ip_file"
    read_ip $ip_file
}

puts "Adding constraint file:"
puts "  $xdc_file"

add_files -fileset constrs_1 -norecurse $xdc_file

set_property top $top_module [get_filesets sources_1]
update_compile_order -fileset sources_1

set ip_objects [get_ips -quiet]

if {[llength $ip_objects] == 0} {
    error "Vivado did not recognize any IP objects"
}

puts "Generating IP output products..."
generate_target all $ip_objects

report_ip_status \
    -file [file join $report_dir ip_status.txt]

report_compile_order \
    -used_in synthesis \
    -file [file join $report_dir compile_order.txt]

puts "============================================================"
puts "Project creation completed successfully"
puts "Project file:"
puts "  [file join $build_dir ${project_name}.xpr]"
puts "IP status report:"
puts "  [file join $report_dir ip_status.txt]"
puts "============================================================"

close_project
exit
