#!/usr/bin/env python3
"""
wifi_inspector.py - Wireless Hardware & Capability Inspector

Automates the discovery, capability inspection, band analysis, and test-mode
recommendation for Wi-Fi network interfaces on Linux test hosts.
Supports 802.11n/ac/ax/be (Wi-Fi 4/5/6/6E/7) and MLD (Multi-Link Device).
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def run_cmd(cmd: List[str]) -> Tuple[int, str, str]:
    """Run a system command and return (returncode, stdout, stderr)."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        return res.returncode, res.stdout, res.stderr
    except FileNotFoundError:
        return 127, "", f"Command not found: {cmd[0]}"
    except Exception as e:
        return 1, "", str(e)


def get_interface_ip_info(iface: str) -> Dict[str, str]:
    """Extract IPv4, IPv6, and default gateway for a network interface."""
    info = {"ipv4": "", "prefix4": "", "ipv6": "", "gateway": ""}
    
    # Query IPv4
    rc, out, _ = run_cmd(["ip", "-4", "-o", "addr", "show", "dev", iface])
    if rc == 0:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                cidr = parts[3]
                if "/" in cidr:
                    info["ipv4"], info["prefix4"] = cidr.split("/", 1)
                    break

    # Query global IPv6
    rc6, out6, _ = run_cmd(["ip", "-6", "-o", "addr", "show", "dev", iface, "scope", "global"])
    if rc6 == 0:
        for line in out6.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                cidr = parts[3]
                if "/" in cidr:
                    info["ipv6"] = cidr
                    break

    # Query gateway/route for this device
    rc_r, out_r, _ = run_cmd(["ip", "-4", "route", "show", "dev", iface])
    if rc_r == 0:
        for line in out_r.splitlines():
            if "default via" in line:
                m = re.search(r"default via ([0-9.]+)", line)
                if m:
                    info["gateway"] = m.group(1)
                    break

    return info


def inspect_phy_supported_bands(phy_name: str) -> List[str]:
    """
    Parse 'iw phy <phy> info' to identify all frequency bands supported by hardware.
    Bands:
      - 2.4GHz: 2400 - 2500 MHz
      - 5GHz:   5150 - 5895 MHz
      - 6GHz:   5925 - 7125 MHz (Wi-Fi 6E / Wi-Fi 7)
    """
    phy_id = phy_name.replace("#", "")
    rc, out, _ = run_cmd(["iw", "phy", phy_id, "info"])
    if rc != 0:
        return []

    supported = []
    has_2g = False
    has_5g = False
    has_6g = False

    for line in out.splitlines():
        mf = re.search(r"(\d+\.\d+)\s+MHz", line)
        if mf:
            freq = float(mf.group(1))
            if 2400.0 <= freq <= 2500.0:
                has_2g = True
            elif 5150.0 <= freq <= 5895.0:
                has_5g = True
            elif 5925.0 <= freq <= 7125.0:
                has_6g = True

    if has_2g:
        supported.append("2.4GHz")
    if has_5g:
        supported.append("5GHz")
    if has_6g:
        supported.append("6GHz")

    return supported


