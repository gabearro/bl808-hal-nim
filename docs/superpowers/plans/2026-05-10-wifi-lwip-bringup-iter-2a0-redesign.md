# WiFi lwIP Bring-up — Iter 2.A.0 Re-design Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bridge the WiFi blob's lwIP stubs to vendor lwIP, in 4 incremental commits, each with mandatory build verification. After this plan's last task, `make m0 FILE=examples/m0_wifi_hal_test.nim ...` builds with vendor lwIP linked in and `wifi_vendor_support.c`'s 3 bridge functions actually delegate to vendor lwIP.

**Architecture:** Layered bring-up. Commit 1 lands the `_ctype_` symbol vendor lwIP needs. Commit 2 lands a typedef guard. Commit 3 deletes 15 colliding stubs and pulls vendor lwIP into the link. Commit 4 activates 3 bridge bodies. Each commit is independently buildable and revertable.

**Tech Stack:** Nim 2.2.6 on M0 RV32 (`-d:bl808m0 -d:bl808kernel -d:bl808WifiVendor`), vendor lwIP from `vendor/lwip/` integrated via `src/bl808/kernel/lwipcore.nim`, C stubs/bridges in `src/bl808/wifi_vendor_support.c`, freestanding bare-metal libc in `src/bl808/kernel/baremetal_libc.c`.

**Files this plan touches:**
- `src/bl808/kernel/baremetal_libc.c` — append `_ctype_` table (Task 1)
- `src/bl808/wifi_vendor_support.c` — typedef guard (Task 2), stub deletions + new netifapi link stubs (Task 3), bridge body replacements (Task 4)
- `src/bl808/wifi.nim` — conditional `import bl808/kernel/lwipcore` in vendor block (Task 3)

**Working directory invariant:** Run all commands from `/Users/gabriel/Documents/nimlang/bl808-hal`. Branch is `master`, HEAD must be `5c02184` or later. The repo has many untracked files (your in-progress work + the .recover_from_snapshot.sh script); leave them alone. Every `git add` lists exact paths; never `git add .` or `git add -A`.

**The build verification command (used after every task):**
```bash
make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password> -d:WifiScanOnly=true' 2>&1 | tail -5
```
Expected output ends with: `Output: build/m0_firmware.bin`

**On failure**: discard the working-tree edits with `git checkout HEAD -- <files>` (NEVER `git reset --hard`), then STOP and surface the failure to the controller with the build error tail. Do NOT add more stubs blindly.

---

### Task 1: Add `_ctype_` table to `baremetal_libc.c` (Commit 1)

**Files:**
- Modify: `src/bl808/kernel/baremetal_libc.c` (append at end)

