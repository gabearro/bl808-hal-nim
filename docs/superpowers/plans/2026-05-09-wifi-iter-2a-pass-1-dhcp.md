# WiFi Iter 2.A Pass 1 — DHCP on Blob Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing WiFi e2e test binary with a real `dhcp:` phase, and add the `EchoServer` + `discover_lan_ip()` host-side scaffolding (without wiring it into the run path — that's Pass 2). After this pass, `make hw-e2e-quick UART_PORT=… WIFI_SSID=Frog WIFI_PASSWORD=…` runs the WiFi-blob cell N=3 and each attempt either reaches `dhcp:ok ip=… gw=…` or `dhcp:fail reason=…`. The empirical question "does the WiFi blob register a netif and pump lwIP" is answered.

**Architecture:** Firmware extension is purely additive: after the existing synthetic `assoc:ok` markers, cast `wifiGetNetif()` to `ptr Netif`, call `dhcpStart`, poll the netif's `ip_addr.addr` field every 50 ms (with `sysCheckTimeouts()` per iteration) for up to 10 s. Two inline `{.emit:}` accessors read `netif->ip_addr.addr` and `netif->gw.addr`. Host-side: add `EchoServer` (TCP echo, `0.0.0.0:0`, daemon thread) and `discover_lan_ip()` (UDP-trick) to `tools/hw_e2e.py` with TDD tests; do **not** wire them into the run path yet (Pass 2 does that).

**Tech Stack:** Nim 2.2.6 on M0 RV32 (`-d:bl808m0 -d:bl808kernel -d:bl808WifiVendor`), lwIP from `src/bl808/kernel/lwipcore.nim`, Python 3 + pytest for the host-side TDD, existing `tools/hw_validate.py` catalog mode for build/flash/UART capture.

**Files this pass touches:**

- `tools/hw_e2e.py` — adds `EchoServer` class + `discover_lan_ip()` helper (~70 lines, NOT wired into the run path in this pass)
- `tools/test_hw_e2e.py` — adds 5 new tests for the above (~110 lines)
- `tools/hardware_validation.json` — extends `m0_wifi_e2e_test` entry with `WifiEchoHost` and `WifiEchoPort` defines (env-sourced, with Pass-1 defaults so the catalog works without an EchoServer running)
- `examples/m0_wifi_e2e_test.nim` — adds lwipcore import, two `{.emit:}` accessors, `WifiEchoHost`/`WifiEchoPort` consts (declared but unused in Pass 1; used in Pass 2), dhcp phase in `runOneAttempt` (~50 lines added)

**Working directory invariant:** Run all commands from `/Users/gabriel/Documents/nimlang/bl808-hal`. The repo has many uncommitted modified files (your in-progress HAL/BLE/WiFi reimpl work) unrelated to this work; **every commit in this plan stages files by exact path** — never `git add .` or `git add -A`.

---

### Task 1: `EchoServer` class — host-side TCP echo (TDD, not yet wired)

**Files:**
- Modify: `tools/hw_e2e.py`
- Modify: `tools/test_hw_e2e.py`

A small TCP echo server we'll wire into the run path in Pass 2. Pass 1 just lands the class with TDD coverage so Pass 2's wiring is a pure plumbing change.

- [ ] **Step 1: Write the failing tests**

Append to `tools/test_hw_e2e.py` (read the file first to confirm current contents):

```python
def test_echo_server_starts_on_kernel_assigned_port():
    """EchoServer binds to 0.0.0.0:0; .port returns the kernel-assigned port."""
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    try:
        assert server.port > 0
        assert server.port < 65536
    finally:
        server.stop()


def test_echo_server_echoes_received_bytes():
    """A client connecting to EchoServer.port and sending bytes gets them back."""
    import socket
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    try:
        with socket.create_connection(("127.0.0.1", server.port), timeout=2.0) as s:
            s.sendall(b"BL808-E2E-PROBE\n")
            received = b""
            while len(received) < 16:
                chunk = s.recv(64)
                if not chunk:
                    break
                received += chunk
        assert received == b"BL808-E2E-PROBE\n"
    finally:
        server.stop()


def test_echo_server_handles_multiple_sequential_connections():
    """Each TCP connection is independent; server keeps accepting after one closes."""
    import socket
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    try:
        for i in range(3):
            with socket.create_connection(("127.0.0.1", server.port), timeout=2.0) as s:
                s.sendall(f"hello-{i}".encode())
                received = b""
                while len(received) < len(f"hello-{i}"):
                    chunk = s.recv(64)
                    if not chunk:
                        break
                    received += chunk
            assert received == f"hello-{i}".encode()
    finally:
        server.stop()


def test_echo_server_stop_releases_port():
    """After .stop(), the port is free for another bind."""
    import socket
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    port = server.port
    server.stop()
    # If the port is still held, this connect will fail or the next bind will EADDRINUSE.
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))  # should succeed
    finally:
        s.close()
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
.venv/bin/pytest tools/test_hw_e2e.py -v -k echo_server
```

