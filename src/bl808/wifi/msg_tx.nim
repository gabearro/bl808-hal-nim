## Nim replacement for the BL808 WiFi host message request builders.

when defined(bl808m0) and defined(bl808WifiNimFw):
  import sdk_headers

  include msg_tx/layout
  include msg_tx/abi
  include msg_tx/accessors

  include msg_tx/channel_plan

  include msg_tx/core

  include msg_tx/mm_control

  include msg_tx/me_control

  include msg_tx/scan

  include msg_tx/station

  include msg_tx/apm

  include msg_tx/cfg_task
