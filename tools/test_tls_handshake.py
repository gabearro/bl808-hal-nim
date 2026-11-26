"""Real TLS handshakes: src/bl808/kernel/tls.nim (host build, software
backends) against a local `openssl s_server`, over a socket-backed TlsIo."""

import contextlib
from pathlib import Path
import select
import shutil
import socket
import ssl
import struct
import subprocess
import threading
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
OPENSSL = shutil.which("openssl")
NIM = shutil.which("nim")

pytestmark = pytest.mark.skipif(
    not OPENSSL or not NIM or not (ROOT / "vendor/mbedtls/library/ssl_tls.c").is_file(),
    reason="needs openssl, Nim and the vendored Mbed TLS")


def openssl(cwd: Path, *args: str) -> None:
    result = subprocess.run([OPENSSL, *args], cwd=cwd, capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stderr


def issue(pki: Path, name: str, subject: str, issuer: str | None, extensions: str,
          key: tuple[str, ...] = ("-newkey", "rsa:2048")) -> None:
    """Create name.key and name.pem, self-signed or signed by `issuer`."""
    (pki / f"{name}.cnf").write_text(extensions)
    if issuer is None:
        openssl(pki, "req", "-x509", *key, "-nodes", "-keyout", f"{name}.key", "-out", f"{name}.pem",
                "-subj", subject, "-days", "30", "-extensions", "ext", "-config", f"{name}.cnf")
        return
    openssl(pki, "req", *key, "-nodes", "-keyout", f"{name}.key", "-out", f"{name}.csr",
            "-subj", subject, "-config", f"{name}.cnf")
    openssl(pki, "x509", "-req", "-in", f"{name}.csr", "-CA", f"{issuer}.pem", "-CAkey", f"{issuer}.key",
            "-CAcreateserial", "-out", f"{name}.pem", "-days", "30", "-extfile", f"{name}.cnf",
            "-extensions", "ext")


CA_EXT = ("[req]\ndistinguished_name=dn\n[dn]\n[ext]\nbasicConstraints=critical,CA:TRUE\n"
          "keyUsage=critical,keyCertSign,cRLSign\n")
LEAF_EXT = ("[req]\ndistinguished_name=dn\n[dn]\n[ext]\nbasicConstraints=CA:FALSE\n"
            "subjectAltName=DNS:localhost\n")


@pytest.fixture(scope="module")
def pki(tmp_path_factory: pytest.TempPathFactory) -> Path:
    pki = tmp_path_factory.mktemp("pki")
    issue(pki, "root", "/CN=Test Root", None, CA_EXT)
    issue(pki, "other", "/CN=Unrelated Root", None, CA_EXT)
    # Bulky intermediates make a Certificate message of several kilobytes.
    padded = CA_EXT + "nsComment=" + "bulk " * 500 + "\n"
    issue(pki, "mid1", "/CN=Test Intermediate 1", "root", padded)
    issue(pki, "mid2", "/CN=Test Intermediate 2", "mid1", padded)
    issue(pki, "leaf", "/CN=localhost", "mid2", LEAF_EXT)
    issue(pki, "ecleaf", "/CN=localhost", "mid2", LEAF_EXT,
          key=("-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256"))
    (pki / "chain.pem").write_text((pki / "mid2.pem").read_text() + (pki / "mid1.pem").read_text())
    for name in ("root", "other"):
        openssl(pki, "x509", "-in", f"{name}.pem", "-outform", "DER", "-out", f"{name}.der")
    (pki / "big.bin").write_bytes(bytes((i * 7 + (i >> 8) * 13) & 255 for i in range(200_000)))
    (pki / "small.bin").write_bytes(bytes((i * 31) & 255 for i in range(3000)))
    return pki


@pytest.fixture(scope="module")
def client(tmp_path_factory: pytest.TempPathFactory) -> Path:
    build = tmp_path_factory.mktemp("tls_client")
    binary = build / "tls_host_client"
    result = subprocess.run(
        [NIM, "c", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg", "--hints:off",
         "--mm:arc", "-d:release", "--assertions:on", f"--path:{ROOT / 'src'}",
         f"--nimcache:{build / 'cache'}", f"-o:{binary}", str(ROOT / "tools/tls_host_client.nim")],
        cwd=ROOT, capture_output=True, text=True, timeout=600)
    assert result.returncode == 0, result.stdout + result.stderr
    return binary


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@contextlib.contextmanager
def s_server(pki: Path, *options: str, leaf: str = "leaf", serve_files: bool = True,
             log: Path | None = None):
    """Serve the PKI directory's files (-WWW), or just print what the client
    sends to the log."""
    port = free_port()
    log = (log or pki / f"s_server.{port}.log").open("w")
    process = subprocess.Popen(
        [OPENSSL, "s_server", "-accept", str(port), "-cert", f"{leaf}.pem", "-key", f"{leaf}.key",
         "-cert_chain", "chain.pem", "-quiet", *(["-WWW"] if serve_files else []), *options],
        # An open, silent stdin: without -WWW the server relays its input.
        cwd=pki, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 10
        while True:
            assert process.poll() is None, "openssl s_server exited"
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                assert time.monotonic() < deadline, "openssl s_server did not start"
                time.sleep(0.05)
        yield port
    finally:
        process.kill()
        process.wait()
        log.close()


@contextlib.contextmanager
def record_proxy(upstream: int):
    """Relay one connection and log its TLS records as
    (from_server, length, content_type)."""
    records: list[tuple[bool, int, int]] = []
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)

    def relay() -> None:
        listener.settimeout(30)
        try:
            near, _ = listener.accept()
        except OSError:
            return
        far = socket.create_connection(("127.0.0.1", upstream))
        pending = {near: b"", far: b""}
        peers = {near: far, far: near}
        try:
            while True:
                readable, _, _ = select.select([near, far], [], [], 30)
                if not readable: return
                for source in readable:
                    data = source.recv(65536)
                    if not data: return
                    peers[source].sendall(data)
                    buffered = pending[source] + data
                    while len(buffered) >= 5 and len(buffered) >= 5 + int.from_bytes(buffered[3:5], "big"):
                        length = int.from_bytes(buffered[3:5], "big")
                        records.append((source is far, length, buffered[0]))
                        buffered = buffered[5 + length:]
                    pending[source] = buffered
        except OSError:
            pass
        finally:
            near.close()
            far.close()

    thread = threading.Thread(target=relay, daemon=True)
    thread.start()
    try:
        yield listener.getsockname()[1], records
    finally:
        thread.join(timeout=30)
        listener.close()


def client_hellos(records: list[tuple[bool, int, int]]) -> int:
    """Plaintext handshake records (type 22) sent by the client."""
    return sum(1 for from_server, _, kind in records if not from_server and kind == 22)


def run_client(client: Path, port: int, tmp_path: Path, path: str = "/big.bin",
               name: str = "localhost", *options: str) -> tuple[dict[str, str], bytes]:
    output = tmp_path / "body.bin"
    result = subprocess.run([str(client), str(port), name, path, str(output), *options],
                            capture_output=True, text=True, timeout=120)
    words = result.stdout.split()
    assert words and words[0] in ("ok", "fail"), result.stdout + result.stderr
    fields = dict(word.split("=", 1) for word in words[1:])
    fields["status"] = words[0]
    assert (result.returncode == 0) == (words[0] == "ok"), result.stdout + result.stderr
    body = b""
    if words[0] == "ok":
        head, _, body = output.read_bytes().partition(b"\r\n\r\n")
        assert head.startswith(b"HTTP/1.0 200"), head
        assert int(fields["bytes"]) == len(head) + 4 + len(body)
    return fields, body


def test_tls13_with_only_aes128gcm_and_p256(pki: Path, client: Path, tmp_path: Path) -> None:
    """The one suite and group the upstream radio requires."""
    with s_server(pki, "-tls1_3", "-ciphersuites", "TLS_AES_128_GCM_SHA256",
                  "-groups", "P-256") as port, record_proxy(port) as (proxy, records):
        fields, body = run_client(client, proxy, tmp_path)
    assert fields["status"] == "ok", fields
    assert fields["version"] == "TLSv1.3"
    assert fields["suite"] == "TLS1-3-AES-128-GCM-SHA256"
    assert body == (pki / "big.bin").read_bytes()
    # Host figures (64-bit, software crypto): the session's two record buffers
    # dominate the heap; the handshake must fit a small embedded stack.
    assert 20_000 < int(fields["open"]) < int(fields["heap"]) < 56_000, fields
    assert int(fields["idle"]) < 4_096, fields
    assert 1_000 < int(fields["stack"]) < 12_000, fields
    # Full-size records: 16384 bytes of plaintext, its type byte and the tag.
    assert max(length for from_server, length, _ in records if from_server) == 16384 + 1 + 16


def test_hardware_backed_choices_are_preferred(pki: Path, client: Path, tmp_path: Path) -> None:
    """Against a server that takes the client's order, the suite the BL808
    accelerates wins, in TLS 1.3 and in TLS 1.2, with P-256 key exchange."""
    with s_server(pki, "-tls1_3") as port, record_proxy(port) as (proxy, records):
        modern, _ = run_client(client, proxy, tmp_path, "/small.bin")
    with s_server(pki, "-tls1_2") as port:
        legacy, _ = run_client(client, port, tmp_path, "/small.bin")
    assert (modern["version"], modern["suite"]) == ("TLSv1.3", "TLS1-3-AES-128-GCM-SHA256"), modern
    assert (legacy["version"], legacy["suite"]) == \
        ("TLSv1.2", "TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256"), legacy
    # No HelloRetryRequest: the P-256 share of the one ClientHello was used.
    assert client_hellos(records) == 1, records[:6]


@pytest.mark.parametrize("suite,name", [
    ("TLS_AES_256_GCM_SHA384", "TLS1-3-AES-256-GCM-SHA384"),
    ("TLS_CHACHA20_POLY1305_SHA256", "TLS1-3-CHACHA20-POLY1305-SHA256"),
])
def test_tls13_other_suites(pki: Path, client: Path, tmp_path: Path, suite: str, name: str) -> None:
    with s_server(pki, "-tls1_3", "-ciphersuites", suite) as port:
        fields, body = run_client(client, port, tmp_path)
    assert (fields["status"], fields["version"], fields["suite"]) == ("ok", "TLSv1.3", name), fields
    assert body == (pki / "big.bin").read_bytes()


@pytest.mark.parametrize("group", ["X25519", "P-384"])
def test_tls13_hello_retry_for_a_group_not_offered_first(pki: Path, client: Path, tmp_path: Path,
                                                         group: str) -> None:
    """The client's first key share is P-256; other groups cost a retry."""
    with s_server(pki, "-tls1_3", "-groups", group) as port, record_proxy(port) as (proxy, records):
        fields, body = run_client(client, proxy, tmp_path, "/small.bin")
    assert (fields["status"], fields["version"]) == ("ok", "TLSv1.3"), fields
    assert body == (pki / "small.bin").read_bytes()
    assert client_hellos(records) == 2, records[:8]


def test_tls13_ecdsa_server_certificate(pki: Path, client: Path, tmp_path: Path) -> None:
    with s_server(pki, "-tls1_3", leaf="ecleaf") as port:
        fields, body = run_client(client, port, tmp_path, "/small.bin", "localhost",
                                  f"--verify={pki / 'root.der'}")
    assert (fields["status"], fields["version"]) == ("ok", "TLSv1.3"), fields
    assert body == (pki / "small.bin").read_bytes()


def test_certificate_chain_spread_over_many_records(pki: Path, client: Path, tmp_path: Path) -> None:
    """A three-certificate chain sent in 512-byte records, verified to the root."""
    chain_bytes = sum(len((pki / f"{name}.pem").read_bytes()) for name in ("leaf", "mid1", "mid2"))
    assert chain_bytes * 3 // 4 > 6 * 512
    with s_server(pki, "-tls1_3", "-ciphersuites", "TLS_AES_128_GCM_SHA256", "-groups", "P-256",
                  "-max_send_frag", "512") as port, record_proxy(port) as (proxy, records):
        fields, body = run_client(client, proxy, tmp_path, "/big.bin", "localhost",
                                  f"--verify={pki / 'root.der'}")
    assert (fields["status"], fields["version"]) == ("ok", "TLSv1.3"), fields
    assert body == (pki / "big.bin").read_bytes()
    # The server's handshake flight sits between the client's two flights.
    client_records = [index for index, record in enumerate(records) if not record[0]]
    flight = [length for _, length, _ in records[client_records[0] + 1:client_records[1]]]
    assert len(flight) >= 10 and max(flight) <= 512 + 1 + 16 and sum(flight) > 6 * 512, flight


@pytest.mark.parametrize("trickle,path", [(1, "/small.bin"), (37, "/big.bin"), (1500, "/big.bin")])
def test_would_block_transport(pki: Path, client: Path, tmp_path: Path, trickle: int, path: str) -> None:
    """Every other transport call moves nothing; the rest move `trickle` bytes.
    The request is padded past one output record so writes resume as well."""
    with s_server(pki, "-tls1_3", "-ciphersuites", "TLS_AES_128_GCM_SHA256",
                  "-groups", "P-256") as port:
        fields, body = run_client(client, port, tmp_path, path, "localhost",
                                  f"--trickle={trickle}", "--pad=9000")
    assert fields["status"] == "ok", fields
    assert int(fields["blocked"]) > 100
    assert body == (pki / path[1:]).read_bytes()


@pytest.mark.parametrize("trickle", [0, 13, 700])
def test_request_bytes_arrive_intact(pki: Path, client: Path, tmp_path: Path, trickle: int) -> None:
    """20 kB of request in 4 kB records, resumed after every "would block":
    the server must have received exactly the bytes handed to tlsWrite."""
    lines = "".join(
        "X-Pad: " + "".join(chr(ord("a") + (line * 31 + column * 7) % 26) for column in range(1000)) + "\r\n"
        for line in range(20))
    expected = ("GET /upload HTTP/1.0\r\nHost: localhost\r\n" + lines + "\r\n").encode()
    received = tmp_path / "received.log"
    with s_server(pki, "-tls1_3", serve_files=False, log=received) as port:
        result = subprocess.run(
            [str(client), str(port), "localhost", "/upload", str(tmp_path / "unused"), "--upload",
             "--pad=20000", f"--trickle={trickle}"], capture_output=True, text=True, timeout=120)
        assert result.returncode == 0 and result.stdout.startswith("ok "), result.stdout + result.stderr
        deadline = time.monotonic() + 10
        while expected not in received.read_bytes() and time.monotonic() < deadline:
            time.sleep(0.05)
    assert expected in received.read_bytes()


def test_verify_peer(pki: Path, client: Path, tmp_path: Path) -> None:
    with s_server(pki, "-tls1_3") as port:
        trusted, body = run_client(client, port, tmp_path, "/small.bin", "localhost",
                                   f"--verify={pki / 'root.der'}")
        wrong_name, _ = run_client(client, port, tmp_path, "/small.bin", "example.org",
                                   f"--verify={pki / 'root.der'}")
        wrong_root, _ = run_client(client, port, tmp_path, "/small.bin", "localhost",
                                   f"--verify={pki / 'other.der'}")
        unverified, _ = run_client(client, port, tmp_path, "/small.bin", "example.org")
    assert trusted["status"] == "ok" and body == (pki / "small.bin").read_bytes()
    for refused in (wrong_name, wrong_root):
        assert (refused["status"], refused["stage"], refused["class"]) == \
            ("fail", "handshake", "tlsErrHandshake"), refused
        assert refused["error"] == "-0x2700"       # MBEDTLS_ERR_X509_CERT_VERIFY_FAILED
    assert unverified["status"] == "ok"            # the default: no verification, as upstream


def test_sessions_release_everything_they_allocate(pki: Path, client: Path, tmp_path: Path) -> None:
    """Three fetches in one process: the client asserts that Mbed TLS's live
    allocations return to the same level after each session."""
    with s_server(pki, "-tls1_3") as port:
        fields, body = run_client(client, port, tmp_path, "/small.bin", "localhost",
                                  f"--verify={pki / 'root.der'}", "--repeat=3")
    assert fields["status"] == "ok", fields
    assert body == (pki / "small.bin").read_bytes()


def test_tls12_fallback(pki: Path, client: Path, tmp_path: Path) -> None:
    with s_server(pki, "-tls1_2") as port:
        fields, body = run_client(client, port, tmp_path, "/big.bin", "localhost",
                                  f"--verify={pki / 'root.der'}", "--trickle=997")
    assert (fields["status"], fields["version"]) == ("ok", "TLSv1.2"), fields
    assert fields["suite"] == "TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256", fields
    assert body == (pki / "big.bin").read_bytes()


def test_server_without_a_common_suite_is_reported_as_refused(pki: Path, client: Path,
                                                             tmp_path: Path) -> None:
    with s_server(pki, "-tls1_3", "-ciphersuites", "TLS_AES_128_CCM_SHA256") as port:
        fields, _ = run_client(client, port, tmp_path, "/small.bin")
    assert (fields["status"], fields["stage"], fields["class"]) == \
        ("fail", "handshake", "tlsErrRefused"), fields
    assert fields["error"] == "-0x7780"            # MBEDTLS_ERR_SSL_FATAL_ALERT_MESSAGE


def test_connection_lost_during_handshake_is_an_io_error(client: Path, tmp_path: Path) -> None:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(20)
        process = subprocess.Popen(
            [str(client), str(listener.getsockname()[1]), "localhost", "/", str(tmp_path / "out")],
            stdout=subprocess.PIPE, text=True)
        peer, _ = listener.accept()
        peer.recv(4096)                            # the ClientHello
        peer.close()
        stdout, _ = process.communicate(timeout=20)
    words = stdout.split()
    assert words[0] == "fail" and "stage=handshake" in words and "class=tlsErrIo" in words, stdout


# ---- How a session ends ------------------------------------------------------
# tlsRead/tlsWrite report `tlsClosed` both for the peer's close_notify and for
# a transport that ended or failed underneath; tlsPeerClosed and tlsErrorClass
# tell them apart. The client below reads (or writes) until the session ends
# and prints what the module says about the ending.

END_CLIENT = r"""
import std/[net, os, posix, strutils]
import bl808/kernel/tls

proc ioSend(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  let moved = send(cast[ptr SocketHandle](ctx)[], data, len.cint, 0)
  if moved > 0: moved else: -1

proc ioRecv(ctx: pointer; data: ptr UncheckedArray[byte]; len: int): int {.nimcall.} =
  let moved = recv(cast[ptr SocketHandle](ctx)[], data, len.cint, 0)
  if moved > 0: moved else: -1      # end of stream and errors alike

proc main() =
  signal(SIGPIPE, SIG_IGN)
  let socket = newSocket()
  socket.connect("127.0.0.1", Port(parseInt(paramStr(1))))
  var fd = socket.getFd               # blocking: no "would block" results
  var session: TlsSession
  doAssert tlsOpen(session, TlsIo(ctx: addr fd, send: ioSend, recv: ioRecv), "localhost")
  doAssert tlsHandshakeStep(session) == tlsOk
  doAssert not tlsPeerClosed(session) and tlsBuffered(session) == (0, 0)
  var status = tlsOk
  var total, decoded = 0
  var buffer: array[1024, byte]
  let data = cast[ptr UncheckedArray[byte]](addr buffer[0])
  if paramStr(2) == "write":
    for attempt in 0 ..< 500:
      var put: int
      status = tlsWrite(session, data, buffer.len, put)
      if status != tlsOk: break
      sleep(10)
  else:
    var cap = 10                      # less than the one record the server sends
    while status == tlsOk:
      var got: int
      status = tlsRead(session, data, cap, got)
      if total == 0: decoded = tlsBuffered(session).decoded
      total += got
      cap = buffer.len
  echo "end=", status, " class=", tlsErrorClass(session), " peer_closed=", tlsPeerClosed(session),
    " error=-0x", toHex(-tlsLastError(session), 4), " bytes=", total, " decoded=", decoded,
    " pending=", tlsBuffered(session).pending
  tlsClose(session)
  doAssert tlsBuffered(session) == (0, 0)
  echo "closed class=", tlsErrorClass(session), " peer_closed=", tlsPeerClosed(session)

main()
"""

PAYLOAD = bytes(range(100))


@pytest.fixture(scope="module")
def end_client(tmp_path_factory: pytest.TempPathFactory) -> Path:
    build = tmp_path_factory.mktemp("tls_end_client")
    (build / "tls_end_client.nim").write_text(END_CLIENT)
    binary = build / "tls_end_client"
    result = subprocess.run(
        [NIM, "c", "--skipParentCfg", "--skipProjCfg", "--skipUserCfg", "--hints:off",
         "--mm:arc", "-d:release", "--assertions:on", f"--path:{ROOT / 'src'}",
         f"--nimcache:{build / 'cache'}", f"-o:{binary}", str(build / "tls_end_client.nim")],
        cwd=ROOT, capture_output=True, text=True, timeout=600)
    assert result.returncode == 0, result.stdout + result.stderr
    return binary


@contextlib.contextmanager
def ending_server(pki: Path, ending: str):
    """One TLS connection that sends PAYLOAD in one record and then ends as
    `ending` says. The TLS bytes go through memory BIOs, so the test decides
    exactly what reaches the wire."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(pki / "leaf.pem", pki / "leaf.key")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(30)

    def reset(peer: socket.socket) -> None:
        peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))

    def serve() -> None:
        try:
            peer, _ = listener.accept()
        except OSError:
            return
        peer.settimeout(30)
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        tls = context.wrap_bio(incoming, outgoing, server_side=True)
        try:
            while True:
                try:
                    tls.do_handshake()
                    break
                except ssl.SSLWantReadError:
                    peer.sendall(outgoing.read())
                    data = peer.recv(65536)
                    if not data: return
                    incoming.write(data)
            peer.sendall(outgoing.read())          # the end of the handshake, session tickets
            if ending == "reset-before-data":
                reset(peer)
                return
            tls.write(PAYLOAD)
            record = outgoing.read()
            if ending == "cut-record":
                peer.sendall(record[:-20])
                return
            peer.sendall(record)
            if ending == "close-notify":
                with contextlib.suppress(ssl.SSLError):
                    tls.unwrap()                   # queues the alert; the reply is not awaited
                peer.sendall(outgoing.read())
                while peer.recv(65536): pass       # until the client has read it and closed
            elif ending == "reset":
                time.sleep(0.5)                    # let the client read the record first
                reset(peer)
        except OSError:
            pass
        finally:
            peer.close()                           # "fin" does nothing more than this

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        yield listener.getsockname()[1]
    finally:
        thread.join(timeout=30)
        listener.close()


def run_end_client(end_client: Path, port: int, mode: str = "read") -> tuple[dict[str, str], dict[str, str]]:
    result = subprocess.run([str(end_client), str(port), mode], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    at_end, after_close = (line.split() for line in result.stdout.splitlines())
    assert after_close[0] == "closed"
    return dict(word.split("=", 1) for word in at_end), dict(word.split("=", 1) for word in after_close[1:])


def test_close_notify_is_an_orderly_end(pki: Path, end_client: Path) -> None:
    with ending_server(pki, "close-notify") as port:
        at_end, after_close = run_end_client(end_client, port)
    assert at_end == {"end": "tlsClosed", "class": "tlsErrNone", "peer_closed": "true",
                      "error": "-0x7880",          # MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY
                      "bytes": str(len(PAYLOAD)), "decoded": str(len(PAYLOAD) - 10), "pending": "0"}
    # The reason stays readable after tlsClose.
    assert after_close == {"class": "tlsErrNone", "peer_closed": "true"}


@pytest.mark.parametrize("ending", ["fin", "reset"])
def test_transport_ending_without_close_notify_is_an_io_error(pki: Path, end_client: Path,
                                                             ending: str) -> None:
    """TCP FIN or RST after a complete record: still `tlsClosed`, but lost."""
    with ending_server(pki, ending) as port:
        at_end, after_close = run_end_client(end_client, port)
    assert (at_end["end"], at_end["class"], at_end["peer_closed"]) == ("tlsClosed", "tlsErrIo", "false"), at_end
    assert at_end["error"] == "-0x0050"            # MBEDTLS_ERR_NET_CONN_RESET, from the transport glue
    assert (at_end["bytes"], at_end["pending"]) == (str(len(PAYLOAD)), "0"), at_end
    assert after_close == {"class": "tlsErrIo", "peer_closed": "false"}


def test_transport_ending_inside_a_record_reports_the_bytes_that_arrived(pki: Path,
                                                                        end_client: Path) -> None:
    with ending_server(pki, "cut-record") as port:
        at_end, _ = run_end_client(end_client, port)
    assert (at_end["end"], at_end["class"], at_end["peer_closed"]) == ("tlsClosed", "tlsErrIo", "false"), at_end
    # Nothing was decrypted; the header and all but 20 bytes of the record
    # (payload, content type and tag) are what tlsBuffered calls pending.
    assert (at_end["bytes"], at_end["decoded"]) == ("0", "0"), at_end
    assert int(at_end["pending"]) == 5 + len(PAYLOAD) + 1 + 16 - 20, at_end


def test_transport_failing_under_a_write_is_an_io_error(pki: Path, end_client: Path) -> None:
    with ending_server(pki, "reset-before-data") as port:
        at_end, after_close = run_end_client(end_client, port, "write")
    assert (at_end["end"], at_end["class"], at_end["peer_closed"]) == ("tlsClosed", "tlsErrIo", "false"), at_end
    assert after_close == {"class": "tlsErrIo", "peer_closed": "false"}