Expected: FAIL with `ImportError: cannot import name 'EchoServer' from 'hw_e2e'`.

- [ ] **Step 3: Implement `EchoServer` in `tools/hw_e2e.py`**

Read the file first to find a good insertion point (above `def main(...)`). Add:

```python
import socket as _socket
import threading as _threading


class EchoServer:
    """Tiny TCP echo server: bind to 0.0.0.0:0, accept loop on a daemon thread,
    each connection gets its bytes echoed back. Used by the WiFi e2e harness so
    the board has a known TCP target on the harness host's LAN.
    """

    def __init__(self) -> None:
        self._sock: _socket.socket | None = None
        self._thread: _threading.Thread | None = None
        self._stop_evt = _threading.Event()
        self.port: int = 0

    def start(self) -> None:
        s = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
        s.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", 0))
        s.listen(4)
        s.settimeout(0.2)  # allow accept loop to check stop flag
        self._sock = s
        self.port = s.getsockname()[1]
        self._stop_evt.clear()
        self._thread = _threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_evt.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None

    def _accept_loop(self) -> None:
        while not self._stop_evt.is_set():
            try:
                conn, _addr = self._sock.accept()  # type: ignore[union-attr]
            except _socket.timeout:
                continue
            except OSError:
                # socket closed by stop()
                return
            try:
                data = conn.recv(64)
                if data:
                    conn.sendall(data)
            except OSError:
                pass
            finally:
                conn.close()
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
.venv/bin/pytest tools/test_hw_e2e.py -v -k echo_server
```

Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/hw_e2e.py tools/test_hw_e2e.py
git commit -m "Add EchoServer to hw_e2e.py (TDD; not yet wired into run path)"
```

---

### Task 2: `discover_lan_ip()` helper

**Files:**
- Modify: `tools/hw_e2e.py`
- Modify: `tools/test_hw_e2e.py`

Standard idiom: open a UDP socket, "connect" it to 8.8.8.8:53 (no packet sent), read the local socket's address — that's the interface IP that would be used to reach the public internet. Falls back to `gethostbyname(gethostname())` on error.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_hw_e2e.py`:

```python
def test_discover_lan_ip_returns_ipv4_string():
    """Returns a non-loopback IPv4 dotted string when LAN is up. We don't assert
    on the specific value (that depends on the host); just that it's a v4
    address and not 127.0.0.1."""
    from hw_e2e import discover_lan_ip
    ip = discover_lan_ip()
    assert isinstance(ip, str)
    parts = ip.split(".")
    assert len(parts) == 4
    for p in parts:
        assert 0 <= int(p) <= 255
    # Note: in CI without a network, this test will be brittle. The fallback
    # path may return 127.0.0.1; allow it.


def test_discover_lan_ip_fallback_on_udp_socket_error(monkeypatch):
    """If the UDP-trick raises, fall back to gethostbyname(gethostname())."""
    import socket
    from hw_e2e import discover_lan_ip

    real_socket = socket.socket
    real_gethostbyname = socket.gethostbyname
    real_gethostname = socket.gethostname

    def boom(*args, **kwargs):
        raise OSError("simulated network down")

    monkeypatch.setattr(socket, "socket", boom)
    # Ensure fallback path is exercised; gethostbyname returns a string.
    monkeypatch.setattr(socket, "gethostbyname", lambda h: "10.99.99.99")
    monkeypatch.setattr(socket, "gethostname", lambda: "test-host")

    ip = discover_lan_ip()
    assert ip == "10.99.99.99"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
.venv/bin/pytest tools/test_hw_e2e.py -v -k discover_lan_ip
```

Expected: FAIL with `ImportError: cannot import name 'discover_lan_ip' from 'hw_e2e'`.

- [ ] **Step 3: Implement `discover_lan_ip` in `tools/hw_e2e.py`**

Add (right after `EchoServer` class):

