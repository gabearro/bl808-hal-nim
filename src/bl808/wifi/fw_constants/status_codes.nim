## Firmware connection and AP-mode status codes reported through host events.

const
  WLAN_FW_SUCCESSFUL*                                       = 0
  WLAN_FW_TX_AUTH_FRAME_ALLOCATE_FAIILURE*                  = 1
  WLAN_FW_AUTHENTICATION_FAIILURE*                          = 2
  WLAN_FW_AUTH_ALGO_FAIILURE*                               = 3
  WLAN_FW_TX_ASSOC_FRAME_ALLOCATE_FAIILURE*                 = 4
  WLAN_FW_ASSOCIATE_FAIILURE*                               = 5
  WLAN_FW_DEAUTH_BY_AP_WHEN_NOT_CONNECTION*                 = 6
  WLAN_FW_DEAUTH_BY_AP_WHEN_CONNECTION*                     = 7
  WLAN_FW_4WAY_HANDSHAKE_ERROR_PSK_TIMEOUT_FAILURE*         = 8
  WLAN_FW_4WAY_HANDSHAKE_TX_DEAUTH_FRAME_TRANSMIT_FAILURE*  = 9
  WLAN_FW_4WAY_HANDSHAKE_TX_DEAUTH_FRAME_ALLOCATE_FAIILURE* = 10
  WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE*            = 11
  WLAN_FW_SCAN_NO_BSSID_AND_CHANNEL*                        = 12
  WLAN_FW_CREATE_CHANNEL_CTX_FAILURE_WHEN_JOIN_NETWORK*      = 13
  WLAN_FW_JOIN_NETWORK_FAILURE*                              = 14
  WLAN_FW_ADD_STA_FAILURE*                                   = 15
  WLAN_FW_BEACON_LOSS*                                       = 16
  WLAN_FW_JOIN_NETWORK_SECURITY_NOMATCH*                     = 17
  WLAN_FW_JOIN_NETWORK_WEPLEN_ERROR*                         = 18
  WLAN_FW_DISCONNECT_BY_USER_WITH_DEAUTH*                    = 19
  WLAN_FW_DISCONNECT_BY_USER_NO_DEAUTH*                      = 20
  WLAN_FW_DISCONNECT_BY_FW_PS_TX_NULLFRAME_FAILURE*          = 21
  WLAN_FW_TRAFFIC_LOSS*                                      = 22
  WLAN_FW_CONNECT_ABORT_BY_USER_WITH_DEAUTH*                 = 23
  WLAN_FW_CONNECT_ABORT_BY_USER_NO_DEAUTH*                   = 24
  WLAN_FW_CONNECT_ABORT_WHEN_JOINING_NETWORK*                = 25
  WLAN_FW_CONNECT_ABORT_WHEN_SCANNING*                       = 26

  WLAN_FW_APM_SUCCESSFUL*                   = 0
  WLAN_FW_APM_DELETESTA_BY_USER*            = 1
  WLAN_FW_APM_DEATUH_BY_STA*                = 2
  WLAN_FW_APM_DISASSOCIATE_BY_STA*          = 3
  WLAN_FW_APM_DELETECONNECTION_TIMEOUT*     = 4
  WLAN_FW_APM_DELETESTA_FOR_NEW_CONNECTION* = 5
  WLAN_FW_APM_DEAUTH_BY_AUTHENTICATOR*      = 6
