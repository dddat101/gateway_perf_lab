#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - AUTOMATED SCENARIO RUNNER
# Evaluates Wire-rate, Rate Mismatch Bursts, STB Gaming/VOD, Simultaneous Use, QoS
# Supports Per-Test-Case Independent Runs & Dual-Sided (WAN/LAN) Captures
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DEBUG="${DEBUG:-0}"
VERBOSE="${VERBOSE:-0}"
DRY_RUN=0
NO_CAPTURE=0
CUSTOM_DURATION=""
CUSTOM_WIFI_MODE=""
SCENARIO_TMP_DIR=""
ACTIVE_BG_PIDS=()
ENABLE_LOG_TEE=0
CUSTOM_LOG_FILE=""
CUSTOM_UNICAST_MODE=""
CUSTOM_UNICAST_OMIT=""
CUSTOM_UNICAST_RATE=""
AUTO_ADAPT_BURST_SPEED="${AUTO_ADAPT_BURST_SPEED:-1}"
ADAPTED_NIC=""
ORIGINAL_NIC_SPEED=""
CUSTOM_GFN_FPS=""
CUSTOM_GFN_BITRATE=""
CUSTOM_GFN_JITTER=""

usage_header() {
    cat <<'EOF'
==================================================================
  Gateway Performance Lab - Automated Scenario Runner
==================================================================

Usage:
  sudo ./scripts/scenario.sh [OPTIONS] <SCENARIO>
  ./scripts/scenario.sh -h [SCENARIO]        (View options for a specific test case)

Global Options (Supported across all scenarios):
  --debug, -v              Enable detailed debug logging (shows exact commands executed at each step)
  --deep-audit, -D         Enable deep packet-by-packet identity correlation & latency audit
  --no-adapt-speed         Disable auto 100M physical LAN link adaptation for burst tests
  --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96, 0 = full packet)
  --no-capture, -C         Disable packet capture (saves disk space & test overhead)
  --collect-artifacts, -A  Bundle PCAPs, logs, JSON metrics & state into artifacts/
  --log, -l [file]         Mirror console output to log file (default: logs/scenario_*.log)
  --dry-run, -n            Dry-run mode (validate configs/parameters without traffic)
  -h, --help [scenario]    Show this help menu (or details for a specific scenario)

EOF
}

usage_block_wr01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-WR-01] 1024B BIDIRECTIONAL UNICAST WIRE-RATE                 |
+------------------------------------------------------------------+
  Scenario Aliases : unicast, tc_wr_01
  Objective        : Bidirectional wire-rate forwarding between WAN & LAN
  Traffic Profile  : 1024-byte UDP (L4 payload: 982B) @ 950 Mbps wire-rate
  Pass Criteria    : 0% frame loss across both directions (Zero Packet Loss)

  Supported Options:
    --bitrate, -b <rate>     Target bitrate (default: 950M, e.g. 950M, 475M)
    --duration, -d <sec>     Test stream duration in seconds (default: 10)
    --omit, -O <sec>         Warm-up omit seconds for flow learning (default: 2)
    --unicast-mode, -U <m>   Execution mode: 'sequential' (default) or 'concurrent'
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh unicast
    sudo ./scripts/scenario.sh -b 475M unicast
    sudo ./scripts/scenario.sh -b 950M -d 10 -O 2 unicast
    sudo ./scripts/scenario.sh -C -d 10 unicast
    sudo ./scripts/scenario.sh -U concurrent -d 15 unicast

EOF
}

usage_block_wr02() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-WR-02] 1024B MULTICAST 80 MBPS FORWARDING                    |
+------------------------------------------------------------------+
  Scenario Aliases : multicast, tc_wr_02
  Objective        : Validate IPTV Multicast forwarding (WAN -> STB LAN)
  Multicast Group  : 239.255.1.1:5001 @ 80 Mbps, 1024B UDP frames
  Pass Criteria    : 0% multicast frame loss forwarded across DUT bridge

  Supported Options:
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh multicast
    sudo ./scripts/scenario.sh -s 96 -A tc_wr_02
    sudo ./scripts/scenario.sh -C multicast

EOF
}

usage_block_rm01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-RM-01] RATE MISMATCH BURST CASE 1 (50% LOAD)                 |
+------------------------------------------------------------------+
  Scenario Aliases : burst_case1, tc_rm_01
  Objective        : Evaluate switch buffer absorptivity (1G WAN -> 100M LAN)
  Burst Profile    : 1500-byte frames, burst size = 53 frames @ 50% load (500 Mbps)
  Pass Criteria    : 0 frame loss (DUT switch buffer absorbs burst completely)

  Supported Options:
    --no-adapt-speed         Disable auto 100M physical LAN link adaptation
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh burst_case1
    sudo ./scripts/scenario.sh -s 128 -A tc_rm_01
    sudo ./scripts/scenario.sh -C burst_case1

EOF
}

usage_block_rm02() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-RM-02] RATE MISMATCH BURST CASE 2 (16% LOAD)                 |
+------------------------------------------------------------------+
  Scenario Aliases : burst_case2, tc_rm_02
  Objective        : Evaluate long burst absorption (1G WAN -> 100M LAN)
  Burst Profile    : 1500-byte frames, burst size = 100 frames @ 16% load (160 Mbps)
  Pass Criteria    : 0 frame loss across 100 consecutive frames

  Supported Options:
    --no-adapt-speed         Disable auto 100M physical LAN link adaptation
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh burst_case2
    sudo ./scripts/scenario.sh -A tc_rm_02
    sudo ./scripts/scenario.sh -s 0 burst_case2

EOF
}

usage_block_app01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-APP-01] GEFORCE NOW UDP CLOUD GAMING                         |
+------------------------------------------------------------------+
  Scenario Aliases : geforce, tc_app_01
  Objective        : Cloud gaming streaming verification on 100M STB client
  Traffic Profile  : 40 Mbps interactive UDP stream (Ports: 49003-49006)
  Pass Criteria    : Packet loss < 0.5%, status "Normal", low jitter

  Supported Options:
    --fps, -F <60|120>       Set frame rate: 60 (standard) or 120 (competitive esports)
    --gfn-bitrate <mbps>     Target video bitrate in Mbps (default: 25 for 60fps, 50 for 120fps)
    --gfn-jitter <ms>        Max RFC 3550 jitter tolerance limit (default: 2.0 for 60fps, 1.5 for 120fps)
    --duration, -d <sec>     Set streaming duration in seconds (default: 5.0)
    --stability, --soak      Soak mode: disables PCAP, duration default 60s
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh geforce
    sudo ./scripts/scenario.sh --fps 120 geforce
    sudo ./scripts/scenario.sh --fps 120 --gfn-bitrate 50 --max-jitter 1.0 -v geforce
    sudo ./scripts/scenario.sh -d 60 --no-capture geforce
    sudo ./scripts/scenario.sh --stability geforce
    sudo ./scripts/scenario.sh -d 300 -C -A tc_app_01

EOF
}

usage_block_app02() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-APP-02] 4K UHD+DOLBY 1.2X VOD PLAYBACK                       |
+------------------------------------------------------------------+
  Scenario Aliases : vod, tc_app_02
  Objective        : 4K UHD VOD playback with Dolby Atmos at 1.2x playback speed
  Traffic Profile  : 40 Mbps TCP HTTP media stream to 100M STB client
  Pass Criteria    : Continuous smooth throughput without buffer stall or drops

  Supported Options:
    --duration, -d <sec>     Set streaming duration in seconds (default: 30)
    --stability, --soak      Soak mode: disables PCAP, duration default 60s
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh vod
    sudo ./scripts/scenario.sh -d 60 -C vod
    sudo ./scripts/scenario.sh --stability vod
    sudo ./scripts/scenario.sh -d 120 -A tc_app_02

EOF
}

usage_block_sim01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-SIM-01] SIMULTANEOUS & MULTI-BAND BENCHMARK (5 TRIALS)       |
+------------------------------------------------------------------+
  Scenario Aliases : simultaneous, tc_sim_01, sequential, tc_sim_seq,
  Objective        : Multi-station aggregate throughput benchmark
  Architecture     : Wired LAN client + Wi-Fi bands (2.4GHz / 5GHz / 6GHz)
  Pass Criteria    : 5 of 5 consecutive trials meet aggregate throughput targets

  Execution Flavors / Sub-scenarios:
    sequential, tc_sim_seq   Sequential isolated benchmarks (5GHz then 2.4GHz)
    simultaneous, tc_sim_01  Simultaneous concurrent traffic (Wired + Tri-Band)
    remote, tc_sim_remote    Distributed execution via Remote Client PC (SSH)
    tri_station, tc_sim_tri  3-way physical concurrency: Wired PC + 5GHz + 2.4GHz

  Supported Options:
    --wifi-mode, -W <mode>   Adaptive Wi-Fi deployment mode:
                             - auto        : Auto-detect NICs & remote PC (default)
                             - real_single : Local physical Wi-Fi NIC (wlan0)
                             - remote      : Remote PC client via SSH
                             - remote_only : Exclusively run on Remote Client PC
                             - distributed : Hybrid local + remote multi-station
                             - tri_station : 3 physical stations (local + remote)
                             - emulated    : mac80211_hwsim virtual Wi-Fi
    --remote-only, -R        Run Wi-Fi traffic exclusively on Remote Client PC
    --duration, -d <sec>     Duration per trial in seconds (default: 10)
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh sequential
    sudo ./scripts/scenario.sh simultaneous
    sudo ./scripts/scenario.sh tri_station
    sudo ./scripts/scenario.sh -W remote simultaneous
    sudo ./scripts/scenario.sh -R -d 15 -A sequential
    sudo ./scripts/scenario.sh -s 96 -A tc_sim_01

EOF
}

usage_block_qos01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-QOS-01] WI-FI PHONE VOIP QOS & WIRED PC ISOLATION            |
+------------------------------------------------------------------+
  Scenario Aliases : voice_qos, tc_qos_01
  Objective        : Validate 2 Wi-Fi phone calls quality (SIP/RTP, DSCP EF)
                     during concurrent saturated Wired PC throughput
  Traffic Profile  : 2 VoIP calls (G.711, 64 kbps, DSCP 46) + Wired PC TCP load
  Pass Criteria    : VoIP packet loss < 1%, jitter < 20ms, no call drops
                     Wired PC throughput maintains fair baseline isolation

  Supported Options:
    --voip-engine, -E <eng>  Select VoIP test generator engine:
                             - auto   : Auto-select best engine available (default)
                             - pjsua  : Production PJSUA SIP user agent
                             - sipp   : SIPp protocol traffic generator
                             - python : Embedded pure-Python RTP/SIP generator
    --wifi-mode, -W <mode>   Wi-Fi mode (auto, real_single, remote, remote_only, etc.)
    --remote-only, -R        Run VoIP calls exclusively on Remote Client PC
    --duration, -d <sec>     VoIP test duration in seconds (default: 30)
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh voice_qos
    sudo ./scripts/scenario.sh -E pjsua voice_qos
    sudo ./scripts/scenario.sh -W remote -E python tc_qos_01
    sudo ./scripts/scenario.sh -d 45 -C -A voice_qos
    sudo ./scripts/scenario.sh -R -E auto voice_qos

EOF
}

usage_block_composite() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [COMPOSITE] MULTI-PHASE TEST BATCH SUITES                        |
+------------------------------------------------------------------+
  Scenario Aliases : wire_rate, rate_mismatch, real_world_stb, all
  Objective        : Automated consecutive execution of multiple test phases

  Available Test Suites:
    wire_rate        Phase 1: TC-WR-01 (Unicast) + TC-WR-02 (Multicast)
    rate_mismatch    Phase 2: TC-RM-01 (50% burst) + TC-RM-02 (16% burst)
    real_world_stb   Phase 3: TC-APP-01 (GeForce NOW) + TC-APP-02 (4K VOD)
    all              Complete Suite: All phases in compliance order (Default)

  Supported Options:
    Inherits all Global Options and scenario-specific flags:
    --no-adapt-speed         Disable auto 100M physical LAN link adaptation
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Set packet capture snaplen for all tests
    --wifi-mode, -W <mode>   Set Wi-Fi mode for wireless test cases
    --remote-only, -R        Route wireless traffic to Remote Client PC
    --voip-engine, -E <eng>  Set VoIP engine for QoS test case
    --no-capture, -C         Disable packet capture across all tests
    --collect-artifacts, -A  Package all deliverables at end of suite
    --log, -l [file]         Mirror suite output to a log file
    --dry-run, -n            Simulate suite execution without traffic

  Examples:
    sudo ./scripts/scenario.sh all
    sudo ./scripts/scenario.sh wire_rate
    sudo ./scripts/scenario.sh rate_mismatch
    sudo ./scripts/scenario.sh real_world_stb
    sudo ./scripts/scenario.sh -C -A all
==================================================================
EOF
}

usage() {
    local filter="${1:-all}"
    usage_header

    case "${filter,,}" in
        unicast|tc_wr_01)
            usage_block_wr01
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        multicast|tc_wr_02)
            usage_block_wr02
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        burst_case1|tc_rm_01)
            usage_block_rm01
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        burst_case2|tc_rm_02)
            usage_block_rm02
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        geforce|tc_app_01)
            usage_block_app01
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        vod|tc_app_02)
            usage_block_app02
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        simultaneous|tc_sim_01|sequential|tc_sim_seq|multiband|remote|tc_sim_remote|distributed|tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way)
            usage_block_sim01
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        voice_qos|tc_qos_01)
            usage_block_qos01
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        wire_rate|rate_mismatch|real_world_stb|composite)
            usage_block_composite
            printf 'Tip: Run "./scripts/scenario.sh -h" without arguments to view all test cases.\n\n'
            ;;
        all|"")
            usage_block_wr01
            usage_block_wr02
            usage_block_rm01
            usage_block_rm02
            usage_block_app01
            usage_block_app02
            usage_block_sim01
            usage_block_qos01
            usage_block_composite
            ;;
        *)
            usage_block_wr01
            usage_block_wr02
            usage_block_rm01
            usage_block_rm02
            usage_block_app01
            usage_block_app02
            usage_block_sim01
            usage_block_qos01
            usage_block_composite
            ;;
    esac
}

