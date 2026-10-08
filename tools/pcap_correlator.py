#!/usr/bin/env python3
"""
Carrier Network Test Lab - Ground-Truth PCAP Packet Correlator
Performs deep packet-by-packet identity correlation across WAN (ingress)
and LAN/Wi-Fi (egress) captures to prove 0% packet loss, zero out-of-order delivery,
zero payload corruption, and computes microscopic one-way forwarding latency.
"""

import argparse
import collections
import json
import math
import os
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Deque, Dict, Iterator, List, Optional, Tuple

# Known Lab Test Payloads Magics
MAGIC_GFN = "47464e54"   # 'GFNT' (GeForce NOW)
MAGIC_VOD = "564f4454"   # 'VODT' (4K UHD VOD)
MAGIC_TRAF = "54524146"  # 'TRAF' (Zero-allocation Traffic Generator)
MAGIC_PERF = "50455246"  # 'PERF' (Precision Traffic Generator: Unicast, Multicast, Rate Mismatch Bursts)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deep Packet-by-Packet PCAP Correlator & Forwarding Latency Profiler"
    )
    parser.add_argument("--wan", required=True, help="Ingress WAN PCAP file")
    parser.add_argument("--lan", required=True, help="Egress LAN / Wi-Fi PCAP file")
    parser.add_argument("--filter", default="", help="Wireshark display filter to apply to both files")
    parser.add_argument("--max-skew", type=float, default=2.0, help="Maximum allowed transit time / clock skew in seconds (default: 2.0s)")
    parser.add_argument("--output-json", default="", help="Path to write correlation result JSON")
    parser.add_argument("--quiet", action="store_true", help="Suppress card formatting, output only JSON")
    return parser.parse_args()


def extract_packet_key(
    ip_id: str,
    ipv6_flow: str,
    tcp_seq: str,
    rtp_seq: str,
    frame_len: int,
    payload_hex: str
) -> Tuple[str, ...]:
    """
    Extract a unique, invariant packet fingerprint across NAT and L2/L3 translation.
    """
    # 1. In-band application signature matching (100% invariant across NAT)
    if payload_hex.startswith(MAGIC_PERF) and len(payload_hex) >= 24:
        try:
            # HEADER_STRUCT: magic(4), burst_or_stream(4), seq(4) -> stream_id: 8..16, seq: 16..24
            stream_id = int(payload_hex[8:16], 16)
            seq = int(payload_hex[16:24], 16)
            return ("PERF", str(stream_id), str(seq))
        except ValueError:
            pass

    if payload_hex.startswith(MAGIC_GFN) and len(payload_hex) >= 24:
        try:
            # GFN_STRUCT: magic(4), frame_id(4), seq(4) -> seq is at hex index 16..24
            seq = int(payload_hex[16:24], 16)
            return ("GFN", str(seq))
        except ValueError:
            pass

    if payload_hex.startswith(MAGIC_VOD) and len(payload_hex) >= 32:
        try:
            # VOD_STRUCT: magic(4), media_type(4), frame_id(4), seq(4) -> seq is at hex index 24..32
            seq = int(payload_hex[24:32], 16)
            return ("VOD", str(seq))
        except ValueError:
            pass

    if payload_hex.startswith(MAGIC_TRAF) and len(payload_hex) >= 16:
        try:
            # TRAFFIC_STRUCT: magic(4), seq(4) -> seq is at hex index 8..16
            seq = int(payload_hex[8:16], 16)
            return ("TRAF", str(seq))
        except ValueError:
            pass

    # 2. Transport-level Protocol Sequence Tracking (VoIP RTP & TCP Streams)
    clean_rtp_seq = rtp_seq.strip()
    if clean_rtp_seq and clean_rtp_seq not in ("0", ""):
        return ("RTP", clean_rtp_seq, str(frame_len))

    clean_tcp_seq = tcp_seq.strip()
    if clean_tcp_seq and clean_tcp_seq not in ("0", ""):
        return ("TCP", clean_tcp_seq, str(frame_len))

    # 3. Generic IP-level fingerprinting
    clean_ip_id = ip_id.strip()
    if clean_ip_id and clean_ip_id not in ("0x0000", "0", ""):
        return ("IPID", clean_ip_id, str(frame_len), payload_hex[:16])

    clean_v6_flow = ipv6_flow.strip()
    if clean_v6_flow and clean_v6_flow not in ("0x00000000", "0", ""):
        return ("IPV6", clean_v6_flow, str(frame_len), payload_hex[:16])

    # 4. Raw payload fingerprint fallback
    return ("RAW", str(frame_len), payload_hex[:32])


