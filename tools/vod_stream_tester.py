#!/usr/bin/env python3
"""
Carrier Network Test Lab - UHD+Dolby 1.2x VOD Playback Tester (Optimized)
Emulates high-bitrate 4K UHD + Dolby Atmos/Vision VOD streaming accelerated at 1.2x speed.
Optimized with zero-allocation buffers, connected UDP sockets, batched timer pacing,
and O(1) buffer stall & packet loss tracking.
"""

import sys
import os
import time
import socket
import struct
import json
import argparse

VOD_MAGIC = 0x55484456  # "UHDV"
VOD_STRUCT = struct.Struct("!IIId")  # 20 bytes: magic(4), stream_id(4), seq(4), send_ts(8)

# NAT Hole Punching Handshake constants
VOD_HANDSHAKE_ID = 0xFFFFFFFF
VOD_HANDSHAKE_PROBE = 0x01
VOD_HANDSHAKE_ACK   = 0x02

def parse_args():
    parser = argparse.ArgumentParser(description="UHD+Dolby VOD 1.2x Stream Tester (Optimized)")
    subparsers = parser.add_subparsers(dest="mode", required=True)

    # Server mode
    srv = subparsers.add_parser("server", help="Run VOD Video Streaming Server")
    srv.add_argument("--dest-ip", required=True, help="STB Client IP address")
    srv.add_argument("--dest-port", type=int, default=5005, help="STB Client UDP port")
    srv.add_argument("--duration", type=float, default=5.0, help="Test duration in seconds")
    srv.add_argument("--base-bitrate-mbps", type=float, default=35.0, help="Base UHD 4K bitrate (Mbps)")
    srv.add_argument("--playback-speed", type=float, default=1.2, help="Playback speed multiplier (e.g. 1.2)")
    srv.add_argument("--wait-handshake", action="store_true", help="Wait for client NAT hole punching probe before streaming")
    srv.add_argument("--handshake-timeout", type=float, default=5.0, help="Seconds to wait for client probe (default: 5.0)")
    srv.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP for handshake listening")
    srv.add_argument("--bind-port", type=int, default=0, help="Binding port for handshake listening (default: same as dest-port)")
    srv.add_argument("--report-interval", type=float, default=1.0, help="Periodic progress reporting interval in seconds (default: 1.0, 0 to disable)")

    # Client mode
    cli = subparsers.add_parser("client", help="Run VOD Playback Client (STB)")
    cli.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP address")
    cli.add_argument("--bind-port", type=int, default=5005, help="Binding UDP port")
    cli.add_argument("--server-ip", default="", help="Streaming server IP to initiate NAT hole punching")
    cli.add_argument("--server-port", type=int, default=0, help="Streaming server port (default: same as bind-port)")
    cli.add_argument("--duration", type=float, default=6.0, help="Listen duration in seconds")
    cli.add_argument("--report-interval", type=float, default=1.0, help="Periodic progress reporting interval in seconds (default: 1.0, 0 to disable)")
    cli.add_argument("--output-json", default="", help="Path to write JSON results")

    return parser.parse_args()

