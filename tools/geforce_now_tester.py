#!/usr/bin/env python3
"""
Carrier Network Test Lab - Cloud Gaming (GeForce NOW) Network Tester (Optimized)
Emulates the interactive UDP streaming and network diagnostic test of GeForce NOW.
Optimized with zero-copy/zero-allocation buffers, connected UDP sockets, monotonic timing,
and O(1) streaming RFC 3550 jitter & packet loss tracking.
"""

import sys
import os
import time
import socket
import struct
import json
import argparse

GFN_MAGIC = 0x47464E54  # "GFNT"
GFN_STRUCT = struct.Struct("!IIId")  # 20 bytes: magic(4), frame_id(4), seq(4), send_ts(8)

# NAT Hole Punching Handshake constants
GFN_HANDSHAKE_ID = 0xFFFFFFFF
GFN_HANDSHAKE_PROBE = 0x01
GFN_HANDSHAKE_ACK   = 0x02

def parse_args():
    parser = argparse.ArgumentParser(description="Cloud Gaming (GeForce NOW) Protocol Tester (Optimized)")
    subparsers = parser.add_subparsers(dest="mode", required=True)

    # Server mode
    srv = subparsers.add_parser("server", help="Run Cloud Gaming streaming server")
    srv.add_argument("--dest-ip", required=True, help="STB Client IP address")
    srv.add_argument("--dest-port", type=int, default=5004, help="STB Client UDP port")
    srv.add_argument("--duration", type=float, default=5.0, help="Test duration in seconds")
    srv.add_argument("--frame-rate", type=int, default=60, help="Game frames per second (60 or 120)")
    srv.add_argument("--bitrate-mbps", type=float, default=25.0, help="Target game video bitrate (Mbps)")
    srv.add_argument("--wait-handshake", action="store_true", help="Wait for client NAT hole punching probe before streaming")
    srv.add_argument("--handshake-timeout", type=float, default=5.0, help="Seconds to wait for client probe (default: 5.0)")
    srv.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP for handshake listening")
    srv.add_argument("--bind-port", type=int, default=0, help="Binding port for handshake listening (default: same as dest-port)")
    srv.add_argument("--report-interval", type=float, default=1.0, help="Interval in seconds for periodic progress log (default: 1.0, 0 to disable)")

    # Client mode
    cli = subparsers.add_parser("client", help="Run Cloud Gaming diagnostic client (STB)")
    cli.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP address")
    cli.add_argument("--bind-port", type=int, default=5004, help="Binding UDP port")
    cli.add_argument("--server-ip", default="", help="Streaming server IP to initiate NAT hole punching")
    cli.add_argument("--server-port", type=int, default=0, help="Streaming server port (default: same as bind-port)")
    cli.add_argument("--duration", type=float, default=6.0, help="Listen duration in seconds")
    cli.add_argument("--report-interval", type=float, default=1.0, help="Interval in seconds for periodic progress log (default: 1.0, 0 to disable)")
    cli.add_argument("--max-loss-pct", type=float, default=0.0, help="Maximum allowed packet loss (percent)")
    cli.add_argument("--max-jitter-ms", type=float, default=2.0, help="Maximum allowed jitter (ms)")
    cli.add_argument("--output-json", default="", help="Path to write JSON results")

    return parser.parse_args()