# Defensive cleanup trap: cleans up temporary directory, background PIDs, and active captures
cleanup_scenario_trap() {
    local exit_code=$?
    trap - EXIT INT TERM ERR
    set +e

    # Terminate any active captures
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop 2>/dev/null || true
    fi

    # Terminate any tracked background jobs
    if (( ${#ACTIVE_BG_PIDS[@]} > 0 )); then
        for pid in "${ACTIVE_BG_PIDS[@]}"; do
            if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done
        ACTIVE_BG_PIDS=()
    fi

    # Terminate any remaining test servers in ns-wan (use exact process name -x to avoid matching caller script arguments like -E sipp)
    if ns_exists "${WAN_NS:-ns-wan}"; then
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x pjsua 2>/dev/null || true
        ip netns exec "${WAN_NS:-ns-wan}" pkill -KILL -x sipp 2>/dev/null || true
        pkill -TERM -f "[v]oip_call_simulator.py" 2>/dev/null || true
    fi

    # Terminate lingering remote processes if remote client was engaged
    if [[ -n "${REMOTE_CLIENT_HOST:-}" ]]; then
        "${SCRIPT_DIR}/remote_client.sh" clean >/dev/null 2>&1 || true
    fi

    # Defensive cleanup of physical Wi-Fi test route and iptables mangle rule
    if [[ -n "${CLEANUP_WIFI_ROUTE:-}" ]]; then
        ip route del ${CLEANUP_WIFI_ROUTE} 2>/dev/null || true
    fi
    if [[ -n "${CLEANUP_IPTABLES_MANGLE:-}" ]]; then
        eval "${CLEANUP_IPTABLES_MANGLE}" 2>/dev/null || true
    fi
    if [[ -n "${CLEANUP_WAN_MANGLE:-}" ]]; then
        eval "${CLEANUP_WAN_MANGLE}" 2>/dev/null || true
    fi

    # Defensive restoration of physical LAN link speed if adapted for burst tests
    restore_burst_physical_speed

    # Preserve raw iperf3 trial JSON outputs to persistent raw_iperf directory
    if [[ -n "${SCENARIO_TMP_DIR:-}" && -d "${SCENARIO_TMP_DIR}" ]]; then
        local raw_iperf_dir="${LOG_DIR:-${LAB_DIR}/logs}/raw_iperf"
        if compgen -G "${SCENARIO_TMP_DIR}/iperf_*.json" >/dev/null 2>&1; then
            mkdir -p "${raw_iperf_dir}" 2>/dev/null || true
            cp -f "${SCENARIO_TMP_DIR}"/iperf_*.json "${raw_iperf_dir}/" 2>/dev/null || true
            chmod 0666 "${raw_iperf_dir}"/iperf_*.json 2>/dev/null || true
            log_info "Preserved raw iperf3 trial outputs to: ${raw_iperf_dir}/"
        fi
        rm -rf "${SCENARIO_TMP_DIR}" 2>/dev/null || true
    fi

    if (( exit_code != 0 )); then
        log_error "Scenario runner exited with code ${exit_code}."
    fi

    if (( ENABLE_LOG_TEE == 1 )); then
        exec 1>&- 2>&-
        wait 2>/dev/null || true
    fi

    exit "${exit_code}"
}

# Helper to execute a subphase wrapped in dual-sided packet capture
run_with_dual_capture() {
    local tag="$1"
    local lan_ns="$2"
    local bpf_filter="$3"
    local wifi_target="${4:-}"
    if [[ "${wifi_target}" =~ ^run_ ]]; then
        wifi_target=""
        shift 3
    else
        shift 4
    fi

    if [[ -z "${wifi_target}" && "${tag}" =~ (simultaneous|tc_sim) ]]; then
        if [[ -n "${DETECTED_WIFI_IF:-}" ]]; then
            wifi_target="${DETECTED_WIFI_IF}"
        fi
    fi

    if (( DRY_RUN == 0 && NO_CAPTURE == 0 )) && [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        log_cmd "${SCRIPT_DIR}/capture.sh start_dual \"${tag}\" \"${lan_ns}\" \"${bpf_filter}\" \"${CAPTURE_SNAPLEN:-96}\" \"${wifi_target}\""
        "${SCRIPT_DIR}/capture.sh" start_dual "${tag}" "${lan_ns}" "${bpf_filter}" "${CAPTURE_SNAPLEN:-96}" "${wifi_target}" || true
    fi

    # Execute the test function
    "$@"

    if (( DRY_RUN == 0 && NO_CAPTURE == 0 )) && [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        log_cmd "${SCRIPT_DIR}/capture.sh stop"
        "${SCRIPT_DIR}/capture.sh" stop || true

        # If user requested --merge-lan, execute post-merge cross-DUT evidence audit
        if [[ "${MERGE_LAN:-0}" == "1" ]]; then
            "${SCRIPT_DIR}/capture.sh" merge-lan --audit ${DEEP_AUDIT:+--deep} || true
        fi

        # If this was voice QoS test and capture.sh stop did not already audit it, run fallback audit
        if [[ "${tag}" =~ (voice|qos) ]] && [[ ! -f "${LOG_DIR}/voice_qos_audit.json" ]] && [[ -x "${LAB_DIR}/tools/voip_pcap_audit.py" ]]; then
            local wan_cap lan_cap p1_cap p2_cap v_mode
            wan_cap="$(cat "${STATE_DIR}/latest_wan_pcap.txt" 2>/dev/null || true)"
            lan_cap="$(cat "${STATE_DIR}/latest_lan_pcap.txt" 2>/dev/null || true)"
            p1_cap="$(cat "${STATE_DIR}/latest_phone1_pcap.txt" 2>/dev/null || true)"
            p2_cap="$(cat "${STATE_DIR}/latest_phone2_pcap.txt" 2>/dev/null || true)"
            v_mode="$(cat "${STATE_DIR}/latest_voip_mode.txt" 2>/dev/null || echo "${CUSTOM_WIFI_MODE:-distributed}")"

            if [[ -f "${wan_cap}" ]]; then
                local -a audit_cmd=("${LAB_DIR}/tools/voip_pcap_audit.py" "--wan-pcap" "${wan_cap}")
                if [[ -f "${p1_cap}" ]]; then audit_cmd+=("--phone1-pcap" "${p1_cap}"); fi
                if [[ -f "${p2_cap}" ]]; then audit_cmd+=("--phone2-pcap" "${p2_cap}"); fi
                if [[ -f "${lan_cap}" ]]; then audit_cmd+=("--lan-pcap" "${lan_cap}"); fi
                if [[ -n "${v_mode}" ]]; then audit_cmd+=("--mode" "${v_mode}"); fi
                audit_cmd+=("--output" "${LOG_DIR}/voice_qos_audit.json")
                log_cmd "${audit_cmd[*]}"
                "${audit_cmd[@]}" || true
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# Defensive Client Endpoint Setup (Assures IP & Default Route in Netns)
# ------------------------------------------------------------------------------
ensure_client_endpoint() {
    local ns="$1"
    local fallback_ip="$2"
    local gw="${DUT_LAN_IP:-192.168.1.1}"

    if ! ns_exists "${ns}"; then
        return 0
    fi

    log_cmd "ip -n ${ns} link set dev eth0 up"
    ip -n "${ns}" link set dev eth0 up 2>/dev/null || true

    # Check if any active IPv4 is already assigned to eth0
    local curr_ip
    curr_ip="$(ip -n "${ns}" -4 -br addr show dev eth0 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)"
    if [[ -z "${curr_ip}" ]]; then
        log_info "Assigning fallback IPv4 ${fallback_ip}/${LAN_PREFIX:-24} to ${ns}:eth0..."
        log_cmd "ip -n ${ns} addr replace ${fallback_ip}/${LAN_PREFIX:-24} dev eth0"
        ip -n "${ns}" addr replace "${fallback_ip}/${LAN_PREFIX:-24}" dev eth0 2>/dev/null || true
        curr_ip="${fallback_ip}"
    fi

    # Dynamically synchronize target IP variables so tests use the actual leased DHCP address
    if [[ "${ns}" == "${STB_NS:-ns-stb}" ]]; then
        STB_IP="${curr_ip}"
        export STB_IP
    elif [[ "${ns}" == "${PC_NS:-ns-pc}" ]]; then
        PC_IP="${curr_ip}"
        export PC_IP
    fi

    # Ensure default route exists via DUT LAN IP to route traffic to WAN
    if ! ip -n "${ns}" -4 route show | grep -q default; then
        log_info "Configuring default route via ${gw} in ${ns}..."
        log_cmd "ip -n ${ns} route replace default via ${gw} dev eth0"
        ip -n "${ns}" route replace default via "${gw}" dev eth0 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 1A: Bidirectional 1024-byte Unicast (TC-WR-01)
# ------------------------------------------------------------------------------
run_subphase_unicast() {
    log_step "[TC-WR-01] Bidirectional Unicast 1024B Wire-Rate Forwarding"
    local tools_dir="${LAB_DIR}/tools"
    local uni_json="${LOG_DIR}/unicast_result.json"
    local duration="${CUSTOM_DURATION:-10}"
    local unicast_rate="${CUSTOM_UNICAST_RATE:-${UNICAST_TARGET_RATE:-950M}}"
    local unicast_mode="${CUSTOM_UNICAST_MODE:-${UNICAST_MODE:-sequential}}"
    local omit_sec="${CUSTOM_UNICAST_OMIT:-${UNICAST_OMIT_SEC:-2}}"
    local sock_buf="${UNICAST_SOCKET_BUFFER:-4M}"
    local fwd_port="${UNICAST_FORWARD_PORT:-5002}"
    local rev_port="${UNICAST_REVERSE_PORT:-5012}"

    # Compute expected packet rate dynamically based on target rate and 1024B frame size
    local rate_clean="${unicast_rate%[Bb/s]*}"
    local rate_num="${rate_clean%[MmKkGg]*}"
    local rate_unit="${rate_clean: -1}"
    local rate_bps=0
    case "${rate_unit^^}" in
        G) rate_bps=$(( rate_num * 1000000000 )) ;;
        M) rate_bps=$(( rate_num * 1000000 )) ;;
        K) rate_bps=$(( rate_num * 1000 )) ;;
        *) rate_bps=$(( rate_num )) ;;
    esac
    local pps=$(( rate_bps / (1024 * 8) ))
    local pps_k=$(( (pps + 500) / 1000 ))
    local pps_str="~${pps_k}k PPS"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test 1024B bidirectional unicast (${unicast_mode}) at ${unicast_rate} (${pps_str}, -w ${sock_buf}, ${duration}s, omit ${omit_sec}s) between ns-wan and ns-pc"
        return 0
    fi

    local engine="${WIRE_RATE_ENGINE:-auto}"
    if [[ "${engine}" == "auto" ]]; then
        if check_command iperf3; then
            engine="iperf3"
        else
            engine="python"
        fi
    fi

    # Optimize kernel socket buffer thresholds to prevent host-side queue drops
    log_cmd "sysctl -w net.core.rmem_max=67108864"
    sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1 || true
    log_cmd "sysctl -w net.core.wmem_max=67108864"
    sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1 || true

    if [[ "${engine}" == "iperf3" ]]; then
        log_info "Using high-performance C-based engine: iperf3 UDP (-l 982, -w ${sock_buf}, ${unicast_rate}, ${pps_str})..."
        local fwd_out="${SCENARIO_TMP_DIR}/iperf_uni_fwd.json"
        local rev_out="${SCENARIO_TMP_DIR}/iperf_uni_rev.json"

        if [[ "${unicast_mode}" == "concurrent" ]]; then
            log_info "Executing CONCURRENT Full-Duplex Forward (port ${fwd_port}) + Reverse (port ${rev_port}) for ${duration}s (omit ${omit_sec}s warm-up)..."
            # Start 2 iperf3 servers in ns-wan (forward WAN->PC, reverse PC->WAN)
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${rev_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${rev_port}" -D >/dev/null 2>&1
            sleep 0.4

            # Launch both Forward & Reverse streams CONCURRENTLY from ns-pc (passes NAT statefully)
            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -u -p ${fwd_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -R -J > ${fwd_out} 2>&1 &"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -R -J > "${fwd_out}" 2>&1 &
            local fwd_pid=$!
            ACTIVE_BG_PIDS+=("${fwd_pid}")

            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -u -p ${rev_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -J > ${rev_out} 2>&1 &"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${rev_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -J > "${rev_out}" 2>&1 &
            local rev_pid=$!
            ACTIVE_BG_PIDS+=("${rev_pid}")

            # Wait for both bidirectional streams to complete concurrently
            wait "${fwd_pid}" "${rev_pid}" || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        else
            log_info "Executing SEQUENTIAL Bidirectional Wire-rate (Forward then Reverse) for ${duration}s each (omit ${omit_sec}s warm-up)..."
            # 1. Forward Path (WAN -> LAN PC via Reverse -R)
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            sleep 0.4
            log_step "Step 1/2: Forward Path (WAN -> LAN PC) at ${unicast_rate} (${pps_str})..."
            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -u -p ${fwd_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -R -J > ${fwd_out}"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -R -J > "${fwd_out}" 2>&1 || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
            sleep 0.5

            # 2. Reverse Path (LAN PC -> WAN)
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${fwd_port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${fwd_port}" -D >/dev/null 2>&1
            sleep 0.4
            log_step "Step 2/2: Reverse Path (LAN PC -> WAN) at ${unicast_rate} (${pps_str})..."
            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -u -p ${fwd_port} -b ${unicast_rate} -l 982 -w ${sock_buf} -t ${duration} -O ${omit_sec} -J > ${rev_out}"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -u -p "${fwd_port}" -b "${unicast_rate}" -l 982 -w "${sock_buf}" -t "${duration}" -O "${omit_sec}" -J > "${rev_out}" 2>&1 || true
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
            ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        fi

        # Preserve raw iperf3 trial outputs for audit & compliance
        mkdir -p "${LOG_DIR}/raw_iperf" 2>/dev/null || true
        cp -f "${fwd_out}" "${LOG_DIR}/raw_iperf/iperf_uni_fwd.json" 2>/dev/null || true
        cp -f "${rev_out}" "${LOG_DIR}/raw_iperf/iperf_uni_rev.json" 2>/dev/null || true
        chmod 0666 "${LOG_DIR}/raw_iperf"/iperf_uni_*.json 2>/dev/null || true

        # Consolidate bidirectional results into standard schema
        log_cmd "${tools_dir}/metric_parser.py consolidate-iperf-bidi --forward ${fwd_out} --reverse ${rev_out} --mode ${unicast_mode} --output ${uni_json}"
        "${tools_dir}/metric_parser.py" consolidate-iperf-bidi \
            --forward "${fwd_out}" \
            --reverse "${rev_out}" \
            --mode "${unicast_mode}" \
            --output "${uni_json}"
    else
        log_info "Using native zero-allocation Python engine: traffic_generator.py..."
        local py_dur=$(( duration > 4 ? duration : 4 ))
        log_cmd "ip netns exec ${PC_NS:-ns-pc} ${tools_dir}/traffic_generator.py unicast-recv --bind-ip ${PC_IP:-192.168.1.10} --bind-port 5002 --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 5002 --duration $(( py_dur + 2 )) --output-json ${uni_json} &"
        ip netns exec "${PC_NS:-ns-pc}" "${tools_dir}/traffic_generator.py" unicast-recv \
            --bind-ip "${PC_IP:-192.168.1.10}" --bind-port 5002 \
            --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5002 \
            --duration $(( py_dur + 2 )) \
            --output-json "${uni_json}" >/dev/null 2>&1 &
        local rx_pid=$!
        ACTIVE_BG_PIDS+=("${rx_pid}")
        sleep 0.2

        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py unicast-send --dest-ip ${PC_IP:-192.168.1.10} --dest-port 5002 --wait-handshake --packet-size ${UNICAST_PACKET_SIZE:-1024} --duration ${py_dur} --rate-mbps 950.0"
        ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" unicast-send \
            --dest-ip "${PC_IP:-192.168.1.10}" --dest-port 5002 \
            --wait-handshake \
            --packet-size "${UNICAST_PACKET_SIZE:-1024}" --duration "${py_dur}" --rate-mbps 950.0

        wait "${rx_pid}" || true
        if [[ -f "${uni_json}" ]]; then
            log_cmd "${tools_dir}/metric_parser.py format-card ${uni_json}"
            "${tools_dir}/metric_parser.py" format-card "${uni_json}"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 1B: Multicast Forwarding 1024B (TC-WR-02)
# ------------------------------------------------------------------------------
run_subphase_multicast() {
    log_step "[TC-WR-02] Multicast Forwarding 1024B (Group: ${MULTICAST_GROUP:-239.255.0.1})"
    local tools_dir="${LAB_DIR}/tools"
    local mcast_json="${LOG_DIR}/multicast_result.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test 1024B multicast forwarding (2,000 packets) to group ${MULTICAST_GROUP:-239.255.0.1}"
        return 0
    fi

    # Start IGMP proxy forwarder in DUT namespace if simulated
    local mcast_fwd_pid=""
    if ns_exists "${DUT_NS:-ns-dut}"; then
        log_cmd "ip netns exec ${DUT_NS:-ns-dut} ${tools_dir}/mcast_forwarder.py --group-ip ${MULTICAST_GROUP:-239.255.0.1} --port 5003 --wan-if-ip ${DUT_WAN_IP:-10.10.0.100} --lan-if-ip ${DUT_LAN_IP:-192.168.1.1} --duration 12.0 >/dev/null 2>&1 &"
        ip netns exec "${DUT_NS:-ns-dut}" "${tools_dir}/mcast_forwarder.py" \
            --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
            --wan-if-ip "${DUT_WAN_IP:-10.10.0.100}" --lan-if-ip "${DUT_LAN_IP:-192.168.1.1}" \
            --duration 12.0 >/dev/null 2>&1 &
        mcast_fwd_pid=$!
        ACTIVE_BG_PIDS+=("${mcast_fwd_pid}")
        sleep 0.2
    fi

    # Start multicast receiver in STB namespace
    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/traffic_generator.py mcast-recv --group-ip ${MULTICAST_GROUP:-239.255.0.1} --port 5003 --expected-packets 2000 --timeout 5.0 --output-json ${mcast_json} >/dev/null 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" mcast-recv \
        --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
        --expected-packets 2000 --timeout 5.0 --output-json "${mcast_json}" >/dev/null 2>&1 &
    local mcast_rx_pid=$!
    ACTIVE_BG_PIDS+=("${mcast_rx_pid}")
    sleep 1.2

    # Start multicast sender in WAN namespace with warmup burst to trigger HW flow cache
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py mcast-send --group-ip ${MULTICAST_GROUP:-239.255.0.1} --port 5003 --packet-size ${MULTICAST_PACKET_SIZE:-1024} --packets 2000 --rate-mbps 80.0 --warmup-packets 30"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" mcast-send \
        --group-ip "${MULTICAST_GROUP:-239.255.0.1}" --port 5003 \
        --packet-size "${MULTICAST_PACKET_SIZE:-1024}" --packets 2000 --rate-mbps 80.0 \
        --warmup-packets 30

    wait "${mcast_rx_pid}" || true
    if [[ -n "${mcast_fwd_pid}" ]]; then
        kill "${mcast_fwd_pid}" 2>/dev/null || true
    fi
    if [[ -f "${mcast_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${mcast_json}"
        "${tools_dir}/metric_parser.py" format-card "${mcast_json}"
    fi
}

# ------------------------------------------------------------------------------
# Automated Physical Link Speed Adaptation for Rate Mismatch Bursts (Option 2)
# In physical topology without dedicated STB_IF, throttles the shared LAN adapter
# from 1 Gbps to 100 Mbps so that the DUT switch buffer is genuinely stressed.
# ------------------------------------------------------------------------------
adapt_burst_physical_speed() {
    local target_speed="${1:-100}"

    if (( AUTO_ADAPT_BURST_SPEED == 0 )); then
        log_info "Automatic physical link speed adaptation disabled by flag."
        return 0
    fi

    if [[ "${TOPOLOGY_MODE:-virtual}" != "physical" ]]; then
        return 0
    fi

    local phy_if="${STB_IF:-${PC_IF:-${LAN_IF:-}}}"
    if [[ -z "${phy_if}" ]] || [[ ! -e "/sys/class/net/${phy_if}" ]]; then
        return 0
    fi

    # Must be a real physical NIC backed by a hardware device in sysfs
    if [[ ! -d "/sys/class/net/${phy_if}/device" ]]; then
        return 0
    fi

    if ! command -v ethtool >/dev/null 2>&1; then
        log_warn "ethtool not available; cannot adapt physical link speed on ${phy_if}."
        return 0
    fi

    local current_speed
    current_speed="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' | tr -dc '0-9' || true)"
    if [[ -z "${current_speed}" ]]; then
        current_speed=1000
    fi

    if (( current_speed == target_speed )); then
        log_info "Physical LAN interface [${phy_if}] is already negotiated at ${target_speed} Mbps."
        return 0
    fi

    log_info "Physical Link Speed Adaptation: Adjusting [${phy_if}] link speed: ${current_speed}M -> ${target_speed}M Full-Duplex..."
    ADAPTED_NIC="${phy_if}"
    ORIGINAL_NIC_SPEED="${current_speed}"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would adapt physical link speed on [${phy_if}]: ${current_speed}M -> ${target_speed}M Full-Duplex"
        return 0
    fi

    log_cmd "ethtool -s ${phy_if} speed ${target_speed} duplex full autoneg on"
    if ! ethtool -s "${phy_if}" speed "${target_speed}" duplex full autoneg on 2>/dev/null; then
        log_cmd "ethtool -s ${phy_if} speed ${target_speed} duplex full autoneg off"
        ethtool -s "${phy_if}" speed "${target_speed}" duplex full autoneg off 2>/dev/null || true
    fi

    log_info "Waiting for physical link carrier re-negotiation on ${phy_if} (${target_speed}M)..."
    local count=0
    local link_up=0
    local now_speed=""
    local carrier=0
    while (( count < 35 )); do
        sleep 0.4
        carrier=0
        if [[ -f "/sys/class/net/${phy_if}/carrier" ]]; then
            carrier="$(cat "/sys/class/net/${phy_if}/carrier" 2>/dev/null || echo 0)"
        fi
        now_speed="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' | tr -dc '0-9' || true)"
        if [[ "${carrier}" == "1" && "${now_speed}" == "${target_speed}" ]]; then
            link_up=1
            break
        fi
        if [[ "${count}" -ge 15 && "${now_speed}" != "${target_speed}" ]]; then
            ethtool -s "${phy_if}" speed "${target_speed}" duplex full autoneg off 2>/dev/null || true
        fi
        count=$(( count + 1 ))
    done

    if (( link_up == 1 )); then
        log_pass "Physical LAN link successfully negotiated at ${target_speed} Mbps Full-Duplex on ${phy_if}."
    else
        local actual_spd
        actual_spd="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' || echo unknown)"
        log_warn "Physical link state on ${phy_if}: speed=${actual_spd} (Carrier: ${carrier}). Proceeding with test..."
    fi

    # Warm up ARP table and verify reachability to DUT gateway
    sleep 0.5
    if ns_exists "${STB_NS:-ns-stb}"; then
        ip netns exec "${STB_NS:-ns-stb}" ping -c 1 -W 2 "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1 || true
    fi
}

restore_burst_physical_speed() {
    if [[ -z "${ADAPTED_NIC:-}" ]]; then
        return 0
    fi

    local phy_if="${ADAPTED_NIC}"
    local restore_spd="${ORIGINAL_NIC_SPEED:-1000}"
    ADAPTED_NIC=""
    ORIGINAL_NIC_SPEED=""

    log_info "Restoring physical LAN adapter [${phy_if}] link speed to ${restore_spd} Mbps (Gigabit Auto-Negotiation)..."

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would restore physical link speed on [${phy_if}]: 100M -> ${restore_spd}M (Gigabit Auto-Negotiation)"
        return 0
    fi

    log_cmd "ethtool -s ${phy_if} autoneg on"
    ethtool -s "${phy_if}" autoneg on 2>/dev/null || ethtool -s "${phy_if}" speed "${restore_spd}" duplex full autoneg on 2>/dev/null || true

    log_info "Waiting for physical link carrier re-negotiation on ${phy_if} (${restore_spd}M)..."
    local count=0
    local link_up=0
    local now_speed=""
    local carrier=0
    while (( count < 35 )); do
        sleep 0.4
        carrier=0
        if [[ -f "/sys/class/net/${phy_if}/carrier" ]]; then
            carrier="$(cat "/sys/class/net/${phy_if}/carrier" 2>/dev/null || echo 0)"
        fi
        now_speed="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' | tr -dc '0-9' || true)"
        if [[ "${carrier}" == "1" && -n "${now_speed}" && "${now_speed}" -ge 1000 ]]; then
            link_up=1
            break
        fi
        count=$(( count + 1 ))
    done

    if (( link_up == 1 )); then
        log_pass "Physical LAN link restored to Gigabit (${now_speed} Mbps) on ${phy_if}."
    else
        local actual_spd
        actual_spd="$(ethtool "${phy_if}" 2>/dev/null | awk '/Speed:/ {print $2}' || echo unknown)"
        log_warn "Physical link state on ${phy_if}: speed=${actual_spd}."
    fi

    # Warm up ARP table for Gigabit PC endpoint
    sleep 0.5
    if ns_exists "${PC_NS:-ns-pc}"; then
        ip netns exec "${PC_NS:-ns-pc}" ping -c 1 -W 2 "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 2A: Burst Case 1 (1500B, 50% Load, >=53 Frames) (TC-RM-01)
# ------------------------------------------------------------------------------
run_subphase_burst_case1() {
    log_step "[TC-RM-01] WAN-to-LAN Rate Mismatch Burst Case 1 (1500B, 50% Load, >=53 Frames)"
    local tools_dir="${LAB_DIR}/tools"

    local c1_frames="${BURST_CASE1_FRAMES:-53}"
    local c1_load="${BURST_CASE1_LOAD:-50.0}"
    local c1_count="${BURST_COUNT:-20}"
    local c1_expected=$(( c1_frames * c1_count ))
    local c1_json="${LOG_DIR}/burst_case1.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test Burst Case 1: 1500B, Length=${c1_frames} frames, Load=${c1_load}%, Total=${c1_expected} frames"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local c1_rx_log="${SCENARIO_TMP_DIR}/burst_c1_rx.log"

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/traffic_generator.py burst-recv --bind-ip 0.0.0.0 --bind-port 5001 --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 5000 --expected-packets ${c1_expected} --timeout 5.0 --output-json ${c1_json} > ${c1_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "0.0.0.0" --bind-port 5001 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5000 \
        --expected-packets "${c1_expected}" --timeout 5.0 --output-json "${c1_json}" > "${c1_rx_log}" 2>&1 &
    local c1_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c1_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py burst-send --dest-ip ${STB_IP:-192.168.1.20} --dest-port 5001 --bind-port 5000 --wait-handshake --packet-size ${BURST_PACKET_SIZE:-1500} --burst-length ${c1_frames} --burst-load ${c1_load} --burst-count ${c1_count} --rate-mbps 1000.0"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5001 \
        --bind-port 5000 --wait-handshake \
        --packet-size "${BURST_PACKET_SIZE:-1500}" --burst-length "${c1_frames}" \
        --burst-load "${c1_load}" --burst-count "${c1_count}" --rate-mbps 1000.0

    wait "${c1_rx_pid}" || true
    if [[ -f "${c1_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${c1_json}"
        "${tools_dir}/metric_parser.py" format-card "${c1_json}"
    else
        log_warn "Burst receiver log output:"
        cat "${c1_rx_log}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 2B: Burst Case 2 (1500B, 16% Load, 100 Frames) (TC-RM-02)
# ------------------------------------------------------------------------------
run_subphase_burst_case2() {
    log_step "[TC-RM-02] WAN-to-LAN Rate Mismatch Burst Case 2 (1500B, 16% Load, 100 Frames)"
    local tools_dir="${LAB_DIR}/tools"

    local c2_frames="${BURST_CASE2_FRAMES:-100}"
    local c2_load="${BURST_CASE2_LOAD:-16.0}"
    local c2_count="${BURST_COUNT:-20}"
    local c2_expected=$(( c2_frames * c2_count ))
    local c2_json="${LOG_DIR}/burst_case2.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test Burst Case 2: 1500B, Length=${c2_frames} frames, Load=${c2_load}%, Total=${c2_expected} frames"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local c2_rx_log="${SCENARIO_TMP_DIR}/burst_c2_rx.log"

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/traffic_generator.py burst-recv --bind-ip 0.0.0.0 --bind-port 5001 --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 5000 --expected-packets ${c2_expected} --timeout 5.0 --output-json ${c2_json} > ${c2_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/traffic_generator.py" burst-recv \
        --bind-ip "0.0.0.0" --bind-port 5001 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5000 \
        --expected-packets "${c2_expected}" --timeout 5.0 --output-json "${c2_json}" > "${c2_rx_log}" 2>&1 &
    local c2_rx_pid=$!
    ACTIVE_BG_PIDS+=("${c2_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/traffic_generator.py burst-send --dest-ip ${STB_IP:-192.168.1.20} --dest-port 5001 --bind-port 5000 --wait-handshake --packet-size ${BURST_PACKET_SIZE:-1500} --burst-length "${c2_frames}" --burst-load "${c2_load}" --burst-count "${c2_count}" --rate-mbps 1000.0"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/traffic_generator.py" burst-send \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5001 \
        --bind-port 5000 --wait-handshake \
        --packet-size "${BURST_PACKET_SIZE:-1500}" --burst-length "${c2_frames}" \
        --burst-load "${c2_load}" --burst-count "${c2_count}" --rate-mbps 1000.0

    wait "${c2_rx_pid}" || true
    if [[ -f "${c2_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${c2_json}"
        "${tools_dir}/metric_parser.py" format-card "${c2_json}"
    else
        log_warn "Burst receiver log output:"
        cat "${c2_rx_log}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 3A: GeForce NOW Network Test Simulation (TC-APP-01)
# ------------------------------------------------------------------------------
run_subphase_geforce() {
    log_step "[TC-APP-01] GeForce NOW Cloud Gaming Network Test Simulation"
    local tools_dir="${LAB_DIR}/tools"
    local gfn_json="${LOG_DIR}/geforce_now.json"

    local eff_fps="${CUSTOM_GFN_FPS:-${GEFORCE_NOW_FPS:-60}}"
    local default_bitrate="25.0"
    local default_jitter="2.0"
    if (( eff_fps >= 120 )); then
        default_bitrate="${GEFORCE_NOW_120FPS_BITRATE_MBPS:-50.0}"
        default_jitter="${GEFORCE_NOW_120FPS_MAX_JITTER_MS:-1.5}"
    else
        default_bitrate="${GEFORCE_NOW_BITRATE_MBPS:-25.0}"
        default_jitter="${GEFORCE_NOW_MAX_JITTER_MS:-2.0}"
    fi
    local eff_bitrate="${CUSTOM_GFN_BITRATE:-${default_bitrate}}"
    local eff_max_jitter="${CUSTOM_GFN_JITTER:-${default_jitter}}"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test GeForce NOW UDP game streaming (${eff_fps} FPS, ${eff_bitrate} Mbps, max jitter ${eff_max_jitter} ms) on ns-stb"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local gfn_rx_log="${SCENARIO_TMP_DIR}/gfn_rx.log"
    local gfn_srv_duration="${CUSTOM_DURATION:-5.0}"
    local gfn_cli_duration
    gfn_cli_duration="$(python3 -c "print(float(${gfn_srv_duration}) + 3.0)")"

    # Clean any stale GeForce tester instances
    log_cmd "ip netns exec ${STB_NS:-ns-stb} pkill -f geforce_now_tester.py"
    ip netns exec "${STB_NS:-ns-stb}" pkill -f "geforce_now_tester.py" 2>/dev/null || true
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -f geforce_now_tester.py"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -f "geforce_now_tester.py" 2>/dev/null || true
    sleep 0.1

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/geforce_now_tester.py client --bind-ip 0.0.0.0 --bind-port 5004 --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 5004 --duration ${gfn_cli_duration} --max-loss-pct ${GEFORCE_NOW_MAX_LOSS_PCT:-0.0} --max-jitter-ms ${eff_max_jitter} --fps ${eff_fps} --target-mbps ${eff_bitrate} --output-json ${gfn_json} > ${gfn_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/geforce_now_tester.py" client \
        --bind-ip "0.0.0.0" --bind-port 5004 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5004 \
        --duration "${gfn_cli_duration}" \
        --max-loss-pct "${GEFORCE_NOW_MAX_LOSS_PCT:-0.0}" \
        --max-jitter-ms "${eff_max_jitter}" \
        --fps "${eff_fps}" \
        --target-mbps "${eff_bitrate}" \
        --output-json "${gfn_json}" > "${gfn_rx_log}" 2>&1 &
    local gfn_rx_pid=$!
    ACTIVE_BG_PIDS+=("${gfn_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/geforce_now_tester.py server --dest-ip ${STB_IP:-192.168.1.20} --dest-port 5004 --wait-handshake --duration ${gfn_srv_duration} --frame-rate ${eff_fps} --bitrate-mbps ${eff_bitrate}"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/geforce_now_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5004 \
        --wait-handshake \
        --duration "${gfn_srv_duration}" \
        --frame-rate "${eff_fps}" --bitrate-mbps "${eff_bitrate}"

    wait "${gfn_rx_pid}" || true
    if [[ -f "${gfn_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${gfn_json}"
        "${tools_dir}/metric_parser.py" format-card "${gfn_json}"
    else
        cat "${gfn_rx_log}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 3B: UHD+Dolby VOD 1.2x Speed Playback (TC-APP-02)
# ------------------------------------------------------------------------------
run_subphase_vod() {
    log_step "[TC-APP-02] UHD+Dolby VOD @ 1.2x Speed Playback"
    local tools_dir="${LAB_DIR}/tools"
    local vod_json="${LOG_DIR}/vod_1_2x.json"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test UHD+Dolby VOD @ 1.2x playback (35 Mbps x 1.2 = 42 Mbps) on ns-stb"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local vod_rx_log="${SCENARIO_TMP_DIR}/vod_rx.log"
    local vod_srv_duration="${CUSTOM_DURATION:-5.0}"
    local vod_cli_duration
    vod_cli_duration="$(python3 -c "print(float(${vod_srv_duration}) + 4.0)")"

    # Clean any stale VOD tester instances
    log_cmd "ip netns exec ${STB_NS:-ns-stb} pkill -f vod_stream_tester.py"
    ip netns exec "${STB_NS:-ns-stb}" pkill -f "vod_stream_tester.py" 2>/dev/null || true
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -f vod_stream_tester.py"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -f "vod_stream_tester.py" 2>/dev/null || true
    sleep 0.1

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/vod_stream_tester.py client --bind-ip 0.0.0.0 --bind-port 5005 --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 5005 --duration ${vod_cli_duration} --output-json ${vod_json} > ${vod_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/vod_stream_tester.py" client \
        --bind-ip "0.0.0.0" --bind-port 5005 \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 5005 \
        --duration "${vod_cli_duration}" \
        --output-json "${vod_json}" > "${vod_rx_log}" 2>&1 &
    local vod_rx_pid=$!
    ACTIVE_BG_PIDS+=("${vod_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/vod_stream_tester.py server --dest-ip ${STB_IP:-192.168.1.20} --dest-port 5005 --wait-handshake --duration ${vod_srv_duration} --base-bitrate-mbps ${VOD_BASE_BITRATE_MBPS:-35.0} --playback-speed ${VOD_SPEED_MULTIPLIER:-1.2}"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/vod_stream_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port 5005 \
        --wait-handshake \
        --duration "${vod_srv_duration}" \
        --base-bitrate-mbps "${VOD_BASE_BITRATE_MBPS:-35.0}" \
        --playback-speed "${VOD_SPEED_MULTIPLIER:-1.2}"

    wait "${vod_rx_pid}" || true
    if [[ -f "${vod_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${vod_json}"
        "${tools_dir}/metric_parser.py" format-card "${vod_json}"
    else
        cat "${vod_rx_log}" 2>/dev/null || true
    fi
}

# Helper: Run N trials of Simultaneous Benchmark (A: Wireless, B: Wired, C: Simultaneous) for a specific band
run_single_band_trials() {
    local band_tag="$1"
    local band_name="$2"
    local target_ssid="$3"
    local wifi_if="$4"
    local out_json="$5"
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local tools_dir="${LAB_DIR}/tools"

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials for [${band_name}] (SSID: '${target_ssid}')..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- [${band_name}] Trial ${i}/${trials} ---"

        # 1. Real Wireless-only speed (A): Single physical card over-the-air (OTA)
        local wifi_out="${SCENARIO_TMP_DIR}/iperf_wifi_${band_tag}_${i}.json"
        log_cmd "iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${wifi_if} -p 5202 -t ${duration} -J > ${wifi_out}"
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${wifi_if}" -p 5202 -t "${duration}" -J > "${wifi_out}" 2>&1 || true
        sleep 0.2
        local a_val
        a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${wifi_out}")"
        a_trials+=("${a_val}")
        log_info "  [Trial ${i}] Real Wireless-only (A, ${band_name}): ${a_val} Mbps"

        # 2. Wired-only speed (B): PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${band_tag}_${i}.json"
        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${pc_out}"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Wired PC + Real Wi-Fi concurrently
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${band_tag}_${i}.json"
        local sim_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_wifi_${band_tag}_${i}.json"

        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${sim_pc_out} &"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
        local sp0=$!
        log_cmd "iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${wifi_if} -p 5202 -t ${duration} -J > ${sim_wifi_out} &"
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${wifi_if}" -p 5202 -t "${duration}" -J > "${sim_wifi_out}" 2>&1 &
        local sp1=$!

        wait "${sp0}" "${sp1}" || true
        sleep 0.2

        local c_wired c_wifi c_val
        c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
        c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_wifi_out}")"
        c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_wifi_out}")"
        c_trials+=("${c_val}")
        c_wired_trials+=("${c_wired}")
        c_wifi_trials+=("${c_wifi}")
        log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Wired: ${c_wired} Mbps, Wi-Fi: ${c_wifi} Mbps)"
    done

    local a_str b_str c_str c_wired_str c_wifi_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"
    c_wired_str="$(IFS=,; echo "${c_wired_trials[*]}")"
    c_wifi_str="$(IFS=,; echo "${c_wifi_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "real_single_band"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${out_json}"
        "--wifi-if" "${wifi_if}"
        "--wifi-band" "${band_name}"
        "--wifi-ssid" "${target_ssid}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    log_cmd "${eval_cmd[*]}"
    "${eval_cmd[@]}"
}

# Helper: Run N trials of Simultaneous Benchmark with a Remote PC Client over SSH
run_remote_station_trials() {
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local tools_dir="${LAB_DIR}/tools"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"
    local remote_host="${REMOTE_CLIENT_HOST:-}"
    local remote_script="${SCRIPT_DIR}/remote_client.sh"

    local remote_env_dump
    remote_env_dump="$("${remote_script}" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${remote_env_dump}"

    local remote_wifi_if="${REMOTE_WIFI_IF:-wlan0}"
    local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"

    log_info "  -> Remote Wi-Fi Station   : ${remote_host} (${remote_wifi_if} [${remote_status}])"
    log_info "     * Target SSID & Band   : '${REMOTE_WIFI_SSID:-none}' (${REMOTE_WIFI_BAND:-none} / Ch ${REMOTE_WIFI_CHANNEL:-?}, Width: ${REMOTE_WIFI_WIDTH:-?})"
    log_info "     * Signal & Bitrate     : ${REMOTE_WIFI_SIGNAL:-none} (Tx: ${REMOTE_WIFI_BITRATE:-none})"
    log_info "     * Station IPv4 Address : ${REMOTE_WIFI_IP:-none} (Gateway: ${REMOTE_WIFI_GATEWAY:-none})"
    if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
        log_pass "     * Remote DUT Reachability: OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${REMOTE_WIFI_PING_RTT})"
    else
        log_warn "     * Remote DUT Reachability: FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
        log_warn "     * Please ensure Remote PC is connected to DUT SSID ('${DUT_SSID_2G:-DUT}' / '${DUT_SSID_5G:-DUT}')."
    fi

    local bind_opt=()
    if [[ -n "${remote_wifi_if}" ]]; then
        bind_opt=("--bind-dev" "${remote_wifi_if}")
    fi

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials with Remote PC Station (${remote_host})..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- [Remote Station] Trial ${i}/${trials} ---"

        # 1. Remote Wireless-only speed (A): Trigger remote PC via SSH
        local wifi_out="${SCENARIO_TMP_DIR}/iperf_wifi_remote_${i}.json"
        log_cmd "${remote_script} run-iperf -c ${WAN_SERVER_IP:-10.10.0.1} ${bind_opt[*]} -p 5202 -t ${duration} -J > ${wifi_out}"
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5202 -t "${duration}" -J > "${wifi_out}" 2>&1 || true
        sleep 0.2
        local a_val
        a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${wifi_out}")"
        a_trials+=("${a_val}")
        log_info "  [Trial ${i}] Remote Wireless-only (A, Remote PC): ${a_val} Mbps"

        # 2. Local Wired-only speed (B): Local PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_remote_${i}.json"
        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${pc_out}"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Local Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Local Wired PC + Remote Wi-Fi concurrently
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_remote_${i}.json"
        local sim_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_wifi_remote_${i}.json"

        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${sim_pc_out} &"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
        local sp0=$!
        log_cmd "${remote_script} run-iperf -c ${WAN_SERVER_IP:-10.10.0.1} ${bind_opt[*]} -p 5202 -t ${duration} -J > ${sim_wifi_out} &"
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5202 -t "${duration}" -J > "${sim_wifi_out}" 2>&1 &
        local sp1=$!

        wait "${sp0}" "${sp1}" || true
        sleep 0.2

        local c_wired c_wifi c_val
        c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
        c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_wifi_out}")"
        c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_wifi_out}")"
        c_trials+=("${c_val}")
        c_wired_trials+=("${c_wired}")
        c_wifi_trials+=("${c_wifi}")
        log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Local Wired: ${c_wired} Mbps, Remote Wi-Fi: ${c_wifi} Mbps)"
    done

    local a_str b_str c_str c_wired_str c_wifi_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"
    c_wired_str="$(IFS=,; echo "${c_wired_trials[*]}")"
    c_wifi_str="$(IFS=,; echo "${c_wifi_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "distributed_remote_station"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${sim_json}"
        "--wifi-if" "remote_pc"
        "--wifi-band" "Remote-WiFi"
        "--wifi-ssid" "${remote_host}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    "${eval_cmd[@]}"
}

# Helper: Run N trials of 3-Way Concurrent Benchmark (Wired 1G + Local Wi-Fi 5GHz + Remote Wi-Fi 2.4GHz)
run_tri_station_trials() {
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local tools_dir="${LAB_DIR}/tools"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"
    local remote_host="${REMOTE_CLIENT_HOST:-}"
    local remote_script="${SCRIPT_DIR}/remote_client.sh"
    local local_wifi_if="${DETECTED_WIFI_IF:-wlp3s0}"

    local remote_env_dump
    remote_env_dump="$("${remote_script}" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${remote_env_dump}"

    local remote_wifi_if="${REMOTE_WIFI_IF:-wlan0}"
    local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"

    log_info "  -> Local Wired PC Adapter   : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
    log_info "  -> Local Wi-Fi Adapter      : ${local_wifi_if} [${DETECTED_WIFI_STATUS:-CONNECTED}] (SSID: '${DETECTED_WIFI_SSID:-DUT}', Band: ${DETECTED_WIFI_BAND:-none}, Signal: ${DETECTED_WIFI_SIGNAL:-none})"
    log_info "  -> Remote Wi-Fi Station     : ${remote_host} (${remote_wifi_if} [${remote_status}], SSID: '${REMOTE_WIFI_SSID:-none}', Band: ${REMOTE_WIFI_BAND:-none}, Signal: ${REMOTE_WIFI_SIGNAL:-none})"

    local bind_opt=()
    if [[ -n "${remote_wifi_if}" ]]; then
        bind_opt=("--bind-dev" "${remote_wifi_if}")
    fi

    # Pre-flight checks: Verify local & remote Wi-Fi connectivity to DUT gateway
    log_info "Verifying Local Wi-Fi connectivity to DUT..."
    if ! ping -c 1 -W 2 -I "${local_wifi_if}" "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1; then
        log_warn "Local Wi-Fi (${local_wifi_if}) cannot ping DUT gateway! Attempting reconnect to 5G..."
        "${SCRIPT_DIR}/wifi_connect.sh" connect 5g || true
    else
        log_pass "Local Wi-Fi (${local_wifi_if}) reachability to DUT is verified."
    fi

    log_info "Verifying Remote Wi-Fi connectivity to DUT..."
    if [[ "${REMOTE_WIFI_PING_OK:-0}" != "1" ]]; then
        log_warn "Remote Wi-Fi (${remote_wifi_if}) cannot ping DUT gateway! Attempting reconnect to 2G..."
        "${remote_script}" wifi-connect 2g || true
    else
        log_pass "Remote Wi-Fi (${remote_wifi_if}) reachability to DUT is verified (Ping RTT: ${REMOTE_WIFI_PING_RTT})."
    fi

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials with 3 Concurrent Clients (Wired + 5G + 2.4G)..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- [3-Way Concurrent] Trial ${i}/${trials} ---"

        # 1. Combined Wireless-only speed (A): Local 5GHz + Remote 2.4GHz concurrently
        local w5g_out="${SCENARIO_TMP_DIR}/iperf_w5g_a_${i}.json"
        local w2g_out="${SCENARIO_TMP_DIR}/iperf_w2g_a_${i}.json"

        log_cmd "iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${local_wifi_if} -p 5202 -t ${duration} -J > ${w5g_out} &"
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${local_wifi_if}" -p 5202 -t "${duration}" -J > "${w5g_out}" 2>&1 &
        local ap0=$!
        log_cmd "${remote_script} run-iperf -c ${WAN_SERVER_IP:-10.10.0.1} ${bind_opt[*]} -p 5203 -t ${duration} -J > ${w2g_out} &"
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5203 -t "${duration}" -J > "${w2g_out}" 2>&1 &
        local ap1=$!

        wait "${ap0}" "${ap1}" || true
        sleep 0.2

        local a5g_val a2g_val a_sum
        a5g_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w5g_out}")"
        a2g_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w2g_out}")"
        a_sum="$(awk "BEGIN {printf \"%.2f\", ${a5g_val} + ${a2g_val}}")"
        a_trials+=("${a_sum}")
        log_info "  [Trial ${i}] Wireless-only (A, 5G+2.4G): ${a_sum} Mbps (Local 5G: ${a5g_val} Mbps, Remote 2.4G: ${a2g_val} Mbps)"

        # 2. Local Wired-only speed (B): Local PC via ns-pc
        local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_b_${i}.json"
        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${pc_out}"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
        sleep 0.2
        local b_val
        b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
        b_trials+=("${b_val}")
        log_info "  [Trial ${i}] Local Wired-only (B, 1G LAN): ${b_val} Mbps"

        # 3. Simultaneous speed (C): Local Wired PC + Local Wi-Fi 5G + Remote Wi-Fi 2.4G concurrently!
        local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
        local sim_w5g_out="${SCENARIO_TMP_DIR}/iperf_sim_w5g_${i}.json"
        local sim_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_w2g_${i}.json"

        log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${sim_pc_out} &"
        ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
        local sp0=$!
        log_cmd "iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${local_wifi_if} -p 5202 -t ${duration} -J > ${sim_w5g_out} &"
        iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${local_wifi_if}" -p 5202 -t "${duration}" -J > "${sim_w5g_out}" 2>&1 &
        local sp1=$!
        log_cmd "${remote_script} run-iperf -c ${WAN_SERVER_IP:-10.10.0.1} ${bind_opt[*]} -p 5203 -t ${duration} -J > ${sim_w2g_out} &"
        "${remote_script}" run-iperf -c "${WAN_SERVER_IP:-10.10.0.1}" "${bind_opt[@]}" -p 5203 -t "${duration}" -J > "${sim_w2g_out}" 2>&1 &
        local sp2=$!

        wait "${sp0}" "${sp1}" "${sp2}" || true
        sleep 0.2

        local c_wired c_w5g c_w2g c_wifi_tot c_val
        c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
        c_w5g="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w5g_out}")"
        c_w2g="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w2g_out}")"
        c_wifi_tot="$(awk "BEGIN {printf \"%.2f\", ${c_w5g} + ${c_w2g}}")"
        c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_w5g_out}" "${sim_w2g_out}")"

        c_trials+=("${c_val}")
        c_wired_trials+=("${c_wired}")
        c_wifi_trials+=("${c_wifi_tot}")
        log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps [Wired: ${c_wired} Mbps | 5GHz: ${c_w5g} Mbps | 2.4GHz: ${c_w2g} Mbps]"
    done

    local a_str b_str c_str c_wired_str c_wifi_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"
    c_wired_str="$(IFS=,; echo "${c_wired_trials[*]}")"
    c_wifi_str="$(IFS=,; echo "${c_wifi_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "tri_station_distributed"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${sim_json}"
        "--wifi-if" "${local_wifi_if}+${remote_wifi_if}"
        "--wifi-band" "5GHz(Local)+2.4GHz(Remote)"
        "--wifi-ssid" "${DETECTED_WIFI_SSID:-U+NetF254_5G}+U+NetF254"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )
    log_cmd "${eval_cmd[*]}"
    "${eval_cmd[@]}"
}

# ------------------------------------------------------------------------------
# Phase 4: Simultaneous Wired & Wireless Use (TC-SIM-01)
# ------------------------------------------------------------------------------
run_phase_simultaneous() {
    local tools_dir="${LAB_DIR}/tools"
    local trials="${BENCHMARK_TRIALS:-5}"
    local duration="${CUSTOM_DURATION:-${BENCHMARK_DURATION_SEC:-3}}"
    local sim_json="${LOG_DIR}/simultaneous_benchmark.json"

    # Step 0: Probe Wi-Fi environment and determine execution mode
    local env_dump
    env_dump="$("${tools_dir}/wifi_inspector.py" export-env 2>/dev/null || true)"
    eval "${env_dump}"

    local eff_mode="${CUSTOM_WIFI_MODE:-${WIFI_TEST_MODE:-auto}}"
    if [[ "${eff_mode}" == "auto" ]]; then
        if [[ "${TOPOLOGY_MODE:-virtual}" == "virtual" ]]; then
            eff_mode="emulated"
        elif (( ${WIFI_CARD_COUNT:-0} == 0 )); then
            eff_mode="emulated"
        elif (( ${WIFI_CARD_COUNT:-0} == 1 )); then
            if [[ -n "${DETECTED_WIFI_SSID:-}" ]]; then
                eff_mode="real_single_band"
            else
                log_warn "Physical Wi-Fi card detected (${DETECTED_WIFI_IF}) but not connected to SSID. Falling back to emulated netns."
                eff_mode="emulated"
            fi
        else
            eff_mode="physical"
        fi
    elif [[ "${eff_mode}" == "real_single" ]]; then
        eff_mode="real_single_band"
    elif [[ "${eff_mode}" == "sequential" || "${eff_mode}" == "sequential_bands" || "${eff_mode}" == "multiband" ]]; then
        eff_mode="sequential"
    elif [[ "${eff_mode}" == "remote" || "${eff_mode}" == "distributed" || "${eff_mode}" == "remote_client" ]]; then
        eff_mode="remote"
    elif [[ "${eff_mode}" == "tri_station" || "${eff_mode}" == "tri_stream" || "${eff_mode}" == "concurrent" || "${eff_mode}" == "distributed_3way" ]]; then
        eff_mode="tri_station"
    fi

    # --------------------------------------------------------------------------
    # Case 1: Sequential Multi-Band Testing (5GHz -> 2.4GHz)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "sequential" ]]; then
        log_step "[TC-SIM-01] Sequential Multi-Band Download Benchmark (5GHz & 2.4GHz)"
        log_info "Sequential Benchmark Mode: [SEQUENTIAL_MULTI_BAND] | Trials per Band: ${trials} | Duration: ${duration}s"
        log_info "  -> Physical Wi-Fi Adapter : ${DETECTED_WIFI_IF:-none}"
        log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would test 5GHz and 2.4GHz bands sequentially (${trials} trials each)."
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}% across all bands"
            return 0
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        # Determine bands to test: 5GHz first (already connected), then 2.4GHz
        local bands_to_test=()
        if [[ -n "${DUT_SSID_5G:-}" ]]; then
            bands_to_test+=("5g:5GHz:${DUT_SSID_5G}")
        fi
        if [[ -n "${DUT_SSID_2G:-}" ]]; then
            bands_to_test+=("2g:2.4GHz:${DUT_SSID_2G}")
        fi
        if [[ -n "${DUT_SSID_6G:-}" && "${DETECTED_WIFI_SUPPORTED_BANDS:-}" == *"6GHz"* ]]; then
            bands_to_test+=("6g:6GHz:${DUT_SSID_6G}")
        fi

        if (( ${#bands_to_test[@]} == 0 )); then
            die "No target DUT SSIDs configured for sequential testing in config.env."
        fi

        local band_json_files=()
        for b_item in "${bands_to_test[@]}"; do
            local b_tag b_name b_ssid
            IFS=":" read -r b_tag b_name b_ssid <<< "${b_item}"

            print_section "SEQUENTIAL MULTI-BAND PHASE: ${b_name} (SSID: ${b_ssid})"
            local cur_link_ssid
            cur_link_ssid="$(iw dev "${DETECTED_WIFI_IF}" link 2>/dev/null | awk -F'SSID: ' '/SSID:/{print $2}' | xargs || true)"

            if [[ "${cur_link_ssid}" != "${b_ssid}" ]]; then
                log_info "Switching physical Wi-Fi [${DETECTED_WIFI_IF}] to ${b_name} (SSID: '${b_ssid}')..."
                log_cmd "${SCRIPT_DIR}/wifi_connect.sh connect ${b_tag} --force"
                "${SCRIPT_DIR}/wifi_connect.sh" connect "${b_tag}" --force
                sleep 2
            else
                log_info "Physical Wi-Fi [${DETECTED_WIFI_IF}] is already associated to ${b_name} (SSID: '${b_ssid}')."
            fi

            # Warm up ARP table to DUT gateway
            ping -c 1 -W 2 -I "${DETECTED_WIFI_IF}" "${DUT_LAN_IP:-192.168.1.1}" >/dev/null 2>&1 || true

            local band_json="${LOG_DIR}/simultaneous_benchmark_${b_tag}.json"
            run_single_band_trials "${b_tag}" "${b_name}" "${b_ssid}" "${DETECTED_WIFI_IF}" "${band_json}"
            band_json_files+=("${band_json}")
        done

        # Reconnect to primary 5GHz band after testing finishes
        log_info "Restoring Wi-Fi connection to 5GHz..."
        log_cmd "${SCRIPT_DIR}/wifi_connect.sh connect 5g --force"
        "${SCRIPT_DIR}/wifi_connect.sh" connect 5g --force >/dev/null 2>&1 || true

        # Stop iperf3 servers in ns-wan
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

        # Consolidate results across all tested bands
        local seq_json="${LOG_DIR}/simultaneous_sequential_benchmark.json"
        local seq_cmd=(
            "${tools_dir}/metric_parser.py" eval-sequential
            "${band_json_files[@]}"
            --tolerance "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
            --output "${seq_json}"
        )
        log_cmd "${seq_cmd[*]}"
        "${seq_cmd[@]}"

        # Mirror to simultaneous_benchmark.json for backward compatibility
        cp -f "${seq_json}" "${sim_json}" 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 2: Distributed Remote Client Testing (Local Wired + Remote Wi-Fi)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "remote" ]]; then
        log_step "[TC-SIM-01] Distributed Multi-Station Benchmark (Local Wired + Remote Wi-Fi)"
        log_info "Simultaneous Benchmark Mode: [REMOTE_CLIENT] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Remote Station Host    : ${REMOTE_CLIENT_HOST:-not_configured}"
        log_info "  -> Local Wired PC Adapter : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (Remote Wi-Fi), B (Local Wired), C (Simultaneous)"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
            return 0
        fi

        if [[ -z "${REMOTE_CLIENT_HOST:-}" ]]; then
            die "REMOTE_CLIENT_HOST is not set in config.env. Configure remote client or run ./scripts/remote_client.sh --help"
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        run_remote_station_trials
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 3: 3-Way Concurrent Physical Testing (Wired 1G + Local 5G + Remote 2.4G)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "tri_station" ]]; then
        log_step "[TC-SIM-01] 3-Way Concurrent Physical Benchmark (Wired 1G + Local 5G + Remote 2.4G)"
        log_info "Simultaneous Benchmark Mode: [TRI_STATION_CONCURRENT] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Local Wired Adapter    : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Local Wi-Fi Adapter    : ${DETECTED_WIFI_IF:-wlp3s0} (OTA 5GHz: '${DETECTED_WIFI_SSID:-U+NetF254_5G}')"
        log_info "  -> Remote Wi-Fi Station   : ${REMOTE_CLIENT_HOST:-not_configured} (OTA 2.4GHz: 'U+NetF254')"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (5G+2.4G Wireless), B (Wired 1G), C (Simultaneous 3-Way)"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
            return 0
        fi

        if [[ -z "${REMOTE_CLIENT_HOST:-}" ]]; then
            die "REMOTE_CLIENT_HOST is not set in config.env. Configure remote client or run ./scripts/remote_client.sh --help"
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        run_tri_station_trials
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 2: Real Single-Band Testing (Single Active Band)
    # --------------------------------------------------------------------------
    if [[ "${eff_mode}" == "real_single_band" ]]; then
        log_step "[TC-SIM-01] Simultaneous Wired & Wireless Download Benchmark (5 Trials)"
        log_info "Simultaneous Benchmark Mode: [REAL_SINGLE_BAND] | Trials: ${trials} | Duration: ${duration}s"
        log_info "  -> Physical Wi-Fi Adapter : ${DETECTED_WIFI_IF:-none} (OTA Band: ${DETECTED_WIFI_BAND:-5GHz}, SSID: '${DETECTED_WIFI_SSID:-DUT}')"
        log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"

        if (( DRY_RUN == 1 )); then
            log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (WLAN), B (Wired), C (Simultaneous) under mode: real_single_band"
            log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
            return 0
        fi

        # Stop any stale iperf3 instances in ns-wan and start fresh
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        sleep 0.2
        for port in 5201 5202 5203 5204; do
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${port} -D"
            ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
        done
        sleep 0.5

        run_single_band_trials "single" "${DETECTED_WIFI_BAND:-5GHz}" "${DETECTED_WIFI_SSID:-DUT}" "${DETECTED_WIFI_IF}" "${sim_json}"
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
        return 0
    fi

    # --------------------------------------------------------------------------
    # Case 3: Hybrid / Emulated Multi-Netns Testing
    # --------------------------------------------------------------------------
    log_step "[TC-SIM-01] Simultaneous Wired & Wireless Download Benchmark (5 Trials)"
    log_info "Simultaneous Benchmark Mode: [${eff_mode^^}] | Trials: ${trials} | Duration: ${duration}s"
    if [[ "${eff_mode}" == "hybrid" ]]; then
        log_info "  -> Physical Wi-Fi Adapter : ${DETECTED_WIFI_IF:-none} (OTA Band: ${DETECTED_WIFI_BAND:-5GHz}, SSID: '${DETECTED_WIFI_SSID:-DUT}')"
        log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
        log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"
    fi

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would run ${trials} benchmark trials measuring A (WLAN), B (Wired), C (Simultaneous) under mode: ${eff_mode}"
        log_info "[DRY-RUN] Acceptance: Degradation <= ${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}%"
        return 0
    fi

    # Stop any stale iperf3 instances in ns-wan
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
    sleep 0.2

    # Start 4 iperf3 server daemons in WAN namespace
    local srv_ports=(5201 5202 5203 5204)
    for port in "${srv_ports[@]}"; do
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p ${port} -D"
        ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p "${port}" -D >/dev/null 2>&1
    done
    sleep 0.5

    local a_trials=()
    local b_trials=()
    local c_trials=()
    local c_wired_trials=()
    local c_wifi_trials=()

    log_info "Executing ${trials} measurement trials..."
    for (( i=1; i<=trials; i++ )); do
        log_info "--- Trial ${i}/${trials} ---"

        if [[ "${eff_mode}" == "hybrid" ]]; then
            # 1. Hybrid Wireless-only speed (A): Real active band + Virtual netns for remaining bands
            local hw_wifi_out="${SCENARIO_TMP_DIR}/iperf_hw_wifi_${i}.json"
            local vir_w2g_out="${SCENARIO_TMP_DIR}/iperf_vir_w2g_${i}.json"
            local vir_w6g_out="${SCENARIO_TMP_DIR}/iperf_vir_w6g_${i}.json"

            log_cmd "iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${DETECTED_WIFI_IF} -p 5202 -t ${duration} -J > ${hw_wifi_out} &"
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${DETECTED_WIFI_IF}" -p 5202 -t "${duration}" -J > "${hw_wifi_out}" 2>&1 &
            local hp1=$!
            log_cmd "ip netns exec ${WLAN2G_NS:-ns-wlan2g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5203 -t ${duration} -J > ${vir_w2g_out} &"
            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${vir_w2g_out}" 2>&1 &
            local hp2=$!
            log_cmd "ip netns exec ${WLAN6G_NS:-ns-wlan6g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5204 -t ${duration} -J > ${vir_w6g_out} &"
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5204 -t "${duration}" -J > "${vir_w6g_out}" 2>&1 &
            local hp3=$!
            wait "${hp1}" "${hp2}" "${hp3}" || true
            sleep 0.2

            local a_val
            a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${hw_wifi_out}" "${vir_w2g_out}" "${vir_w6g_out}")"
            a_trials+=("${a_val}")
            log_info "  [Trial ${i}] Hybrid Wireless-only (A, Real+Virtual): ${a_val} Mbps"

            # 2. Wired-only speed (B): PC
            local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${i}.json"
            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${pc_out}"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
            sleep 0.2
            local b_val
            b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
            b_trials+=("${b_val}")
            log_info "  [Trial ${i}] Wired-only (B, 1G LAN): ${b_val} Mbps"

            # 3. Simultaneous speed (C): PC + Real Wi-Fi + Virtual netns
            local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
            local sim_hw_wifi_out="${SCENARIO_TMP_DIR}/iperf_sim_hw_wifi_${i}.json"
            local sim_vir_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_vir_w2g_${i}.json"
            local sim_vir_w6g_out="${SCENARIO_TMP_DIR}/iperf_sim_vir_w6g_${i}.json"

            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${sim_pc_out} &"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
            local hsp0=$!
            log_cmd "iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} --bind-dev ${DETECTED_WIFI_IF} -p 5202 -t ${duration} -J > ${sim_hw_wifi_out} &"
            iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" --bind-dev "${DETECTED_WIFI_IF}" -p 5202 -t "${duration}" -J > "${sim_hw_wifi_out}" 2>&1 &
            local hsp1=$!
            log_cmd "ip netns exec ${WLAN2G_NS:-ns-wlan2g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5203 -t ${duration} -J > ${sim_vir_w2g_out} &"
            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${sim_vir_w2g_out}" 2>&1 &
            local hsp2=$!
            log_cmd "ip netns exec ${WLAN6G_NS:-ns-wlan6g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5204 -t ${duration} -J > ${sim_vir_w6g_out} &"
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5204 -t "${duration}" -J > "${sim_vir_w6g_out}" 2>&1 &
            local hsp3=$!
            wait "${hsp0}" "${hsp1}" "${hsp2}" "${hsp3}" || true
            sleep 0.2

            local c_wired c_wifi c_val
            c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
            c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_hw_wifi_out}" "${sim_vir_w2g_out}" "${sim_vir_w6g_out}")"
            c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_hw_wifi_out}" "${sim_vir_w2g_out}" "${sim_vir_w6g_out}")"
            c_trials+=("${c_val}")
            c_wired_trials+=("${c_wired}")
            c_wifi_trials+=("${c_wifi}")
            log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Wired: ${c_wired} Mbps, Wi-Fi: ${c_wifi} Mbps)"

        else
            # emulated or default multi-netns
            # 1. Measure Wireless-only speed (A): 2.4G + 5G + 6G in parallel
            local w2g_out="${SCENARIO_TMP_DIR}/iperf_w2g_${i}.json"
            local w5g_out="${SCENARIO_TMP_DIR}/iperf_w5g_${i}.json"
            local w6g_out="${SCENARIO_TMP_DIR}/iperf_w6g_${i}.json"

            log_cmd "ip netns exec ${WLAN2G_NS:-ns-wlan2g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${w2g_out} &"
            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${w2g_out}" 2>&1 &
            local p1=$!
            log_cmd "ip netns exec ${WLAN5G_NS:-ns-wlan5g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5202 -t ${duration} -J > ${w5g_out} &"
            ip netns exec "${WLAN5G_NS:-ns-wlan5g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5202 -t "${duration}" -J > "${w5g_out}" 2>&1 &
            local p2=$!
            log_cmd "ip netns exec ${WLAN6G_NS:-ns-wlan6g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5203 -t ${duration} -J > ${w6g_out} &"
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${w6g_out}" 2>&1 &
            local p3=$!
            wait "${p1}" "${p2}" "${p3}" || true
            sleep 0.2

            local a_val
            a_val="$("${tools_dir}/metric_parser.py" sum-mbps "${w2g_out}" "${w5g_out}" "${w6g_out}")"
            a_trials+=("${a_val}")
            log_info "  [Trial ${i}] Wireless-only (A): ${a_val} Mbps"

            # 2. Measure Wired-only speed (B): PC
            local pc_out="${SCENARIO_TMP_DIR}/iperf_pc_${i}.json"
            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${pc_out}"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${pc_out}" 2>&1 || true
            sleep 0.2
            local b_val
            b_val="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_out}")"
            b_trials+=("${b_val}")
            log_info "  [Trial ${i}] Wired-only (B): ${b_val} Mbps"

            # 3. Measure Simultaneous speed (C): PC + 2.4G + 5G + 6G in parallel
            local sim_pc_out="${SCENARIO_TMP_DIR}/iperf_sim_pc_${i}.json"
            local sim_w2g_out="${SCENARIO_TMP_DIR}/iperf_sim_w2g_${i}.json"
            local sim_w5g_out="${SCENARIO_TMP_DIR}/iperf_sim_w5g_${i}.json"
            local sim_w6g_out="${SCENARIO_TMP_DIR}/iperf_sim_w6g_${i}.json"

            log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${duration} -J > ${sim_pc_out} &"
            ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${duration}" -J > "${sim_pc_out}" 2>&1 &
            local sp0=$!
            log_cmd "ip netns exec ${WLAN2G_NS:-ns-wlan2g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5202 -t ${duration} -J > ${sim_w2g_out} &"
            ip netns exec "${WLAN2G_NS:-ns-wlan2g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5202 -t "${duration}" -J > "${sim_w2g_out}" 2>&1 &
            local sp1=$!
            log_cmd "ip netns exec ${WLAN5G_NS:-ns-wlan5g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5203 -t ${duration} -J > ${sim_w5g_out} &"
            ip netns exec "${WLAN5G_NS:-ns-wlan5g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5203 -t "${duration}" -J > "${sim_w5g_out}" 2>&1 &
            local sp2=$!
            log_cmd "ip netns exec ${WLAN6G_NS:-ns-wlan6g} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5204 -t ${duration} -J > ${sim_w6g_out} &"
            ip netns exec "${WLAN6G_NS:-ns-wlan6g}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5204 -t "${duration}" -J > "${sim_w6g_out}" 2>&1 &
            local sp3=$!

            wait "${sp0}" "${sp1}" "${sp2}" "${sp3}" || true
            sleep 0.2

            local c_wired c_wifi c_val
            c_wired="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}")"
            c_wifi="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_w2g_out}" "${sim_w5g_out}" "${sim_w6g_out}")"
            c_val="$("${tools_dir}/metric_parser.py" sum-mbps "${sim_pc_out}" "${sim_w2g_out}" "${sim_w5g_out}" "${sim_w6g_out}")"
            c_trials+=("${c_val}")
            c_wired_trials+=("${c_wired}")
            c_wifi_trials+=("${c_wifi}")
            log_info "  [Trial ${i}] Simultaneous (C): ${c_val} Mbps (Wired: ${c_wired} Mbps, Wi-Fi: ${c_wifi} Mbps)"
        fi
    done

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true

    local a_str b_str c_str c_wired_str c_wifi_str
    a_str="$(IFS=,; echo "${a_trials[*]}")"
    b_str="$(IFS=,; echo "${b_trials[*]}")"
    c_str="$(IFS=,; echo "${c_trials[*]}")"
    c_wired_str="$(IFS=,; echo "${c_wired_trials[*]}")"
    c_wifi_str="$(IFS=,; echo "${c_wifi_trials[*]}")"

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-simultaneous
        "--trials-a" "${a_str}"
        "--trials-b" "${b_str}"
        "--trials-c" "${c_str}"
        "--mode" "${eff_mode}"
        "--tolerance" "${THROUGHPUT_DROP_TOLERANCE_PCT:-1.0}"
        "--output" "${sim_json}"
        "--trials-c-wired" "${c_wired_str}"
        "--trials-c-wifi" "${c_wifi_str}"
    )

    log_cmd "${eval_cmd[*]}"
    "${eval_cmd[@]}"
}

# ------------------------------------------------------------------------------
# Phase 5: Voice QoS Isolation (TC-QOS-01)
# ------------------------------------------------------------------------------
run_phase_voice_qos() {
    log_step "[TC-QOS-01] Wired PC Throughput with 2 Active Wi-Fi Phone Calls"
    local tools_dir="${LAB_DIR}/tools"
    local voice_json="${LOG_DIR}/voice_pc_qos.json"
    rm -f "${voice_json}" "${LOG_DIR}/voice_qos_audit.json" 2>/dev/null || true
    local pc_concurrent_dur="${CUSTOM_DURATION:-4}"
    local pc_baseline_dur=4
    if (( pc_concurrent_dur > 10 )); then
        pc_baseline_dur=5
    fi
    local call_duration=$(( pc_concurrent_dur + 8 ))

    # 1. Engine Detection
    local engine="${CUSTOM_VOIP_ENGINE:-${VOIP_ENGINE:-auto}}"
    local pjsua_bin="${tools_dir}/bin/pjsua"
    local sipp_bin="${tools_dir}/bin/sipp"
    if [[ ! -x "${sipp_bin}" ]] && command -v sipp >/dev/null 2>&1; then
        sipp_bin="$(command -v sipp)"
    fi

    if [[ "${engine}" == "auto" ]]; then
        if [[ -x "${pjsua_bin}" ]]; then
            engine="pjsua"
        elif command -v pjsua >/dev/null 2>&1; then
            pjsua_bin="$(command -v pjsua)"
            engine="pjsua"
        elif [[ -x "${sipp_bin}" ]]; then
            engine="sipp"
        else
            engine="python"
        fi
    elif [[ "${engine}" == "pjsua" ]]; then
        if [[ ! -x "${pjsua_bin}" ]] && ! command -v pjsua >/dev/null 2>&1; then
            log_warn "pjsua requested but binary not found. Run ./scripts/install_pjsip.sh to build it. Falling back to sipp/python."
            if [[ -x "${sipp_bin}" ]]; then
                engine="sipp"
            else
                engine="python"
            fi
        fi
    elif [[ "${engine}" == "sipp" ]]; then
        if [[ ! -x "${sipp_bin}" ]]; then
            log_warn "sipp requested but binary not found. Run ./scripts/install_sipp.sh to install it. Falling back to python."
            engine="python"
        fi
    fi

    # 2. Topology Mode Detection
    local env_dump
    env_dump="$("${tools_dir}/wifi_inspector.py" export-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
    eval "${env_dump}"

    local eff_mode="${CUSTOM_WIFI_MODE:-auto}"
    if [[ "${eff_mode}" == "auto" ]]; then
        if [[ "${TOPOLOGY_MODE:-virtual}" == "virtual" ]]; then
            eff_mode="virtual"
        elif (( ${WIFI_CARD_COUNT:-0} == 0 )); then
            eff_mode="virtual"
        elif [[ -z "${DETECTED_WIFI_SSID:-}" ]]; then
            log_warn "Physical Wi-Fi card detected (${DETECTED_WIFI_IF}) but not connected to SSID. Falling back to virtual netns."
            eff_mode="virtual"
        elif [[ -n "${REMOTE_CLIENT_HOST:-}" ]] && "${SCRIPT_DIR}/remote_client.sh" test-connection >/dev/null 2>&1; then
            eff_mode="distributed"
        else
            eff_mode="physical_single"
        fi
    elif [[ "${eff_mode}" == "real_single" || "${eff_mode}" == "real_single_band" ]]; then
        eff_mode="physical_single"
    elif [[ "${eff_mode}" == "remote" || "${eff_mode}" == "remote_only" ]]; then
        eff_mode="remote_only"
    elif [[ "${eff_mode}" == "distributed" || "${eff_mode}" == "tri_station" ]]; then
        eff_mode="distributed"
    elif [[ "${eff_mode}" == "emulated" ]]; then
        eff_mode="virtual"
    fi

    local wifi_ip="${DETECTED_WIFI_IP:-}"
    if [[ -z "${wifi_ip}" && ( "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ) ]]; then
        wifi_ip="$(ip -4 -o addr show dev "${DETECTED_WIFI_IF:-wlp3s0}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
    fi

    # In remote_only or distributed mode, query remote client Wi-Fi connection state
    if [[ "${eff_mode}" == "remote_only" || "${eff_mode}" == "distributed" ]]; then
        local remote_env_dump
        remote_env_dump="$("${SCRIPT_DIR}/remote_client.sh" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" 2>/dev/null || true)"
        eval "${remote_env_dump}"
    fi

    log_info "VoIP QoS Test Mode : [${eff_mode^^}] | Engine: [${engine^^}]"
    if [[ "${eff_mode}" == "remote_only" ]]; then
        local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"
        log_info "  -> Remote Wi-Fi Station   : ${REMOTE_CLIENT_HOST} (via SSH)"
        log_info "     * Interface & Status   : ${REMOTE_WIFI_IF:-none} [${remote_status}] (MAC: ${REMOTE_WIFI_MAC:-none})"
        log_info "     * Target SSID & Band   : '${REMOTE_WIFI_SSID:-none}' (${REMOTE_WIFI_BAND:-none} / Ch ${REMOTE_WIFI_CHANNEL:-?}, Width: ${REMOTE_WIFI_WIDTH:-?})"
        log_info "     * Signal & Bitrate     : ${REMOTE_WIFI_SIGNAL:-none} (Tx: ${REMOTE_WIFI_BITRATE:-none})"
        log_info "     * Station IPv4 Address : ${REMOTE_WIFI_IP:-none} (Gateway: ${REMOTE_WIFI_GATEWAY:-none})"
        if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
            log_pass "     * Remote DUT Reachability: OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${REMOTE_WIFI_PING_RTT})"
        else
            log_warn "     * Remote DUT Reachability: FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
            log_warn "     * Please ensure Remote PC is connected to DUT SSID ('${DUT_SSID_2G:-DUT}' / '${DUT_SSID_5G:-DUT}')."
        fi
        log_info "  -> Local Wi-Fi Adapter    : BYPASSED (Exclusively using Remote Wi-Fi Station)"
    elif [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
        local local_status="${DETECTED_WIFI_STATUS:-DISCONNECTED}"
        log_info "  -> Local Wi-Fi Adapter    : ${DETECTED_WIFI_IF:-none} [${local_status}] (SSID: '${DETECTED_WIFI_SSID:-DUT}', IP: ${wifi_ip:-unknown}, Band: ${DETECTED_WIFI_BAND:-unknown}, Signal: ${DETECTED_WIFI_SIGNAL:-unknown})"
        if [[ "${DETECTED_WIFI_PING_OK:-0}" == "1" ]]; then
            log_pass "     * Local DUT Reachability : OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${DETECTED_WIFI_PING_RTT})"
        else
            log_warn "     * Local DUT Reachability : FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
        fi

        if [[ "${eff_mode}" == "distributed" ]]; then
            local remote_status="${REMOTE_WIFI_STATUS:-DISCONNECTED}"
            log_info "  -> Remote Wi-Fi Station   : ${REMOTE_CLIENT_HOST} (via SSH)"
            log_info "     * Interface & Status   : ${REMOTE_WIFI_IF:-none} [${remote_status}] (MAC: ${REMOTE_WIFI_MAC:-none})"
            log_info "     * Target SSID & Band   : '${REMOTE_WIFI_SSID:-none}' (${REMOTE_WIFI_BAND:-none} / Ch ${REMOTE_WIFI_CHANNEL:-?}, Width: ${REMOTE_WIFI_WIDTH:-?})"
            log_info "     * Signal & Bitrate     : ${REMOTE_WIFI_SIGNAL:-none} (Tx: ${REMOTE_WIFI_BITRATE:-none})"
            log_info "     * Station IPv4 Address : ${REMOTE_WIFI_IP:-none} (Gateway: ${REMOTE_WIFI_GATEWAY:-none})"
            if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
                log_pass "     * Remote DUT Reachability: OK (Ping to ${DUT_LAN_IP:-192.168.1.1}: ${REMOTE_WIFI_PING_RTT})"
            else
                log_warn "     * Remote DUT Reachability: FAILED (Cannot ping gateway ${DUT_LAN_IP:-192.168.1.1})"
                log_warn "     * Please ensure Remote PC is connected to DUT SSID ('${DUT_SSID_2G:-DUT}' / '${DUT_SSID_5G:-DUT}')."
            fi
        fi
    fi
    log_info "  -> Wired PC Adapter       : ${PC_IF:-enx6c1ff76608e2} (ns-pc: 1 Gbps LAN)"
    log_info "  -> Upstream WAN Endpoint  : ${WAN_SERVER_IP:-10.10.0.1}"
    log_info "  -> QoS Marking            : DSCP 46 (EF / TOS 0xb8 = 184) -> Wi-Fi WMM Voice (AC_VO)"

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test PC throughput with and without 2 active VoIP calls using ${engine^^} under mode ${eff_mode}."
        log_info "[DRY-RUN] Acceptance: |A - B| / A <= ${VOIP_IMPACT_TOLERANCE_PCT:-1.0}%"
        return 0
    fi

    # 3. Network routing & DSCP preparation for physical Wi-Fi
    local added_wifi_route=0
    local added_mangle_rule=0
    if [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
        if [[ -n "${DETECTED_WIFI_IF:-}" && -n "${wifi_ip:-}" ]]; then
            # Ensure host route for WAN_SERVER_IP points via DUT gateway over physical Wi-Fi
            log_cmd "ip route replace ${WAN_SERVER_IP:-10.10.0.1} via ${DUT_LAN_IP:-192.168.1.1} dev ${DETECTED_WIFI_IF}"
            ip route replace "${WAN_SERVER_IP:-10.10.0.1}" via "${DUT_LAN_IP:-192.168.1.1}" dev "${DETECTED_WIFI_IF}" 2>/dev/null || true
            CLEANUP_WIFI_ROUTE="${WAN_SERVER_IP:-10.10.0.1} via ${DUT_LAN_IP:-192.168.1.1} dev ${DETECTED_WIFI_IF}"
            added_wifi_route=1

            # Ensure DSCP 46 (EF = 0xb8) marking on outgoing UDP voice packets for WMM Voice mapping
            log_cmd "iptables -t mangle -A POSTROUTING -o ${DETECTED_WIFI_IF} -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46"
            iptables -t mangle -A POSTROUTING -o "${DETECTED_WIFI_IF}" -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true
            log_cmd "iptables -t mangle -A POSTROUTING -o ${DETECTED_WIFI_IF} -p udp -m multiport --sports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46"
            iptables -t mangle -A POSTROUTING -o "${DETECTED_WIFI_IF}" -p udp -m multiport --sports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true
            CLEANUP_IPTABLES_MANGLE="iptables -t mangle -D POSTROUTING -o ${DETECTED_WIFI_IF} -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true; iptables -t mangle -D POSTROUTING -o ${DETECTED_WIFI_IF} -p udp -m multiport --sports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true"
            added_mangle_rule=1
        fi

        if [[ ( "${eff_mode}" == "remote_only" || "${eff_mode}" == "distributed" ) && -n "${REMOTE_WIFI_IF:-}" ]]; then
            local remote_gw="${REMOTE_WIFI_GATEWAY:-${DUT_LAN_IP:-192.168.1.1}}"
            "${SCRIPT_DIR}/remote_client.sh" exec "sudo -n ip route replace '${WAN_SERVER_IP:-10.10.0.1}' via '${remote_gw}' dev '${REMOTE_WIFI_IF}' 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true" >/dev/null 2>&1 || true
        fi
    elif [[ "${eff_mode}" == "remote_only" && -n "${REMOTE_WIFI_IF:-}" ]]; then
        local remote_gw="${REMOTE_WIFI_GATEWAY:-${DUT_LAN_IP:-192.168.1.1}}"
        "${SCRIPT_DIR}/remote_client.sh" exec "sudo -n ip route replace '${WAN_SERVER_IP:-10.10.0.1}' via '${remote_gw}' dev '${REMOTE_WIFI_IF}' 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true; sudo -n iptables -t mangle -C POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || sudo -n iptables -t mangle -A POSTROUTING -o '${REMOTE_WIFI_IF}' -p udp -m multiport --sports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true" >/dev/null 2>&1 || true
    fi

    # 4. Ensure Downlink VoIP packets leaving WAN server (ns-wan) are marked DSCP 46 (EF = 0xb8)
    # This enables Gateway testing of DSCP-to-WMM Voice (AC_VO) downlink scheduling.
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp -m multiport --sports 4000,4002,5060,10000,10002,10004 -j DSCP --set-dscp 46"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp -m multiport --sports 4000,4002,5060,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -A POSTROUTING -p udp -m multiport --dports 4000,4002,5060,10000,10002,10004 -j DSCP --set-dscp 46"
    ip netns exec "${WAN_NS:-ns-wan}" iptables -t mangle -A POSTROUTING -p udp -m multiport --dports 4000,4002,5060,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true
    CLEANUP_WAN_MANGLE="ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp -m multiport --sports 4000,4002,5060,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true; ip netns exec ${WAN_NS:-ns-wan} iptables -t mangle -D POSTROUTING -p udp -m multiport --dports 4000,4002,5060,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true"

    # 5. Start iperf3 server in ns-wan
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM iperf3"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM iperf3 2>/dev/null || true
    sleep 0.2
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} iperf3 -s -p 5201 -D"
    ip netns exec "${WAN_NS:-ns-wan}" iperf3 -s -p 5201 -D >/dev/null 2>&1
    sleep 0.3

    # Step 1: Baseline PC Throughput (A)
    log_info "Measuring baseline PC throughput without VoIP calls (A, duration: ${pc_baseline_dur}s)..."
    local pc_base_out="${SCENARIO_TMP_DIR}/iperf_pc_base.json"
    log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${pc_baseline_dur} -J > ${pc_base_out}"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${pc_baseline_dur}" -J > "${pc_base_out}" 2>&1
    local a_mbps
    a_mbps="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_base_out}")"
    log_info "  Baseline PC throughput (A): ${a_mbps} Mbps"

    # Step 2: Start VoIP server and 2 Wi-Fi phone calls
    log_info "Starting VoIP media server and 2 active Wi-Fi phone calls using [${engine^^}]..."
    log_info "  -> Media Server (UAS)  : ns-wan:5060 (Listening for incoming SIP/RTP media, Downlink QoS: DSCP 46)"
    if [[ "${eff_mode}" == "physical_single" ]]; then
        log_info "  -> Phone 1 (Physical)  : ${DETECTED_WIFI_IF} (${wifi_ip}:5062 -> RTP 10000 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
        log_info "  -> Phone 2 (Physical)  : ${DETECTED_WIFI_IF} (${wifi_ip}:5064 -> RTP 10002 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
    elif [[ "${eff_mode}" == "remote_only" ]]; then
        log_info "  -> Phone 1 (Remote Wi-Fi): ${REMOTE_CLIENT_HOST} (${REMOTE_WIFI_IF:-wlp3s0}:${REMOTE_WIFI_IP:-unknown}:5062 -> RTP 10000 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
        log_info "  -> Phone 2 (Remote Wi-Fi): ${REMOTE_CLIENT_HOST} (${REMOTE_WIFI_IF:-wlp3s0}:${REMOTE_WIFI_IP:-unknown}:5064 -> RTP 10002 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
    elif [[ "${eff_mode}" == "distributed" ]]; then
        log_info "  -> Phone 1 (Local Wi-Fi): ${DETECTED_WIFI_IF} (${wifi_ip}:5062 -> RTP 10000 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
        log_info "  -> Phone 2 (Remote Wi-Fi): ${REMOTE_CLIENT_HOST} (${REMOTE_WIFI_IF:-wlan0}:${REMOTE_WIFI_IP:-unknown}:5064 -> RTP 10002 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
    else
        log_info "  -> Phone 1 (Virtual)   : ns-phone1 (5060 -> RTP 10000 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
        log_info "  -> Phone 2 (Virtual)   : ns-phone2 (5062 -> RTP 10002 -> ${WAN_SERVER_IP:-10.10.0.1}:5060)"
    fi
    local voip_srv_pid=""
    local phone1_pid=""
    local phone2_pid=""

    local ts_voip
    ts_voip="$(date +%Y%m%d_%H%M%S)"
    local phone1_pcap="${CAPTURE_DIR}/tc_qos_01_voice_${ts_voip}_phone1_wifi.pcap"
    local phone2_pcap="${CAPTURE_DIR}/tc_qos_01_voice_${ts_voip}_phone2_wifi.pcap"
    if [[ "${eff_mode}" == "remote_only" ]]; then
        phone2_pcap="${CAPTURE_DIR}/tc_qos_01_voice_${ts_voip}_remote_wifi.pcap"
        phone1_pcap="${phone2_pcap}"
    fi
    local phone1_cap_pid=""
    local phone2_cap_pid=""
    local remote_cap_active=0

    rm -f "${STATE_DIR}/latest_phone1_pcap.txt" "${STATE_DIR}/latest_phone2_pcap.txt" "${STATE_DIR}/latest_voip_mode.txt" 2>/dev/null || true
    echo "${eff_mode}" > "${STATE_DIR}/latest_voip_mode.txt"

    # Start Targeted Station Packet Captures (LAN / Wi-Fi side)
    if (( NO_CAPTURE == 0 && DRY_RUN == 0 )); then
        local voice_bpf="udp port 5060 or udp port 5062 or udp port 5064 or udp portrange 10000-10004"
        if [[ "${eff_mode}" == "remote_only" ]]; then
            log_info "  -> Remote Wi-Fi VoIP capture: [${REMOTE_CLIENT_HOST}:${REMOTE_WIFI_IF:-wlp3s0}] => ${phone2_pcap}"
            "${SCRIPT_DIR}/remote_client.sh" start-capture "${REMOTE_WIFI_IF:-wlp3s0}" "${voice_bpf}" "/tmp/tc_qos_01_phone2.pcap" >/dev/null 2>&1 || true
            remote_cap_active=1
        elif [[ "${eff_mode}" == "physical_single" || "${eff_mode}" == "distributed" ]]; then
            if [[ -n "${DETECTED_WIFI_IF:-}" ]]; then
                log_info "  -> Local Wi-Fi VoIP capture : [${DETECTED_WIFI_IF}] => ${phone1_pcap} (snaplen: ${CAPTURE_SNAPLEN:-96}B)"
                log_cmd "tcpdump -ni ${DETECTED_WIFI_IF} -s ${CAPTURE_SNAPLEN:-96} -U -w ${phone1_pcap} ${voice_bpf} &"
                tcpdump -ni "${DETECTED_WIFI_IF}" -s "${CAPTURE_SNAPLEN:-96}" -U -w "${phone1_pcap}" ${voice_bpf} >/dev/null 2>&1 &
                phone1_cap_pid=$!
                disown "${phone1_cap_pid}" 2>/dev/null || true
                echo "${phone1_pcap}" > "${STATE_DIR}/latest_phone1_pcap.txt"
            fi
            if [[ "${eff_mode}" == "distributed" ]]; then
                log_info "  -> Remote Wi-Fi VoIP capture: [${REMOTE_CLIENT_HOST}:${REMOTE_WIFI_IF:-wlp3s0}] => ${phone2_pcap}"
                "${SCRIPT_DIR}/remote_client.sh" start-capture "${REMOTE_WIFI_IF:-wlp3s0}" "${voice_bpf}" "/tmp/tc_qos_01_phone2.pcap" "${CAPTURE_SNAPLEN:-96}" >/dev/null 2>&1 || true
                remote_cap_active=1
            fi
        elif [[ "${eff_mode}" == "virtual" ]]; then
            if ns_exists "${PHONE1_NS:-ns-phone1}"; then
                log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} tcpdump -ni eth0 -s ${CAPTURE_SNAPLEN:-96} -U -w ${phone1_pcap} ${voice_bpf} &"
                ip netns exec "${PHONE1_NS:-ns-phone1}" tcpdump -ni eth0 -s "${CAPTURE_SNAPLEN:-96}" -U -w "${phone1_pcap}" ${voice_bpf} >/dev/null 2>&1 &
                phone1_cap_pid=$!
                disown "${phone1_cap_pid}" 2>/dev/null || true
                echo "${phone1_pcap}" > "${STATE_DIR}/latest_phone1_pcap.txt"
            fi
            if ns_exists "${PHONE2_NS:-ns-phone2}"; then
                log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} tcpdump -ni eth0 -s ${CAPTURE_SNAPLEN:-96} -U -w ${phone2_pcap} ${voice_bpf} &"
                ip netns exec "${PHONE2_NS:-ns-phone2}" tcpdump -ni eth0 -s "${CAPTURE_SNAPLEN:-96}" -U -w "${phone2_pcap}" ${voice_bpf} >/dev/null 2>&1 &
                phone2_cap_pid=$!
                disown "${phone2_cap_pid}" 2>/dev/null || true
                echo "${phone2_pcap}" > "${STATE_DIR}/latest_phone2_pcap.txt"
            fi
        fi
    fi

    if [[ "${engine}" == "pjsua" ]]; then
        # Server UAS in ns-wan (auto-answers all incoming calls with 200 OK, loops media back, and sets DSCP 46)
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${pjsua_bin} --local-port=5060 --null-audio --auto-answer=200 --auto-loop --no-vad --set-qos --use-cli --no-cli-console --app-log-level=0 < /dev/null &"
        ip netns exec "${WAN_NS:-ns-wan}" "${pjsua_bin}" \
            --local-port=5060 --null-audio --auto-answer=200 --auto-loop --no-vad --set-qos --use-cli --no-cli-console --app-log-level=0 < /dev/null >/dev/null 2>&1 &
        voip_srv_pid=$!
        disown "${voip_srv_pid}" 2>/dev/null || true
        ACTIVE_BG_PIDS+=("${voip_srv_pid}")
        sleep 0.5

        if [[ "${eff_mode}" == "physical_single" ]]; then
            log_cmd "${pjsua_bin} --local-port=5062 --rtp-port=10000 --null-audio --no-vad --ip-addr=${wifi_ip} --bound-addr=${wifi_ip} --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:5060 &"
            "${pjsua_bin}" --local-port=5062 --rtp-port=10000 --null-audio --no-vad \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" < /dev/null >/dev/null 2>&1 &
            phone1_pid=$!
            disown "${phone1_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            log_cmd "${pjsua_bin} --local-port=5064 --rtp-port=10002 --null-audio --no-vad --ip-addr=${wifi_ip} --bound-addr=${wifi_ip} --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:5060 &"
            "${pjsua_bin}" --local-port=5064 --rtp-port=10002 --null-audio --no-vad \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" < /dev/null >/dev/null 2>&1 &
            phone2_pid=$!
            disown "${phone2_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone2_pid}")

        elif [[ "${eff_mode}" == "remote_only" ]]; then
            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "pjsua" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 5060 \
                --local-port 5062 \
                --rtp-port 10000 \
                --duration "${call_duration}" \
                --phone-id "phone-1" || true

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "pjsua" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 5060 \
                --local-port 5064 \
                --rtp-port 10002 \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        elif [[ "${eff_mode}" == "distributed" ]]; then
            log_cmd "${pjsua_bin} --local-port=5062 --rtp-port=10000 --null-audio --no-vad --ip-addr=${wifi_ip} --bound-addr=${wifi_ip} --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:5060 &"
            "${pjsua_bin}" --local-port=5062 --rtp-port=10000 --null-audio --no-vad \
                --ip-addr="${wifi_ip}" --bound-addr="${wifi_ip}" \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" < /dev/null >/dev/null 2>&1 &
            phone1_pid=$!
            disown "${phone1_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "pjsua" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 5060 \
                --local-port 5064 \
                --rtp-port 10002 \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        else
            log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} ${pjsua_bin} --local-port=5060 --rtp-port=10000 --null-audio --no-vad --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:5060 &"
            ip netns exec "${PHONE1_NS:-ns-phone1}" "${pjsua_bin}" \
                --local-port=5060 --rtp-port=10000 --null-audio --no-vad \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" < /dev/null >/dev/null 2>&1 &
            phone1_pid=$!
            disown "${phone1_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} ${pjsua_bin} --local-port=5062 --rtp-port=10002 --null-audio --no-vad --duration=${call_duration} --set-qos --use-cli --no-cli-console --app-log-level=0 sip:${WAN_SERVER_IP:-10.10.0.1}:5060 &"
            ip netns exec "${PHONE2_NS:-ns-phone2}" "${pjsua_bin}" \
                --local-port=5062 --rtp-port=10002 --null-audio --no-vad \
                --duration="${call_duration}" --set-qos --use-cli --no-cli-console --app-log-level=0 "sip:${WAN_SERVER_IP:-10.10.0.1}:5060" < /dev/null >/dev/null 2>&1 &
            phone2_pid=$!
            disown "${phone2_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone2_pid}")
        fi

    elif [[ "${engine}" == "sipp" ]]; then
        local uac_tpl_src="${PROJECT_ROOT}/templates/sipp_uac_pcap.xml"
        local uas_tpl_src="${PROJECT_ROOT}/templates/sipp_uas_pcap.xml"
        local pcap_media="${PROJECT_ROOT}/templates/g711a_voice.pcap"
        if [[ ! -f "${pcap_media}" ]]; then
            if [[ -f "${PROJECT_ROOT}/templates/g711a_20s.pcap" ]]; then
                pcap_media="${PROJECT_ROOT}/templates/g711a_20s.pcap"
            elif [[ -x "${PROJECT_ROOT}/tools/generate_g711_pcap.py" ]]; then
                python3 "${PROJECT_ROOT}/tools/generate_g711_pcap.py" --output "${pcap_media}" --duration 30.0 >/dev/null 2>&1 || true
            fi
        fi
        local sipp_dur_ms=$(( call_duration * 1000 ))

        local uac_tpl="${SCENARIO_TMP_DIR}/sipp_uac_pcap.xml"
        local uas_tpl="${SCENARIO_TMP_DIR}/sipp_uas_pcap.xml"
        sed "s|__PCAP_FILE__|${pcap_media}|g" "${uac_tpl_src}" > "${uac_tpl}"
        sed "s|__PCAP_FILE__|${pcap_media}|g" "${uas_tpl_src}" > "${uas_tpl}"
        ln -sf "${pcap_media}" "${PROJECT_ROOT}/g711a_voice.pcap" 2>/dev/null || true

        if [[ -f "${uac_tpl}" && -f "${pcap_media}" ]]; then
            # Continuous G.711 RTP media playback at 50 PPS (20ms interval) via XML scenario
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${sipp_bin} -sf ${uas_tpl} -i ${WAN_SERVER_IP:-10.10.0.1} -mi ${WAN_SERVER_IP:-10.10.0.1} -p 5060 -mp 10000 -nostdin > ${LOG_DIR}/sipp_uas.log 2>&1 &"
            ip netns exec "${WAN_NS:-ns-wan}" "${sipp_bin}" \
                -sf "${uas_tpl}" \
                -i "${WAN_SERVER_IP:-10.10.0.1}" \
                -mi "${WAN_SERVER_IP:-10.10.0.1}" \
                -p 5060 -mp 10000 -nostdin > "${LOG_DIR}/sipp_uas.log" 2>&1 &
            voip_srv_pid=$!
            disown "${voip_srv_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${voip_srv_pid}")
            sleep 0.5

            if [[ "${eff_mode}" == "physical_single" ]]; then
                log_cmd "${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${wifi_ip} -mi ${wifi_ip} -p 5062 -mp 10000 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p 5062 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                disown "${phone1_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${wifi_ip} -mi ${wifi_ip} -p 5064 -mp 10002 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone2.log 2>&1 &"
                "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p 5064 -mp 10002 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone2.log" 2>&1 &
                phone2_pid=$!
                disown "${phone2_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone2_pid}")

            elif [[ "${eff_mode}" == "remote_only" ]]; then
                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port 5060 \
                    --local-port 5062 \
                    --rtp-port 10000 \
                    --duration "${call_duration}" \
                    --phone-id "phone-1" || true

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port 5060 \
                    --local-port 5064 \
                    --rtp-port 10002 \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            elif [[ "${eff_mode}" == "distributed" ]]; then
                log_cmd "${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${wifi_ip} -mi ${wifi_ip} -p 5062 -mp 10000 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p 5062 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                disown "${phone1_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port 5060 \
                    --local-port 5064 \
                    --rtp-port 10002 \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            else
                log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} ${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${PHONE1_IP:-192.168.1.101} -mi ${PHONE1_IP:-192.168.1.101} -p 5060 -mp 10000 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                ip netns exec "${PHONE1_NS:-ns-phone1}" "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${PHONE1_IP:-192.168.1.101}" -mi "${PHONE1_IP:-192.168.1.101}" -p 5060 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                disown "${phone1_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} ${sipp_bin} -sf ${uac_tpl} ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${PHONE2_IP:-192.168.1.102} -mi ${PHONE2_IP:-192.168.1.102} -p 5062 -mp 10002 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone2.log 2>&1 &"
                ip netns exec "${PHONE2_NS:-ns-phone2}" "${sipp_bin}" -sf "${uac_tpl}" "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${PHONE2_IP:-192.168.1.102}" -mi "${PHONE2_IP:-192.168.1.102}" -p 5062 -mp 10002 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone2.log" 2>&1 &
                phone2_pid=$!
                disown "${phone2_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone2_pid}")
            fi

        else
            # Standard SIP signaling fallback
            log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${sipp_bin} -sn uas -i ${WAN_SERVER_IP:-10.10.0.1} -mi ${WAN_SERVER_IP:-10.10.0.1} -p 5060 -mp 10000 -nostdin > ${LOG_DIR}/sipp_uas.log 2>&1 &"
            ip netns exec "${WAN_NS:-ns-wan}" "${sipp_bin}" -sn uas \
                -i "${WAN_SERVER_IP:-10.10.0.1}" -mi "${WAN_SERVER_IP:-10.10.0.1}" \
                -p 5060 -mp 10000 -nostdin > "${LOG_DIR}/sipp_uas.log" 2>&1 &
            voip_srv_pid=$!
            disown "${voip_srv_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${voip_srv_pid}")
            sleep 0.5

            if [[ "${eff_mode}" == "physical_single" ]]; then
                log_cmd "${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${wifi_ip} -mi ${wifi_ip} -p 5062 -mp 10000 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p 5062 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                disown "${phone1_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${wifi_ip} -mi ${wifi_ip} -p 5064 -mp 10002 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone2.log 2>&1 &"
                "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p 5064 -mp 10002 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone2.log" 2>&1 &
                phone2_pid=$!
                disown "${phone2_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone2_pid}")

            elif [[ "${eff_mode}" == "remote_only" ]]; then
                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port 5060 \
                    --local-port 5062 \
                    --rtp-port 10000 \
                    --duration "${call_duration}" \
                    --phone-id "phone-1" || true

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port 5060 \
                    --local-port 5064 \
                    --rtp-port 10002 \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            elif [[ "${eff_mode}" == "distributed" ]]; then
                log_cmd "${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${wifi_ip} -mi ${wifi_ip} -p 5062 -mp 10000 -m 1 -d ${sipp_dur_ms} -nostdin > ${LOG_DIR}/sipp_phone1.log 2>&1 &"
                "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${wifi_ip}" -mi "${wifi_ip}" -p 5062 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin > "${LOG_DIR}/sipp_phone1.log" 2>&1 &
                phone1_pid=$!
                disown "${phone1_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                "${SCRIPT_DIR}/remote_client.sh" run-voip \
                    --engine "sipp" \
                    --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                    --server-port 5060 \
                    --local-port 5064 \
                    --rtp-port 10002 \
                    --duration "${call_duration}" \
                    --phone-id "phone-2" || true

            else
                log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} ${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${PHONE1_IP:-192.168.1.101} -mi ${PHONE1_IP:-192.168.1.101} -p 5060 -mp 10000 -m 1 -d ${sipp_dur_ms} -nostdin >/dev/null 2>&1 &"
                ip netns exec "${PHONE1_NS:-ns-phone1}" "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${PHONE1_IP:-192.168.1.101}" -mi "${PHONE1_IP:-192.168.1.101}" -p 5060 -mp 10000 -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
                phone1_pid=$!
                disown "${phone1_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone1_pid}")

                log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} ${sipp_bin} -sn uac ${WAN_SERVER_IP:-10.10.0.1}:5060 -i ${PHONE2_IP:-192.168.1.102} -mi ${PHONE2_IP:-192.168.1.102} -p 5062 -mp 10002 -m 1 -d ${sipp_dur_ms} -nostdin >/dev/null 2>&1 &"
                ip netns exec "${PHONE2_NS:-ns-phone2}" "${sipp_bin}" -sn uac "${WAN_SERVER_IP:-10.10.0.1}:5060" \
                    -i "${PHONE2_IP:-192.168.1.102}" -mi "${PHONE2_IP:-192.168.1.102}" -p 5062 -mp 10002 -m 1 -d "${sipp_dur_ms}" -nostdin >/dev/null 2>&1 &
                phone2_pid=$!
                disown "${phone2_pid}" 2>/dev/null || true
                ACTIVE_BG_PIDS+=("${phone2_pid}")
            fi
        fi

    else
        # Native Python G.711 RTP Simulator
        log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/voip_call_simulator.py server --ports 10000,10002 --duration $(( call_duration + 10 )) &"
        ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/voip_call_simulator.py" server \
            --ports "10000,10002" --duration "$(( call_duration + 10 ))" >/dev/null 2>&1 &
        voip_srv_pid=$!
        disown "${voip_srv_pid}" 2>/dev/null || true
        ACTIVE_BG_PIDS+=("${voip_srv_pid}")
        sleep 0.3

        if [[ "${eff_mode}" == "physical_single" ]]; then
            log_cmd "${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 10000 --bind-ip ${wifi_ip} --bind-port 10000 --duration ${call_duration} --phone-id phone-1 &"
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10000 \
                --bind-ip "${wifi_ip}" --bind-port 10000 \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            disown "${phone1_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            log_cmd "${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 10002 --bind-ip ${wifi_ip} --bind-port 10002 --duration ${call_duration} --phone-id phone-2 &"
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10002 \
                --bind-ip "${wifi_ip}" --bind-port 10002 \
                --duration "${call_duration}" --phone-id "phone-2" >/dev/null 2>&1 &
            phone2_pid=$!
            disown "${phone2_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone2_pid}")

        elif [[ "${eff_mode}" == "remote_only" ]]; then
            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "python" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 10000 \
                --duration "${call_duration}" \
                --phone-id "phone-1" || true

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "python" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 10002 \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        elif [[ "${eff_mode}" == "distributed" ]]; then
            log_cmd "${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 10000 --bind-ip ${wifi_ip} --bind-port 10000 --duration ${call_duration} --phone-id phone-1 &"
            "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10000 \
                --bind-ip "${wifi_ip}" --bind-port 10000 \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            disown "${phone1_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            "${SCRIPT_DIR}/remote_client.sh" run-voip \
                --engine "python" \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" \
                --server-port 10002 \
                --duration "${call_duration}" \
                --phone-id "phone-2" || true

        else
            log_cmd "ip netns exec ${PHONE1_NS:-ns-phone1} ${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 10000 --duration ${call_duration} --phone-id phone-1 &"
            ip netns exec "${PHONE1_NS:-ns-phone1}" "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10000 \
                --duration "${call_duration}" --phone-id "phone-1" >/dev/null 2>&1 &
            phone1_pid=$!
            disown "${phone1_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone1_pid}")

            log_cmd "ip netns exec ${PHONE2_NS:-ns-phone2} ${tools_dir}/voip_call_simulator.py client --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port 10002 --duration ${call_duration} --phone-id phone-2 &"
            ip netns exec "${PHONE2_NS:-ns-phone2}" "${tools_dir}/voip_call_simulator.py" client \
                --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port 10002 \
                --duration "${call_duration}" --phone-id "phone-2" >/dev/null 2>&1 &
            phone2_pid=$!
            disown "${phone2_pid}" 2>/dev/null || true
            ACTIVE_BG_PIDS+=("${phone2_pid}")
        fi
    fi

    log_pass "VoIP call media streams active on Wi-Fi client stations."
    sleep 1.0 # Allow calls to establish and stabilize

    # Step 3: Measure PC Throughput during active calls (B)
    log_info "Measuring PC throughput during 2 active Wi-Fi phone calls (B, duration: ${pc_concurrent_dur}s)..."
    local pc_call_out="${SCENARIO_TMP_DIR}/iperf_pc_call.json"
    log_cmd "ip netns exec ${PC_NS:-ns-pc} iperf3 -c ${WAN_SERVER_IP:-10.10.0.1} -p 5201 -t ${pc_concurrent_dur} -J > ${pc_call_out}"
    ip netns exec "${PC_NS:-ns-pc}" iperf3 -c "${WAN_SERVER_IP:-10.10.0.1}" -p 5201 -t "${pc_concurrent_dur}" -J > "${pc_call_out}" 2>&1
    local b_mbps
    b_mbps="$("${tools_dir}/metric_parser.py" sum-mbps "${pc_call_out}")"
    log_info "  Concurrent PC throughput (B): ${b_mbps} Mbps"

    # Verify that calls were actually running and did not terminate prematurely
    local verified_calls=2
    if [[ "${eff_mode}" == "remote_only" ]]; then
        local r1_alive r2_alive
        r1_alive="$("${SCRIPT_DIR}/remote_client.sh" is-voip-running "phone-1" 2>/dev/null | tr -d '\r\n ' || echo 0)"
        r2_alive="$("${SCRIPT_DIR}/remote_client.sh" is-voip-running "phone-2" 2>/dev/null | tr -d '\r\n ' || echo 0)"
        if [[ "${r1_alive}" != "1" ]]; then
            log_error "Remote Phone 1 VoIP client terminated prematurely or failed during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
        if [[ "${r2_alive}" != "1" ]]; then
            log_error "Remote Phone 2 VoIP client terminated prematurely or failed during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
    elif [[ "${eff_mode}" == "distributed" ]]; then
        if [[ -n "${phone1_pid}" ]] && ! kill -0 "${phone1_pid}" 2>/dev/null; then
            log_error "Phone 1 VoIP client terminated prematurely during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
        local remote_alive
        remote_alive="$("${SCRIPT_DIR}/remote_client.sh" is-voip-running "phone-2" 2>/dev/null | tr -d '\r\n ' || echo 0)"
        if [[ "${remote_alive}" != "1" ]]; then
            log_error "Remote Phone 2 VoIP client terminated prematurely or failed during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
    else
        if [[ -n "${phone1_pid}" ]] && ! kill -0 "${phone1_pid}" 2>/dev/null; then
            log_error "Phone 1 VoIP client terminated prematurely during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
        if [[ -n "${phone2_pid}" ]] && ! kill -0 "${phone2_pid}" 2>/dev/null; then
            log_error "Phone 2 VoIP client terminated prematurely during the test!"
            verified_calls=$(( verified_calls - 1 ))
        fi
    fi

    if (( verified_calls < 2 )); then
        log_error "VoIP load generator verification FAILED: Only ${verified_calls}/2 calls active."
    else
        log_pass "Both VoIP calls verified continuously active throughout throughput test."
    fi

    # Clean up background VoIP processes and iperf server
    if [[ -n "${phone1_pid}" ]]; then
        if [[ "${engine}" == "sipp" ]]; then
            kill -KILL "${phone1_pid}" 2>/dev/null || true
        else
            kill -TERM "${phone1_pid}" 2>/dev/null || true
        fi
    fi
    if [[ -n "${phone2_pid}" ]]; then
        if [[ "${engine}" == "sipp" ]]; then
            kill -KILL "${phone2_pid}" 2>/dev/null || true
        else
            kill -TERM "${phone2_pid}" 2>/dev/null || true
        fi
    fi
    if [[ -n "${voip_srv_pid}" ]]; then
        if [[ "${engine}" == "sipp" ]]; then
            kill -KILL "${voip_srv_pid}" 2>/dev/null || true
        else
            kill -TERM "${voip_srv_pid}" 2>/dev/null || true
        fi
    fi
    ACTIVE_BG_PIDS=()

    # Stop Targeted Station Packet Captures (LAN / Wi-Fi side)
    if [[ -n "${phone1_cap_pid}" ]]; then
        kill -TERM "${phone1_cap_pid}" 2>/dev/null || true
        chmod 0666 "${phone1_pcap}" 2>/dev/null || true
    fi
    if [[ -n "${phone2_cap_pid}" ]]; then
        kill -TERM "${phone2_cap_pid}" 2>/dev/null || true
        chmod 0666 "${phone2_pcap}" 2>/dev/null || true
    fi
    if (( remote_cap_active == 1 )); then
        "${SCRIPT_DIR}/remote_client.sh" stop-capture "/tmp/tc_qos_01_phone2.pcap" >/dev/null 2>&1 || true
        "${SCRIPT_DIR}/remote_client.sh" fetch-capture "/tmp/tc_qos_01_phone2.pcap" "${phone2_pcap}" >/dev/null 2>&1 || true
        chmod 0666 "${phone2_pcap}" 2>/dev/null || true
        echo "${phone2_pcap}" > "${STATE_DIR}/latest_phone2_pcap.txt"
        if [[ "${eff_mode}" == "remote_only" ]]; then
            echo "${phone2_pcap}" > "${STATE_DIR}/latest_phone1_pcap.txt"
            phone1_pcap="${phone2_pcap}"
        fi
    fi

    if [[ "${eff_mode}" == "remote_only" || "${eff_mode}" == "distributed" ]]; then
        "${SCRIPT_DIR}/remote_client.sh" clean >/dev/null 2>&1 || true
    fi
    log_cmd "ip netns exec ${WAN_NS:-ns-wan} pkill -TERM -x iperf3"
    ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -x iperf3 2>/dev/null || true

    # Clean up physical Wi-Fi route and iptables rule
    if (( added_wifi_route == 1 )); then
        log_cmd "ip route del ${WAN_SERVER_IP:-10.10.0.1} via ${DUT_LAN_IP:-192.168.1.1} dev ${DETECTED_WIFI_IF}"
        ip route del "${WAN_SERVER_IP:-10.10.0.1}" via "${DUT_LAN_IP:-192.168.1.1}" dev "${DETECTED_WIFI_IF}" 2>/dev/null || true
        CLEANUP_WIFI_ROUTE=""
    fi
    if (( added_mangle_rule == 1 )); then
        log_cmd "iptables -t mangle -D POSTROUTING -o ${DETECTED_WIFI_IF} -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46"
        iptables -t mangle -D POSTROUTING -o "${DETECTED_WIFI_IF}" -p udp -m multiport --dports 5060,5062,5064,10000,10002,10004 -j DSCP --set-dscp 46 2>/dev/null || true
        CLEANUP_IPTABLES_MANGLE=""
    fi
    if [[ -n "${CLEANUP_WAN_MANGLE:-}" ]]; then
        eval "${CLEANUP_WAN_MANGLE}" 2>/dev/null || true
        CLEANUP_WAN_MANGLE=""
    fi

    local wifi_if_rep="${DETECTED_WIFI_IF:-}"
    local wifi_ssid_rep="${DETECTED_WIFI_SSID:-}"
    if [[ "${eff_mode}" == "remote_only" ]]; then
        wifi_if_rep="${REMOTE_WIFI_IF:-wlp3s0}"
        wifi_ssid_rep="${REMOTE_WIFI_SSID:-DUT}"
    fi

    local eval_cmd=(
        "${tools_dir}/metric_parser.py" eval-qos
        --baseline "${a_mbps}"
        --during "${b_mbps}"
        --mode "${eff_mode}"
        --engine "${engine}"
        --wifi-if "${wifi_if_rep}"
        --wifi-ssid "${wifi_ssid_rep}"
        --calls 2
        --verified-calls "${verified_calls}"
        --tolerance "${VOIP_IMPACT_TOLERANCE_PCT:-1.0}"
        --output "${voice_json}"
    )
    log_cmd "${eval_cmd[*]}"
    "${eval_cmd[@]}"
}

# ------------------------------------------------------------------------------
# Dispatcher for Individual & Composite Scenarios
# ------------------------------------------------------------------------------
execute_scenario() {
    local scn="$1"
    case "${scn}" in
        unicast|tc_wr_01)
            run_with_dual_capture "tc_wr_01_unicast" "${PC_NS:-ns-pc}" "udp port 5002 or udp port 5012" run_subphase_unicast
            ;;
        multicast|tc_wr_02)
            run_with_dual_capture "tc_wr_02_multicast" "${STB_NS:-ns-stb}" "udp port 5003" run_subphase_multicast
            ;;
        wire_rate)
            run_with_dual_capture "tc_wr_01_unicast" "${PC_NS:-ns-pc}" "udp port 5002 or udp port 5012" run_subphase_unicast
            run_with_dual_capture "tc_wr_02_multicast" "${STB_NS:-ns-stb}" "udp port 5003" run_subphase_multicast
            ;;
        burst_case1|tc_rm_01)
            adapt_burst_physical_speed 100
            run_with_dual_capture "tc_rm_01_burst53" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case1
            restore_burst_physical_speed
            ;;
        burst_case2|tc_rm_02)
            adapt_burst_physical_speed 100
            run_with_dual_capture "tc_rm_02_burst100" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case2
            restore_burst_physical_speed
            ;;
        rate_mismatch)
            adapt_burst_physical_speed 100
            run_with_dual_capture "tc_rm_01_burst53" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case1
            run_with_dual_capture "tc_rm_02_burst100" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case2
            restore_burst_physical_speed
            ;;
        geforce|tc_app_01)
            adapt_burst_physical_speed 100
            run_with_dual_capture "tc_app_01_geforce" "${STB_NS:-ns-stb}" "udp port 5004" run_subphase_geforce
            restore_burst_physical_speed
            ;;
        vod|tc_app_02)
            adapt_burst_physical_speed 100
            run_with_dual_capture "tc_app_02_vod" "${STB_NS:-ns-stb}" "udp port 5005" run_subphase_vod
            restore_burst_physical_speed
            ;;
        real_world_stb)
            adapt_burst_physical_speed 100
            run_with_dual_capture "tc_app_01_geforce" "${STB_NS:-ns-stb}" "udp port 5004" run_subphase_geforce
            run_with_dual_capture "tc_app_02_vod" "${STB_NS:-ns-stb}" "udp port 5005" run_subphase_vod
            restore_burst_physical_speed
            ;;
        simultaneous|tc_sim_01)
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        sequential|tc_sim_seq|multiband)
            CUSTOM_WIFI_MODE="sequential"
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        remote|tc_sim_remote|distributed)
            CUSTOM_WIFI_MODE="remote"
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way)
            CUSTOM_WIFI_MODE="tri_station"
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            ;;
        voice_qos|tc_qos_01)
            run_with_dual_capture "tc_qos_01_voice" "${PC_NS:-ns-pc}" "tcp port 5201 or udp port 10000 or udp port 10002 or udp port 10004 or udp port 5060 or udp port 5062 or udp port 5064" run_phase_voice_qos
            ;;
        all)
            run_with_dual_capture "tc_wr_01_unicast" "${PC_NS:-ns-pc}" "udp port 5002 or udp port 5012" run_subphase_unicast
            run_with_dual_capture "tc_wr_02_multicast" "${STB_NS:-ns-stb}" "udp port 5003" run_subphase_multicast
            adapt_burst_physical_speed 100
            run_with_dual_capture "tc_rm_01_burst53" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case1
            run_with_dual_capture "tc_rm_02_burst100" "${STB_NS:-ns-stb}" "udp port 5001" run_subphase_burst_case2
            run_with_dual_capture "tc_app_01_geforce" "${STB_NS:-ns-stb}" "udp port 5004" run_subphase_geforce
            run_with_dual_capture "tc_app_02_vod" "${STB_NS:-ns-stb}" "udp port 5005" run_subphase_vod
            restore_burst_physical_speed
            run_with_dual_capture "tc_sim_01_simultaneous" "${PC_NS:-ns-pc}" "tcp port 5201 or tcp port 5202 or tcp port 5203 or tcp port 5204" run_phase_simultaneous
            run_with_dual_capture "tc_qos_01_voice" "${PC_NS:-ns-pc}" "tcp port 5201 or udp port 10000 or udp port 10002 or udp port 10004 or udp port 5060 or udp port 5062 or udp port 5064" run_phase_voice_qos
            ;;
        *)
            die "Unknown scenario: ${scn}"
            ;;
    esac
}

