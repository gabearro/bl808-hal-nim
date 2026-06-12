{.passL: "-Lsrc/bl808".}
when defined(bl808WifiWrapWaitUs):
  {.passL: "-Wl,--wrap=wait_us".}
when defined(bl808WifiConnectTrace):
  {.passL: "-Wl,--wrap=mm_active -Wl,--wrap=mm_hw_info_set -Wl,--wrap=mm_sec_machwaddr_wr -Wl,--wrap=sm_handle_eapol_input -Wl,--wrap=wpa_sm_rx_eapol -Wl,--wrap=txu_cntrl_push -Wl,--wrap=txl_cntrl_push -Wl,--wrap=txl_frame_push -Wl,--wrap=txl_frame_push_force -Wl,--wrap=txl_frame_cfm -Wl,--wrap=txl_cfm_push -Wl,--wrap=rxu_cntrl_frame_handle".}
when defined(bl808WifiConnectTraceRawRx):
  {.passL: "-Wl,--wrap=rxl_cntrl_evt".}
{.passL: "-Wl,--wrap=phy_assert_err".}
