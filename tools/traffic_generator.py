#!/usr/bin/env python3
"""
Gateway Network Test Lab - Traffic Generator Utility
High-Performance Wire-rate Unicast, Multicast, and WAN-to-LAN Burst Engine.
Optimized with zero-allocation buffers, connected UDP sockets, and O(1) sequence tracking.
"""

import sys
import os
import time
import socket
import struct
import json
import argparse
from typing import Dict, Any

MAGIC_HEADER = 0x50455246  # "PERF" in hex
HEADER_STRUCT = struct.Struct("!IIId")  # 20 bytes: magic(4), burst_or_stream(4), seq(4), ts(8)

# NAT Hole Punching Handshake constants (reserved burst/stream ID 0xFFFFFFFF)
HANDSHAKE_BURST_IDX = 0xFFFFFFFF
HANDSHAKE_SEQ_PROBE = 0x01
HANDSHAKE_SEQ_ACK   = 0x02

def parse_args():
    parser = argparse.ArgumentParser(description="Precision Network Traffic Generator & Receiver (Optimized)")
    subparsers = parser.add_subparsers(dest="mode", required=True)

    # 1. Burst Mode Sender
    burst_send = subparsers.add_parser("burst-send", help="Send precision burst traffic")
    burst_send.add_argument("--dest-ip", required=True, help="Destination IP address")
    burst_send.add_argument("--dest-port", type=int, default=5001, help="Destination UDP port")
    burst_send.add_argument("--packet-size", type=int, default=1500, help="Total Ethernet frame size (bytes)")
    burst_send.add_argument("--burst-length", type=int, default=53, help="Frames per burst")
    burst_send.add_argument("--burst-load", type=float, default=50.0, help="Burst load percentage (e.g. 50 or 16)")
    burst_send.add_argument("--burst-count", type=int, default=20, help="Number of bursts to emit")
    burst_send.add_argument("--rate-mbps", type=float, default=1000.0, help="Ingress line rate (Mbps)")
    burst_send.add_argument("--wait-handshake", action="store_true", help="Wait for client NAT hole punching probe before sending")
    burst_send.add_argument("--handshake-timeout", type=float, default=5.0, help="Seconds to wait for client probe (default: 5.0)")
    burst_send.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP for handshake listening")
    burst_send.add_argument("--bind-port", type=int, default=0, help="Binding port for handshake listening (default: same as dest-port)")

    # 2. Burst Mode Receiver
    burst_recv = subparsers.add_parser("burst-recv", help="Receive and verify burst traffic")
    burst_recv.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP address")
    burst_recv.add_argument("--bind-port", type=int, default=5001, help="Binding UDP port")
    burst_recv.add_argument("--server-ip", default="", help="Traffic generator IP to initiate NAT hole punching")
    burst_recv.add_argument("--server-port", type=int, default=0, help="Traffic generator port (default: same as bind-port)")
    burst_recv.add_argument("--expected-packets", type=int, default=1060, help="Expected packet count")
    burst_recv.add_argument("--timeout", type=float, default=5.0, help="Timeout waiting for packets (sec)")
    burst_recv.add_argument("--output-json", default="", help="Path to write JSON results")

    # 3. Unicast Sender
    uni_send = subparsers.add_parser("unicast-send", help="Send wire-rate unicast packets")
    uni_send.add_argument("--dest-ip", required=True, help="Destination IP address")
    uni_send.add_argument("--dest-port", type=int, default=5002, help="Destination UDP port")
    uni_send.add_argument("--packet-size", type=int, default=1024, help="Total frame size (bytes)")
    uni_send.add_argument("--duration", type=float, default=5.0, help="Duration in seconds")
    uni_send.add_argument("--rate-mbps", type=float, default=950.0, help="Target transmission rate (Mbps)")
    uni_send.add_argument("--wait-handshake", action="store_true", help="Wait for client NAT hole punching probe before sending")
    uni_send.add_argument("--handshake-timeout", type=float, default=5.0, help="Seconds to wait for client probe (default: 5.0)")
    uni_send.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP for handshake listening")
    uni_send.add_argument("--bind-port", type=int, default=0, help="Binding port for handshake listening (default: same as dest-port)")

    # 4. Unicast Receiver
    uni_recv = subparsers.add_parser("unicast-recv", help="Receive wire-rate unicast packets")
    uni_recv.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP address")
    uni_recv.add_argument("--bind-port", type=int, default=5002, help="Binding UDP port")
    uni_recv.add_argument("--server-ip", default="", help="Traffic generator IP to initiate NAT hole punching")
    uni_recv.add_argument("--server-port", type=int, default=0, help="Traffic generator port (default: same as bind-port)")
    uni_recv.add_argument("--duration", type=float, default=6.0, help="Listen duration (sec)")
    uni_recv.add_argument("--output-json", default="", help="Path to write JSON results")

    # 5. Multicast Sender
    mcast_send = subparsers.add_parser("mcast-send", help="Send wire-rate multicast packets")
    mcast_send.add_argument("--group-ip", default="239.255.0.1", help="Multicast group IP")
    mcast_send.add_argument("--port", type=int, default=5003, help="Multicast UDP port")
    mcast_send.add_argument("--packet-size", type=int, default=1024, help="Total frame size (bytes)")
    mcast_send.add_argument("--packets", type=int, default=5000, help="Number of packets to send")
    mcast_send.add_argument("--rate-mbps", type=float, default=100.0, help="Target rate (Mbps)")
    mcast_send.add_argument("--interface-ip", default="", help="Source interface IP")
    mcast_send.add_argument("--warmup-packets", type=int, default=20, help="Number of warmup packets to trigger hardware flow table")

    # 6. Multicast Receiver
    mcast_recv = subparsers.add_parser("mcast-recv", help="Receive wire-rate multicast packets")
    mcast_recv.add_argument("--group-ip", default="239.255.0.1", help="Multicast group IP")
    mcast_recv.add_argument("--port", type=int, default=5003, help="Multicast UDP port")
    mcast_recv.add_argument("--expected-packets", type=int, default=5000, help="Expected packets")
    mcast_recv.add_argument("--interface-ip", default="0.0.0.0", help="Interface IP to join group on")
    mcast_recv.add_argument("--timeout", type=float, default=6.0, help="Timeout in seconds")
    mcast_recv.add_argument("--output-json", default="", help="Path to write JSON results")

    return parser.parse_args()

