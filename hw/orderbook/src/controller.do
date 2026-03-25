onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /test_controller_tb/clk
add wave -noupdate /test_controller_tb/reset_n
add wave -noupdate -expand /test_controller_tb/SW
add wave -noupdate -expand /test_controller_tb/KEY
add wave -noupdate /test_controller_tb/side_out
add wave -noupdate -radix decimal /test_controller_tb/price_out
add wave -noupdate -radix decimal /test_controller_tb/delta_qty_out
add wave -noupdate /test_controller_tb/valid_out
add wave -noupdate /test_controller_tb/dut/current_state
add wave -noupdate /test_controller_tb/dut/next_state
add wave -noupdate /test_controller_tb/dut/stream_active
add wave -noupdate /test_controller_tb/dut/stream_msg_index
add wave -noupdate /test_controller_tb/dut/debug_msg_index
add wave -noupdate /test_controller_tb/dut/stream_vector_sel
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {175000 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 283
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ps
update
WaveRestoreZoom {124449 ps} {251237 ps}