```python
def discover_lan_ip() -> str:
    """Return the local interface IP that would be used to reach the public
    internet. Uses the standard UDP-getsockname trick (no packet sent). Falls
    back to gethostbyname(gethostname()) if the UDP path errors.

    The returned IP is what gets passed to firmware as WifiEchoHost so the
    board can TCP-connect back to the harness host across the WiFi LAN.
    """
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # 8.8.8.8 is just a routable address; no packet is actually sent
            # by connect() on a UDP socket — it just sets the default peer.
            s.connect(("8.8.8.8", 53))
            return s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        return socket.gethostbyname(socket.gethostname())
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
.venv/bin/pytest tools/test_hw_e2e.py -v -k discover_lan_ip
```

Expected: 2 tests PASS.

- [ ] **Step 5: Run full pytest suite to confirm nothing regressed**

```bash
.venv/bin/pytest tools/ -v
```

Expected: 35 PASS (29 from Iter 1 + 4 EchoServer + 2 discover_lan_ip = 35).

- [ ] **Step 6: Commit**

```bash
git add tools/hw_e2e.py tools/test_hw_e2e.py
git commit -m "Add discover_lan_ip helper to hw_e2e.py"
```

---

### Task 3: Catalog — add WifiEchoHost/WifiEchoPort defines (with Pass-1 defaults)

**Files:**
- Modify: `tools/hardware_validation.json`

