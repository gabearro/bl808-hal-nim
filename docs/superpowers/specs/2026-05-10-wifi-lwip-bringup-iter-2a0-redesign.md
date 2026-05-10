# WiFi lwIP Bring-up — Iter 2.A.0 Re-design

**Date**: 2026-05-10
**Status**: Approved by user, ready for implementation planning
**Supersedes**: `docs/superpowers/specs/2026-05-10-wifi-lwip-bridge-iter-2a0-design.md` (the original Iter 2.A.0 spec, whose monolithic T3 attempt failed because it underestimated the integration complexity — multiple layers of unresolved symbols cascade once the shadowing stubs are deleted)

**Related history**:
- Original Iter 2.A.0 spec: `docs/superpowers/specs/2026-05-10-wifi-lwip-bridge-iter-2a0-design.md`
- Investigation findings (Section 6 of original spec): committed at `61295b6`
- T3 attempt that broke the build: `f2736e2` (effectively reversed by the recovery commit `5c02184`)
- Recovery checkpoint after data-loss event: `5c02184`

---

## 1. Goal and success criteria

Replace the `wifi_vendor_support.c` lwIP stubs with real bridges to vendor lwIP, integrated **incrementally** so the build is verifiable after each commit. After this iteration:

- `make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=6509171272 -d:WifiScanOnly=true'` builds cleanly with vendor lwIP linked into the binary
- `wifi_vendor_support.c`'s `netifapi_netif_add` / `tcpip_input` / `wifi_netif_dhcp_start` bridges actually call vendor lwIP (no longer no-ops)
- The blob's WiFi netif is registered in vendor lwIP's netif chain
- Future `dhcp_start(netif)` calls would actually trigger DHCP packets (untested in this iteration; smoke test is a follow-up)

**Out of scope for this iteration**:
- New test binary (`m0_wifi_lwip_smoke.nim`) — follow-up
- Hardware verification that DHCP actually completes — follow-up
- TX path correctness verification — follow-up
- Reimpl backend (`bl808WifiNimFw=1`) — separate iteration entirely
- Anything BLE — separate iteration

**Success criterion per commit** (mandatory, no exceptions):
- Each commit must leave `make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=6509171272 -d:WifiScanOnly=true' 2>&1 | tail -5` ending in `Output: build/m0_firmware.bin`. If a commit breaks the build, the commit is wrong and gets reverted before continuing.

**Predicted state after iteration**: same observable behavior (scan/auth/4whs/assoc work; DHCP doesn't reach the AP because the test binary doesn't call `dhcp_start`). The DIFFERENCE is that the substrate is now correct — a follow-up iteration writing the smoke test will actually exercise DHCP.