def run_server(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
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
        print(f"=== GEFORCE NOW SERVER: WAITING FOR CLIENT NAT HANDSHAKE ===")
        print(f"  Listening on: {getattr(args, 'bind_ip', '0.0.0.0')}:{listen_port} (Timeout: {getattr(args, 'handshake_timeout', 5.0)}s)...")

        start_wait = time.time()
        handshake_done = False
        rx_buf = bytearray(2048)

        while (time.time() - start_wait) < getattr(args, "handshake_timeout", 5.0):
            try:
                nbytes, client_addr = sock.recvfrom_into(rx_buf)
                if nbytes >= 20:
                    magic, f_id, seq, _ = GFN_STRUCT.unpack_from(rx_buf, 0)
                    if magic == GFN_MAGIC and f_id == GFN_HANDSHAKE_ID:
                        print(f"  [PASS] Received NAT handshake probe from {client_addr[0]}:{client_addr[1]}. Session established.")
                        target_addr = client_addr
                        ack_buf = bytearray(max(32, 1200 - 42))
                        GFN_STRUCT.pack_into(ack_buf, 0, GFN_MAGIC, GFN_HANDSHAKE_ID, GFN_HANDSHAKE_ACK, time.time())
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

    # Optimization: Connect UDP socket once to eliminate per-slice kernel routing lookups
    try:
        sock.connect(target_addr)
    except Exception as e:
        print(f"Error connecting UDP socket: {e}")
        sock.close()
        return

    # Calculate packets per frame and slice size
    packets_per_frame = max(1, int((args.bitrate_mbps * 1e6) / (args.frame_rate * 8 * 1200)))
    packet_size = 1200
    payload_len = max(32, packet_size - 42)

    # Optimization: Pre-allocate reusable bytearray buffer
    buf = bytearray(payload_len)
    buf[20:] = b"\xdd" * (payload_len - 20)

    frame_interval = 1.0 / args.frame_rate
    slice_interval = frame_interval / packets_per_frame

    # Local caching for tight loop speed
    pack_into = GFN_STRUCT.pack_into
    send_call = sock.send
    perf_counter = time.perf_counter
    sleep_func = time.sleep

    print(f"=== GEFORCE NOW SERVER STREAMING (OPTIMIZED) ===")
    print(f"  Target STB: {args.dest_ip}:{args.dest_port}")
    print(f"  Bitrate: {args.bitrate_mbps} Mbps | FPS: {args.frame_rate} | Slices/Frame: {packets_per_frame}")
    print(f"  Duration: {args.duration}s")

    start_stream = perf_counter()
    end_time = start_stream + args.duration
    seq = 0
    frame_idx = 0
    total_sent = 0
    next_packet_time = start_stream
    last_report_time = start_stream
    report_interval = getattr(args, "report_interval", 1.0)

    while perf_counter() < end_time:
        for _ in range(packets_per_frame):
            send_ts = perf_counter()
            pack_into(buf, 0, GFN_MAGIC, frame_idx, seq, send_ts)
            send_call(buf)
            seq += 1
            total_sent += 1

            next_packet_time += slice_interval
            wait_time = next_packet_time - perf_counter()
            if wait_time > 0:
                if wait_time > 0.001:
                    sleep_func(wait_time - 0.0005)
                while perf_counter() < next_packet_time:
                    pass
        frame_idx += 1

        now_pc = perf_counter()
        if report_interval > 0 and (now_pc - last_report_time) >= report_interval:
            elapsed = now_pc - start_stream
            current_pps = total_sent / elapsed if elapsed > 0 else 0
            current_mbps = (total_sent * 1200 * 8) / (elapsed * 1e6) if elapsed > 0 else 0
            print(f"  [Tx {elapsed:5.1f}s / {args.duration:.1f}s] Sent: {total_sent:7d} pkts ({frame_idx:4d} frames) | Rate: {current_mbps:5.2f} Mbps | PPS: {current_pps:5.0f}", flush=True)
            last_report_time = now_pc

    sock.close()
    print(f"=== GEFORCE NOW SERVER COMPLETE: Sent {total_sent} packets ({frame_idx} frames) ===", flush=True)

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

    print(f"=== GEFORCE NOW CLIENT LISTENING on {args.bind_ip}:{args.bind_port} (OPTIMIZED) ===", flush=True)
    print(f"  Criteria: Max Loss <= {args.max_loss_pct}%, Max Jitter <= {args.max_jitter_ms} ms", flush=True)
    if has_server:
        print(f"  NAT Traversal: Active (Probing {args.server_ip}:{target_server_port})", flush=True)

    # Optimization: Zero-allocation buffer & O(1) streaming metrics
    rx_buf = bytearray(2048)
    recv_into = sock.recv_into
    unpack_from = GFN_STRUCT.unpack_from
    probe_buf = bytearray(32)
    pack_into = GFN_STRUCT.pack_into
    perf_counter = time.perf_counter
    time_func = time.time

    received = 0
    min_seq = None
    max_seq = 0
    expected_next_seq = 0
    dropped_packets = 0

    jitter = 0.0
    prev_send_ts = None
    prev_recv_ts = None
    first_ts = None
    last_ts = None
    handshake_acked = False
    last_probe_time = 0.0
    last_report_time = 0.0
    last_report_rx = 0

    start_listen = perf_counter()
    while (perf_counter() - start_listen) < args.duration:
        now_t = time_func()

        if has_server and not handshake_acked and received == 0:
            if (now_t - last_probe_time) >= 0.15:
                try:
                    pack_into(probe_buf, 0, GFN_MAGIC, GFN_HANDSHAKE_ID, GFN_HANDSHAKE_PROBE, perf_counter())
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
                magic, f_id, seq, send_ts = unpack_from(rx_buf, 0)
                if magic == GFN_MAGIC:
                    if f_id == GFN_HANDSHAKE_ID:
                        handshake_acked = True
                        continue

                    handshake_acked = True
                    if first_ts is None:
                        first_ts = now
                    last_ts = now
                    received += 1

                    # O(1) sequence and drop tracking
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
                            # Late or reordered packet
                            pass

                    # RFC 3550 Interarrival Jitter calculation with monotonic high-res clock
                    if prev_send_ts is not None and prev_recv_ts is not None:
                        d = (now - send_ts) - (prev_recv_ts - prev_send_ts)
                        jitter += (abs(d) - jitter) / 16.0
                    prev_send_ts = send_ts
                    prev_recv_ts = now

                    report_interval = getattr(args, "report_interval", 1.0)
                    if report_interval > 0 and (now - last_report_time) >= report_interval:
                        if last_report_time == 0.0:
                            last_report_time = first_ts
                        int_sec = now - last_report_time
                        int_rx = received - last_report_rx
                        int_mbps = (int_rx * 1200 * 8) / (int_sec * 1e6) if int_sec > 0 else 0
                        int_pps = int_rx / int_sec if int_sec > 0 else 0
                        total_elapsed = now - first_ts
                        print(f"  [Rx {total_elapsed:5.1f}s] Rx: {received:7d} pkts | Rate: {int_mbps:5.2f} Mbps | Jitter: {jitter*1000:6.3f} ms | Drops: {dropped_packets:2d}", flush=True)
                        last_report_time = now
                        last_report_rx = received
        except socket.timeout:
            if received > 0 and (perf_counter() - last_ts) > 2.0:
                break

    sock.close()

    if min_seq is not None:
        expected = max_seq - min_seq + 1
        lost = max(0, expected - received)
        loss_pct = (lost / expected * 100.0) if expected > 0 else 0.0
    else:
        expected = 0
        lost = 0
        loss_pct = 100.0

    jitter_ms = jitter * 1000.0
    is_normal = (lost == 0) and (jitter_ms <= args.max_jitter_ms) and (received > 100)
    status = "PASS" if is_normal else "FAIL"

    result = {
        "test": "geforce_now_network_test",
        "expected_packets": expected,
        "received_packets": received,
        "lost_packets": lost,
        "loss_pct": round(loss_pct, 4),
        "jitter_ms": round(jitter_ms, 3),
        "network_test_status": "NORMAL" if is_normal else "ABNORMAL",
        "verdict": status
    }

    print("\n--- GEFORCE NOW NETWORK TEST RESULT ---")
    print(f"  Received: {received} / {expected} | Loss: {loss_pct:.2f}% | Jitter: {jitter_ms:.3f} ms")
    print(f"  App Status: {result['network_test_status']}")
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