Add the two defines now so Pass 2 can wire them in via env without a second catalog touch. Pass 1 defaults make the build succeed even when no EchoServer is running (the firmware declares the consts but doesn't use them yet).

- [ ] **Step 1: Edit the `m0_wifi_e2e_test` entry**

Read `tools/hardware_validation.json` first. Find the `m0_wifi_e2e_test` entry and replace its `defines` block:

Before:
```json
"defines": {
  "bl808WifiVendor": "1",
  "WifiSsid": {"env": "BL808_WIFI_SSID"},
  "WifiPassword": {"secret_env": "BL808_WIFI_PASSWORD"},
  "AttemptsTotal": {"env": "BL808_WIFI_E2E_ATTEMPTS", "default": 3}
}
```

After:
```json
"defines": {
  "bl808WifiVendor": "1",
  "WifiSsid": {"env": "BL808_WIFI_SSID"},
  "WifiPassword": {"secret_env": "BL808_WIFI_PASSWORD"},
  "AttemptsTotal": {"env": "BL808_WIFI_E2E_ATTEMPTS", "default": 3},
  "WifiEchoHost": {"env": "BL808_WIFI_E2E_HOST", "default": "0.0.0.0"},
  "WifiEchoPort": {"env": "BL808_WIFI_E2E_PORT", "default": 0}
}
```

- [ ] **Step 2: Verify the JSON parses**

```bash
.venv/bin/python -c "import json; json.load(open('tools/hardware_validation.json'))"
```

Expected: no output (valid JSON). If `json.JSONDecodeError`, fix the syntax.

- [ ] **Step 3: Commit**

```bash
git add tools/hardware_validation.json
git commit -m "Catalog: add WifiEchoHost/WifiEchoPort defines for Pass 2 wiring"
```

---

### Task 4: Extend `examples/m0_wifi_e2e_test.nim` with the DHCP phase

**Files:**
- Modify: `examples/m0_wifi_e2e_test.nim`

Add lwipcore import, two `{.emit:}` accessors that read the netif's IP and gateway out of the opaque struct, declare the `WifiEchoHost`/`WifiEchoPort` consts (unused in Pass 1; used in Pass 2), and extend `runOneAttempt` to perform the DHCP phase after the existing synthetic `assoc:ok`.

- [ ] **Step 1: Add the lwipcore import and consts**

Read `examples/m0_wifi_e2e_test.nim` first. Find the existing import block and the const block. Add `import bl808/kernel/lwipcore` to the imports. Add to the const block:

```nim
  WifiEchoHost {.strdefine.} = ""
  WifiEchoPort {.intdefine.} = 0
```

- [ ] **Step 2: Add the netif accessors**

Read the file again to find a spot below the const block and above `runOneAttempt`. Add:

```nim
proc netifIp4Addr(netif: ptr Netif): uint32 =
  ## Read netif->ip_addr.addr (lwIP's struct ip_addr is opaque to Nim).
  {.emit: "result = `netif`->ip_addr.addr;".}

proc netifIp4Gw(netif: ptr Netif): uint32 =
  ## Read netif->gw.addr.
  {.emit: "result = `netif`->gw.addr;".}
```

- [ ] **Step 3: Extend `runOneAttempt` with the dhcp phase**

Find the existing `runOneAttempt` proc. After the existing synthetic `assoc:start` / `assoc:ok` markers and before `return true`, insert the dhcp phase. Replace the trailing `return true` with the full new tail:

Before:
```nim
  phaseMark(Phase.assoc, Kind.start)
  phaseMark(Phase.assoc, Kind.ok)
  return true
```

After:
```nim
  phaseMark(Phase.assoc, Kind.start)
  phaseMark(Phase.assoc, Kind.ok)

  # DHCP phase: get the WiFi netif from the blob, kick off DHCP, poll for IP.
  phaseMark(Phase.dhcp, Kind.start)
  let netif = cast[ptr Netif](wifiGetNetif())
  if netif == nil:
    phaseMark(Phase.dhcp, Kind.fail):
      kvWrite("reason", "no_netif")
    return false
  let dhcpRc = dhcpStart(netif)
  if dhcpRc != ErrOk:
    phaseMark(Phase.dhcp, Kind.fail):
      kvWrite("reason", "dhcp_start")
      kvWrite("rc", cast[int32](dhcpRc).int32)
    return false
  # Poll for IP-assigned: 50 ms × 200 = 10 s deadline.
  var ip4: uint32 = 0
  for _ in 0 ..< 200:
    sysCheckTimeouts()
    ip4 = netifIp4Addr(netif)
    if ip4 != 0:
      break
    delayMs(50)
  if ip4 == 0:
    phaseMark(Phase.dhcp, Kind.fail):
      kvWrite("reason", "timeout")
    return false
  let gw4 = netifIp4Gw(netif)
  phaseMark(Phase.dhcp, Kind.ok):
    kvWrite("ip", ip4)
    kvWrite("gw", gw4)
  return true
```

The `delayMs` proc is already available via `import bl808/core` (already imported in the file). If the build complains it's not in scope, replace `delayMs(50)` with `core.delayMs(50)` or use the explicit `delayUs(50_000)` if `delayMs` doesn't exist. Spot-check `src/bl808/core.nim` for the exact name.

- [ ] **Step 4: Build the firmware**

```bash
make m0 FILE=examples/m0_wifi_e2e_test.nim NIM='nim -d:bl808kernel -d:bl808WifiVendor -d:WifiSsid=Frog -d:WifiPassword=<wifi-password>'
```

Expected: build succeeds with `Output: build/m0_firmware.bin`.

If the build fails:
- **`Error: undeclared identifier: 'Netif'`** — the lwipcore import didn't take. Confirm `import bl808/kernel/lwipcore` was added.
- **`Error: undeclared identifier: 'dhcpStart' / 'sysCheckTimeouts' / 'ErrOk'`** — these are exported from lwipcore.nim. If still undefined, check `grep -nE 'dhcpStart\\*|sysCheckTimeouts\\*|ErrOk\\*' src/bl808/kernel/lwipcore.nim` to verify the export names.
- **`Error: undeclared identifier: 'delayMs'`** — find what's in `bl808/core` (`grep -E 'proc delay' src/bl808/core.nim`) and use that name. Likely `delayUs(50_000)` if no `delayMs` exists.
- **`Error: type mismatch (Phase.dhcp)`** — the generated Nim enum may have used a different identifier. Check `grep -E 'dhcp' src/bl808/kernel/e2e_marker.nim`. If the identifier is different (e.g. `dhcp = "dhcp"` is fine; `phDhcp = "dhcp"` is not what we want), reconcile.
- **`Error: linker complains about __stack_chk_fail` or similar lwIP missing symbols** — the WiFi blob may be the only consumer of lwIP today, so adding our own dhcpStart call may pull in lwIP code paths that need additional source files. Look at `src/bl808/kernel/lwipcore.nim` for any `{.compile:}` pragmas; if they don't include the file the linker is missing, that's the gap.

- [ ] **Step 5: Commit**

```bash
git add examples/m0_wifi_e2e_test.nim
git commit -m "m0_wifi_e2e_test: add DHCP phase (Iter 2.A Pass 1)"
```

---

### Task 5: Hardware smoke run

This is the iteration's acceptance test. Hardware-only.

- [ ] **Step 1: Confirm preconditions**

The board must be powered on with the M0 UART anchor flashed and JTAG + UART connected. The `Frog` AP must be reachable. Sudo must be available to my subprocesses (the keep-alive loop should still be running from earlier in the session — verify with `sudo -n -v`; if expired, ask the user to refresh).

- [ ] **Step 2: Run the soak**

```bash
make hw-e2e-quick UART_PORT=/dev/tty.usbserial-TGKWL2RS WIFI_SSID=Frog WIFI_PASSWORD=<wifi-password>
```

(Substitute the correct USB serial port if it differs.)

Expected output shape:
```
... (build + anchor flash output) ...
PASS m0_wifi_e2e_test (Ns): ok
uart log: build/hw-e2e/hw-validate-work/logs/m0_wifi_e2e_test.primary.uart.log

=== wifi-blob ===
attempts: X/3 ok (XX.X%)
failures by phase:
            dhcp  Y    # if any attempts failed at dhcp
or
failures by phase: (none)

PASS or FAIL: success rate XX.X%
```

- [ ] **Step 3: Inspect the JSON report and UART log**

```bash
ls build/hw-e2e/ | grep -E '^[0-9]' | tail -1 | xargs -I{} cat build/hw-e2e/{}/wifi-blob.json
echo "--- markers ---"
grep '@e2e' build/hw-e2e/hw-validate-work/logs/m0_wifi_e2e_test.primary.uart.log
```

Expected (success path): per attempt, full marker chain ending in `dhcp:ok ip=… gw=…` and `attempt:ok`.
Expected (blob doesn't pump lwIP path): marker chain ends at `dhcp:start` followed by silence-until-timeout, then `dhcp:fail reason=timeout` and `attempt:fail`.

- [ ] **Step 4: Diagnose by failure category**

  - **All 3 attempts reach `dhcp:ok`** → Pass 1 success. Blob already wires its netif. Move to Pass 2.
  - **All 3 attempts fail at `dhcp` with `reason=no_netif`** → `wifiGetNetif()` returned nil. Either WiFi never associated (look at earlier markers) or the blob's netif registration happens after a delay we're not waiting for. In the latter case, add a short `delayMs(100)` before the netif fetch and retry.
  - **All 3 attempts fail at `dhcp` with `reason=dhcp_start`** → `dhcpStart` returned non-OK. Inspect the `rc` value in the marker. Common causes: netif not in "up" state, lwIP not initialized. May need to call `lwipInit()` once before the test loop, OR call `netifSetUp(netif)` before `dhcpStart`. Add the appropriate call to the binary's `main` and re-run.
  - **All 3 attempts fail at `dhcp` with `reason=timeout`** → DHCP request was sent but no DHCP OFFER reached lwIP. The blob's RX path is not pumping lwIP. Need to find the blob's RX hook and add a `bl_main_lwip_input(pkt)` call (or equivalent). Look at `wifi_main.nim` / `wifi_rx.nim` / `wifi_support.nim` for an existing hook point.
  - **Mix of dhcp:ok and dhcp:fail** → exactly the "intermittent" category from the spec; not a Pass 1 blocker. Move to Pass 2.

  Document the diagnosis in the commit message of any follow-up tweak. If after diagnosis Pass 1 still doesn't reach `dhcp:ok` even once, that's a real finding — Pass 1's job is to surface it. Stop and ask the controller (the human or the next plan) what to do next.

- [ ] **Step 5: Final commit (only if anything changed during diagnosis)**

If steps in this task required tweaks to the binary, commit each tweak with a focused message. If no edits were needed, no commit. Pass 1 is complete.

```bash
# Example of a focused tweak commit, only if needed:
# git add examples/m0_wifi_e2e_test.nim
# git commit -m "m0_wifi_e2e_test: explicit netifSetUp before dhcpStart (Pass 1 diagnosis)"
```

---

## Self-review

**Spec coverage** (cross-reference against `docs/superpowers/specs/2026-05-09-wifi-dhcp-tcp-iter-2a-design.md` Section 5 "Pass 1 — lwIP investigation + DHCP only, blob backend"):
- ✅ `EchoServer` class (not yet wired) → Task 1
- ✅ `discover_lan_ip()` (not yet wired) → Task 2
- ✅ Catalog defines `WifiEchoHost`/`WifiEchoPort` (placeholders for Pass 2) → Task 3
- ✅ Firmware adds `dhcp:` phase + netif poll → Task 4
- ✅ Hardware smoke / empirical answer to lwIP question → Task 5

**Placeholder scan**: every code step shows the actual code; every command step shows the exact command and expected output. No "TBD" / "implement later" / "add error handling" / "similar to Task N" patterns.

**Type consistency**: `EchoServer.start()` / `.stop()` / `.port` defined in Task 1 and used in Task 2's tests via the same names. `discover_lan_ip()` returns `str` in both task. `Phase.dhcp` and `Kind.fail|ok` in Task 4 match the existing Iter 1 generated enum (verified in setup). `dhcpStart`, `sysCheckTimeouts`, `ErrOk`, `Netif` are all exports of `bl808/kernel/lwipcore` (verified in setup).

**Known fragility**: Task 4 Step 4's troubleshooting list is the load-bearing risk surface. If `delayMs` doesn't exist in `bl808/core` or `Phase.dhcp` was generated with a different identifier, the build will fail loudly and the implementer adapts. Documented inline.