def scan_wifi_devices() -> List[Dict[str, Any]]:
    """Scan and analyze all wireless network devices on the Linux host."""
    rc, out, _ = run_cmd(["iw", "dev"])
    if rc != 0:
        return []

    devices: List[Dict[str, Any]] = []
    current_phy = None
    current_dev: Optional[Dict[str, Any]] = None

    for line in out.splitlines():
        line_str = line.strip()
        if line_str.startswith("phy#"):
            current_phy = line_str
        elif line_str.startswith("Interface"):
            parts = line_str.split()
            if len(parts) >= 2:
                ifname = parts[1]
                current_dev = {
                    "phy": current_phy or "phy0",
                    "interface": ifname,
                    "mac": "",
                    "ssid": "",
                    "bssid": "",
                    "channel": None,
                    "frequency_mhz": None,
                    "channel_width": "",
                    "txpower_dbm": None,
                    "current_band": "Not Connected",
                    "is_mld": False,
                    "mld_link_addr": "",
                    "mld_link_id": None,
                    "supported_bands": [],
                    "ip_info": {}
                }
                devices.append(current_dev)
        elif current_dev:
            if line_str.startswith("addr "):
                current_dev["mac"] = line_str.split()[1]
            elif line_str.startswith("ssid "):
                current_dev["ssid"] = line_str.split(maxsplit=1)[1]
            elif "MLD with links:" in line_str:
                current_dev["is_mld"] = True
            elif line_str.startswith("link addr "):
                current_dev["mld_link_addr"] = line_str.split()[-1]
            elif "link ID" in line_str:
                m_lid = re.search(r"link ID\s+(\d+)", line_str)
                if m_lid:
                    current_dev["mld_link_id"] = int(m_lid.group(1))
            elif "channel " in line_str and "MHz" in line_str:
                m_ch = re.search(r"channel\s+(\d+)", line_str)
                if m_ch:
                    current_dev["channel"] = int(m_ch.group(1))
                m_freq = re.search(r"\((\d+)\s+MHz\)", line_str)
                if m_freq:
                    freq = int(m_freq.group(1))
                    current_dev["frequency_mhz"] = freq
                    if 2400 <= freq <= 2500:
                        current_dev["current_band"] = "2.4GHz"
                    elif 5150 <= freq <= 5895:
                        current_dev["current_band"] = "5GHz"
                    elif 5925 <= freq <= 7125:
                        current_dev["current_band"] = "6GHz"
                m_width = re.search(r"width:\s+([^,]+)", line_str)
                if m_width:
                    current_dev["channel_width"] = m_width.group(1).strip()
            elif "txpower " in line_str:
                m_pwr = re.search(r"txpower\s+([0-9.]+)\s+dBm", line_str)
                if m_pwr:
                    current_dev["txpower_dbm"] = float(m_pwr.group(1))

    # Enrich each device with supported bands and IP information
    for dev in devices:
        dev["supported_bands"] = inspect_phy_supported_bands(dev["phy"])
        dev["ip_info"] = get_interface_ip_info(dev["interface"])

        # If SSID was not in iw dev output, query iw dev <iface> link
        if not dev.get("ssid"):
            rc_l, out_l, _ = run_cmd(["iw", "dev", dev["interface"], "link"])
            if rc_l == 0:
                for l_line in out_l.splitlines():
                    l_s = l_line.strip()
                    if "SSID:" in l_s:
                        dev["ssid"] = l_s.split("SSID:", 1)[1].strip()
                    elif "freq:" in l_s:
                        try:
                            f_val = float(l_s.split("freq:", 1)[1].strip())
                            dev["frequency_mhz"] = int(f_val)
                            if 2400 <= f_val <= 2500:
                                dev["current_band"] = "2.4GHz"
                            elif 5150 <= f_val <= 5895:
                                dev["current_band"] = "5GHz"
                            elif 5925 <= f_val <= 7125:
                                dev["current_band"] = "6GHz"
                        except Exception:
                            pass

    return devices


