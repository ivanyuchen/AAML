# Build the Arty A7-100T GEMV FPGA bitstream.
#
# Usage:
#   vivado -mode batch \
#     -source BOARD/scripts/build_bitstream.tcl
#
# Optional thread count:
#   vivado -mode batch \
#     -source BOARD/scripts/build_bitstream.tcl \
#     -tclargs 4

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ../..]]

set project_name "gemv_board"
set top_module   "TPU_top"

set project_dir  [file join $project_root build vivado]
set project_file [file join $project_dir ${project_name}.xpr]

set output_dir   [file join $project_root build bitstream]
set report_dir   [file join $project_root build reports]

set output_bit   [file join $output_dir ${project_name}.bit]

# Default Vivado parallel job count.
set jobs 4

if {$argc >= 1} {
    set jobs [lindex $argv 0]
}

if {![string is integer -strict $jobs] || $jobs < 1} {
    error "Invalid job count: $jobs"
}

if {![file exists $project_file]} {
    error "Vivado project not found: $project_file\nRun create_board_project.tcl first."
}

file mkdir $output_dir
file mkdir $report_dir

puts "============================================================"
puts "Building Arty A7-100T bitstream"
puts "Project file : $project_file"
puts "Project name : $project_name"
puts "Top module   : $top_module"
puts "Parallel jobs: $jobs"
puts "Output file  : $output_bit"
puts "============================================================"

open_project $project_file

set_property top $top_module [get_filesets sources_1]
update_compile_order -fileset sources_1

# Reset prior synthesis/implementation results so RTL and constraints are
# always rebuilt from the current source files.
set synth_status [get_property STATUS [get_runs synth_1]]

if {![string match -nocase "*not started*" $synth_status]} {
    puts "Resetting previous synthesis and implementation results..."
    reset_run synth_1
}

puts "============================================================"
puts "Starting synthesis"
puts "============================================================"

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts "Synthesis status: $synth_status"

if {![string match -nocase "*complete*" $synth_status]} {
    error "Synthesis failed or did not complete: $synth_status"
}

open_run synth_1

report_utilization \
    -file [file join $report_dir post_synth_utilization.txt]

report_timing_summary \
    -delay_type max \
    -max_paths 10 \
    -file [file join $report_dir post_synth_timing.txt]

close_design

puts "============================================================"
puts "Starting implementation and bitstream generation"
puts "============================================================"

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
puts "Implementation status: $impl_status"

if {![string match -nocase "*complete*" $impl_status]} {
    error "Implementation failed or did not complete: $impl_status"
}

open_run impl_1

report_utilization \
    -file [file join $report_dir post_impl_utilization.txt]

report_timing_summary \
    -delay_type min_max \
    -max_paths 20 \
    -file [file join $report_dir post_impl_timing.txt]

report_drc \
    -file [file join $report_dir post_impl_drc.txt]

set generated_bit [file join \
    $project_dir \
    ${project_name}.runs \
    impl_1 \
    ${top_module}.bit]

if {![file exists $generated_bit]} {
    error "Generated bitstream not found: $generated_bit"
}

file copy -force $generated_bit $output_bit

# Copy an ILA debug probes file if one was generated.
set generated_ltx [file join \
    $project_dir \
    ${project_name}.runs \
    impl_1 \
    ${top_module}.ltx]

if {[file exists $generated_ltx]} {
    set output_ltx [file join $output_dir ${project_name}.ltx]
    file copy -force $generated_ltx $output_ltx
    puts "Debug probes copied to: $output_ltx"
}

set timing_paths [get_timing_paths -quiet -setup -max_paths 1]

if {[llength $timing_paths] > 0} {
    set worst_slack [get_property SLACK [lindex $timing_paths 0]]
    puts "Implementation worst setup slack: $worst_slack ns"

    if {$worst_slack < 0} {
        puts "WARNING: Timing constraints are not met."
    } else {
        puts "Timing constraints are met."
    }
}

puts "============================================================"
puts "BITSTREAM BUILD COMPLETED SUCCESSFULLY"
puts "Bitstream:"
puts "  $output_bit"
puts "Reports:"
puts "  $report_dir"
puts "============================================================"

close_project
exit
