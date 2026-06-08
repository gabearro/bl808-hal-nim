## SCANU, station-manager, connection, crypto, and scan parameter layouts.

const
  ScanuChanOff = 0'u
  ScanuSsidOff = 252'u
  ScanuBssidOff = 286'u
  ScanuMacOff = 292'u
  ScanuAddIesOff = 300'u
  ScanuAddIeLenOff = 304'u
  ScanuVifIdxOff = 306'u
  ScanuChanCntOff = 307'u
  ScanuSsidCntOff = 308'u
  ScanuNoCckOff = 309'u
  ScanuDurationOff = 316'u
  ScanuRawPktOff = 0'u
  ScanuRawLenOff = 4'u

  SmSsidOff = 0'u
  SmBssidOff = 34'u
  SmChanOff = 40'u
  SmFlagsOff = 48'u
  SmCtrlPortEthertypeOff = 52'u
  SmListenIntervalOff = 54'u
  SmDontWaitBcmcOff = 56'u
  SmAuthTypeOff = 57'u
  SmUapsdQueuesOff = 58'u
  SmVifIdxOff = 59'u
  SmSupplicantEnabledOff = 61'u
  SmPhraseOff = 62'u
  SmPhrasePmkOff = 126'u

  ConnChannelOff = 0'u
  ConnBssidOff = 56'u
  ConnSsidOff = 64'u
  ConnSsidLenOff = 68'u
  ConnAuthTypeOff = 72'u
  ConnMfpOff = 84'u
  ConnCryptoOff = 88'u
  ConnKeyOff = 148'u
  ConnPmkOff = 152'u
  ConnKeyLenOff = 156'u
  ConnPmkLenOff = 157'u
  ConnFlagsOff = 160'u
  ConnChanBandOff = 0'u
  ConnChanFreqOff = 2'u
  ConnChanFlagsOff = 8'u
  CryptoCipherGroupOff = 4'u
  CryptoNCiphersOff = 8'u
  CryptoCiphers0Off = 12'u
  CryptoControlPortOff = 44'u
  CryptoControlEthertypeOff = 46'u
  CryptoControlNoEncOff = 48'u

  ScanParaChannelsOff = 0'u
  ScanParaChannelNumOff = 4'u
  ScanParaBssidOff = 8'u
  ScanParaSsidOff = 12'u
  ScanParaMacOff = 16'u
  ScanParaModeOff = 20'u
  ScanParaDurationOff = 24'u
