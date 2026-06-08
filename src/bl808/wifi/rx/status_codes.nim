proc smStatusStr(statusCode: uint16): cstring =
  case statusCode
  of 0: "sm connect ind ok"
  of 1: "tx auth frame alloc failure"
  of 2: "Authentication failure"
  of 3: "Auth response but auth algo failure"
  of 4: "tx assoc frame alloc failure"
  of 5: "Association failure"
  of 6: "deauth by AP when connecting"
  of 7: "deauth by AP when connected"
  of 8: "Passwd error, 4-way handshake timeout"
  of 9: "Passwd error, tx deauth frame transmit failure"
  of 10: "Passwd error, tx deauth frame allocate failure"
  of 11: "auth or associate frame response timeout failure"
  of 12: "SSID error, scan no bssid and channel"
  of 13: "create channel context failure when join network"
  of 14: "join network failure"
  of 15: "add sta failure"
  of 16: "ap beacon loss"
  of 17: "network security no match"
  of 18: "wep network psk len error"
  of 19: "user disconnect and send deauth"
  of 20: "user disconnect but no send deauth"
  of 21: "fw disconnect(tx nullframe failures)"
  of 22: "fw disconnect(traffic loss)"
  of 23: "user connect abort and send deauth"
  of 24: "user connect abort without sending deauth"
  of 25: "user connect abort when joining network"
  of 26: "user connect abort when scanning"
  else: "Unknown Code"

proc apmStatusStr(statusCode: uint16): cstring =
  case statusCode
  of 0: "apm connect ind ok"
  of 1: "User delete STA"
  of 2: "STA send deauth to AP"
  of 3: "STA send disassociate to AP"
  of 4: "timeout and delete connection"
  of 5: "Delete STA for new connection"
  else: "Unknown Code"

proc wifi_mgmr_get_sm_status_code_str*(statusCode: uint16): cstring {.exportc, cdecl.} =
  smStatusStr(statusCode)

proc wifi_mgmr_get_apm_status_code_str*(statusCode: uint16): cstring {.exportc, cdecl.} =
  apmStatusStr(statusCode)
