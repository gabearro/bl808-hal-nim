## LP names for the shared D0/LP WASM page client.

import ./wasm_page_client
export wasm_page_client

type WasmLpPageClient* = WasmPageClient

template initWasmLpPageClient*(client: var WasmLpPageClient, slots: uint32,
                                timeoutMs = WasmLpPageTimeoutMsDefault.uint64): bool =
  initWasmPageClient(client, slots, timeoutMs)

when defined(wasmPageWireHostTest):
  type WasmLpPageRpc* = WasmPageRpc
  template wasmLpPageRpc*: untyped = wasmPageRpc