def run_burst_sender(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 * 1024 * 1024)

    target_addr = (args.dest_ip, args.dest_port)

    # Stateful NAT Hole Punching: Wait for client probe before sending
    if getattr(args, "wait_handshake", False):
        listen_port = args.bind_port if getattr(args, "bind_port", 0) > 0 else args.dest_port
        try:
            sock.bind((getattr(args, "bind_ip", "0.0.0.0"), listen_port))
        except Exception as e:
            print(f"Error binding UDP socket on {args.bind_ip}:{listen_port}: {e}")
            sock.close()
            return

        sock.settimeout(0.5)
        print(f"=== BURST SENDER: WAITING FOR CLIENT NAT HANDSHAKE ===")
        print(f"  Listening on: {getattr(args, 'bind_ip', '0.0.0.0')}:{listen_port} (Timeout: {getattr(args, 'handshake_timeout', 5.0)}s)...")

        start_wait = time.time()
        handshake_done = False
        rx_buf = bytearray(2048)

        while (time.time() - start_wait) < getattr(args, "handshake_timeout", 5.0):
            try:
                nbytes, client_addr = sock.recvfrom_into(rx_buf)
                if nbytes >= 20:
                    magic, burst_idx, seq, _ = HEADER_STRUCT.unpack_from(rx_buf, 0)
                    if magic == MAGIC_HEADER and burst_idx == HANDSHAKE_BURST_IDX:
                        print(f"  [PASS] Received NAT handshake probe from {client_addr[0]}:{client_addr[1]}. Session established.")
                        target_addr = client_addr
                        # Send ACK back so receiver knows probe succeeded and NAT pinhole is open
                        ack_buf = bytearray(max(32, args.packet_size - 42))
                        HEADER_STRUCT.pack_into(ack_buf, 0, MAGIC_HEADER, HANDSHAKE_BURST_IDX, HANDSHAKE_SEQ_ACK, time.time())
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
            time.sleep(0.05)  # Allow NAT pinhole to settle

    # Optimization: Connect UDP socket once to avoid repeated routing lookups in kernel
    try:
        sock.connect(target_addr)
    except Exception as e:
        print(f"Error connecting UDP socket: {e}")
        sock.close()
        return

    payload_len = max(32, args.packet_size - 42)
    # Optimization: Pre-allocate single bytearray and pack into it in-place
    buf = bytearray(payload_len)
    buf[20:] = b"\xaa" * (payload_len - 20)
    pack_into = HEADER_STRUCT.pack_into
    send_call = sock.send

    frame_bits = (args.packet_size + 20) * 8
    frame_time_sec = frame_bits / (args.rate_mbps * 1e6)
    burst_duration_sec = frame_time_sec * args.burst_length

    # RFC 2544 / RFC 2889: Time required for 100M egress to drain one burst of frames
    drain_time_100m = (frame_bits * args.burst_length) / (100.0 * 1e6)
    duty_cycle_idle = burst_duration_sec * ((100.0 - args.burst_load) / args.burst_load) if args.burst_load < 100.0 else 0.0
    inter_burst_pause = max(duty_cycle_idle, drain_time_100m + 0.003)

    print(f"=== BURST GENERATOR START (OPTIMIZED) ===")
    print(f"  Target: {target_addr[0]}:{target_addr[1]}")
    print(f"  Frame Size: {args.packet_size}B (Payload: {payload_len}B)")
    print(f"  Burst Length: {args.burst_length} frames | Load: {args.burst_load}% | Bursts: {args.burst_count}")
    print(f"  Burst Active: {burst_duration_sec * 1e6:.2f} us | Inter-Burst Pause: {inter_burst_pause * 1e3:.2f} ms")

    total_sent = 0
    time.sleep(0.05)

    perf_counter = time.perf_counter
    time_func = time.time

    for burst_idx in range(args.burst_count):
        burst_start = perf_counter()
        now_ts = time_func()
        for seq_in_burst in range(args.burst_length):
            pack_into(buf, 0, MAGIC_HEADER, burst_idx, seq_in_burst, now_ts)
            send_call(buf)
            total_sent += 1

        burst_elapsed = perf_counter() - burst_start
        sleep_needed = inter_burst_pause - burst_elapsed
        if sleep_needed > 0:
            target_time = perf_counter() + sleep_needed
            if sleep_needed > 0.002:
                time.sleep(sleep_needed - 0.001)
            while perf_counter() < target_time:
                pass

    sock.close()
    print(f"=== BURST GENERATOR COMPLETE: Sent {total_sent} frames ===")