def run_server(args):
    target_bitrate = args.base_bitrate_mbps * args.playback_speed
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except Exception:
            pass
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)

    target_addr = (args.dest_ip, args.dest_port)

    # Stateful NAT Hole Punching: Wait for client probe before streaming
    if getattr(args, "wait_handshake", False):
        listen_port = args.bind_port if getattr(args, "bind_port", 0) > 0 else args.dest_port
        try:
            sock.bind((getattr(args, "bind_ip", "0.0.0.0"), listen_port))
        except Exception as e:
            print(f"Error binding UDP socket on {args.bind_ip}:{listen_port}: {e}")
            sock.close()
            return

        sock.settimeout(0.5)
        print(f"=== UHD+DOLBY VOD SERVER: WAITING FOR CLIENT NAT HANDSHAKE ===")
        print(f"  Listening on: {getattr(args, 'bind_ip', '0.0.0.0')}:{listen_port} (Timeout: {getattr(args, 'handshake_timeout', 5.0)}s)...")

        start_wait = time.time()
        handshake_done = False
        rx_buf = bytearray(2048)

        while (time.time() - start_wait) < getattr(args, "handshake_timeout", 5.0):
            try:
                nbytes, client_addr = sock.recvfrom_into(rx_buf)
                if nbytes >= 20:
                    magic, stream_id, seq, _ = VOD_STRUCT.unpack_from(rx_buf, 0)
                    if magic == VOD_MAGIC and stream_id == VOD_HANDSHAKE_ID:
                        print(f"  [PASS] Received NAT handshake probe from {client_addr[0]}:{client_addr[1]}. Session established.")
                        target_addr = client_addr
                        ack_buf = bytearray(max(32, 1316 - 42))
                        VOD_STRUCT.pack_into(ack_buf, 0, VOD_MAGIC, VOD_HANDSHAKE_ID, VOD_HANDSHAKE_ACK, time.time())
                        for _ in range(3):
                            sock.sendto(ack_buf, client_addr)
                            time.sleep(0.005)
                        handshake_done = True
                        break
            except socket.timeout:
                continue

        if not handshake_done:
            print(f"  [WARN] No handshake probe received within {getattr(args, 'handshake_timeout', 5.0)}s. Falling back to {target_addr[0]}:{target_addr[1]}")
        else:
            time.sleep(0.05)

    # Optimization: Connect UDP socket once to avoid repeated kernel routing lookups
    try:
        sock.connect(target_addr)
    except Exception as e:
        print(f"Error connecting UDP socket: {e}")
        sock.close()
        return

    # Packet size: 1316 bytes (7 MPEG-TS packets of 188 bytes)
    packet_size = 1316
    payload_len = max(32, packet_size - 42)

    # Optimization: Pre-allocate reusable bytearray buffer
    buf = bytearray(payload_len)
    buf[20:] = b"\xee" * (payload_len - 20)

    frame_bits = (packet_size + 20) * 8
    target_pps = (target_bitrate * 1e6) / frame_bits
    inter_packet_delay = 1.0 / target_pps

    # Local caching for tight loop speed
    pack_into = VOD_STRUCT.pack_into
    send_call = sock.send
    perf_counter = time.perf_counter
    sleep_func = time.sleep

    # Adaptive micro-batching: 4 packets per batch to balance timer overhead and jitter
    batch_size = 4
    batch_delay = inter_packet_delay * batch_size

    print(f"=== UHD+DOLBY VOD SERVER START (OPTIMIZED) ===")
    print(f"  Target STB: {args.dest_ip}:{args.dest_port}")
    print(f"  Base Bitrate: {args.base_bitrate_mbps} Mbps | Speed: {args.playback_speed}x -> Target: {target_bitrate:.2f} Mbps")
    print(f"  Duration: {args.duration}s (~{target_pps:.0f} PPS)")

    start_stream = perf_counter()
    end_time = start_stream + args.duration
    seq = 0
    total_sent = 0
    next_send = perf_counter()
    last_report_time = start_stream
    report_interval = getattr(args, "report_interval", 1.0)

    while perf_counter() < end_time:
        now_ts = perf_counter()
        for _ in range(batch_size):
            pack_into(buf, 0, VOD_MAGIC, 0, seq, now_ts)
            send_call(buf)
            seq += 1
            total_sent += 1

        if report_interval > 0 and (now_ts - last_report_time) >= report_interval:
            elapsed = now_ts - start_stream
            current_pps = total_sent / elapsed if elapsed > 0 else 0
            current_mbps = (total_sent * (packet_size + 20) * 8) / (elapsed * 1e6) if elapsed > 0 else 0
            print(f"  [Tx {elapsed:5.1f}s / {args.duration:.1f}s] Sent: {total_sent:7d} pkts | Rate: {current_mbps:5.2f} Mbps | PPS: {current_pps:5.0f}", flush=True)
            last_report_time = now_ts

        next_send += batch_delay
        wait = next_send - perf_counter()
        if wait > 0:
            if wait > 0.001:
                sleep_func(wait - 0.0005)
            while perf_counter() < next_send:
                pass

    sock.close()
    print(f"=== UHD+DOLBY VOD SERVER COMPLETE: Sent {total_sent} packets ===", flush=True)