Vendor lwIP's `vendor/lwip/src/core/ipv4/ip4_addr.c` calls `isdigit()` from `<ctype.h>`. The newlib `<ctype.h>` macros expand to `(_ctype_+1)[c] & _N`. We're freestanding (no libc), so `_ctype_` must be provided. Standard ASCII-only table is fine (Bouffalo SDK doesn't enable extended-ASCII variants).

- [ ] **Step 1: Verify the symbol is currently absent**

```bash
cd /Users/gabriel/Documents/nimlang/bl808-hal
grep -n '_ctype_' src/bl808/kernel/baremetal_libc.c
```

Expected: no output (symbol not yet defined).

- [ ] **Step 2: Append the `_ctype_` table to `baremetal_libc.c`**

Read `src/bl808/kernel/baremetal_libc.c` first to confirm current end-of-file shape (last lines are the `abort()` definition). Then append exactly this block:

```c

/* ============================================================================
 * _ctype_ table — newlib-format character-classification table.
 *
 * Vendor lwIP's vendor/lwip/src/core/ipv4/ip4_addr.c uses <ctype.h> macros
 * (isdigit, isalpha, etc.) which expand to lookups against this table. We
 * build freestanding (-nostdlib), so newlib's libc.a is not in the link;
 * supply a minimal ASCII-only table that satisfies those references.
 *
 * The table has 257 entries: index 0 is the value for EOF (-1+1=0); indices
 * 1..256 correspond to characters 0..255. Bit flags per newlib convention:
 *   _U=01 upper, _L=02 lower, _N=04 numeric, _S=010 whitespace,
 *   _P=020 punct, _C=040 control, _X=0100 hex, _B=0200 blank.
 * ========================================================================== */

#define _U 01
#define _L 02
#define _N 04
#define _S 010
#define _P 020
#define _C 040
#define _X 0100
#define _B 0200

const char _ctype_[1 + 256] = {
    0,
    _C,     _C,     _C,     _C,     _C,     _C,     _C,     _C,
    _C,     _C|_S,  _C|_S,  _C|_S,  _C|_S,  _C|_S,  _C,     _C,
    _C,     _C,     _C,     _C,     _C,     _C,     _C,     _C,
    _C,     _C,     _C,     _C,     _C,     _C,     _C,     _C,
    _S|_B,  _P,     _P,     _P,     _P,     _P,     _P,     _P,
    _P,     _P,     _P,     _P,     _P,     _P,     _P,     _P,
    _N,     _N,     _N,     _N,     _N,     _N,     _N,     _N,
    _N,     _N,     _P,     _P,     _P,     _P,     _P,     _P,
    _P,     _U|_X,  _U|_X,  _U|_X,  _U|_X,  _U|_X,  _U|_X,  _U,
    _U,     _U,     _U,     _U,     _U,     _U,     _U,     _U,
    _U,     _U,     _U,     _U,     _U,     _U,     _U,     _U,
    _U,     _U,     _U,     _P,     _P,     _P,     _P,     _P,
    _P,     _L|_X,  _L|_X,  _L|_X,  _L|_X,  _L|_X,  _L|_X,  _L,
    _L,     _L,     _L,     _L,     _L,     _L,     _L,     _L,
    _L,     _L,     _L,     _L,     _L,     _L,     _L,     _L,
    _L,     _L,     _L,     _P,     _P,     _P,     _P,     _C,
    /* 128..255 — non-ASCII; left zero-classified */
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
};
```

- [ ] **Step 3: Build verification**

```bash
make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password> -d:WifiScanOnly=true' 2>&1 | tail -5
```

Expected: ends with `Output: build/m0_firmware.bin`. The new symbol is currently unreferenced (vendor lwIP not yet in link), so this is a pure-addition commit.

If the build fails (extremely unlikely — the only thing this commit does is add a `const char` array), discard with `git checkout HEAD -- src/bl808/kernel/baremetal_libc.c` and surface.

- [ ] **Step 4: Commit**

```bash
git add src/bl808/kernel/baremetal_libc.c
git commit -m "baremetal_libc: add _ctype_ table for vendor lwIP ip4_addr.c (Iter 2.A.0 step 1/4)"
```

- [ ] **Step 5: Verify clean state**

```bash
git status --short | grep '^ M' | wc -l | tr -d ' '
```

Expected: `0` (no modified-but-unstaged files).

---

### Task 2: Add `LWIP_NETIF_API` typedef guard to `wifi_vendor_support.c` (Commit 2)

**Files:**
- Modify: `src/bl808/wifi_vendor_support.c` (insert in the `#include` block region, after `#include <lwip/tcpip.h>`)

After Task 3 lands, vendor lwIP's `-I` will come first in the C compile (because `lwipcore.nim`'s passC fires first), so vendor headers win the include race. Vendor `lwip/opt.h` leaves `LWIP_NETIF_API` undefined → vendor `netifapi.h` does not declare `netifapi_void_fn` / `netifapi_errt_fn`. But `wifi_vendor_support.c` uses these typedefs in its `netifapi_netif_common` signature. This guard provides them locally when missing.

- [ ] **Step 1: Read the existing include block**

Read `src/bl808/wifi_vendor_support.c` lines 1-30 to confirm the include structure. The last lwIP include before the SDK includes is `#include <lwip/tcpip.h>` at line 22.

- [ ] **Step 2: Insert the typedef guard after the lwIP includes**

Apply this exact edit (the implementer must use Read first since Edit requires it):

Find the existing block:
```c
#include <lwip/etharp.h>
#include <lwip/ip4_addr.h>
#include <lwip/netif.h>
#include <lwip/netifapi.h>
#include <lwip/pbuf.h>
#include <lwip/tcpip.h>

#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_main.h"
```