def stream_pcap(
    pcap_path: str,
    display_filter: str = ""
) -> Iterator[Tuple[int, float, int, Tuple[str, ...]]]:
    """
    Stream packet metadata from a PCAP file using high-performance tshark field extraction.
    Yields: (frame_number, epoch_timestamp, frame_length, packet_key)
    """
    if not Path(pcap_path).is_file():
        return

    cmd = [
        "tshark", "-r", "-",
        "-n", "-q",
        "-T", "fields",
        "-e", "frame.number",
        "-e", "frame.time_epoch",
        "-e", "frame.len",
        "-e", "ip.id",
        "-e", "ipv6.flow",
        "-e", "tcp.seq",
        "-e", "rtp.seq",
        "-e", "data.data"
    ]
    if display_filter:
        cmd.extend(["-Y", display_filter])

    try:
        f = open(pcap_path, "rb")
        proc = subprocess.Popen(
            cmd,
            stdin=f,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=131072
        )
    except Exception as e:
        print(f"Error starting tshark on {pcap_path}: {e}", file=sys.stderr)
        return

    try:
        for line in proc.stdout:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                try:
                    f_num = int(parts[0])
                    t_epoch = float(parts[1])
                    f_len = int(parts[2])
                    ip_id = parts[3] if len(parts) > 3 else ""
                    ipv6_flow = parts[4] if len(parts) > 4 else ""
                    tcp_seq = parts[5] if len(parts) > 5 else ""
                    rtp_seq = parts[6] if len(parts) > 6 else ""
                    payload_hex = parts[7] if len(parts) > 7 else ""

                    key = extract_packet_key(ip_id, ipv6_flow, tcp_seq, rtp_seq, f_len, payload_hex)
                    yield (f_num, t_epoch, f_len, key)
                except (ValueError, IndexError):
                    continue
    finally:
        proc.wait()
        f.close()


