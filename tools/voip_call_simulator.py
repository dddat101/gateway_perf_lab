#!/usr/bin/env python3
"""
Carrier Network Test Lab - Wi-Fi Phone (VoIP/SIP/RTP) Simulator (Optimized)
Emulates concurrent Wi-Fi phone calls using standard G.711 RTP streams (20ms packet pacing, DSCP EF).
Optimized with pre-allocated zero-copy buffers, connected sockets, non-blocking echo checks,
and high-resolution monotonic pacing.
"""

import sys
import os
import time
import socket
import struct
import json
import argparse
import threading

RTP_STRUCT = struct.Struct("!BBHII")  # 12 bytes: V/P/X/CC(1), M/PT(1), seq(2), ts(4), ssrc(4)

def parse_args():
    parser = argparse.ArgumentParser(description="Wi-Fi Phone (VoIP RTP) Simulator (Optimized)")
    subparsers = parser.add_subparsers(dest="mode", required=True)

    # Server mode (in ns-wan)
    srv = subparsers.add_parser("server", help="Run VoIP RTP Echo/Media Server")
    srv.add_argument("--bind-ip", default="0.0.0.0", help="Binding IP address")
    srv.add_argument("--ports", default="10000,10002", help="Comma-separated UDP ports to listen on")
    srv.add_argument("--duration", type=float, default=60.0, help="Server run duration in seconds")
    srv.add_argument("--dscp", type=int, default=46, help="IP DSCP value (default: 46 for Voice EF = 0xb8)")

    # Client mode (in ns-phone1, ns-phone2, or physical Wi-Fi interface)
    cli = subparsers.add_parser("client", help="Run Wi-Fi Phone Call Endpoint")
    cli.add_argument("--server-ip", required=True, help="VoIP Server IP address")
    cli.add_argument("--server-port", type=int, default=10000, help="VoIP Server UDP port")
    cli.add_argument("--bind-ip", default="0.0.0.0", help="Local IP address to bind (e.g. Wi-Fi interface IP)")
    cli.add_argument("--bind-port", type=int, default=0, help="Local UDP port to bind")
    cli.add_argument("--duration", type=float, default=30.0, help="Call duration in seconds")
    cli.add_argument("--phone-id", default="phone-1", help="Identifier for logging")
    cli.add_argument("--dscp", type=int, default=46, help="IP DSCP value (default: 46 for Voice EF = 0xb8)")
    cli.add_argument("--output-json", default="", help="Path to write JSON results")

    return parser.parse_args()

def handle_rtp_echo(sock, port):
    # Optimization: Pre-allocate reusable buffer and memoryview for zero-copy echo
    buf = bytearray(1024)
    view = memoryview(buf)
    recvfrom_into = sock.recvfrom_into
    sendto = sock.sendto

    while True:
        try:
            nbytes, addr = recvfrom_into(buf)
            sendto(view[:nbytes], addr)
        except Exception:
            break

def run_server(args):
    ports = [int(p.strip()) for p in args.ports.split(",")]
    sockets = []
    threads = []

    print(f"=== VOIP MEDIA SERVER LISTENING on ports {ports} (OPTIMIZED) ===")
    for port in ports:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 * 1024 * 1024)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 2 * 1024 * 1024)
        if getattr(args, "dscp", 0) > 0:
            try:
                sock.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, args.dscp << 2)
            except Exception as e:
                print(f"Warning: Could not set IP_TOS on server socket: {e}")
        sock.bind((args.bind_ip, port))
        sockets.append(sock)

        t = threading.Thread(target=handle_rtp_echo, args=(sock, port), daemon=True)
        t.start()
        threads.append(t)

    time.sleep(args.duration)
    for s in sockets:
        s.close()
    print("=== VOIP MEDIA SERVER TERMINATED ===")

