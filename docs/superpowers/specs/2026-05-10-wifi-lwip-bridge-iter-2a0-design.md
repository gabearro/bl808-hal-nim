# WiFi lwIP Bridge — Iter 2.A.0 Design

**Date**: 2026-05-10
**Status**: Approved by user, ready for implementation planning
**Parent spec**: `docs/superpowers/specs/2026-05-09-wifi-dhcp-tcp-iter-2a-design.md` (Iter 2.A — discovered during execution that the WiFi blob's lwIP integration is fully stubbed in `wifi_vendor_support.c`; this sub-iteration unstubs it before 2.A.1 can resume)

---

## 1. Goal and success criteria

Replace the lwIP stubs in `src/bl808/wifi_vendor_support.c` with real bridges to the vendor lwIP that's already integrated via `src/bl808/kernel/lwipcore.nim`. After 2.A.0:

- The WiFi STA netif registered by the blob actually exists in vendor lwIP's netif chain
- DHCP can be started against that netif and reaches DHCPDISCOVER over the air
- Incoming DHCPOFFER packets from the AP reach vendor lwIP and DHCP completes (lease assigned)
- An ICMP ECHO REQUEST sent from the board reaches the gateway and the ECHO REPLY gets back to vendor lwIP
- All of the above without modifying the WiFi blob, the SDK lwIP path, or any other test

**Concrete success criterion** (one new test binary, run from the existing soak harness):

```
m0_wifi_lwip_smoke
  associate to Frog
  dhcp_start(netif), poll for IP-assigned, max 10s          → IP received
  raw ICMP: send ECHO REQUEST to gateway, await REPLY, max 3s → reply with RTT
  emit @e2e markers for each phase
```

Pass: at least 1 of 3 attempts completes the ICMP echo. Failures are bucketed per phase using the same marker pattern as Iter 1 / 2.A.

**Out of scope for 2.A.0**:
- TCP path (waited until 2.A.1)
- UDP beyond what DHCP itself uses
- DHCP renew/rebind logic (one-shot lease only)
- IPv6, DNS, multicast
- The reimpl backend (`bl808WifiNimFw=1`) — defer until 2.A.0 works on the blob path
- Live UART streaming
- Performance tuning of the RX/TX path (correctness first; throughput later)

**Verified preconditions** (established during the brainstorm):
- vendor lwIP and SDK lwIP have **identical** `struct netif` and `struct pbuf` layouts under current lwipopts (verified via `diff` of header struct definitions: 3 conditional netif fields and 1 conditional pbuf macro hook differ; none are enabled in either build)
- `tcpip_stack_input` is the only lwIP-side symbol the blob references (verified via `nm libwifi_fw.a`)
- Vendor lwIP `dhcp_start`, `pbuf_alloc`, `etharp_output`, `netif_add` are already exposed via `lwipcore.nim` and compile-included via that file's `{.compile:}` blocks

**Known unknowns** (resolved in Pass 1's investigation phase):
- The blob's TX API entry point (likely `bl_main_tx`, `bl_main_tx_frame`, or `bl_send_data`)
- The blob's `wifi_pkt` alloc/free convention after `tcpip_stack_input` consumes a packet
- Whether `bl606a0_wifi_netif_init` already sets a `linkoutput` we'd be overwriting

---

## 2. Architecture

Six C functions in `wifi_vendor_support.c` get real bodies. The vendor-lwIP-side wrappers are already exported by `src/bl808/kernel/lwipcore.nim` (compiles vendor lwIP and exposes `dhcp_start`, `pbuf_alloc`, `netif_add`, etc. via importc). The C bridge functions just call them directly — both sides see the same lwIP symbols at link time.

### 2.1 Bridge functions (replace stubs in `wifi_vendor_support.c`)

```
1. netifapi_netif_add(netif, ipaddr, netmask, gw, state, init, input)
   → netif_add(netif, ipaddr, netmask, gw, state, init, input)  [vendor lwIP]
   Now the netif joins lwIP's netif_list chain instead of being orphaned.

2. netif_set_up(netif), pbuf_alloc(...), pbuf_take(...), etharp_output(...),
   netif_set_default(...) — DELETE the local stubs entirely; vendor lwIP's
   real implementations win at link time.

3. wifi_netif_dhcp_start(netif)
   → return dhcp_start(netif)  [vendor lwIP]
   Currently returns 0 without doing anything.

4. tcpip_input(p, inp)
   → return inp->input(p, inp)  [NO_SYS=1, no thread; just dispatch]

5. tcpip_stack_input(swdesc, status, hwhdr, msdu_offset, pkt, extra_status)
   → wrap blob's wifi_pkt into a vendor pbuf, call netif->input(p, netif),
   release blob's wifi_pkt back to its pool
   This is the load-bearing one.
```

### 2.2 New TX adapter `bl808_wifi_linkoutput`

```c
err_t bl808_wifi_linkoutput(struct netif *netif, struct pbuf *p)
  → pbuf_copy_partial(p, buf, sizeof(buf), 0) to flatten chain
  → call blob's TX entry point (TBD by Pass 1 investigation)
  → return ErrOk on success, ErrIf on failure
```

Wired into the netif via the existing `bl606a0_wifi_netif_init` callback, OR by setting `netif->linkoutput = bl808_wifi_linkoutput` immediately after `netifapi_netif_add` returns. Pass 1 picks based on what the init callback already does.

### 2.3 Investigation task (first task of 2.A.0 Pass 1)

Before any code change, identify:
- The blob's TX API symbol and signature
- The blob's `wifi_pkt` alloc/free convention
- Whether `bl606a0_wifi_netif_init` already sets a `linkoutput`

Output: a short investigation note appended to this spec as Section 6 (committed before Pass 1's code-change tasks proceed).

### 2.4 Symbol shadowing strategy

Today, `wifi_vendor_support.c` defines local stubs for symbols that vendor lwIP also defines (`netif_set_up`, `pbuf_alloc`, etc.). The local stubs win at link time because they're in the same translation unit chain compiled first. **Strategy**: delete the local stubs entirely. The C linker will then resolve to vendor lwIP's real implementations from `lwipcore.nim`'s `{.compile:}` blocks.

Functions where we DO want our wrapper (`netifapi_netif_add`, `tcpip_stack_input`, `wifi_netif_dhcp_start`, `tcpip_input`) keep their definitions because vendor lwIP doesn't provide those (Bouffalo-specific names).

### 2.5 No new files

All changes are localized:
- `src/bl808/wifi_vendor_support.c` — replace 5 stub bodies, delete ~5 shadowing stubs, add 1 new function (~150 lines net change)
- `tools/hardware_validation.json` — add `m0_wifi_lwip_smoke` test entry
- `examples/m0_wifi_lwip_smoke.nim` — new test binary

The vendor lwIP integration in `src/bl808/kernel/lwipcore.nim` is unchanged (additive only if missing importc wrappers turn up).

---

## 3. Data flow per attempt (m0_wifi_lwip_smoke)

```
board                                     vendor lwIP                blob (libwifi_fw.a)
─────                                     ───────────                ───────────────────
boot, e2e_runner.start
  for attempt n in 1..3:
    @e2e attempt:start n=n total=3

    @e2e scan:start ssid=Frog
      wifiInit()                                                   wifi_mgmr_init
        netif_add(&wlan_sta.netif, ...)  →  netif_list += wlan_sta
        netif_set_up(netif)              →  netif.flags |= UP
    @e2e scan:ok
    @e2e auth:start
      wifiConnect(Frog, password)                                  scan + auth + 4whs + assoc
                                                                    (unchanged from Iter 1)
    @e2e auth:ok
    @e2e four_whs:start / :ok                                       (synthetic, unchanged)
    @e2e assoc:start / :ok                                          (synthetic, unchanged)

    @e2e dhcp:start
      dhcp_start(netif)
        send DHCPDISCOVER:
          dhcp.c calls etharp_output → ip4_output → netif->linkoutput
          → bl808_wifi_linkoutput(netif, p)
            flatten p into contiguous buf
            call blob TX API                            →  blob queues frame, schedules TX
                                                            (radio packet leaves the chip)

      poll for IP:
        for 200 iters (50ms each):
          sysCheckTimeouts()
          ip4 = netif->ip_addr.addr; if non-zero, break

                                                            (radio packet arrives: DHCPOFFER)
                                                          blob RX path:
                                                            extract wifi_pkt from MAC RX FIFO
                                                            tcpip_stack_input(...)
            ↓ our bridge ↓
            wrap pkt's payload into vendor pbuf via pbuf_alloc + memcpy
            netif->input(p, netif)
              → ethernet_input → ip4_input → udp_input → dhcp_recv
              → netif->ip_addr.addr = OFFER's yiaddr
            release wifi_pkt back to blob's pool

      ip4 = netif->ip_addr.addr → non-zero
      gw4 = netif->gw.addr
    @e2e dhcp:ok ip=10.0.0.42 gw=10.0.0.1

    @e2e icmp:start dst=gw
      raw_new(IP_PROTO_ICMP)
      raw_recv(pcb, icmp_recv_cb, &state)
      raw_sendto(pcb, p_icmp_request, &gw_ip)
        → ip4_output → linkoutput → blob TX → radio packet leaves
                                                            (radio: ICMP ECHO REPLY arrives)
                                                          blob RX → tcpip_stack_input → our bridge
                                                            → ip4_input → icmp_input
                                                            → raw_input → icmp_recv_cb fires
      poll state.replied for up to 3s; sysCheckTimeouts()
    @e2e icmp:ok rtt_ms=12 src=10.0.0.1
    @e2e attempt:ok n=n total=3
    deinitForRetry: wifiDisconnect()
```

### Failure modes per phase (new for 2.A.0)

- **dhcp**:
  - `no_netif` — `wifiGetNetif()` returned nil
  - `dhcp_start` — `dhcp_start()` returned non-OK
  - `tx_failed` — first DHCPDISCOVER's linkoutput returned err
  - `timeout` — IP stayed 0 for 10s
- **icmp**:
  - `pcb_alloc` — `raw_new` returned nil
  - `tx_failed` — sendto returned err
  - `recv_timeout` — no ECHO REPLY in 3s

The aggregator's "explicit fail wins" rule already handles all of these without parser changes.

### TX path detail — pbuf flattening

```c
err_t bl808_wifi_linkoutput(struct netif *netif, struct pbuf *p) {
  uint8_t buf[1500];
  uint16_t len = pbuf_copy_partial(p, buf, sizeof(buf), 0);
  if (len == 0) return ERR_BUF;
  return blob_tx_api(buf, len);  /* symbol resolved by Pass 1 investigation */
}
```

`pbuf_copy_partial` is a vendor lwIP API (already exported via lwipcore). Returns the number of bytes copied across the chain.

### RX path detail — pbuf wrap

```c
int tcpip_stack_input(void *swdesc, uint8_t status, void *hwhdr,
                      unsigned int msdu_offset, struct wifi_pkt *pkt,
                      uint8_t extra_status) {
  uint8_t *payload = (uint8_t *)pkt->pkt[0] + msdu_offset;
  uint16_t len = pkt->len[0] - msdu_offset;
  struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_POOL);
  if (!p) goto release;
  pbuf_take(p, payload, len);
  err_t err = wifiMgmr.wlan_sta.netif.input(p, &wifiMgmr.wlan_sta.netif);
  if (err != ERR_OK) pbuf_free(p);
release:
  /* return wifi_pkt to blob's pool — convention determined by Pass 1 */
  return 0;
}
```

`status`, `extra_status`, and `hwhdr` are largely ignorable for 2.A.0 (used by Bouffalo's reference impl for sniffer mode + AMSDU + RSSI tracking; not relevant to DHCP+ICMP).

---

## 4. File and module layout

### New files

```
examples/m0_wifi_lwip_smoke.nim          ~150 lines
  Single-binary smoke test. Reuses e2e_marker + e2e_runner from Iter 1.
  Phases: scan → auth → 4whs → assoc → dhcp → icmp.
  Inline {.importc.} declarations for: dhcp_start, sysCheckTimeouts,
  raw_new, raw_recv, raw_sendto, raw_remove (and friends).
  Inline {.emit:} accessors for netif->ip_addr.addr, netif->gw.addr.
  Validation surface — when icmp:ok lands, 2.A.0 is done.
```

### Modified files

```
src/bl808/wifi_vendor_support.c                ~150 lines net change
  Delete (let vendor lwIP win at link time):
    - netif_set_up stub          (~line 2032)
    - pbuf_alloc stub            (~line 2092)
    - pbuf_alloced_custom stub   (~line 2108, if also a stub)
    - pbuf_take stub             (~line 2147)
    - etharp_output stub         (~line 2067)
    - netif_set_default stub
  Replace bodies:
    - netifapi_netif_add → call vendor netif_add
    - netifapi_netif_set_addr → keep field-set body (already correct)
    - netifapi_netif_set_default → call vendor netif_set_default
    - netifapi_netif_set_up → call vendor netif_set_up
    - netifapi_netif_common → unchanged
    - tcpip_input → return inp->input(p, inp) (one-line passthrough)
    - tcpip_stack_input → real wrap-and-input bridge (Section 3)
    - wifi_netif_dhcp_start → return dhcp_start(netif)
  Add:
    - bl808_wifi_linkoutput(netif, p) — flatten pbuf, call blob TX API
    - In bl606a0_wifi_netif_init OR post-add in netifapi_netif_add:
      set netif->linkoutput = bl808_wifi_linkoutput

tools/hardware_validation.json                 ~+15 lines
  New test entry m0_wifi_lwip_smoke:
    tier: e2e
    source: examples/m0_wifi_lwip_smoke.nim
    defines: bl808WifiVendor=1, WifiSsid env, WifiPassword secret_env,
             AttemptsTotal env (default 3)
    required: ["=== BL808 LwIP Smoke Complete ==="]
    timeout: 240

tools/e2e_phases.py                            ~+1 line
  Add Phase.ICMP = "icmp" to the enum. Re-run gen_e2e_marker_nim.py to
  regenerate the Nim copy. Drift test catches missing regenerate.

src/bl808/kernel/e2e_marker.nim                generated (don't hand-edit)
  Re-run python tools/gen_e2e_marker_nim.py after Phase.ICMP add.

Makefile                                       ~+3 lines
  Add hw-e2e-lwip-smoke target (parallel to hw-e2e-quick).

tools/hw_e2e.py                                ~+30 lines
  Add "wifi-lwip-smoke" cell mode. Same flow as "wifi-blob": anchor-flash,
  parse log, summarize. No EchoServer wiring (TCP comes in 2.A.1).

src/bl808/kernel/lwipcore.nim                  possibly +5 lines
  If raw_new / raw_recv / raw_sendto / pbuf_copy_partial aren't already
  exported, add the importc wrappers. Quick check during Pass 1.
```

### Conventions unchanged

- Phase enum: still single-source-of-truth in `tools/e2e_phases.py`; drift test catches desync.
- Build path: `make m0` via hw_validate.py catalog mode.
- Anchor flash: same pattern as Iter 1.
- Marker grammar: same `@e2e <phase>:<kind> [k=v]…`.
- Test scaffolding: `e2eRun(N, runOneAttempt, deinitForRetry)` from `e2e_runner.nim`.
- The new `m0_wifi_lwip_smoke` binary lives **alongside** `m0_wifi_e2e_test` (it doesn't replace it). After 2.A.0 demonstrates lwIP works, 2.A.1 extends `m0_wifi_e2e_test` with dhcp+tcp markers (resuming from the earlier stash).

### What does NOT change

- `src/bl808/wifi.nim` — no edits.
- `src/bl808/wifi_main.nim` — no edits.
- `src/bl808/kernel/lwipcore.nim` — only additive (new importc wrappers if needed).
- The vendor lwIP source files compiled by lwipcore — unchanged.

---

## 5. Staging within 2.A.0

Three implementation passes. Each produces something testable on hardware.

### Pass 1 — Investigation + DHCP-only path

Lands:
- **Read-only investigation** (no commits yet): identify the blob's TX API symbol and signature; read `bl606a0_wifi_netif_init`'s body to see what fields it sets and whether it already wires a linkoutput; find the blob's wifi_pkt alloc/free convention. Output: a short note appended to this spec as Section 6, committed before Pass 1's code-change tasks proceed.
- `tools/e2e_phases.py` → add `Phase.ICMP`. Re-run generator. Drift test still passes.
- `src/bl808/wifi_vendor_support.c`:
  - Delete the symbol-shadowing stubs (`netif_set_up`, `pbuf_alloc`, `pbuf_take`, `etharp_output`, `netif_set_default`)
  - Replace `netifapi_netif_add` body with `return netif_add(...)` delegate
  - Replace `tcpip_input` body with `return inp->input(p, inp)`
  - Replace `wifi_netif_dhcp_start` body with `return dhcp_start(netif)`
  - Replace `tcpip_stack_input` body with the wrap-and-input bridge (Section 3)
  - Add `bl808_wifi_linkoutput` and wire it into the netif post-add
- `examples/m0_wifi_lwip_smoke.nim` → new binary, scan/auth/4whs/assoc/**dhcp** only (no icmp yet)
- Catalog entry for `m0_wifi_lwip_smoke`
- Makefile `hw-e2e-lwip-smoke` target

Success: `make hw-e2e-lwip-smoke UART_PORT=… WIFI_SSID=Frog WIFI_PASSWORD=…` runs the smoke binary N=3, attempts reach `dhcp:ok ip=… gw=…` at least once. The full chain (DHCPDISCOVER TX → DHCPOFFER RX → lwIP state populated) is proven.

If DHCP times out, the failure bucket tells us where:
- `dhcp:fail reason=tx_failed` — TX bridge broken
- `dhcp:fail reason=timeout` — TX worked but no OFFER got back, OR OFFER got back but our RX bridge dropped it (most likely failure mode)

Pass 1 deliberately does NOT add ICMP. If DHCP doesn't work, ICMP can't possibly work, and adding both at once doubles the failure surface.

### Pass 2 — ICMP echo

Lands:
- `src/bl808/kernel/lwipcore.nim` → additive importc wrappers for `raw_new`, `raw_recv`, `raw_sendto`, `raw_remove`, `pbuf_copy_partial` (any not already exported)
- `examples/m0_wifi_lwip_smoke.nim` → extend `runOneAttempt` with the icmp phase: open raw PCB, send ECHO REQUEST to gw, wait for ECHO REPLY callback, validate seq/identifier
- Catalog entry → unchanged (timeout already 240s)

Success: `make hw-e2e-lwip-smoke` reaches `icmp:ok rtt_ms=… src=…` at least once across N=3 attempts. Bidirectional packet flow proven.

If ICMP fails after DHCP works:
- `icmp:fail reason=tx_failed` — same TX bridge that DHCP TX uses; would be surprising at this point but possible if ICMP-sized packets vs DHCP-sized exposes a length issue
- `icmp:fail reason=recv_timeout` — ECHO REPLY didn't arrive or didn't reach lwIP

### Pass 3 — Cleanup + handoff to 2.A.1

Lands:
- Pop the stash from earlier (the in-progress `m0_wifi_e2e_test.nim` DHCP additions). Now that the lwIP bridge is real, those changes work as the original plan intended.
- Resume Iter 2.A Pass 1 (the original DHCP markers in `m0_wifi_e2e_test`) — but it's now mostly a no-op since the smoke test already proved the same path. Quick verification run.
- Optionally: delete `m0_wifi_lwip_smoke` if its only purpose was bringup validation. Recommend keeping — small file, focused per-phase regression target separate from the full WiFi e2e binary.

### Stop conditions for 2.A.0 as a whole

- Pass 1 lands `dhcp:ok` reliably (≥ 1 of 3 attempts; "land the data shape" applies, not "tune the rate")
- Pass 2 lands `icmp:ok` at least once
- Pass 3 reconnects the smoke validation to the broader 2.A.1 plan

Total Iter 2.A.0 effort: probably 2-3 sessions, depending on how much TX-API archaeology Pass 1 turns up.

---

## 6. Investigation findings

### Blob TX API entry point

- **Symbol:** `bl_output`
- **Signature:** `err_t bl_output(struct bl_hw *bl_hw, int is_sta, struct pbuf *p, struct bl_tx_cfm *custom_cfm)` (BL808 build — no `from_local` flag; that field only appears under `CFG_NETBUS_WIFI_ENABLE`).
- **Source of evidence:**
  - SDK reference: `build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_tx.c:549` (declaration), `bl_tx.h:111`.
  - Already implemented in our HAL as a Nim `exportc` proc: `src/bl808/wifi_tx.nim:442` (full body that pushes onto `sta->waiting_list` and calls `bl_irq_handler` via `txCntrlCheckFc`).
  - The blob itself does NOT export a TX entry point — `nm libwifi_fw.a` shows zero `bl_main_tx*` / `bl_send_data` / `bl_main_send_data` symbols. The blob's only undefined lwIP-side symbol is `tcpip_stack_input`. The TX entry is host-side code we already own.
- **Implication:** Linkoutput is NOT a flat-byte-buffer API; it takes a `struct pbuf *` directly (same pbuf type the lwIP stack hands us — vendor pbuf == SDK pbuf, header layouts verified identical). `bl_output` reads the ethernet header from `p->payload`, expands the pbuf header by `PBUF_LINK_ENCAPSULATION_HLEN` (48), writes a `bl_txhdr` in front, calls `pbuf_ref(p)`, and queues the pbuf on the per-STA `waiting_list`. **No flatten/copy step is needed in `bl808_wifi_linkoutput` — we hand `bl_output` the pbuf as-is.** Section 3.4 of this spec ("TX path detail — pbuf flattening") was based on a wrong assumption; Task 3 should drop the `pbuf_copy_partial` step.

### wifi_pkt free convention after tcpip_stack_input

- **Caller-owned (blob owns and frees the wifi_pkt).** Our `tcpip_stack_input` MUST **return a non-zero value (use -1)** to signal "blob, please free". Returning 0 means "callee retained ownership" (used by zerocopy/custom-pbuf path that we are NOT taking on BL808).
- **Evidence:**
  - SDK reference impl: `build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_utils.c:391-521`. The function uses a local `bool free_by_lowlayer = true` (line 398), only sets it to `false` in the zerocopy branch (line 513), and the final `if (free_by_lowlayer) return -1; else return 0;` (lines 515-520) encodes the contract.
  - For BL808 specifically: `bl_utils.c:438-440` — `#if defined(CFG_CHIP_BL808)` selects `_handle_frame_from_stack_with_mempool` (which `pbuf_alloc`+`pbuf_take` the payload) and sets `zerocopy = false`. So BL808 **always** returns -1.
  - Our existing Nim impl in `src/bl808/wifi_utils.nim:216-251` already encodes this convention: it returns `-1` unconditionally at the end and uses the mempool path under `bl808WifiRxPbufInput`.
  - Caller side: `src/bl808/wifi_fw.nim:19995-20007` (`rxu_swdesc_upload_evt`) — if `tcpip_stack_input` returns non-zero, it calls `rxl_mpdu_free(entry)`. So returning -1 triggers the blob's own free path; we do nothing extra.
- **Implication for `wifi_vendor_support.c` bridge:** Use the mempool wrap (alloc a vendor pbuf, `pbuf_take` the payload, push to `netif->input`, `pbuf_free` on input failure). No call to a `bl_pkt_free` / `bl_msdu_free` API is needed — those don't exist. Just return -1 and the blob's `rxl_mpdu_free` runs in the caller.

### bl606a0_wifi_netif_init body summary

- **Already implemented in our HAL** (Nim, exportc) at `src/bl808/wifi_driver.nim:155-166`. Currently wired into the netif by `wifi_vendor_support.c:2810-2811`'s `netifapi_netif_add(... , bl606a0_wifi_netif_init, tcpip_input)` call. The C `extern err_t bl606a0_wifi_netif_init(struct netif *netif);` at line 52 imports it.
- **Sets `netif->mtu`:** yes, `1500`.
- **Sets `netif->flags`:** yes, `NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_IGMP`.
- **Sets `netif->hostname`:** yes, points to `wifiMgmr.hostname`.
- **Sets `netif->hwaddr_len`:** yes, `ETHARP_HWADDR_LEN` (6).
- **Sets `netif->output`:** yes, to vendor lwIP `etharp_output`.
- **Sets `netif->linkoutput`:** **YES, to a private `wifiTx` (Nim proc, file-scope, `cdecl` but NOT exported).** The proc body (`wifi_driver.nim:122-135`) calls `bl_output(bl606a0StaHw, isSta, p, addr customCfm)` — i.e., it already does the right thing.
- **Sets `netif->status_callback`:** yes, via `netif_set_status_callback`.
- **Implication for Task 3:**
  - We do **NOT** need to add a separate `bl808_wifi_linkoutput` C function — `wifiTx` in `wifi_driver.nim` is already the linkoutput, already wired by init, and already calls `bl_output`. Section 2.2 of this spec is largely obsolete; the linkoutput exists.
  - The bug today is NOT a missing linkoutput. The bugs are: (a) `netifapi_netif_add` does not call vendor `netif_add` so the netif never joins `netif_list` (lines 1977-1988 ignore ipaddr/netmask/gw and never link the netif), (b) `tcpip_input` is a stub that just frees the pbuf (lines 2060-2065), (c) `wifi_netif_dhcp_start` is a no-op (line 3104), (d) `tcpip_stack_input` C entry has no body in this file (only the gated Nim version in `wifi_utils.nim`).
  - Critical caveat: `bl606a0StaHw` is initialized inside `bl606a0_wifi_init` (`wifi_driver.nim:191-211`) and consumed by `wifiTx` via `bl_output(bl606a0StaHw, ...)`. Verify this is non-nil before any `dhcp_start` runs in the smoke test, otherwise the linkoutput will return `ErrConn` immediately.

### RX context (tcpip_stack_input)

- **Task context.** `tcpip_stack_input` is reached only from `rxu_swdesc_upload_evt`, which is dispatched as KE event handler index 8 (`wifi_fw.nim:1506`). Handlers are invoked synchronously by `ke_evt_schedule` (`wifi_fw.nim:2032-2046`) via an indirect call. `ke_evt_schedule` is called from `vendor_poll_once` in `src/bl808/wifi_vendor_support.c:1272`, which itself runs from a polled main-loop call (`vendor_poll_for` at line 1280-1286, called from `bl808_wifi_vendor_poll`).
- **No real ISR path:** The MAC IRQ is consumed by polling (`bl808_wifi_vendor_poll_mac_irq`, line 1260) and the IPC IRQ is also polled (`bl808_wifi_vendor_host_ipc_status() != 0` → call `bl_irq_handler`, lines 1263-1266). `wifi_irqs.nim` exposes `bl_irq_bottomhalf` for IPC processing — also called from polled context.
- **Implication for bridge:** Safe to `pbuf_alloc` directly inside `tcpip_stack_input`. No deferred ring buffer required for Pass 1. (Future caveat: if any RX path is ever switched to a true ISR — e.g., an actual MAC RX IRQ wired to the CLIC — this assumption breaks. None of the existing code does that today.)

### Additional notes for Task 3 implementer

- The spec's Section 2.2 ("New TX adapter `bl808_wifi_linkoutput`") and Section 3 "TX path detail — pbuf flattening" should be considered superseded — there is no new TX adapter to write and no flatten step. Task 3 just needs to make sure `netifapi_netif_add` actually calls vendor `netif_add` (so the chain init runs `bl606a0_wifi_netif_init`, which already wires `wifiTx`).
- Because `wifi_driver.nim` already provides `wifiTx`, `bl_output`, `bl606a0_wifi_netif_init`, `netifStatusCallback`, the C `extern` declarations and the C-side stubs in `wifi_vendor_support.c` are duplicates that sometimes mask the Nim definitions. The "delete shadowing stubs" plan in Section 2.4 still applies, and extra care is needed: `wifi_vendor_support.c` defines `netif_set_status_callback` (line 2053-2058) — if vendor lwIP also defines it, deleting the stub may be a no-op; if not, keep the stub since `bl606a0_wifi_netif_init` calls it.
- The spec's Section 3 RX-path code uses `pkt->pkt[0]` and `pkt->len[0]`, matching the SDK's `struct wifi_pkt` (defined in `bl_utils.c:215-219`: `uint32_t pkt[4]; void *pbuf[4]; uint16_t len[4];`). That layout is correct.
- `extra_status` carries the AMSDU bit (`BL_RX_STATUS_AMSDU`); set `p->flags |= PBUF_FLAG_AMSDU` when present. The existing Nim impl in `wifi_utils.nim:240-241` already does this; the C bridge should mirror it.

---

## 7. Risks and unknowns

- **Blob's TX API discovery may take longer than expected.** If grep doesn't find a clean entry point, may need to read `wifi_main.nim`'s existing `bl_send_*` calls to triangulate.
- **`tcpip_stack_input`'s wifi_pkt convention** — the SDK's reference `bl_utils.c` implementation uses `_handle_frame_from_stack_with_mempool(swdesc, msdu_offset, pkt)` to wrap and `bl_pkt_free` (or similar) to release. We're skipping the mempool wrap and going straight to vendor-pbuf-copy. May leak the blob's wifi_pkt if we don't release it. First hardware run with `dhcp:ok` is the canary: if it works once and times out on subsequent attempts, the leak is the cause.
- **Symbol-shadow deletion may break other tests.** Removing `pbuf_alloc` stub etc. means anything that called the stub now calls vendor lwIP. If anything depended on the stub's no-op behavior (unlikely), it'll change. **Smoke-test the existing `m0_wifi_hal_test` after Pass 1's stub deletion** to confirm it still scans/connects.
- **lwIP heap/pool sizing** under Bouffalo's vendor lwipopts may not be tuned for the additional traffic. DHCP packets are small (~300 bytes), ICMP is small (~64 bytes); should be fine for one in-flight at a time. Performance later.
- **Concurrent TX/RX safety.** Vendor lwIP is NO_SYS=1, single-threaded. The blob's RX path may call `tcpip_stack_input` from an IRQ context; if so, `pbuf_alloc` from IRQ is unsafe. Pass 1 investigation should check whether blob RX is IRQ-context or task-context. If IRQ, we need a small ring buffer to defer the input call to the main loop.