def recommend_test_strategy(devices: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Recommend the optimal test mode based on detected Wi-Fi hardware.
    """
    count = len(devices)
    connected_devs = [d for d in devices if d.get("ssid")]

    if count == 0:
        return {
            "mode": "emulated",
            "reason": "No physical Wi-Fi adapters detected on host.",
            "description": "Fallback to virtual netns simulation (ns-wlan2g/5g/6g). Zero hardware required.",
            "recommended_scenario": "virtual_tri_band",
            "active_card": None
        }

    if count == 1:
        dev = devices[0]
        active_band = dev.get("current_band", "5GHz")
        bands_str = ",".join(dev.get("supported_bands", []))
        is_connected = bool(dev.get("ssid"))

        return {
            "mode": "real_single_band" if is_connected else "hybrid",
            "reason": f"Detected 1 physical Wi-Fi card ({dev['interface']}) supporting [{bands_str}].",
            "description": (
                f"Card is currently connected to SSID '{dev.get('ssid', 'N/A')}' on {active_band} "
                f"({dev.get('channel_width', 'N/A')}). Use physical OTA traffic for {active_band} "
                "to fully exercise DUT wireless RF chip and MAC, paired with 1 Gbps Wired LAN."
            ),
            "recommended_scenario": "wired_plus_real_wifi",
            "active_card": dev["interface"],
            "active_band": active_band,
            "supported_bands": dev.get("supported_bands", []),
            "alternative_modes": [
                {
                    "mode": "hybrid",
                    "description": f"Real OTA on {active_band} + virtual netns for remaining bands"
                },
                {
                    "mode": "sequential",
                    "description": "Sequential band testing (2.4G -> 5G -> 6G) by reconnecting SSID"
                }
            ]
        }

    # count >= 2
    return {
        "mode": "physical",
        "reason": f"Detected {count} physical Wi-Fi adapters.",
        "description": "Full multi-card physical testbed. Dedicated physical interfaces per band.",
        "recommended_scenario": "multi_station_physical",
        "active_card": devices[0]["interface"]
    }


def cmd_detect(args: argparse.Namespace) -> int:
    """Print detected devices in JSON format."""
    devices = scan_wifi_devices()
    rec = recommend_test_strategy(devices)
    result = {
        "device_count": len(devices),
        "devices": devices,
        "recommendation": rec
    }
    print(json.dumps(result, indent=2))
    return 0


def cmd_table(args: argparse.Namespace) -> int:
    """Print a clean human-readable ASCII table of detected Wi-Fi devices."""
    devices = scan_wifi_devices()
    rec = recommend_test_strategy(devices)

    print("=" * 78)
    print("  WIRELESS HARDWARE & BAND CAPABILITY AUDIT")
    print("=" * 78)

    if not devices:
        print("  [WARN] No physical Wi-Fi interfaces detected on this host.")
        print(f"  Recommended Mode: {rec['mode'].upper()} - {rec['description']}")
        print("=" * 78)
        return 0

    print(f"{'Interface':<12} {'Phy':<8} {'Hardware Bands':<18} {'Connected SSID':<16} {'Active Band':<12} {'IP Address':<15}")
    print("-" * 78)

    for d in devices:
        iface = d["interface"]
        phy = d["phy"]
        bands = ",".join(d["supported_bands"]) or "Unknown"
        ssid = d["ssid"] or "(disconnected)"
        active_b = d["current_band"]
        if d.get("channel"):
            active_b = f"{d['current_band']} (Ch {d['channel']})"
        ip = d.get("ip_info", {}).get("ipv4", "none")

        print(f"{iface:<12} {phy:<8} {bands:<18} {ssid:<16} {active_b:<12} {ip:<15}")

    print("=" * 78)
    print(f"  Adaptive Recommendation : {rec['mode'].upper()}")
    print(f"  Reason                   : {rec['reason']}")
    print(f"  Strategy                 : {rec['description']}")
    print("=" * 78)
    return 0


def cmd_export_env(args: argparse.Namespace) -> int:
    """Output shell environment variables suitable for eval / source."""
    devices = scan_wifi_devices()
    rec = recommend_test_strategy(devices)

    count = len(devices)
    print(f'WIFI_CARD_COUNT="{count}"')
    print(f'WIFI_RECOMMENDED_MODE="{rec["mode"]}"')

    if devices:
        first = devices[0]
        print(f'DETECTED_WIFI_IF="{first["interface"]}"')
        print(f'DETECTED_WIFI_PHY="{first["phy"]}"')
        print(f'DETECTED_WIFI_MAC="{first["mac"]}"')
        print(f'DETECTED_WIFI_SSID="{first["ssid"]}"')
        print(f'DETECTED_WIFI_BAND="{first["current_band"]}"')
        print(f'DETECTED_WIFI_SUPPORTED_BANDS="{",".join(first["supported_bands"])}"')
        print(f'DETECTED_WIFI_IP="{first.get("ip_info", {}).get("ipv4", "")}"')
        print(f'DETECTED_WIFI_GATEWAY="{first.get("ip_info", {}).get("gateway", "")}"')
        print(f'DETECTED_WIFI_IS_MLD="{1 if first["is_mld"] else 0}"')
    else:
        print('DETECTED_WIFI_IF=""')
        print('DETECTED_WIFI_PHY=""')
        print('DETECTED_WIFI_MAC=""')
        print('DETECTED_WIFI_SSID=""')
        print('DETECTED_WIFI_BAND=""')
        print('DETECTED_WIFI_SUPPORTED_BANDS=""')
        print('DETECTED_WIFI_IP=""')
        print('DETECTED_WIFI_GATEWAY=""')
        print('DETECTED_WIFI_IS_MLD="0"')

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Wireless hardware discovery & band capability analyzer."
    )
    subparsers = parser.add_subparsers(dest="subcommand")

    p_detect = subparsers.add_parser("detect", help="Output detected devices in JSON format.")
    p_detect.set_defaults(func=cmd_detect)

    p_table = subparsers.add_parser("table", help="Print formatted ASCII device summary table.")
    p_table.set_defaults(func=cmd_table)

    p_env = subparsers.add_parser("export-env", help="Export variables for shell scripts.")
    p_env.set_defaults(func=cmd_export_env)

    args = parser.parse_args()
    if not args.subcommand:
        return cmd_table(args)

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
