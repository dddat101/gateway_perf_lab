#!/usr/bin/env python3
"""
metric_parser.py - Metric Aggregator & Performance Result Analyzer

Centralized utility for parsing iperf3 JSON results, computing multi-stream
throughput summations, evaluating statistical benchmark tolerances, and
formatting structured test result artifacts for Gateway Performance Labs.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import List, Tuple


def _parse_iperf_single(file_path: str) -> Tuple[int, int, float]:
    """
    Safely extract (total_packets, lost_packets, throughput_mbps) from an iperf3 JSON file.
    Works for both TCP and UDP outputs.
    """
    p = Path(file_path)
    if not p.is_file() or p.stat().st_size == 0:
        return 0, 0, 0.0

    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        
        end_section = data.get("end", {})
        udp_sum = end_section.get("sum", {})
        rx_sum = end_section.get("sum_received", {}) or udp_sum

        lost_packets = udp_sum.get("lost_packets", 0)
        total_packets = udp_sum.get("packets", 0)
        bps = rx_sum.get("bits_per_second", 0.0)
        mbps = bps / 1e6
        return total_packets, lost_packets, mbps
    except Exception:
        return 0, 0, 0.0


def cmd_iperf_bidi(args: argparse.Namespace) -> int:
    """
    Consolidate forward (WAN->PC) and reverse (PC->WAN) iperf3 test results into
    the standard wire-rate unicast schema.
    """
    f_tot, f_lost, f_mbps = _parse_iperf_single(args.forward)
    r_tot, r_lost, r_mbps = _parse_iperf_single(args.reverse)

    tot_pkts = f_tot + r_tot
    lost_pkts = f_lost + r_lost
    avg_mbps = (f_mbps + r_mbps) / 2.0 if (f_mbps > 0 and r_mbps > 0) else max(f_mbps, r_mbps)
    loss_pct = (lost_pkts / tot_pkts * 100.0) if tot_pkts > 0 else 0.0
    status = "PASS" if loss_pct == 0.0 and tot_pkts > 1000 else "FAIL"

    res = {
        "test": "unicast_throughput",
        "engine": "iperf3_c_kernel",
        "received_packets": tot_pkts - lost_pkts,
        "throughput_mbps": round(avg_mbps, 2),
        "loss_pct": round(loss_pct, 4),
        "status": status,
        "details": {
            "forward_pkts": f_tot,
            "forward_lost": f_lost,
            "forward_mbps": round(f_mbps, 2),
            "reverse_pkts": r_tot,
            "reverse_lost": r_lost,
            "reverse_mbps": round(r_mbps, 2),
        }
    }

    output_json = json.dumps(res, indent=2)
    print(output_json)

    if args.output:
        out_p = Path(args.output)
        out_p.parent.mkdir(parents=True, exist_ok=True)
        with open(out_p, "w", encoding="utf-8") as f:
            f.write(output_json + "\n")

    return 0


def cmd_sum_mbps(args: argparse.Namespace) -> int:
    """
    Sum the received bits_per_second across one or more iperf3 JSON files
    and output the total throughput in Mbps rounded to 2 decimal places.
    """
    total_mbps = 0.0
    for path in args.files:
        _, _, mbps = _parse_iperf_single(path)
        total_mbps += mbps
    print(round(total_mbps, 2))
    return 0


def cmd_eval_simultaneous(args: argparse.Namespace) -> int:
    """
    Evaluate multi-trial simultaneous wired & wireless benchmark results.
    Computes averages for A (wireless), B (wired), C (simultaneous),
    asserts |C - B| / B <= tolerance threshold.
    """
    def parse_float_list(s: str) -> List[float]:
        normalized = s.replace(",", " ")
        return [float(x) for x in normalized.split() if x.strip()]

    a_list = parse_float_list(args.trials_a)
    b_list = parse_float_list(args.trials_b)
    c_list = parse_float_list(args.trials_c)
    tol = float(args.tolerance)

    avg_a = sum(a_list) / len(a_list) if a_list else 0.0
    avg_b = sum(b_list) / len(b_list) if b_list else 0.0
    avg_c = sum(c_list) / len(c_list) if c_list else 0.0

    # In 1 Gbps bottleneck environments: C should not fall below B by more than tolerance %
    diff_pct = ((avg_b - avg_c) / avg_b * 100.0) if avg_b > 0 else 0.0
    abs_diff_pct = (abs(avg_c - avg_b) / avg_b * 100.0) if avg_b > 0 else 0.0
    verdict = "PASS" if diff_pct <= tol else "FAIL"

    result = {
        "test": "simultaneous_wired_wireless",
        "mode": getattr(args, "mode", "auto"),
        "wifi_device": getattr(args, "wifi_if", ""),
        "wifi_band": getattr(args, "wifi_band", ""),
        "wifi_ssid": getattr(args, "wifi_ssid", ""),
        "trials": len(a_list),
        "avg_wireless_only_mbps": round(avg_a, 2),
        "avg_wired_only_mbps": round(avg_b, 2),
        "avg_simultaneous_mbps": round(avg_c, 2),
        "wireless_only_avg_mbps": round(avg_a, 2),
        "wired_only_avg_mbps": round(avg_b, 2),
        "simultaneous_sum_avg_mbps": round(avg_c, 2),
        "degradation_pct": round(max(0.0, diff_pct), 3),
        "diff_percentage": round(abs_diff_pct, 3),
        "abs_diff_percentage": round(abs_diff_pct, 3),
        "tolerance_threshold_pct": tol,
        "verdict": verdict,
        "raw_trials": {
            "wireless_only_a": a_list,
            "wired_only_b": b_list,
            "simultaneous_c": c_list,
        }
    }

    if getattr(args, "trials_c_wired", None):
        result["raw_trials"]["simultaneous_c_wired_distribution"] = parse_float_list(args.trials_c_wired)
    if getattr(args, "trials_c_wifi", None):
        result["raw_trials"]["simultaneous_c_wifi_distribution"] = parse_float_list(args.trials_c_wifi)

    output_json = json.dumps(result, indent=2)
    print(output_json)

    if args.output:
        out_p = Path(args.output)
        out_p.parent.mkdir(parents=True, exist_ok=True)
        with open(out_p, "w", encoding="utf-8") as f:
            f.write(output_json + "\n")

    return 0


def cmd_eval_qos(args: argparse.Namespace) -> int:
    """
    Evaluate PC throughput degradation during concurrent VoIP calls.
    Asserts |A - B| / A <= tolerance threshold.
    """
    a = float(args.baseline)
    b = float(args.during)
    tol = float(args.tolerance)

    diff_pct = (abs(a - b) / a * 100.0) if a > 0 else 0.0
    verdict = "PASS" if diff_pct <= tol else "FAIL"

    result = {
        "test": "pc_throughput_during_voip_calls",
        "mode": getattr(args, "mode", "auto"),
        "engine": getattr(args, "engine", "auto"),
        "wifi_device": getattr(args, "wifi_if", ""),
        "wifi_ssid": getattr(args, "wifi_ssid", ""),
        "active_calls": getattr(args, "calls", 2),
        "pc_baseline_mbps": round(a, 2),
        "pc_during_calls_mbps": round(b, 2),
        "diff_percentage": round(diff_pct, 3),
        "tolerance_threshold_pct": tol,
        "verdict": verdict
    }

    output_json = json.dumps(result, indent=2)
    print(output_json)

    if args.output:
        out_p = Path(args.output)
        out_p.parent.mkdir(parents=True, exist_ok=True)
        with open(out_p, "w", encoding="utf-8") as f:
            f.write(output_json + "\n")

    return 0


def cmd_eval_sequential(args: argparse.Namespace) -> int:
    """
    Consolidate and evaluate multi-band sequential simultaneous benchmarks.
    Asserts degradation <= tolerance across all tested bands.
    """
    files = args.files
    bands_data = {}
    summary_rows = []
    overall_pass = True
    tol = float(args.tolerance)

    for f_path in files:
        p = Path(f_path)
        if not p.is_file():
            continue
        try:
            with open(p, "r", encoding="utf-8") as f:
                data = json.load(f)
            band = data.get("wifi_band", "Unknown")
            ssid = data.get("wifi_ssid", "DUT")
            w_only = data.get("avg_wireless_only_mbps", 0.0)
            wired_only = data.get("avg_wired_only_mbps", 0.0)
            sim_sum = data.get("avg_simultaneous_mbps", 0.0)
            degr = data.get("degradation_pct", 0.0)
            verdict = data.get("verdict", "FAIL")

            if verdict != "PASS":
                overall_pass = False

            bands_data[band] = data
            summary_rows.append({
                "band": band,
                "ssid": ssid,
                "wired_only_mbps": wired_only,
                "wireless_only_mbps": w_only,
                "simultaneous_mbps": sim_sum,
                "degradation_pct": degr,
                "verdict": verdict
            })
        except Exception as e:
            print(f"[WARN] Failed to parse {f_path}: {e}", file=sys.stderr)

    overall_verdict = "PASS" if overall_pass and len(summary_rows) > 0 else "FAIL"

    # Backward compatibility with single-band parsers (e.g. verify_compliance.sh)
    last_dev = list(bands_data.values())[0].get("wifi_device", "") if bands_data else ""
    max_degr = max([r["degradation_pct"] for r in summary_rows]) if summary_rows else 0.0
    avg_wired = round(sum(r["wired_only_mbps"] for r in summary_rows) / len(summary_rows), 2) if summary_rows else 0.0
    avg_sim = round(sum(r["simultaneous_mbps"] for r in summary_rows) / len(summary_rows), 2) if summary_rows else 0.0

    result = {
        "test": "simultaneous_sequential_multiband",
        "mode": "sequential_multi_band",
        "verdict": overall_verdict,
        "overall_verdict": overall_verdict,
        "tolerance_threshold_pct": tol,
        "diff_percentage": max_degr,
        "degradation_pct": max_degr,
        "wired_only_avg_mbps": avg_wired,
        "simultaneous_sum_avg_mbps": avg_sim,
        "wifi_device": last_dev,
        "wifi_band": "+".join(r["band"] for r in summary_rows),
        "wifi_ssid": "+".join(r["ssid"] for r in summary_rows),
        "bands_tested": [r["band"] for r in summary_rows],
        "bands": bands_data,
        "summary_table": summary_rows
    }

    # Print clean summary table
    print("=" * 86)
    print("  SEQUENTIAL MULTI-BAND BENCHMARK SUMMARY (TC-SIM-01)")
    print("=" * 86)
    print(f"{'Band':<10} {'SSID':<18} {'Wired Only':<14} {'Wireless Only':<15} {'Simultaneous':<16} {'Degradation':<12} {'Verdict'}")
    print("-" * 86)
    for r in summary_rows:
        w_str = f"{r['wired_only_mbps']:.2f} Mbps"
        wl_str = f"{r['wireless_only_mbps']:.2f} Mbps"
        s_str = f"{r['simultaneous_mbps']:.2f} Mbps"
        d_str = f"{r['degradation_pct']:.2f}%"
        v_col = f"\033[1;32m{r['verdict']}\033[0m" if r["verdict"] == "PASS" else f"\033[1;31m{r['verdict']}\033[0m"
        print(f"{r['band']:<10} {r['ssid']:<18} {w_str:<14} {wl_str:<15} {s_str:<16} {d_str:<12} {v_col}")
    print("=" * 86)
    res_col = f"\033[1;32m{overall_verdict}\033[0m" if overall_verdict == "PASS" else f"\033[1;31m{overall_verdict}\033[0m"
    print(f"  OVERALL MULTI-BAND VERDICT : {res_col} (Wired degradation <= {tol}% across all bands)")
    print("=" * 86)

    output_json = json.dumps(result, indent=2)
    if args.output:
        out_p = Path(args.output)
        out_p.parent.mkdir(parents=True, exist_ok=True)
        with open(out_p, "w", encoding="utf-8") as f:
            f.write(output_json + "\n")

    return 0


def cmd_get_field(args: argparse.Namespace) -> int:
    """
    Safely extract a specific field value from a JSON file.
    """
    p = Path(args.file)
    if not p.is_file():
        print(args.default)
        return 0

    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        val = data.get(args.field, args.default)
        print(val)
    except Exception:
        print(args.default)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Metric aggregator and performance result analyzer for network test labs."
    )
    subparsers = parser.add_subparsers(dest="subcommand", required=True)

    # 1. consolidate-iperf-bidi
    p_bidi = subparsers.add_parser("consolidate-iperf-bidi", help="Consolidate forward + reverse iperf3 UDP runs.")
    p_bidi.add_argument("--forward", "-f", required=True, help="Path to forward iperf3 JSON.")
    p_bidi.add_argument("--reverse", "-r", required=True, help="Path to reverse iperf3 JSON.")
    p_bidi.add_argument("--output", "-o", help="Optional path to output consolidated JSON.")
    p_bidi.set_defaults(func=cmd_iperf_bidi)

    # 2. sum-mbps
    p_sum = subparsers.add_parser("sum-mbps", help="Sum throughput across multiple iperf3 JSON files.")
    p_sum.add_argument("files", nargs="+", help="One or more iperf3 JSON files to sum.")
    p_sum.set_defaults(func=cmd_sum_mbps)

    # 3. eval-simultaneous
    p_sim = subparsers.add_parser("eval-simultaneous", help="Evaluate simultaneous wired + wireless benchmark trials.")
    p_sim.add_argument("--trials-a", required=True, help="Comma-separated wireless-only speeds.")
    p_sim.add_argument("--trials-b", required=True, help="Comma-separated wired-only speeds.")
    p_sim.add_argument("--trials-c", required=True, help="Comma-separated simultaneous speeds.")
    p_sim.add_argument("--trials-c-wired", help="Optional comma-separated wired speeds during simultaneous test.")
    p_sim.add_argument("--trials-c-wifi", help="Optional comma-separated wifi speeds during simultaneous test.")
    p_sim.add_argument("--mode", default="auto", help="Execution mode (real_single_band, hybrid, emulated).")
    p_sim.add_argument("--wifi-if", default="", help="Wi-Fi interface used.")
    p_sim.add_argument("--wifi-band", default="", help="Wi-Fi frequency band used (e.g. 5GHz).")
    p_sim.add_argument("--wifi-ssid", default="", help="Target SSID connected.")
    p_sim.add_argument("--tolerance", default=1.0, type=float, help="Max allowed percent difference (default: 1.0).")
    p_sim.add_argument("--output", "-o", help="Optional path to output evaluation JSON.")
    p_sim.set_defaults(func=cmd_eval_simultaneous)

    # 4. eval-sequential
    p_seq = subparsers.add_parser("eval-sequential", help="Consolidate and evaluate multi-band sequential benchmark results.")
    p_seq.add_argument("files", nargs="+", help="One or more band-specific simultaneous benchmark JSON files.")
    p_seq.add_argument("--tolerance", default=1.0, type=float, help="Max allowed degradation percent (default: 1.0).")
    p_seq.add_argument("--output", "-o", help="Optional path to output consolidated multi-band evaluation JSON.")
    p_seq.set_defaults(func=cmd_eval_sequential)

    # 5. eval-qos
    p_qos = subparsers.add_parser("eval-qos", help="Evaluate VoIP QoS impact on PC throughput.")
    p_qos.add_argument("--baseline", "-a", required=True, type=float, help="Baseline PC throughput in Mbps.")
    p_qos.add_argument("--during", "-b", required=True, type=float, help="PC throughput during VoIP calls in Mbps.")
    p_qos.add_argument("--mode", default="auto", help="Topology mode (physical_single_station, distributed_remote_station, virtual_netns).")
    p_qos.add_argument("--engine", default="auto", help="VoIP engine used (pjsua, sipp, python).")
    p_qos.add_argument("--wifi-if", default="", help="Wi-Fi interface used.")
    p_qos.add_argument("--wifi-ssid", default="", help="Connected Wi-Fi SSID.")
    p_qos.add_argument("--calls", default=2, type=int, help="Number of concurrent calls.")
    p_qos.add_argument("--tolerance", default=1.0, type=float, help="Max allowed degradation percent (default: 1.0).")
    p_qos.add_argument("--output", "-o", help="Optional path to output evaluation JSON.")
    p_qos.set_defaults(func=cmd_eval_qos)

    # 6. get-field
    p_get = subparsers.add_parser("get-field", help="Extract a single field from a JSON file.")
    p_get.add_argument("--file", "-f", required=True, help="Path to JSON file.")
    p_get.add_argument("--field", "-k", required=True, help="Field key to extract.")
    p_get.add_argument("--default", "-d", default="MISSING", help="Default value if missing.")
    p_get.set_defaults(func=cmd_get_field)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