def run_client(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        except Exception:
            pass
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    try:
        sock.bind((args.bind_ip, args.bind_port))
    except Exception as e:
        print(f"Error binding UDP socket on {args.bind_ip}:{args.bind_port}: {e}", file=sys.stderr, flush=True)
        sock.close()
        return 1
    sock.settimeout(0.1)

    target_server_port = args.server_port if getattr(args, "server_port", 0) > 0 else args.bind_port
    has_server = bool(getattr(args, "server_ip", ""))

    print(f"=== UHD+DOLBY VOD CLIENT LISTENING on {args.bind_ip}:{args.bind_port} (OPTIMIZED) ===", flush=True)
    if has_server:
        print(f"  NAT Traversal: Active (Probing {args.server_ip}:{target_server_port})", flush=True)

    # Optimization: Zero-allocation buffer & O(1) streaming metrics
    rx_buf = bytearray(2048)
    recv_into = sock.recv_into
    unpack_from = VOD_STRUCT.unpack_from
    probe_buf = bytearray(32)
    pack_into = VOD_STRUCT.pack_into
    perf_counter = time.perf_counter
    time_func = time.time

    received = 0
    bytes_rx = 0
    min_seq = None
    max_seq = 0
    expected_next_seq = 0
    dropped_packets = 0

    first_ts = None
    last_ts = None
    stall_events = 0
    prev_rx = None
    handshake_acked = False
    last_probe_time = 0.0
    last_report_time = 0.0
    last_report_rx = 0
    last_report_bytes = 0

    start_listen = perf_counter()
    while (perf_counter() - start_listen) < args.duration:
        now_t = time_func()

        if has_server and not handshake_acked and received == 0:
            if (now_t - last_probe_time) >= 0.15:
                try:
                    pack_into(probe_buf, 0, VOD_MAGIC, VOD_HANDSHAKE_ID, VOD_HANDSHAKE_PROBE, perf_counter())
                    sock.sendto(probe_buf, (args.server_ip, target_server_port))
                    if last_probe_time == 0.0:
                        print(f"  [INFO] Sent initial NAT probe to {args.server_ip}:{target_server_port}...", flush=True)
                    last_probe_time = now_t
                except Exception as e:
                    if last_probe_time == 0.0 or (now_t - last_probe_time) >= 1.0:
                        print(f"  [WARN] NAT probe sendto({args.server_ip}:{target_server_port}) failed: {e}", file=sys.stderr, flush=True)
                    last_probe_time = now_t

        try:
            nbytes = recv_into(rx_buf)
            now = perf_counter()

            if nbytes >= 20:
                magic, stream_id, seq, _ = unpack_from(rx_buf, 0)
                if magic == VOD_MAGIC:
                    if stream_id == VOD_HANDSHAKE_ID:
                        handshake_acked = True
                        continue

                    handshake_acked = True
                    if first_ts is None:
                        first_ts = now

                    # Check for buffer underrun/stall (> 50ms gap between packets at 40+ Mbps)
                    if prev_rx is not None and (now - prev_rx) > 0.05:
                        stall_events += 1

                    prev_rx = now
                    last_ts = now
                    received += 1
                    bytes_rx += nbytes + 42

                    if min_seq is None:
                        min_seq = seq
                        max_seq = seq
                        expected_next_seq = seq + 1
                    else:
                        if seq > max_seq:
                            max_seq = seq
                        if seq == expected_next_seq:
                            expected_next_seq = seq + 1
                        elif seq > expected_next_seq:
                            dropped_packets += (seq - expected_next_seq)
                            expected_next_seq = seq + 1
                        else:
                            pass

                    report_interval = getattr(args, "report_interval", 1.0)
                    if report_interval > 0 and (now - last_report_time) >= report_interval:
                        if last_report_time == 0.0:
                            last_report_time = first_ts
                        int_sec = now - last_report_time
                        int_rx = received - last_report_rx
                        int_bytes = bytes_rx - last_report_bytes
                        int_mbps = (int_bytes * 8) / (int_sec * 1e6) if int_sec > 0 else 0
                        int_pps = int_rx / int_sec if int_sec > 0 else 0
                        total_elapsed = now - first_ts
                        print(f"  [Rx {total_elapsed:5.1f}s] Rx: {received:7d} pkts | Rate: {int_mbps:5.2f} Mbps | PPS: {int_pps:5.0f} | Stalls: {stall_events:2d} | Drops: {dropped_packets:2d}", flush=True)
                        last_report_time = now
                        last_report_rx = received
                        last_report_bytes = bytes_rx
        except socket.timeout:
            if received > 0 and (perf_counter() - last_ts) > 2.0:
                break

    sock.close()

    elapsed = (last_ts - first_ts) if (first_ts and last_ts and last_ts > first_ts) else 1.0
    throughput_mbps = (bytes_rx * 8) / (elapsed * 1e6)

    if min_seq is not None:
        expected = max_seq - min_seq + 1
        lost = max(0, expected - received)
        loss_pct = (lost / expected * 100.0) if expected > 0 else 0.0
    else:
        expected = 0
        lost = 0
        loss_pct = 100.0

    is_normal = (lost == 0) and (throughput_mbps >= 35.0) and (stall_events <= 1)
    status = "PASS" if is_normal else "FAIL"

    result = {
        "test": "uhd_dolby_vod_1_2x",
        "received_packets": received,
        "loss_pct": round(loss_pct, 4),
        "throughput_mbps": round(throughput_mbps, 2),
        "stall_events": stall_events,
        "playback_status": "NORMAL" if is_normal else "STALLING_OR_DROPPED",
        "verdict": status
    }

    print("\n--- UHD+DOLBY 1.2x VOD TEST RESULT ---")
    print(f"  Throughput: {throughput_mbps:.2f} Mbps | Loss: {loss_pct:.2f}% | Stalls: {stall_events}")
    print(f"  Playback Status: {result['playback_status']}")
    print(f"  Verdict: [{status}]")

    if args.output_json:
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)

    return 0 if status == "PASS" else 1

def main():
    args = parse_args()
    if args.mode == "server":
        run_server(args)
    elif args.mode == "client":
        sys.exit(run_client(args))

if __name__ == "__main__":
    main()