def run_burst_receiver(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    try:
        sock.bind((args.bind_ip, args.bind_port))
    except Exception as e:
        print(f"Error binding burst receiver on {args.bind_ip}:{args.bind_port}: {e}", file=sys.stderr, flush=True)
        sock.close()
        return 1

    sock.settimeout(0.1)  # 100ms timeout for responsive probing and timeout loop

    target_server_port = args.server_port if getattr(args, "server_port", 0) > 0 else args.bind_port
    has_server = bool(getattr(args, "server_ip", ""))

    print(f"=== BURST RECEIVER LISTENING on {args.bind_ip}:{args.bind_port} ===", flush=True)
    print(f"  Expected packets: {args.expected_packets} | Timeout: {args.timeout}s", flush=True)
    if has_server:
        print(f"  NAT Traversal: Active (Probing {args.server_ip}:{target_server_port})", flush=True)

    # Optimization: Pre-allocated buffer and O(1) burst tracking
    rx_buf = bytearray(2048)
    recv_into = sock.recv_into
    unpack_from = HEADER_STRUCT.unpack_from

    probe_buf = bytearray(32)
    pack_into = HEADER_STRUCT.pack_into

    received_packets = 0
    burst_counts = {}
    start_time = None
    last_rx_time = time.time()
    time_func = time.time

    handshake_acked = False
    last_probe_time = 0.0

    while True:
        now = time_func()

        # Proactive NAT Hole Punching: send probes until data or ACK received
        if has_server and not handshake_acked and received_packets == 0:
            if (now - last_probe_time) >= 0.15:
                try:
                    pack_into(probe_buf, 0, MAGIC_HEADER, HANDSHAKE_BURST_IDX, HANDSHAKE_SEQ_PROBE, now)
                    sock.sendto(probe_buf, (args.server_ip, target_server_port))
                    if last_probe_time == 0.0:
                        print(f"  [INFO] Sent initial NAT probe to {args.server_ip}:{target_server_port}...", flush=True)
                    last_probe_time = now
                except Exception as e:
                    if last_probe_time == 0.0 or (now - last_probe_time) >= 1.0:
                        print(f"  [WARN] NAT probe sendto({args.server_ip}:{target_server_port}) failed: {e}", file=sys.stderr, flush=True)
                    last_probe_time = now

        try:
            nbytes = recv_into(rx_buf)
            if nbytes >= 20:
                magic, burst_idx, seq_in_burst, _ = unpack_from(rx_buf, 0)
                if magic == MAGIC_HEADER:
                    if burst_idx == HANDSHAKE_BURST_IDX:
                        # Handshake probe or ACK received; pinhole confirmed open
                        handshake_acked = True
                        continue

                    # Valid burst traffic frame received
                    handshake_acked = True
                    if start_time is None:
                        start_time = now
                    received_packets += 1
                    burst_counts[burst_idx] = burst_counts.get(burst_idx, 0) + 1
                    last_rx_time = now
        except socket.timeout:
            now = time_func()
            if start_time is not None and (now - last_rx_time) > args.timeout:
                break
            if start_time is None and (now - last_rx_time) > (args.timeout + 4.0):
                break

    sock.close()

    lost_packets = max(0, args.expected_packets - received_packets)
    loss_pct = (lost_packets / args.expected_packets * 100.0) if args.expected_packets > 0 else 0.0
    status = "PASS" if lost_packets == 0 else "FAIL"

    result = {
        "test": "burst_traffic",
        "expected_packets": args.expected_packets,
        "received_packets": received_packets,
        "lost_packets": lost_packets,
        "loss_pct": round(loss_pct, 4),
        "total_bursts_seen": len(burst_counts),
        "status": status
    }

    print("\n--- BURST TEST RESULT ---")
    print(f"  Expected: {args.expected_packets} | Received: {received_packets} | Lost: {lost_packets} ({loss_pct:.2f}%)")
    print(f"  Verdict: [{status}]")

    if args.output_json:
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)

    return 0 if status == "PASS" else 1