def run_client(args):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024 * 1024)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1024 * 1024)

    # Set DSCP (default EF: DSCP 46 -> IP TOS 0xb8 = 184)
    dscp_val = getattr(args, "dscp", 46)
    if dscp_val > 0:
        try:
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_TOS, dscp_val << 2)
        except Exception as e:
            print(f"Warning: Could not set IP_TOS: {e}")

    # Optionally bind to local IP/port (e.g. physical Wi-Fi IP)
    bind_ip = getattr(args, "bind_ip", "0.0.0.0")
    bind_port = getattr(args, "bind_port", 0)
    if bind_ip != "0.0.0.0" or bind_port != 0:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((bind_ip, bind_port))
        except Exception as e:
            print(f"Warning: Could not bind to {bind_ip}:{bind_port}: {e}")

    # Connect UDP socket once to avoid repeated routing lookups
    try:
        sock.connect((args.server_ip, args.server_port))
    except Exception as e:
        print(f"Error connecting UDP socket: {e}")
        return 1

    # Set non-blocking mode for fast echo polling without exception overhead
    sock.setblocking(False)

    # G.711: 12 bytes RTP header + 160 bytes audio payload = 172 bytes
    tx_buf = bytearray(172)
    rx_buf = bytearray(512)

    ssrc = 0x12345678
    seq = 0
    rtp_ts = 0

    packet_interval = 0.020  # 20ms = 50 PPS
    pack_into = RTP_STRUCT.pack_into
    send_call = sock.send
    recv_into = sock.recv_into
    perf_counter = time.perf_counter
    sleep_func = time.sleep

    print(f"=== WI-FI PHONE ({args.phone_id}) CALL IN PROGRESS (OPTIMIZED) ===")
    print(f"  Target Server: {args.server_ip}:{args.server_port} | Codec: G.711 (20ms, 64kbps + overhead)")
    print(f"  Call Duration: {args.duration}s")

    end_time = perf_counter() + args.duration
    sent = 0
    received = 0
    next_send = perf_counter()

    while perf_counter() < end_time:
        # Build RTP packet: V=2, P=0, X=0, CC=0, M=0, PT=0 (PCMU)
        pack_into(tx_buf, 0, 0x80, 0x00, seq & 0xffff, rtp_ts & 0xffffffff, ssrc)
        try:
            send_call(tx_buf)
            sent += 1
        except Exception:
            pass

        seq += 1
        rtp_ts += 160

        # Drain any available echo replies non-blockingly
        while True:
            try:
                nbytes = recv_into(rx_buf)
                if nbytes >= 12:
                    received += 1
            except (BlockingIOError, socket.error):
                break

        next_send += packet_interval
        wait = next_send - perf_counter()
        if wait > 0:
            if wait > 0.001:
                sleep_func(wait - 0.0005)
            while perf_counter() < next_send:
                pass

    # Final grace period to receive lingering echoes
    grace_end = perf_counter() + 0.3
    while perf_counter() < grace_end:
        try:
            nbytes = recv_into(rx_buf)
            if nbytes >= 12:
                received += 1
        except (BlockingIOError, socket.error):
            sleep_func(0.01)

    sock.close()

    loss_pct = ((sent - received) / sent * 100.0) if sent > 0 else 0.0
    status = "PASS" if loss_pct < 2.0 else "WARN"

    result = {
        "phone_id": args.phone_id,
        "sent_packets": sent,
        "received_packets": received,
        "loss_pct": round(loss_pct, 2),
        "status": status
    }

    print(f"=== WI-FI PHONE ({args.phone_id}) CALL ENDED: Sent {sent}, Recv {received}, Loss {loss_pct:.2f}% ===")

    if args.output_json:
        with open(args.output_json, "w") as f:
            json.dump(result, f, indent=2)

    return 0

def main():
    args = parse_args()
    if args.mode == "server":
        run_server(args)
    elif args.mode == "client":
        sys.exit(run_client(args))

if __name__ == "__main__":
    main()
