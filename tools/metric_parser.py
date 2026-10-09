#!/usr/bin/env python3
"""
metric_parser.py - Metric Aggregator & Performance Result Analyzer

Thin backward-compatible adapter delegating to deep domain service
tools/benchmark_evaluator.py. Preserves all 8 canonical CLI subcommands.
"""

import argparse
from pathlib import Path
import sys
from typing import Any, Dict, List, Tuple

try:
    from benchmark_evaluator import (
        BenchmarkEvaluator,
        BenchmarkVerdict,
        EvaluationResult,
        IperfTelemetryReader,
        TableRenderer,
    )
except ImportError:
    from tools.benchmark_evaluator import (
        BenchmarkEvaluator,
        BenchmarkVerdict,
        EvaluationResult,
        IperfTelemetryReader,
        TableRenderer,
    )


def _parse_iperf_single(file_path: str) -> Tuple[int, int, float]:
    """Preserved for backward-compatible module imports."""
    return IperfTelemetryReader.parse_single(file_path)


def cmd_iperf_bidi(args: argparse.Namespace) -> int:
    res = BenchmarkEvaluator.evaluate_unicast(
        forward_path=args.forward,
        reverse_path=args.reverse,
        mode=getattr(args, "mode", "sequential"),
        output_file=args.output,
        as_json=getattr(args, "json", False)
    )
    if getattr(args, "json", False):
        print(res.to_json())
    else:
        print(res.rendered_table)
    return res.exit_code


def cmd_sum_mbps(args: argparse.Namespace) -> int:
    mbps = IperfTelemetryReader.sum_mbps(args.files)
    print(mbps)
    return 0


def cmd_eval_simultaneous(args: argparse.Namespace) -> int:
    res = BenchmarkEvaluator.evaluate_simultaneous(
        trials_a=args.trials_a,
        trials_b=args.trials_b,
        trials_c=args.trials_c,
        trials_c_wired=getattr(args, "trials_c_wired", None),
        trials_c_wifi=getattr(args, "trials_c_wifi", None),
        mode=getattr(args, "mode", "auto"),
        wifi_if=getattr(args, "wifi_if", ""),
        wifi_band=getattr(args, "wifi_band", ""),
        wifi_ssid=getattr(args, "wifi_ssid", ""),
        tolerance=float(args.tolerance),
        output_file=args.output,
        as_json=getattr(args, "json", False)
    )
    if getattr(args, "json", False):
        print(res.to_json())
    else:
        print(res.rendered_table)
    return res.exit_code


def cmd_eval_sequential(args: argparse.Namespace) -> int:
    res = BenchmarkEvaluator.evaluate_sequential(
        files=args.files,
        tolerance=float(args.tolerance),
        output_file=args.output
    )
    print(res.rendered_table)
    return res.exit_code


def cmd_eval_qos(args: argparse.Namespace) -> int:
    res = BenchmarkEvaluator.evaluate_qos(
        baseline_mbps=float(args.baseline),
        during_mbps=float(args.during),
        tolerance=float(args.tolerance),
        calls_expected=getattr(args, "calls", 2),
        calls_verified=getattr(args, "verified_calls", getattr(args, "calls", 2)),
        mode=getattr(args, "mode", "auto"),
        engine=getattr(args, "engine", "auto"),
        wifi_if=getattr(args, "wifi_if", ""),
        wifi_ssid=getattr(args, "wifi_ssid", ""),
        output_file=args.output,
        as_json=getattr(args, "json", False)
    )
    if getattr(args, "json", False):
        print(res.to_json())
    else:
        print(res.rendered_table)
    return res.exit_code


def cmd_get_field(args: argparse.Namespace) -> int:
    val = BenchmarkEvaluator.get_field(args.file, args.field, args.default)
    print(val)
    return 0


def cmd_format_card(args: argparse.Namespace) -> int:
    rendered = BenchmarkEvaluator.format_card(args.file, as_json=getattr(args, "json", False))
    print(rendered)
    return 0