def run_unicast_sender(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 * 1024 * 1024)

    target_addr = (args.dest_ip, args.dest_port)

    # Stateful NAT Hole Punching: Wait for client probe before sending
    if getattr(args, "wait_handshake", False):
        listen_port = args.bind_port if getattr(args, "bind_port", 0) > 0 else args.dest_port
        try:
            sock.bind((getattr(args, "bind_ip", "0.0.0.0"), listen_port))
        except Exception as e:
            print(f"Error binding UDP socket on {args.bind_ip}:{listen_port}: {e}")
            sock.close()
            return

        sock.settimeout(0.5)
        print(f"=== UNICAST SENDER: WAITING FOR CLIENT NAT HANDSHAKE ===")
        print(f"  Listening on: {getattr(args, 'bind_ip', '0.0.0.0')}:{listen_port} (Timeout: {getattr(args, 'handshake_timeout', 5.0)}s)...")

        start_wait = time.time()
        handshake_done = False
        rx_buf = bytearray(2048)

        while (time.time() - start_wait) < getattr(args, "handshake_timeout", 5.0):
            try:
                nbytes, client_addr = sock.recvfrom_into(rx_buf)
                if nbytes >= 20:
                    magic, burst_idx, seq, _ = HEADER_STRUCT.unpack_from(rx_buf, 0)
                    if magic == MAGIC_HEADER and burst_idx == HANDSHAKE_BURST_IDX:
                        print(f"  [PASS] Received NAT handshake probe from {client_addr[0]}:{client_addr[1]}. Session established.")
                        target_addr = client_addr
                        ack_buf = bytearray(max(32, args.packet_size - 42))
                        HEADER_STRUCT.pack_into(ack_buf, 0, MAGIC_HEADER, HANDSHAKE_BURST_IDX, HANDSHAKE_SEQ_ACK, time.time())
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

    try:
        sock.connect(target_addr)
    except Exception as e:
        print(f"Error connecting UDP socket: {e}")
        return

    payload_len = max(32, args.packet_size - 42)
    buf = bytearray(payload_len)
    buf[20:] = b"\xbb" * (payload_len - 20)

    pack_into = HEADER_STRUCT.pack_into
    send_call = sock.send
    perf_counter = time.perf_counter
    time_func = time.time

    frame_bits = (args.packet_size + 20) * 8
    target_pps = (args.rate_mbps * 1e6) / frame_bits
    inter_packet_delay = 1.0 / target_pps

    # Optimization: Batch clock pacing to avoid timer syscall overhead on every packet
    batch_size = 16 if target_pps > 20000 else 4
    batch_delay = inter_packet_delay * batch_size

    print(f"=== UNICAST SENDER START (OPTIMIZED) ===")
    print(f"  Target: {target_addr[0]}:{target_addr[1]}")
    print(f"  Frame Size: {args.packet_size}B | Target Rate: {args.rate_mbps} Mbps (~{target_pps:.0f} PPS)")
    print(f"  Duration: {args.duration}s | Batch Size: {batch_size}")

    end_time = time_func() + args.duration
    sent_count = 0
    seq = 0
    next_send = perf_counter()

    while time_func() < end_time:
        now_ts = time_func()
        for _ in range(batch_size):
            pack_into(buf, 0, MAGIC_HEADER, 0, seq, now_ts)
            send_call(buf)
            seq += 1
            sent_count += 1

        next_send += batch_delay
        wait = next_send - perf_counter()
        if wait > 0:
            if wait > 0.001:
                time.sleep(wait)
            else:
                while perf_counter() < next_send:
                    pass

    sock.close()
    print(f"=== UNICAST SENDER COMPLETE: Sent {sent_count} packets ===")

