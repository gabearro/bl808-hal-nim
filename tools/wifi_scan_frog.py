"""Scan Wi-Fi networks via CoreWLAN and dump security details for SSID 'Frog'.

Used to diagnose why the BL808 vendor supplicant gets DEAUTHed by the AP
(status_code 19 = CIPHER_REJECTED_PER_POLICY): we need to see what cipher
suites, AKM modes, and PMF capability the AP actually advertises in its
RSN IE.
"""
from __future__ import annotations

import sys
import time

from CoreWLAN import CWWiFiClient


def describe_security(net) -> str:
    # CoreWLAN security constants (from CWNetwork.h):
    sec_names = {
        0: "None",
        1: "WEP",
        2: "WPA Personal",
        3: "WPA Personal Mixed",
        4: "WPA2 Personal",
        5: "Personal (legacy)",
        6: "Dynamic WEP",
        7: "WPA Enterprise",
        8: "WPA Enterprise Mixed",
        9: "WPA2 Enterprise",
        10: "Enterprise (legacy)",
        11: "WPA3 Personal",
        12: "WPA3 Enterprise",
        13: "WPA3 Transition",
        14: "OWE",
        15: "OWE Transition",
    }
    bits = []
    for n in range(16):
        try:
            if net.supportsSecurity_(n):
                bits.append(f"{sec_names.get(n, str(n))}({n})")
        except Exception:
            pass
    return ",".join(bits) if bits else "?"


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else "Frog"
    client = CWWiFiClient.sharedWiFiClient()
    iface = client.interface()
    if iface is None:
        print("no Wi-Fi interface")
        return 1
    print(f"interface: {iface.interfaceName()}")
    print(f"target SSID: {target}")
    print()

    # Active scan, blocking up to ~6 s.
    print("scanning...")
    nets, err = iface.scanForNetworksWithName_includeHidden_error_(
        target, True, None
    )
    if err is not None:
        print(f"scan error: {err}")
        # Fall back to broad scan filtered later
        nets, err = iface.scanForNetworksWithName_error_(None, None)
        if err is not None:
            print(f"broad scan also failed: {err}")
            return 2

    if nets is None or len(nets) == 0:
        print(f"no networks named {target!r} found")
        return 3

    print(f"found {len(nets)} BSSID(s) for {target!r}:")
    print()
    for i, net in enumerate(nets):
        ssid = net.ssid()
        bssid = net.bssid() or "(hidden)"
        rssi = net.rssiValue()
        ch = net.wlanChannel()
        ch_num = ch.channelNumber() if ch else None
        ch_band = ch.channelBand() if ch else None
        ch_width = ch.channelWidth() if ch else None
        country = net.countryCode() or "?"
        beacon = net.beaconInterval()
        ie_data = None
        try:
            ie_data = net.informationElementData()
        except Exception:
            pass

        # Direct property reads on CoreWLAN's CWNetwork (KVC fallback for
        # private fields).
        def kvc(key):
            try:
                return net.valueForKey_(key)
            except Exception:
                return None

        rsn_ie = kvc("rsnIE") or kvc("rsnInformationElement")
        sec_str = describe_security(net)

        print(f"  [{i}] BSSID={bssid}  ch={ch_num} band={ch_band} width={ch_width}")
        print(f"      RSSI={rssi} dBm  country={country}  beacon={beacon}")
        print(f"      security: {sec_str}")
        if ie_data is not None and len(ie_data) > 0:
            hex_blob = bytes(ie_data).hex()
            print(f"      IE data ({len(ie_data)} bytes): {hex_blob[:200]}{'...' if len(hex_blob) > 200 else ''}")
        if rsn_ie is not None:
            try:
                rsn_bytes = bytes(rsn_ie)
                print(f"      RSN IE ({len(rsn_bytes)} bytes): {rsn_bytes.hex()}")
            except Exception:
                pass
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
