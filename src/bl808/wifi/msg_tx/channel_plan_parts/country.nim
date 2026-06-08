proc channelCountFor(code: cstring): int32 =
  if code != nil and code[0] == 'J' and code[1] == 'P':
    14
  elif code != nil and code[0] == 'U' and code[1] == 'S':
    11
  elif code != nil and code[0] == 'E' and code[1] == 'U':
    13
  elif code != nil and code[0] == 'C' and code[1] == 'N':
    13
  else:
    -1

proc bl_msg_update_channel_cfg*(code: cstring) {.exportc, cdecl.} =
  let count = channelCountFor(code)
  if count < 0:
    channelNumDefault = 14
    countryCode0 = 'C'.uint8
    countryCode1 = 'N'.uint8
    countryMaxPower = 20
    bl_os_printf("[WF] %s NOT found, using General instead, num of channel %d\r\n",
                 code, channelNumDefault)
  else:
    channelNumDefault = count
    countryCode0 = code[0].uint8
    countryCode1 = code[1].uint8
    countryMaxPower = 20
    bl_os_printf("[WF] country code %s used, num of channel %d\r\n",
                 code, channelNumDefault)

proc bl_msg_get_channel_nums*(): cint {.exportc, cdecl.} =
  channelNumDefault.cint