Replace it with:
```c
#include <lwip/etharp.h>
#include <lwip/ip4_addr.h>
#include <lwip/netif.h>
#include <lwip/netifapi.h>
#include <lwip/pbuf.h>
#include <lwip/tcpip.h>

/* Iter 2.A.0 step 2: vendor lwIP's lwipopts.h leaves LWIP_NETIF_API
 * undefined, so vendor netifapi.h does not declare these typedefs. SDK lwIP
 * defines them. When vendor headers win the include race (Task 3 onward),
 * declare them locally so this file's netifapi_netif_common signature
 * compiles. Today (SDK headers active) this block is dead code. */
#ifndef LWIP_NETIF_API
#define LWIP_NETIF_API 0
#endif
#if !LWIP_NETIF_API
typedef void  (*netifapi_void_fn)(struct netif *netif);
typedef err_t (*netifapi_errt_fn)(struct netif *netif);
#endif

#include "../../build/bl_iot_sdk_b773b3f/components/network/wifi_manager/bl60x_wifi_driver/bl_main.h"
```

- [ ] **Step 3: Build verification**

```bash
make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password> -d:WifiScanOnly=true' 2>&1 | tail -5
```

Expected: ends with `Output: build/m0_firmware.bin`. The guard's `#if !LWIP_NETIF_API` evaluates false today (SDK header sets `LWIP_NETIF_API=1`), so the typedef block is dead code in this commit — pure-addition behavior.

If the build fails (would mean a syntax error in the guard), discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c` and surface.

- [ ] **Step 4: Commit**

```bash
git add src/bl808/wifi_vendor_support.c
git commit -m "wifi_vendor_support: LWIP_NETIF_API typedef guard (Iter 2.A.0 step 2/4)"
```

- [ ] **Step 5: Verify clean state**

```bash
git status --short | grep '^ M' | wc -l | tr -d ' '
```

Expected: `0`.

---

### Task 3: Wire vendor lwIP into wifi-vendor builds (Commit 3)

**Files:**
- Modify: `src/bl808/wifi.nim` (insert conditional import after `import mmio, memmap`)
- Modify: `src/bl808/wifi_vendor_support.c` (delete 15 stub function bodies, add 2 new netifapi link stubs)

The big load-bearing commit. Three coordinated changes happen atomically; the build is verified after all three are in place.

**3a: Add the lwipcore import to wifi.nim**

- [ ] **Step 1: Read wifi.nim lines 17-22**

Read `src/bl808/wifi.nim` lines 17-22 to confirm the structure. Expected: `import mmio, memmap` at line 18, blank line 19, `when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):` at line 20.

- [ ] **Step 2: Apply the wifi.nim edit**

Find:
```nim
import mmio, memmap

when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):
  import wifi_fw
```

Replace with:
```nim
import mmio, memmap

# Iter 2.A.0 step 3: vendor lwIP source compilation. Required because
# wifi_vendor_support.c's lwIP-side bridges (netifapi_netif_add -> netif_add,
# tcpip_input -> ethernet_input, wifi_netif_dhcp_start -> dhcp_start) call
# vendor lwIP functions that otherwise wouldn't be in the link.
when defined(bl808m0) and defined(bl808WifiVendor):
  import bl808/kernel/lwipcore

when defined(bl808m0) and defined(bl808WifiVendor) and defined(bl808WifiNimFw):
  import wifi_fw
