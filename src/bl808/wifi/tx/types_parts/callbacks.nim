type
  TxCallback = proc(cbArg: pointer; txOk: bool) {.cdecl.}