**Verified preconditions** (established during this brainstorm):
- Vendor lwIP and SDK lwIP have **identical** `struct netif` and `struct pbuf` layouts under current lwipopts (verified during the original spec brainstorm)
- The link-error landscape has been exhaustively enumerated:
  - **15 symbols collide** (vendor lwIP provides; need to delete our stubs): `netif_set_default`, `netif_set_up`, `netif_set_link_up`, `netif_set_link_down`, `netif_set_status_callback`, `etharp_output`, `pbuf_alloc`, `pbuf_alloced_custom`, `pbuf_take`, `pbuf_free`, `pbuf_ref`, `pbuf_cat`, `pbuf_header`, `ipaddr_addr`, `ip4addr_ntoa`
  - **2 must keep stubbed** (vendor's `netifapi.c` not compiled by lwipcore): `netifapi_netif_set_link_up`, `netifapi_netif_set_link_down`
  - **1 missing libc symbol**: `_ctype_` (newlib's 256-byte table, used by vendor's `ip4_addr.c`)
  - **1 unique stub keeps**: `inet_addr` (libc-compat, not in vendor)

---

## 2. The four commits in detail

### Commit 1 — Add `_ctype_` table to `baremetal_libc.c`

**Files**: `src/bl808/kernel/baremetal_libc.c`

Append a 257-byte newlib-format `_ctype_` table at end of file. Indexed by `c+1`; bit flags per character class (`_U` upper, `_L` lower, `_N` digit, `_S` whitespace, `_P` punct, `_C` control, `_X` hex, `_B` blank). Vendor lwIP's `ip4_addr.c` uses `<ctype.h>` macros like `isdigit()` which expand to `(_ctype_+1)[c] & _N`.

Take the `_ctype_` definition verbatim from a known newlib source (or the Bouffalo SDK's copy if simpler) rather than inventing one — wrong bit flags would silently fail later.

**Build verification**: `make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=6509171272 -d:WifiScanOnly=true' 2>&1 | tail -5` must end in `Output: build/m0_firmware.bin`. The new symbol is currently unreferenced (no vendor lwIP in the link yet), so this is a pure-addition commit with zero behavior change.

**Commit message**: `baremetal_libc: add _ctype_ table for vendor lwIP ip4_addr.c (Iter 2.A.0 step 1/4)`

---

### Commit 2 — Add `LWIP_NETIF_API` typedef guard to `wifi_vendor_support.c`

**Files**: `src/bl808/wifi_vendor_support.c`

After the existing `#include <lwip/netifapi.h>` block, add:
```c
#ifndef LWIP_NETIF_API
#define LWIP_NETIF_API 0
#endif
#if !LWIP_NETIF_API
typedef void  (*netifapi_void_fn)(struct netif *netif);
typedef err_t (*netifapi_errt_fn)(struct netif *netif);
#endif
```

**Build verification**: same command — succeeds. Today `LWIP_NETIF_API=1` (SDK lwipopts), so the `#if !LWIP_NETIF_API` block is skipped and this commit is a no-op semantically. Once Commit 3 lands and vendor headers win the include race (with `LWIP_NETIF_API=0`), this guard kicks in and provides the typedefs.

**Commit message**: `wifi_vendor_support: LWIP_NETIF_API typedef guard (Iter 2.A.0 step 2/4)`

---

### Commit 3 — Wire vendor lwIP into wifi-vendor builds

**Files**: `src/bl808/wifi.nim`, `src/bl808/wifi_vendor_support.c`

This is the load-bearing commit. Two coordinated changes:

**3a) `src/bl808/wifi.nim`** — add immediately after `import mmio, memmap`:
```nim
when defined(bl808m0) and defined(bl808WifiVendor):
  import bl808/kernel/lwipcore
```

**3b) `src/bl808/wifi_vendor_support.c`** — delete the bodies of these 15 stub functions (vendor lwIP provides them, multi-def collision):
- `netif_set_default`, `netif_set_up`, `netif_set_link_up`, `netif_set_link_down`, `netif_set_status_callback`
- `etharp_output`
- `pbuf_alloc`, `pbuf_alloced_custom`, `pbuf_take`, `pbuf_free`, `pbuf_ref`, `pbuf_cat`, `pbuf_header`
- `ipaddr_addr`, `ip4addr_ntoa`

KEEP `inet_addr` (vendor doesn't have it).

ADD two new tiny stubs that vendor's `netifapi.c` would normally provide (gated behind `LWIP_NETIF_API=1` which we don't enable):
```c
err_t netifapi_netif_set_link_up(struct netif *netif) {
    netif_set_link_up(netif);
    return ERR_OK;
}
err_t netifapi_netif_set_link_down(struct netif *netif) {
    netif_set_link_down(netif);
    return ERR_OK;
}
```

**Build verification**: same command — succeeds. Vendor lwIP `.c` files compile (lwipcore brings them in), `_ctype_` resolves (Commit 1), typedefs resolve (Commit 2), no multi-def (stubs deleted), `netifapi_netif_set_link_*` resolve (new stubs).

If anything else surfaces as undefined, **STOP**. Don't add more stubs blindly. Surface the failure with the link error tail to the user.

**Commit message**: `wifi: link vendor lwIP for wifi-vendor builds (Iter 2.A.0 step 3/4)`

---

### Commit 4 — Replace 3 bridge bodies with real lwIP delegations

**Files**: `src/bl808/wifi_vendor_support.c`

Three bridge function bodies get real implementations:

**`netifapi_netif_add`** — was a stub that just set state/input fields without joining lwIP's netif chain. Replace body with:
```c
err_t netifapi_netif_add(struct netif *netif, const ip4_addr_t *ipaddr,
                         const ip4_addr_t *netmask, const ip4_addr_t *gw,
                         void *state, netif_init_fn init,
                         netif_input_fn input)
{
    return netif_add(netif, ipaddr, netmask, gw, state, init, input)
        ? ERR_OK : ERR_IF;
}
```

**`tcpip_input`** — was a stub that pbuf_free'd everything. Replace with:
```c
err_t tcpip_input(struct pbuf *p, struct netif *inp)
{
    return ethernet_input(p, inp);  /* NO_SYS=1, no tcpip thread */
}
```

**`wifi_netif_dhcp_start`** — was `return 0`. Replace with:
```c
int wifi_netif_dhcp_start(struct netif *netif)
{
    return netif ? (int)dhcp_start(netif) : -1;
}
```
Add `#include <lwip/dhcp.h>` near top of file if not already present.

**Build verification**: same command — succeeds. New behavior: `wifi_mgmr_sta_dhcp_enable()` (which calls `wifi_netif_dhcp_start`) would now actually start DHCP. Nothing in `m0_wifi_hal_test` exercises DHCP, so observable behavior is unchanged. The substrate is now active.

**Commit message**: `wifi_vendor_support: activate lwIP bridges (Iter 2.A.0 step 4/4)`

---

## 3. File and module layout

### Modified files

```
src/bl808/kernel/baremetal_libc.c
  ~ +260 lines (the _ctype_ table is conventionally 257 entries, plus the
    bit flag constants if not already imported from a header). Standalone
    newlib-format table.

src/bl808/wifi_vendor_support.c
  ~ +12 lines (LWIP_NETIF_API typedef guard, in Commit 2)
  ~ -150 lines (stub body deletions in Commit 3)
  ~ +8 lines (new netifapi_netif_set_link_up/down stubs in Commit 3)
  ~ +6 lines (3 bridge body replacements in Commit 4)
  ~ +1 line (#include <lwip/dhcp.h> in Commit 4 if not already there)
  Net: ~-130 lines

src/bl808/wifi.nim
  ~ +8 lines (conditional `import bl808/kernel/lwipcore` block in Commit 3)
```

### New files

(none)

### Files NOT touched