```

**3b: Delete 15 colliding stubs in wifi_vendor_support.c + add 2 new netifapi link stubs**

The 15 stubs to delete (vendor lwIP provides them; multi-def collision otherwise): `netif_set_default`, `netif_set_up`, `netif_set_link_up`, `netif_set_link_down`, `netif_set_status_callback`, `etharp_output`, `pbuf_alloc`, `pbuf_alloced_custom`, `pbuf_take`, `pbuf_free`, `pbuf_ref`, `pbuf_cat`, `pbuf_header`, `ipaddr_addr`, `ip4addr_ntoa`.

KEEP: `inet_addr` (vendor doesn't have it — libc-compat).
KEEP: `tcpip_input`, `wifi_netif_dhcp_start`, `netifapi_netif_add` (these are bridge bodies, modified in Task 4).
KEEP: `netifapi_netif_set_default`, `netifapi_netif_set_up`, `netifapi_netif_common`, `netifapi_netif_set_addr` (these wrap netif_set_* and aren't provided by vendor without LWIP_NETIF_API=1).

- [ ] **Step 3: Apply the deletion edits**

Read `src/bl808/wifi_vendor_support.c` lines 2025-2200 to confirm current state. Then perform each Edit one at a time. The implementer can use `Edit` (one Edit per stub) or read the entire range and use a multi-line replace.

For each of the following functions, find the function definition in the file and DELETE the entire definition (from the function header through the closing brace, inclusive of any preceding blank line that's part of the function's "block"):

```c
/* DELETE the body of this function entirely */
void netif_set_default(struct netif *netif)
{
    (void)netif;
}
```

```c
/* DELETE */
void netif_set_up(struct netif *netif)
{
    if (netif) {
        netif->flags |= NETIF_FLAG_UP;
    }
}
```

```c
/* DELETE */
void netif_set_link_up(struct netif *netif)
{
    if (netif) {
        netif->flags |= NETIF_FLAG_LINK_UP;
    }
}
```

```c
/* DELETE */
void netif_set_link_down(struct netif *netif)
{
    if (netif) {
        netif->flags &= (uint8_t)~NETIF_FLAG_LINK_UP;
    }
}
```

```c
/* DELETE */
void netif_set_status_callback(struct netif *netif, netif_status_callback_fn status_callback)
{
    if (netif) {
        netif->status_callback = status_callback;
    }
}
```

```c
/* DELETE */
err_t etharp_output(struct netif *netif, struct pbuf *q, const ip4_addr_t *ipaddr)
{
    (void)netif;
    (void)q;
    (void)ipaddr;
    return 0;
}
```

```c
/* DELETE */
uint32_t ipaddr_addr(const char *cp)
{
    (void)cp;
    return 0;
}
```

```c
/* DELETE */
char *ip4addr_ntoa(const ip4_addr_t *addr)
{
    (void)addr;
    return "0.0.0.0";
}
```

```c
/* DELETE */
struct pbuf *pbuf_alloc(pbuf_layer layer, u16_t length, pbuf_type type)
{
    struct pbuf *p;
    (void)layer;
    (void)type;
    p = calloc(1, sizeof(struct pbuf) + length);
    if (!p) {
        return NULL;
    }
    p->payload = (uint8_t *)p + sizeof(struct pbuf);
    p->len = length;
    p->tot_len = length;
    p->ref = 1;
    return p;
}
```

```c
/* DELETE */
struct pbuf *pbuf_alloced_custom(pbuf_layer layer, u16_t length,
                                 pbuf_type type, struct pbuf_custom *p,
                                 void *payload_mem, u16_t payload_mem_len)
{
    (void)layer;
    (void)type;
    (void)payload_mem_len;
    memset(&p->pbuf, 0, sizeof(p->pbuf));
    p->pbuf.payload = payload_mem;
    p->pbuf.len = length;
    p->pbuf.tot_len = length;
    p->pbuf.ref = 1;
    return &p->pbuf;
}
```

```c
/* DELETE */
u8_t pbuf_free(struct pbuf *p)
{
    while (p) {
        struct pbuf *next = p->next;
        if (p->flags & PBUF_FLAG_IS_CUSTOM) {
            struct pbuf_custom *custom = (struct pbuf_custom *)p;
            if (custom->custom_free_function) {
                custom->custom_free_function(p);
            }
        } else {
            free(p);
        }
        p = next;
    }
    return 1;
}
```

```c
/* DELETE */
void pbuf_ref(struct pbuf *p)
{
    if (p) {
        p->ref++;
    }
}
```

```c
/* DELETE */
err_t pbuf_take(struct pbuf *buf, const void *dataptr, u16_t len)
{
    if (!buf || !buf->payload || len > buf->len) {
        return -1;
    }
    memcpy(buf->payload, dataptr, len);
    return 0;
}
```

```c
/* DELETE */
void pbuf_cat(struct pbuf *head, struct pbuf *tail)
{
    struct pbuf *p = head;
    if (!p) {
        return;
    }
    while (p->next) {
        p = p->next;
    }
    p->next = tail;
    if (tail) {
        head->tot_len += tail->tot_len;
    }
}
```

```c
/* DELETE */
u8_t pbuf_header(struct pbuf *p, s16_t header_size_increment)
{
    if (!p) {
        return 1;
    }
    p->payload = (uint8_t *)p->payload - header_size_increment;
    p->len = (u16_t)(p->len + header_size_increment);
    p->tot_len = (u16_t)(p->tot_len + header_size_increment);
    return 0;
}
```

After deletions, two notable function definitions remain in that region: `tcpip_input` (a bridge — body modified in Task 4) and `inet_addr` (kept; vendor doesn't have it).

- [ ] **Step 4: Add the 2 new netifapi link stubs**

Find the existing `netifapi_netif_set_up` function (around line 2022 area) — that's a stub that wraps `netif_set_up`. Right AFTER it, insert two new stubs that wrap the link-up/down counterparts (vendor's `netifapi.c` would normally provide these but isn't compiled because `LWIP_NETIF_API=0` in vendor lwipopts):

Find:
```c
void netifapi_netif_set_up(struct netif *netif)
{
    netif_set_up(netif);
}
```

Replace with:
```c
void netifapi_netif_set_up(struct netif *netif)
{
    netif_set_up(netif);
}