def cmd_eval_wireless_qos(args: argparse.Namespace) -> int:
    res = BenchmarkEvaluator.evaluate_wireless_qos(
        voice_json=args.voice_json,
        vod_json=args.vod_json,
        be_json=args.be_json,
        be_mbps=args.be_mbps,
        be_proto=getattr(args, "be_proto", "auto"),
        mode=getattr(args, "mode", "virtual"),
        voice_dscp=args.voice_dscp,
        video_dscp=args.video_dscp,
        max_loss_pct=args.max_loss_pct,
        traffic_error=getattr(args, "traffic_error", ""),
        output_file=args.output,
        quiet=getattr(args, "quiet", False)
    )
    if not getattr(args, "quiet", False):
        print(res.rendered_table)
    return res.exit_code


def cmd_get_metrics(args: argparse.Namespace) -> int:
    """Batch query multiple metrics in a single pass."""
    res = BenchmarkEvaluator.query_metrics(args.file, args.fields, args.default)
    print(" ".join(str(res[f]) for f in args.fields))
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
    p_bidi.add_argument("--mode", "-m", default="sequential", choices=["sequential", "concurrent"], help="Bidirectional test mode.")
    p_bidi.add_argument("--output", "-o", help="Optional path to output consolidated JSON.")
    p_bidi.add_argument("--json", action="store_true", help="Output raw JSON instead of formatted table.")
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
    p_sim.add_argument("--json", action="store_true", help="Output raw JSON instead of formatted table.")
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
    p_qos.add_argument("--verified-calls", default=2, type=int, help="Number of verified active calls during test.")
    p_qos.add_argument("--tolerance", default=1.0, type=float, help="Max allowed degradation percent (default: 1.0).")
    p_qos.add_argument("--output", "-o", help="Optional path to output evaluation JSON.")
    p_qos.add_argument("--json", action="store_true", help="Output raw JSON instead of formatted table.")
    p_qos.set_defaults(func=cmd_eval_qos)

    # 6. get-field
    p_get = subparsers.add_parser("get-field", help="Extract a single field from a JSON file.")
    p_get.add_argument("--file", "-f", required=True, help="Path to JSON file.")
    p_get.add_argument("--field", "-k", required=True, help="Field key to extract.")
    p_get.add_argument("--default", "-d", default="MISSING", help="Default value if missing.")
    p_get.set_defaults(func=cmd_get_field)

    # 7. format-card
    p_card = subparsers.add_parser("format-card", help="Format and display test result JSON as a clean summary card.")
    p_card.add_argument("file", help="Path to JSON test result file.")
    p_card.add_argument("--json", action="store_true", help="Output raw JSON instead of formatted card.")
    p_card.set_defaults(func=cmd_format_card)

    # 8. eval-wireless-qos
    p_wqos = subparsers.add_parser("eval-wireless-qos", help="Evaluate Wireless QoS client-side metrics.")
    p_wqos.add_argument("--voice-json", help="Path to VoIP client JSON result.")
    p_wqos.add_argument("--vod-json", help="Path to VOD client JSON result.")
    p_wqos.add_argument("--be-json", help="Path to Best Effort iperf3 JSON result.")
    p_wqos.add_argument("--be-proto", default="auto", choices=["auto", "tcp", "udp"], help="Best Effort transport protocol.")
    p_wqos.add_argument("--be-mbps", type=float, default=0.0, help="Best Effort throughput in Mbps.")
    p_wqos.add_argument("--mode", default="virtual", help="Test execution mode.")
    p_wqos.add_argument("--voice-dscp", type=int, default=46, help="Target DSCP for Voice.")
    p_wqos.add_argument("--video-dscp", type=int, default=34, help="Target DSCP for Video.")
    p_wqos.add_argument("--max-loss-pct", type=float, default=1.0, help="Max loss percentage for priority services.")
    p_wqos.add_argument("--output", "-o", help="Path to output wireless_qos_audit.json.")
    p_wqos.add_argument("--quiet", action="store_true", help="Suppress terminal output.")
    p_wqos.add_argument("--traffic-error", default="", help="Generator startup or execution failure.")
    p_wqos.set_defaults(func=cmd_eval_wireless_qos)

    # 9. get-metrics (Batch query helper)
    p_m = subparsers.add_parser("get-metrics", help="Batch extract multiple fields from a JSON file.")
    p_m.add_argument("--file", "-f", required=True, help="Path to JSON file.")
    p_m.add_argument("fields", nargs="+", help="Fields to extract.")
    p_m.add_argument("--default", "-d", default="MISSING", help="Default fallback value.")
    p_m.set_defaults(func=cmd_get_metrics)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