- `src/bl808/kernel/lwipcore.nim` — no changes; we use it as-is
- `src/bl808/kernel/sys_arch.c` — no changes
- `src/bl808/wifi_main.nim`, `wifi_support.nim`, `wifi_driver.nim` etc. — no changes (`wifiTx` in wifi_driver.nim already provides the linkoutput per investigation finding #3 in the original spec)
- `examples/m0_wifi_hal_test.nim` and other test binaries — no changes
- `tools/hardware_validation.json` — no changes
- Phase enum / e2e infrastructure — no changes (the Phase.ICMP commit `cf8099e` is preserved in history but not extended here)

### Conventions

- Each commit's diff scope is **only** the files listed for that commit. No incidental changes.
- Build verification command is fixed: `make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=6509171272 -d:WifiScanOnly=true' 2>&1 | tail -5`. Output must end with `Output: build/m0_firmware.bin`.
- If any commit's verification fails, STOP and surface to the user. Do not paper over with more stubs.
- Commit messages exact: the strings in Section 2.

### What does NOT change in observable behavior

- `m0_wifi_hal_test` still scans, auths, 4-way-handshakes, and associates the same way.
- The test binary doesn't call DHCP, so observable WiFi runtime behavior is identical pre- and post-iteration.
- The build artifact size will GROW (vendor lwIP adds compiled code to the binary). That's expected.

### What CHANGES in behavior (substrate-level)

- `netifapi_netif_add()` now actually registers the netif with vendor lwIP. The blob's `bl606a0_wifi_netif_init` now finds a working netif chain.
- `tcpip_input()` now actually delivers packets to lwIP's input chain via `ethernet_input`. The blob's RX delivery (via `tcpip_stack_input` in `bl_utils.c`, which eventually calls `netif->input`) now reaches lwIP for processing.
- `wifi_netif_dhcp_start()` now actually starts DHCP. Currently nothing calls it in the build, so this is dormant until a future smoke test wires it.

---

## 4. Order of operations and risks

### Strict sequence

```
START at HEAD = 5c02184 (the recovery checkpoint, build verified working)

1. Apply Commit 1 (_ctype_ table)
   → Build verify → "Output: build/m0_firmware.bin"
   → If pass: commit. If fail: revert the file edit (no commit), surface.

2. Apply Commit 2 (LWIP_NETIF_API typedef guard)
   → Build verify → success
   → If pass: commit. If fail: revert + surface.

3. Apply Commit 3 (lwipcore import + delete 15 stubs + add 2 link stubs)
   → Build verify → success
   → If pass: commit. If fail: revert + surface (this is the high-risk one;
     surface with the link error list, do NOT add more stubs blindly).

4. Apply Commit 4 (3 bridge body replacements)
   → Build verify → success
   → If pass: commit. Iteration done.
```

After each commit, `git status --short | grep '^ M'` must show 0 unstaged-modified files.

### Risks

- **Commit 1**: minimal. Worst case is a typo in the `_ctype_` table — but it's currently unreferenced, so a typo wouldn't fail the build now. Could fail at LINK time in Commit 3. Mitigation: take the definition verbatim from a known source.

- **Commit 2**: minimal. The typedef guard is gated by `#if !LWIP_NETIF_API`, today evaluating false (SDK header sets `LWIP_NETIF_API=1`), so the guarded block is dead. Activates only after Commit 3 changes the include order.

- **Commit 3**: highest risk. The empirical link-error list from earlier showed: ✓ multi-def for vendor-provided symbols (fixed by deletions), ✓ `_ctype_` undefined (fixed by Commit 1), ✓ `netifapi_netif_set_link_*` undefined (fixed by new stubs in Commit 3 itself). If MORE undefined symbols surface that we didn't anticipate, that's a real surprise — the response is to STOP, not to keep adding stubs. Possible new surprises: more libc symbols beyond `_ctype_`; sys_arch dependencies the kernel `sys_arch.c` doesn't provide; packed/aligned attribute differences in struct passing.

- **Commit 4**: low risk if Commits 1-3 succeed. Bridge bodies just delegate to vendor lwIP functions. Nothing in `m0_wifi_hal_test` exercises these code paths, so even if a body is logically wrong, the build succeeds and the runtime regression is invisible until a future smoke test.

### What gets reverted on failure

If any commit fails its build verification:
- The working-tree edits for that commit get discarded via `git checkout HEAD -- <files>`
- **No `git reset --hard`, no destructive commands** — never again
- Surface the failure to the user with the build error tail
- Wait for direction

### State at the end of the iteration

```
HEAD = (4 new commits on top of 5c02184)
9755439                                                  (HAL state before blob reimplementation)
b4ee601                                                  (Iter 1 squash)
... (Iter 2.A spec, Iter 2.A.0 spec + investigation, Phase.ICMP, T3 (now reversed), recovery checkpoint)
5c02184  Restore pre-loss working tree from APFS snapshots after git reset --hard mishap
+ 1: baremetal_libc: add _ctype_ table for vendor lwIP ip4_addr.c (Iter 2.A.0 step 1/4)
+ 2: wifi_vendor_support: LWIP_NETIF_API typedef guard (Iter 2.A.0 step 2/4)
+ 3: wifi: link vendor lwIP for wifi-vendor builds (Iter 2.A.0 step 3/4)
+ 4: wifi_vendor_support: activate lwIP bridges (Iter 2.A.0 step 4/4)
```

`m0_wifi_hal_test` still works on hardware (regression-safe). The substrate is now correctly bridged to vendor lwIP. A follow-up iteration writing a DHCP smoke test will actually exercise it.

### Stop conditions for the iteration

Each commit succeeds with a clean build. No failed commit → no broken HEAD → never need a recovery cycle. If commit 3 surfaces unanticipated link errors, STOP and revisit the design.
