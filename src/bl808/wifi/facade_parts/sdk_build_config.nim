# =============================================================================
# WiFi manager host API (SDK scaffolding plus Nim firmware backend)
#
# Firmware symbols resolve to src/bl808/wifi_fw.nim. BL808 M0 builds reject the
# old firmware archive path.
# =============================================================================
when defined(bl808m0):
  include sdk_build_config_parts/compiler_defines
  include sdk_build_config_parts/include_paths
  include sdk_build_config_parts/wpa_sources
  include sdk_build_config_parts/crypto_sources
  include sdk_build_config_parts/linker_policy