/* Iter 2.A.0 step 3: vendor netifapi.c is gated behind LWIP_NETIF_API=1
 * which we don't enable. SDK files (bl_rx.c) call these. Provide thin
 * stubs that delegate to vendor lwIP's netif_set_link_up/down. */
err_t netifapi_netif_set_link_up(struct netif *netif)
{
    netif_set_link_up(netif);
    return ERR_OK;
}

err_t netifapi_netif_set_link_down(struct netif *netif)
{
    netif_set_link_down(netif);
    return ERR_OK;
}
```

- [ ] **Step 5: Build verification**

```bash
make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password> -d:WifiScanOnly=true' 2>&1 | tail -10
```

Expected: ends with `Output: build/m0_firmware.bin`. Vendor lwIP `.c` files compile (lwipcore brings them in), `_ctype_` resolves (Task 1), typedefs resolve (Task 2), no multi-def (15 stubs deleted), `netifapi_netif_set_link_*` resolve (2 new stubs).

**If the build fails with new undefined symbols beyond what the spec anticipated, STOP**:
- discard all edits: `git checkout HEAD -- src/bl808/wifi.nim src/bl808/wifi_vendor_support.c`
- surface the failure with the link-error tail to the controller
- DO NOT add more stubs blindly

If a deletion missed a stub (multi-def errors persist), re-check that all 15 listed functions were actually deleted and re-build.

- [ ] **Step 6: Commit**

```bash
git add src/bl808/wifi.nim src/bl808/wifi_vendor_support.c
git commit -m "wifi: link vendor lwIP for wifi-vendor builds (Iter 2.A.0 step 3/4)"
```

- [ ] **Step 7: Verify clean state**

```bash
git status --short | grep '^ M' | wc -l | tr -d ' '
```

Expected: `0`.

---

### Task 4: Activate the 3 lwIP bridges (Commit 4)

**Files:**
- Modify: `src/bl808/wifi_vendor_support.c` (replace 3 bridge bodies; possibly add `#include <lwip/dhcp.h>`)

Three bridge function bodies get real implementations. After this commit, the WiFi blob's lwIP-side calls actually do something useful (substrate-level change; no observable behavior change in `m0_wifi_hal_test` since it doesn't exercise these code paths).

- [ ] **Step 1: Verify `<lwip/dhcp.h>` is included; add if not**

```bash
grep -n '#include <lwip/dhcp.h>' src/bl808/wifi_vendor_support.c
```

If no output, add `#include <lwip/dhcp.h>` to the include block. The cleanest insertion point is right after `#include <lwip/tcpip.h>` (line ~22), BEFORE the `LWIP_NETIF_API` guard added in Task 2.

If you need to add it, find:
```c
#include <lwip/tcpip.h>

/* Iter 2.A.0 step 2: vendor lwIP's lwipopts.h leaves LWIP_NETIF_API
```

Replace with:
```c
#include <lwip/tcpip.h>
#include <lwip/dhcp.h>

/* Iter 2.A.0 step 2: vendor lwIP's lwipopts.h leaves LWIP_NETIF_API
```

- [ ] **Step 2: Replace `netifapi_netif_add` body**

Find the current `netifapi_netif_add` definition (around line 1977). It currently looks like:

```c
err_t netifapi_netif_add(struct netif *netif, const ip4_addr_t *ipaddr,
                         const ip4_addr_t *netmask, const ip4_addr_t *gw,
                         void *state, netif_init_fn init,
                         netif_input_fn input)
{
    (void)ipaddr;
    (void)netmask;
    (void)gw;
    netif->state = state;
    netif->input = input;
    return init ? init(netif) : 0;
}
```

Replace with:

```c
err_t netifapi_netif_add(struct netif *netif, const ip4_addr_t *ipaddr,
                         const ip4_addr_t *netmask, const ip4_addr_t *gw,
                         void *state, netif_init_fn init,
                         netif_input_fn input)
{
    /* Iter 2.A.0 step 4: real bridge to vendor lwIP. Joins the netif chain
     * so dhcp_start, etharp_output, etc. find the netif. The previous stub
     * set state/input but never registered with lwIP. */
    return netif_add(netif, ipaddr, netmask, gw, state, init, input)
        ? ERR_OK : ERR_IF;
}
```

- [ ] **Step 3: Replace `tcpip_input` body**

Find the current `tcpip_input` definition (around line 2060). It currently looks like:

```c
err_t tcpip_input(struct pbuf *p, struct netif *inp)
{
    (void)inp;
    pbuf_free(p);
    return 0;
}
```

Replace with:

```c
err_t tcpip_input(struct pbuf *p, struct netif *inp)
{
    /* Iter 2.A.0 step 4: NO_SYS=1, no tcpip thread. Deliver directly to
     * lwIP's Ethernet input. The blob passes tcpip_input as the input arg
     * to netif_add, so calling inp->input(p, inp) here would loop. */
    return ethernet_input(p, inp);
}
```

- [ ] **Step 4: Replace `wifi_netif_dhcp_start` body**

Find the current `wifi_netif_dhcp_start` definition (around line 3104). It currently looks like:

```c
int wifi_netif_dhcp_start(struct netif *netif) { (void)netif; return 0; }
```

Replace with:

```c
int wifi_netif_dhcp_start(struct netif *netif)
{
    /* Iter 2.A.0 step 4: real bridge. Previous stub returned 0 without
     * doing anything, leaving the netif without DHCP. */
    if (netif == NULL) return -1;
    return (int)dhcp_start(netif);
}
```

- [ ] **Step 5: Build verification**

```bash
make m0 FILE=examples/m0_wifi_hal_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password> -d:WifiScanOnly=true' 2>&1 | tail -5
```

Expected: ends with `Output: build/m0_firmware.bin`. Bridges now delegate to vendor lwIP. Nothing in `m0_wifi_hal_test` exercises these paths, so observable runtime behavior is unchanged from the previous commit; the substrate is now active.

If the build fails (would mean a vendor lwIP function we delegate to is missing or has a different signature than expected), discard with `git checkout HEAD -- src/bl808/wifi_vendor_support.c` and surface.

- [ ] **Step 6: Commit**

```bash
git add src/bl808/wifi_vendor_support.c
git commit -m "wifi_vendor_support: activate lwIP bridges (Iter 2.A.0 step 4/4)"
```

- [ ] **Step 7: Verify clean state**

```bash
git status --short | grep '^ M' | wc -l | tr -d ' '
```

Expected: `0`.

---

## Self-review

**Spec coverage** (cross-reference against `docs/superpowers/specs/2026-05-10-wifi-lwip-bringup-iter-2a0-redesign.md`):
- ✅ Section 2 Commit 1 (`_ctype_` table) → Task 1
- ✅ Section 2 Commit 2 (LWIP_NETIF_API typedef guard) → Task 2
- ✅ Section 2 Commit 3 (lwipcore import + 15 stub deletions + 2 new netifapi stubs) → Task 3 (3a + 3b)
- ✅ Section 2 Commit 4 (3 bridge body replacements, including `#include <lwip/dhcp.h>`) → Task 4
- ✅ Section 4 stop-on-failure rule (`git checkout HEAD --`, NEVER `git reset --hard`) → repeated in every task's failure block

**Placeholder scan**: every step shows the actual code/command. `_ctype_` table is given verbatim (not "use a known source"). Stub deletions show each function's full body (so the implementer matches exactly). Bridge replacements show before/after.

**Type consistency**: `ERR_OK`, `ERR_IF`, `err_t`, `struct netif`, `struct pbuf`, `netif_init_fn`, `netif_input_fn`, `pbuf_layer`, `pbuf_type`, `u16_t`, `s16_t`, `u8_t`, `uint32_t` — all standard lwIP types used unchanged. `dhcp_start`, `netif_add`, `ethernet_input`, `netif_set_link_up`, `netif_set_link_down` — all vendor lwIP functions used unchanged from their canonical signatures.

**Known fragility**: Task 3 Step 5 explicitly handles the "more undefined symbols than expected" case with STOP rather than blind stub-adding. Task 1 Step 3 acknowledges build-fail is unlikely but provides recovery. Task 4 Step 5 acknowledges the vendor-signature-mismatch possibility.