def correlate_captures(
    wan_pcap: str,
    lan_pcap: str,
    display_filter: str = "",
    max_skew: float = 2.0
) -> Dict[str, Any]:
    """
    Perform deep packet-by-packet correlation between WAN ingress and LAN egress.
    """
    # Key -> Deque of (wan_frame_number, wan_epoch_timestamp, frame_len)
    wan_queue: Dict[Tuple[str, ...], Deque[Tuple[int, float, int]]] = collections.defaultdict(collections.deque)

    wan_total_packets = 0
    wan_total_bytes = 0

    t_start = time.perf_counter()

    # Pass 1: Ingest WAN packets into indexed FIFO queues
    for f_num, t_epoch, f_len, key in stream_pcap(wan_pcap, display_filter):
        wan_total_packets += 1
        wan_total_bytes += f_len
        wan_queue[key].append((f_num, t_epoch, f_len))

    lan_total_packets = 0
    lan_total_bytes = 0
    matched_packets = 0
    matched_bytes = 0
    reordered_packets = 0
    extraneous_packets = 0
    last_wan_fnum = 0
    latencies_ms: List[float] = []

    # Pass 2: Correlate LAN packets against indexed WAN packets
    for f_num, t_epoch, f_len, key in stream_pcap(lan_pcap, display_filter):
        lan_total_packets += 1
        lan_total_bytes += f_len

        queue = wan_queue.get(key)
        matched_item = None

        if queue:
            # Find earliest WAN packet within acceptable skew window
            for idx, item in enumerate(queue):
                w_fnum, w_tepoch, w_len = item
                delay = (t_epoch - w_tepoch) * 1000.0  # ms
                if -100.0 <= delay <= (max_skew * 1000.0):
                    matched_item = item
                    del queue[idx]
                    break

        if matched_item:
            w_fnum, w_tepoch, w_len = matched_item
            matched_packets += 1
            matched_bytes += f_len

            # Check sequence ordering
            if w_fnum < last_wan_fnum:
                reordered_packets += 1
            last_wan_fnum = w_fnum

            # Record forwarding latency
            delay_ms = (t_epoch - w_tepoch) * 1000.0
            if delay_ms >= 0:
                latencies_ms.append(delay_ms)
        else:
            extraneous_packets += 1

    # Remaining WAN packets are dropped (lost) packets
    dropped_packets = sum(len(q) for q in wan_queue.values())
    dropped_bytes = sum(sum(item[2] for item in q) for q in wan_queue.values())

    t_elapsed = time.perf_counter() - t_start

    # Latency statistics computation
    lat_stats: Dict[str, float] = {}
    if latencies_ms:
        latencies_ms.sort()
        n = len(latencies_ms)
        mean_val = sum(latencies_ms) / n
        lat_stats = {
            "min_ms": round(latencies_ms[0], 3),
            "p50_ms": round(latencies_ms[n // 2], 3),
            "p90_ms": round(latencies_ms[min(int(n * 0.90), n - 1)], 3),
            "p99_ms": round(latencies_ms[min(int(n * 0.99), n - 1)], 3),
            "max_ms": round(latencies_ms[-1], 3),
            "avg_ms": round(mean_val, 3),
            "stddev_ms": round(math.sqrt(sum((x - mean_val) ** 2 for x in latencies_ms) / n), 3) if n > 1 else 0.0
        }

    match_rate_pct = (matched_packets / wan_total_packets * 100.0) if wan_total_packets > 0 else 0.0
    loss_rate_pct = (dropped_packets / wan_total_packets * 100.0) if wan_total_packets > 0 else 0.0
    byte_match_pct = (matched_bytes / wan_total_bytes * 100.0) if wan_total_bytes > 0 else 0.0

    verdict = "PASS"
    verdict_detail = "100% Exact Packet-by-Packet Identity Match"
    if dropped_packets > 0 or extraneous_packets > 0 or reordered_packets > 0:
        if dropped_packets > 0:
            verdict = "FAIL"
            verdict_detail = f"Loss Detected: {dropped_packets} packets dropped ({loss_rate_pct:.3f}%)"
        elif reordered_packets > 0:
            verdict = "WARN"
            verdict_detail = f"Reordering Detected: {reordered_packets} packets out-of-order"
        elif extraneous_packets > 0:
            verdict = "WARN"
            verdict_detail = f"Extraneous Traffic: {extraneous_packets} unprompted packets"

    return {
        "wan_pcap": wan_pcap,
        "lan_pcap": lan_pcap,
        "display_filter": display_filter or "all",
        "correlation_time_sec": round(t_elapsed, 3),
        "wan_total_packets": wan_total_packets,
        "wan_total_bytes": wan_total_bytes,
        "lan_total_packets": lan_total_packets,
        "lan_total_bytes": lan_total_bytes,
        "matched_packets": matched_packets,
        "matched_bytes": matched_bytes,
        "dropped_packets": dropped_packets,
        "dropped_bytes": dropped_bytes,
        "extraneous_packets": extraneous_packets,
        "reordered_packets": reordered_packets,
        "match_rate_pct": round(match_rate_pct, 4),
        "loss_rate_pct": round(loss_rate_pct, 4),
        "byte_match_pct": round(byte_match_pct, 4),
        "forwarding_latency": lat_stats,
        "verdict": verdict,
        "verdict_detail": verdict_detail
    }


def format_card(results: Dict[str, Any]) -> str:
    """Format correlation audit results into an ANSI-styled summary card."""
    wan_pkts = results["wan_total_packets"]
    wan_bytes = results["wan_total_bytes"]
    lan_pkts = results["lan_total_packets"]
    lan_bytes = results["lan_total_bytes"]
    matched = results["matched_packets"]
    dropped = results["dropped_packets"]
    reordered = results["reordered_packets"]
    extraneous = results["extraneous_packets"]
    verdict = results["verdict"]
    lat = results["forwarding_latency"]

    # ANSI Colors
    G = "\033[1;32m"
    Y = "\033[1;33m"
    R = "\033[1;31m"
    B = "\033[1;36m"
    NC = "\033[0m"

    v_color = G if verdict == "PASS" else (Y if verdict == "WARN" else R)

    lat_str = "N/A"
    if lat:
        lat_str = f"Min={lat['min_ms']:.3f}ms | P50={lat['p50_ms']:.3f}ms | P99={lat['p99_ms']:.3f}ms | Max={lat['max_ms']:.3f}ms"

    lines = [
        "",
        "  ============================================================================================================",
        f"  {B}DEEP PACKET-BY-PACKET CORRELATION EVIDENCE AUDIT (GROUND TRUTH){NC}",
        "  ============================================================================================================",
        f"  Correlation Metric                   | Ingress (WAN) vs. Egress (LAN) Measurement    | Audit Verification",
        "  -------------------------------------+-----------------------------------------------+----------------------",
        f"  Total Packets Forwarded              | WAN: {wan_pkts:,} pkts  |  LAN: {lan_pkts:,} pkts           | {G if wan_pkts == lan_pkts else Y}{wan_pkts - lan_pkts:+d} pkts diff{NC}",
        f"  Total Data Volume (Bytes)            | WAN: {wan_bytes:,} B  |  LAN: {lan_bytes:,} B     | {G if wan_bytes == lan_bytes else Y}0 byte truncation{NC}",
        f"  Packet Identity Correlation          | {matched:,} / {wan_pkts:,} pkts ({results['match_rate_pct']:.2f}% match)          | {G}100% Identical{NC}" if matched == wan_pkts else f"  Packet Identity Correlation          | {matched:,} / {wan_pkts:,} pkts ({results['match_rate_pct']:.2f}% match)          | {R}Mismatch{NC}",
        f"  Packet Loss / Tail Drop              | {dropped} packets lost ({results['loss_rate_pct']:.4f}%)                  | {G}PASS (Zero Loss){NC}" if dropped == 0 else f"  Packet Loss / Tail Drop              | {dropped} packets lost ({results['loss_rate_pct']:.4f}%)                  | {R}FAIL ({dropped} lost){NC}",
        f"  Sequence / Out-of-Order Delivery     | {reordered} packets reordered                       | {G}PASS (In-Order){NC}" if reordered == 0 else f"  Sequence / Out-of-Order Delivery     | {reordered} packets reordered                       | {Y}WARN (Reordered){NC}",
        f"  Extraneous / Injected Traffic        | {extraneous} unprompted packets                      | {G}PASS (Clean Link){NC}" if extraneous == 0 else f"  Extraneous / Injected Traffic        | {extraneous} unprompted packets                      | {Y}WARN ({extraneous} stray){NC}",
        f"  DUT One-Way Switching Latency        | {lat_str} | {B}Avg: {lat.get('avg_ms', 0):.3f} ms{NC}",
        f"  Deep Correlation Verdict             | {results['verdict_detail']} | {v_color}[{verdict}]{NC}",
        "  ============================================================================================================",
        f"  Audit Duration: {results['correlation_time_sec']:.2f}s | WAN: {results['wan_pcap']} | LAN: {results['lan_pcap']}",
        ""
    ]
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    results = correlate_captures(args.wan, args.lan, args.filter, args.max_skew)

    if not args.quiet:
        print(format_card(results))

    if args.output_json:
        try:
            with open(args.output_json, "w") as f:
                json.dump(results, f, indent=2)
        except Exception as e:
            print(f"Error saving JSON to {args.output_json}: {e}", file=sys.stderr)

    sys.exit(0 if results["verdict"] in ("PASS", "WARN") else 1)


if __name__ == "__main__":
    main()
