{.passL: "-Lsrc/bl808".}
when defined(bl808WifiWrapWaitUs):
  {.passL: "-Wl,--wrap=wait_us".}
when defined(bl808WifiConnectTrace):
  {.passL: "-Wl,--wrap=mm_active -Wl,--wrap=mm_hw_info_set -Wl,--wrap=mm_sec_machwaddr_wr -Wl,--wrap=sm_handle_eapol_input -Wl,--wrap=wpa_sm_rx_eapol -Wl,--wrap=txu_cntrl_push -Wl,--wrap=txl_cntrl_push -Wl,--wrap=txl_frame_push -Wl,--wrap=txl_frame_push_force -Wl,--wrap=txl_frame_cfm -Wl,--wrap=txl_cfm_push -Wl,--wrap=rxu_cntrl_frame_handle".}
when defined(bl808WifiConnectTraceRawRx):
  {.passL: "-Wl,--wrap=rxl_cntrl_evt".}
when defined(bl808WifiUseBl808Rf):
  {.passL: "-Wl,--wrap=phy_assert_err".}
elif defined(bl808WifiAllowLegacyBl606pRfFallback):
  {.passL: "-Wl,--start-group build/bl_iot_sdk_b773b3f/components/platform/soc/bl606p/bl606p_phyrf/lib/libbl606p_phyrf.a -Wl,--end-group".}
else:
  {.error: "BL808 WiFi RF requires bl808WifiUseBl808Rf; define bl808WifiAllowLegacyBl606pRfFallback only for archive comparison builds".}