def run_unicast_receiver(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
    sock.bind((args.bind_ip, args.bind_port))
    sock.settimeout(0.1)

    target_server_port = args.server_port if getattr(args, "server_port", 0) > 0 else args.bind_port
    has_server = bool(getattr(args, "server_ip", ""))

    print(f"=== UNICAST RECEIVER LISTENING on {args.bind_ip}:{args.bind_port} (OPTIMIZED) ===")
    if has_server:
        print(f"  NAT Traversal: Active (Probing {args.server_ip}:{target_server_port})")

    # Optimization: O(1) streaming stats without accumulating giant packet lists in memory
    rx_buf = bytearray(2048)
    recv_into = sock.recv_into
    unpack_from = HEADER_STRUCT.unpack_from
    probe_buf = bytearray(32)
    pack_into = HEADER_STRUCT.pack_into
    time_func = time.time

    received_packets = 0
    bytes_received = 0
    first_ts = None
    last_ts = None
    min_seq = None
    max_seq = None
    dropped_packets = 0
    expected_next_seq = 0
    handshake_acked = False
    last_probe_time = 0.0

    start_listen = time_func()
    while (time_func() - start_listen) < args.duration:
        now = time_func()

        if has_server and not handshake_acked and received_packets == 0:
            if (now - last_probe_time) >= 0.15:
                try:
                    pack_into(probe_buf, 0, MAGIC_HEADER, HANDSHAKE_BURST_IDX, HANDSHAKE_SEQ_PROBE, now)
                    sock.sendto(probe_buf, (args.server_ip, target_server_port))
                    last_probe_time = now
                except Exception:
                    pass

        try:
            nbytes = recv_into(rx_buf)
            now = time_func()

            if nbytes >= 20:
                magic, stream_idx, seq, _ = unpack_from(rx_buf, 0)
                if magic == MAGIC_HEADER:
                    if stream_idx == HANDSHAKE_BURST_IDX:
                        handshake_acked = True
                        continue

                    handshake_acked = True
                    if first_ts is None:
                        first_ts = now
                    last_ts = now
                    received_packets += 1
                    bytes_received += nbytes + 42

                    if min_seq is None:
                        min_seq = seq
                        max_seq = seq
                        expected_next_seq = seq + 1
                    else:
                        if seq > max_seq:
                            max_seq = seq
                        if seq > expected_next_seq:
                            dropped_packets += (seq - expected_next_seq)
                            expected_next_seq = seq + 1
                        elif seq == expected_next_seq:
                            expected_next_seq += 1
        except socket.timeout:
            continue

    sock.close()
    elapsed = (last_ts - first_ts) if (first_ts and last_ts and last_ts > first_ts) else 1.0
    throughput_mbps = (bytes_received * 8) / (elapsed * 1e6)

    if min_seq is not None and max_seq is not None:
        total_expected = max_seq - min_seq + 1
        loss_pct = (dropped_packets / total_expected * 100.0) if total_expected > 0 else 0.0
    else:
        loss_pct = 0.0

    status = "PASS" if loss_pct == 0.0 and received_packets > 0 else "FAIL"

    result = {
        "test": "unicast_throughput",
        "received_packets": received_packets,
        "throughput_mbps": round(throughput_mbps, 2),
        "loss_pct": round(loss_pct, 4),
        "status": status
    }

    print("\n--- UNICAST TEST RESULT ---")
    print(f"  Received: {received_packets} packets | Throughput: {throughput_mbps:.2f} Mbps | Loss: {loss_pct:.2f}%")
    print(f"  Verdict: [{status}]")

    if args.output_json:
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)

    return 0 if status == "PASS" else 1