main() {
    local scenario="all"
    local collect_artifacts=0
    local cli_debug=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug|-v|--verbose)
                DEBUG=1
                VERBOSE=1
                cli_debug=1
                export DEBUG VERBOSE
                shift
                ;;
            --no-adapt-speed)
                AUTO_ADAPT_BURST_SPEED=0
                shift
                ;;
            --collect-artifacts|-A)
                collect_artifacts=1
                shift
                ;;
            --snaplen|-s)
                [[ $# -ge 2 ]] || die "Option --snaplen requires a length argument (e.g. 96, 128, 0)"
                CUSTOM_SNAPLEN="$2"
                shift 2
                ;;
            --dry-run|-n)
                DRY_RUN=1
                shift
                ;;
            --no-capture|-C)
                NO_CAPTURE=1
                shift
                ;;
            --duration|-d)
                [[ $# -ge 2 ]] || die "Option --duration requires a seconds argument"
                CUSTOM_DURATION="$2"
                shift 2
                ;;
            --omit|-O)
                [[ $# -ge 2 ]] || die "Option --omit requires a seconds argument (e.g. 2)"
                CUSTOM_UNICAST_OMIT="$2"
                shift 2
                ;;
            --bitrate|-b)
                [[ $# -ge 2 ]] || die "Option --bitrate requires a rate argument (e.g. 950M, 475M)"
                CUSTOM_UNICAST_RATE="$2"
                shift 2
                ;;
            --unicast-mode|-U)
                [[ $# -ge 2 ]] || die "Option --unicast-mode requires a mode argument (sequential, concurrent)"
                CUSTOM_UNICAST_MODE="$2"
                shift 2
                ;;
            --wifi-mode|-W)
                [[ $# -ge 2 ]] || die "Option --wifi-mode requires a mode argument (auto, real_single, remote, remote_only, distributed, tri_station, emulated)"
                CUSTOM_WIFI_MODE="$2"
                shift 2
                ;;
            --remote-only|-R)
                CUSTOM_WIFI_MODE="remote_only"
                shift
                ;;
            --voip-engine|-E)
                [[ $# -ge 2 ]] || die "Option --voip-engine requires an engine argument (auto, pjsua, sipp, python)"
                CUSTOM_VOIP_ENGINE="$2"
                shift 2
                ;;
            --fps|-F)
                [[ $# -ge 2 ]] || die "Option --fps requires a frame rate argument (e.g. 60, 120)"
                CUSTOM_GFN_FPS="$2"
                shift 2
                ;;
            --gfn-bitrate)
                [[ $# -ge 2 ]] || die "Option --gfn-bitrate requires a bitrate in Mbps (e.g. 25.0, 50.0)"
                CUSTOM_GFN_BITRATE="$2"
                shift 2
                ;;
            --gfn-jitter|--max-jitter)
                [[ $# -ge 2 ]] || die "Option --gfn-jitter requires a jitter limit in ms (e.g. 1.5, 2.0)"
                CUSTOM_GFN_JITTER="$2"
                shift 2
                ;;
            --deep-audit|--deep|-D)
                export DEEP_AUDIT=1
                shift
                ;;
            --merge-lan|-M)
                export MERGE_LAN=1
                shift
                ;;
            --stability|--soak)
                NO_CAPTURE=1
                CUSTOM_DURATION="${CUSTOM_DURATION:-60}"
                shift
                ;;
            --log|-l)
                ENABLE_LOG_TEE=1
                if [[ $# -ge 2 && ! "$2" =~ ^- && ! "$2" =~ ^(unicast|tc_wr_01|multicast|tc_wr_02|wire_rate|burst_case1|tc_rm_01|burst_case2|tc_rm_02|rate_mismatch|geforce|tc_app_01|vod|tc_app_02|real_world_stb|simultaneous|tc_sim_01|sequential|tc_sim_seq|multiband|remote|tc_sim_remote|distributed|tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way|voice_qos|tc_qos_01|all)$ ]]; then
                    CUSTOM_LOG_FILE="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -h|--help|help)
                if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
                    usage "$2"
                    exit 0
                else
                    usage "${scenario:-all}"
                    exit 0
                fi
                ;;
            unicast|tc_wr_01|multicast|tc_wr_02|wire_rate|burst_case1|tc_rm_01|burst_case2|tc_rm_02|rate_mismatch|geforce|tc_app_01|vod|tc_app_02|real_world_stb|simultaneous|tc_sim_01|sequential|tc_sim_seq|multiband|remote|tc_sim_remote|distributed|tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way|voice_qos|tc_qos_01|all)
                scenario="$1"
                shift
                ;;
            *)
                log_error "Unknown option or scenario: $1"
                usage "${scenario:-all}"
                exit 1
                ;;
        esac
    done

    load_config "${LAB_DIR}/config.env"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/topology_state.env"
    fi

    if (( cli_debug == 1 )); then
        DEBUG=1
        VERBOSE=1
        export DEBUG VERBOSE
    fi

    if [[ -n "${CUSTOM_SNAPLEN:-}" ]]; then
        CAPTURE_SNAPLEN="${CUSTOM_SNAPLEN}"
    else
        CAPTURE_SNAPLEN="${CAPTURE_SNAPLEN:-96}"
    fi
    export CAPTURE_SNAPLEN

    local tools_dir="${LAB_DIR}/tools"
    if [[ -x "${tools_dir}/wifi_inspector.py" ]]; then
        local env_dump
        env_dump="$("${tools_dir}/wifi_inspector.py" export-env 2>/dev/null || true)"
        eval "${env_dump}"
    fi

    if (( DRY_RUN == 0 )); then
        require_root
        require_command ip
        require_command python3
        require_command iperf3
    fi

    ensure_runtime_dirs

    if (( ENABLE_LOG_TEE == 1 )); then
        local ts_run
        ts_run="$(date +%Y%m%d_%H%M%S)"
        local log_run_file="${CUSTOM_LOG_FILE:-${LOG_DIR}/scenario_${scenario}_${ts_run}.log}"
        mkdir -p "$(dirname "${log_run_file}")" 2>/dev/null || true
        touch "${log_run_file}" 2>/dev/null || true
        chmod 0666 "${log_run_file}" 2>/dev/null || true
        log_info "Mirroring all console output to log file: ${log_run_file}"
        exec > >(tee >(sed -u -r 's/\x1B\[[0-9;]*[a-zA-Z]//g' >> "${log_run_file}")) 2>&1
    fi

    SCENARIO_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gw_perf_scenario.XXXXXX")"
    trap cleanup_scenario_trap EXIT INT TERM ERR

    print_header "STARTING GATEWAY PERFORMANCE TEST: [${scenario^^}]"

    if (( DRY_RUN == 0 )); then
        if ns_exists "${WAN_NS:-ns-wan}"; then
            log_cmd "ip -n ${WAN_NS:-ns-wan} route replace ${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24} via ${DUT_WAN_IP:-10.10.0.100} dev eth0"
            ip -n "${WAN_NS:-ns-wan}" route replace "${DUT_LAN_IP:-192.168.1.1}/${LAN_PREFIX:-24}" via "${DUT_WAN_IP:-10.10.0.100}" dev eth0 2>/dev/null || true
            log_cmd "ip -n ${WAN_NS:-ns-wan} route replace default via ${DUT_WAN_IP:-10.10.0.100} dev eth0"
            ip -n "${WAN_NS:-ns-wan}" route replace default via "${DUT_WAN_IP:-10.10.0.100}" dev eth0 2>/dev/null || true
            log_cmd "ip -n ${WAN_NS:-ns-wan} route replace 224.0.0.0/4 dev eth0"
            ip -n "${WAN_NS:-ns-wan}" route replace 224.0.0.0/4 dev eth0 2>/dev/null || true
        fi
        if ns_exists "${DUT_NS:-ns-dut}"; then
            log_cmd "ip netns exec ${DUT_NS:-ns-dut} iptables -P FORWARD ACCEPT"
            ip netns exec "${DUT_NS:-ns-dut}" iptables -P FORWARD ACCEPT 2>/dev/null || true
            log_cmd "ip netns exec ${DUT_NS:-ns-dut} iptables -A FORWARD -j ACCEPT"
            ip netns exec "${DUT_NS:-ns-dut}" iptables -A FORWARD -j ACCEPT 2>/dev/null || true
            log_cmd "ip -n ${DUT_NS:-ns-dut} route replace 224.0.0.0/4 dev br-lan"
            ip -n "${DUT_NS:-ns-dut}" route replace 224.0.0.0/4 dev br-lan 2>/dev/null || true
        fi
    fi

    execute_scenario "${scenario}"

    log_success "Scenario run complete. Summary logs generated in ${LOG_DIR}/."
    if (( collect_artifacts == 1 )) && [[ -x "${SCRIPT_DIR}/collect_artifacts.sh" ]]; then
        "${SCRIPT_DIR}/collect_artifacts.sh" --latest
    fi

    printf '\nSuggested next steps:\n'
    printf '  - Run compliance verifier: ./scripts/verify_compliance.sh\n'
    printf '  - Collect test artifacts:  ./scripts/collect_artifacts.sh\n'
    printf '  - Inspect captures:        ./scripts/capture.sh status\n'
    printf '  - Audit dual captures:     ./scripts/capture.sh compare\n'
}

main "$@"
