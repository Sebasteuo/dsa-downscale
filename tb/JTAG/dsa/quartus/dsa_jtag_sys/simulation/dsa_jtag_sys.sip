set_global_assignment -entity "dsa_jtag_sys" -library "lib_dsa_jtag_sys" -name IP_TOOL_NAME "Qsys"
set_global_assignment -entity "dsa_jtag_sys" -library "lib_dsa_jtag_sys" -name IP_TOOL_VERSION "25.1"
set_global_assignment -entity "dsa_jtag_sys" -library "lib_dsa_jtag_sys" -name IP_TOOL_ENV "Qsys"
set_global_assignment -library "lib_dsa_jtag_sys" -name SPD_FILE [file join $::quartus(sip_path) "../dsa_jtag_sys.spd"]
set_global_assignment -library "lib_dsa_jtag_sys" -name MISC_FILE [file join $::quartus(sip_path) "../../dsa_jtag_sys.qsys"]

set_global_assignment -library "lib_dsa_jtag_sys" -name MISC_FILE [file join $::quartus(sip_path) "dsa_jtag_sys.v"]