def run_mcast_sender(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
    if args.interface_ip:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.interface_ip))

    try:
        sock.connect((args.group_ip, args.port))
    except Exception:
        pass

    payload_len = max(32, args.packet_size - 42)
    buf = bytearray(payload_len)
    buf[20:] = b"\xcc" * (payload_len - 20)

    pack_into = HEADER_STRUCT.pack_into
    send_call = sock.send
    perf_counter = time.perf_counter
    time_func = time.time

    frame_bits = (args.packet_size + 20) * 8
    target_pps = (args.rate_mbps * 1e6) / frame_bits
    inter_delay = 1.0 / target_pps

    print(f"=== MULTICAST SENDER START (OPTIMIZED) ===")
    print(f"  Group: {args.group_ip}:{args.port}")
    print(f"  Frame Size: {args.packet_size}B | Packets: {args.packets} | Rate: {args.rate_mbps} Mbps")

    warmup_count = getattr(args, "warmup_packets", 0)
    if warmup_count > 0:
        print(f"  Emitting {warmup_count} warmup packets to prime DUT hardware flow table...")
        for wseq in range(warmup_count):
            pack_into(buf, 0, MAGIC_HEADER, 0, wseq, time_func())
            send_call(buf)
            time.sleep(0.003)
        time.sleep(0.05)

    sent = 0
    next_t = perf_counter()
    for seq in range(args.packets):
        pack_into(buf, 0, MAGIC_HEADER, 1, seq, time_func())
        send_call(buf)
        sent += 1
        next_t += inter_delay
        wait = next_t - perf_counter()
        if wait > 0:
            if wait > 0.001:
                time.sleep(wait)
            else:
                while perf_counter() < next_t:
                    pass

    sock.close()
    print(f"=== MULTICAST SENDER COMPLETE: Sent {sent} packets ===")

def run_mcast_receiver(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", args.port))

    mreq = struct.pack("4s4s", socket.inet_aton(args.group_ip), socket.inet_aton(args.interface_ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(0.5)

    print(f"=== MULTICAST RECEIVER JOINED {args.group_ip}:{args.port} (OPTIMIZED) ===")
    print(f"  Expecting {args.expected_packets} packets | Timeout: {args.timeout}s")

    rx_buf = bytearray(2048)
    recv_into = sock.recv_into
    unpack_from = HEADER_STRUCT.unpack_from
    time_func = time.time

    received = 0
    first_seq = None
    last_seq = None
    start = None
    last_rx = time_func()

    while True:
        try:
            nbytes = recv_into(rx_buf)
            now = time_func()
            if start is None:
                start = now
            last_rx = now
            if nbytes >= 20:
                magic, stream_type, seq, _ = unpack_from(rx_buf, 0)
                if magic == MAGIC_HEADER:
                    if stream_type == 0:
                        continue  # Skip warmup packet
                    received += 1
                    if first_seq is None:
                        first_seq = seq
                    last_seq = seq
        except socket.timeout:
            now = time_func()
            if start and (now - last_rx) > args.timeout:
                break
            if not start and (now - last_rx) > (args.timeout + 4.0):
                break

    sock.close()
    lost = max(0, args.expected_packets - received)
    loss_pct = (lost / args.expected_packets * 100.0) if args.expected_packets > 0 else 0.0
    status = "PASS" if lost == 0 else "FAIL"

    result = {
        "test": "multicast_forwarding",
        "expected_packets": args.expected_packets,
        "received_packets": received,
        "lost_packets": lost,
        "loss_pct": round(loss_pct, 4),
        "first_seq_received": first_seq,
        "last_seq_received": last_seq,
        "status": status
    }

    print("\n--- MULTICAST TEST RESULT ---")
    print(f"  Expected: {args.expected_packets} | Received: {received} (seq {first_seq}..{last_seq}) | Lost: {lost} ({loss_pct:.2f}%)")
    print(f"  Verdict: [{status}]")

    if args.output_json:
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)

    return 0 if status == "PASS" else 1

def main():
    args = parse_args()
    if args.mode == "burst-send":
        run_burst_sender(args)
    elif args.mode == "burst-recv":
        sys.exit(run_burst_receiver(args))
    elif args.mode == "unicast-send":
        run_unicast_sender(args)
    elif args.mode == "unicast-recv":
        sys.exit(run_unicast_receiver(args))
    elif args.mode == "mcast-send":
        run_mcast_sender(args)
    elif args.mode == "mcast-recv":
        sys.exit(run_mcast_receiver(args))

if __name__ == "__main__":
    main()
