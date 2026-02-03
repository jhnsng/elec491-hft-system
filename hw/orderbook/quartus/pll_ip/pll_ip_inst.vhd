	component pll_ip is
		port (
			clk_clk             : in  std_logic := 'X'; -- clk
			pll_0_locked_export : out std_logic;        -- export
			pll_0_outclk0_clk   : out std_logic;        -- clk
			reset_reset_n       : in  std_logic := 'X'  -- reset_n
		);
	end component pll_ip;

	u0 : component pll_ip
		port map (
			clk_clk             => CONNECTED_TO_clk_clk,             --           clk.clk
			pll_0_locked_export => CONNECTED_TO_pll_0_locked_export, --  pll_0_locked.export
			pll_0_outclk0_clk   => CONNECTED_TO_pll_0_outclk0_clk,   -- pll_0_outclk0.clk
			reset_reset_n       => CONNECTED_TO_reset_reset_n        --         reset.reset_n
		);

