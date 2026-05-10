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

(To be filled in by Pass 1's investigation task before any code change.)

Required findings:
- Blob TX API entry point symbol + signature
- Blob `wifi_pkt` alloc/free convention (does our `tcpip_stack_input` need to release the pkt back? via what API?)
- `bl606a0_wifi_netif_init` body — what does it set, does it wire a `linkoutput`?

---

## 7. Risks and unknowns

- **Blob's TX API discovery may take longer than expected.** If grep doesn't find a clean entry point, may need to read `wifi_main.nim`'s existing `bl_send_*` calls to triangulate.
- **`tcpip_stack_input`'s wifi_pkt convention** — the SDK's reference `bl_utils.c` implementation uses `_handle_frame_from_stack_with_mempool(swdesc, msdu_offset, pkt)` to wrap and `bl_pkt_free` (or similar) to release. We're skipping the mempool wrap and going straight to vendor-pbuf-copy. May leak the blob's wifi_pkt if we don't release it. First hardware run with `dhcp:ok` is the canary: if it works once and times out on subsequent attempts, the leak is the cause.
- **Symbol-shadow deletion may break other tests.** Removing `pbuf_alloc` stub etc. means anything that called the stub now calls vendor lwIP. If anything depended on the stub's no-op behavior (unlikely), it'll change. **Smoke-test the existing `m0_wifi_hal_test` after Pass 1's stub deletion** to confirm it still scans/connects.
- **lwIP heap/pool sizing** under Bouffalo's vendor lwipopts may not be tuned for the additional traffic. DHCP packets are small (~300 bytes), ICMP is small (~64 bytes); should be fine for one in-flight at a time. Performance later.
- **Concurrent TX/RX safety.** Vendor lwIP is NO_SYS=1, single-threaded. The blob's RX path may call `tcpip_stack_input` from an IRQ context; if so, `pbuf_alloc` from IRQ is unsafe. Pass 1 investigation should check whether blob RX is IRQ-context or task-context. If IRQ, we need a small ring buffer to defer the input call to the main loop.
