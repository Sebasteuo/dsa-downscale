// Top físico que instancia el sistema Qsys 'dsa_jtag_sys'.

module dsa_top_jtag (
  input  logic CLOCK_50,
  input  logic RESET_N,   // activo en bajo
  input  logic step
);

  dsa_jtag_sys u_sys (
    .clk_clk       (CLOCK_50),
    .reset_reset_n (RESET_N),
	 .step          (step)
  );

endmodule
