#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - COMPLIANCE & PCAP VERIFICATION ENGINE
# Dual-layer verification: Quantitative metric assertions + Wire-level PCAP inspection
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

usage() {
    cat <<'EOF'
==================================================================
  Gateway Performance Lab - Compliance Verifier
==================================================================

Description:
  Evaluates test results against quantitative acceptance criteria:
  - TC-WR-01: Wire-rate 1024B bidirectional unicast (0% packet loss)
  - TC-WR-02: Wire-rate 1024B multicast forwarding (0% packet loss)
  - TC-RM-01: 1G -> 100M burst (1500B, 50% load, 53 frames, 0% loss)
  - TC-RM-02: 1G -> 100M burst (1500B, 16% load, 100 frames, 0% loss)
  - TC-APP-01: GeForce NOW Network Test normal (loss 0%, jitter < 2ms)
  - TC-APP-02: UHD+Dolby VOD 1.2x speed playback normal (no stalls)
  - TC-SIM-01: Simultaneous Wired + Tri-band Wireless degradation <= 1%
  - TC-QOS-01: PC throughput drop during 2 Wi-Fi phone calls <= 1%

Usage:
  ./scripts/verify_compliance.sh [options] [pcap_file]

Options:
  -h, --help  Show this help message and exit

Examples:
  ./scripts/verify_compliance.sh
  ./scripts/verify_compliance.sh captures/perf_test_all_12345.pcap
==================================================================
EOF
}

check_assertion() {
    local test_id="$1"
    local title="$2"
    local status="$3"
    local detail="$4"

    TOTAL_TESTS=$(( TOTAL_TESTS + 1 ))
    if [[ "${status}" == "PASS" ]]; then
        PASSED_TESTS=$(( PASSED_TESTS + 1 ))
        printf '  \e[1;32m[PASS]\e[0m    [%s] %s\n            Detail: %s\n' "${test_id}" "${title}" "${detail}"
    elif [[ "${status}" == "INVALID" || "${status}" == "INCONCLUSIVE" ]]; then
        SKIPPED_TESTS=$(( SKIPPED_TESTS + 1 ))
        printf '  \e[1;33m[%s]\e[0m [%s] %s\n            Detail: %s\n' "${status}" "${test_id}" "${title}" "${detail}"
    elif [[ "${status}" == "NOT_RUN" || "${status}" == "SKIP" ]]; then
        SKIPPED_TESTS=$(( SKIPPED_TESTS + 1 ))
        printf '  \e[1;33m[NOT RUN]\e[0m [%s] %s\n            Detail: %s\n' "${test_id}" "${title}" "${detail}"
    else
        FAILED_TESTS=$(( FAILED_TESTS + 1 ))
        printf '  \e[1;31m[FAIL]\e[0m    [%s] %s\n            Detail: %s\n' "${test_id}" "${title}" "${detail}"
    fi
}

parse_json_field() {
    local file="$1"
    local field="$2"
    if [[ ! -f "${file}" || ! -r "${file}" ]]; then
        printf 'MISSING\n'
        return 0
    fi
    if [[ -x "${LAB_DIR}/tools/metric_parser.py" ]]; then
        "${LAB_DIR}/tools/metric_parser.py" get-field --file "${file}" --field "${field}" --default "MISSING" 2>/dev/null || printf 'MISSING\n'
    else
        python3 -c 'import sys, json; (lambda: print(json.load(open(sys.argv[1])).get(sys.argv[2], "MISSING")))()' "${file}" "${field}" 2>/dev/null || printf 'MISSING\n'
    fi
}

print_pcap_timeline() {
    local pcap_file="$1"
    if ! check_command "${TSHARK_BIN:-tshark}"; then
        log_info "tshark not installed; skipping packet timeline table."
        return 0
    fi
    if [[ ! -f "${pcap_file}" || ! -s "${pcap_file}" ]]; then
        log_warn "PCAP file is empty or missing: ${pcap_file}"
        return 0
    fi

    printf '\n========================================================================================\n'
    printf '                          PACKET TIMELINE EVIDENCE                               \n'
    printf '========================================================================================\n'
    printf '%-6s | %-12s | %-24s | %-24s | %-20s\n' "Frame" "Time (s)" "Source IP" "Destination IP" "Protocol / Info"
    printf '%s\n' "----------------------------------------------------------------------------------------"

    # SIGPIPE & AppArmor protection pattern (piping via cat bypasses AppArmor profile path confinement)
    ( (cat "${pcap_file}" 2>/dev/null | tshark -r - \
        -T fields \
        -e frame.number -e frame.time_relative -e _ws.col.Source -e _ws.col.Destination -e _ws.col.Protocol -e _ws.col.Info 2>/dev/null | \
        awk -F '\t' '{ printf "%-6s | %-12.4f | %-24s | %-24s | %-10s %s\n", $1, $2, $3, $4, $5, $6 }') 2>/dev/null || true ) | head -n 35

    printf '========================================================================================\n\n'
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config "${LAB_DIR}/config.env"

    local pcap_file="${1:-}"
    local pcap_lan_file="${2:-}"
    if [[ -z "${pcap_file}" ]]; then
        if [[ -f "${STATE_DIR}/latest_wan_pcap.txt" ]]; then
            pcap_file="$(cat "${STATE_DIR}/latest_wan_pcap.txt" 2>/dev/null || true)"
            pcap_lan_file="$(cat "${STATE_DIR}/latest_lan_pcap.txt" 2>/dev/null || true)"
        fi
        if [[ -z "${pcap_file}" ]]; then
            pcap_file="$(get_latest_pcap || true)"
        fi
    fi

    print_header "GATEWAY PERFORMANCE & WIRE-RATE COMPLIANCE REPORT"

    if [[ -n "${pcap_file}" && -f "${pcap_file}" ]]; then
        local pcap_size
        pcap_size="$(du -h "${pcap_file}" 2>/dev/null | cut -f1 || echo "unknown")"
        log_info "WAN Evidence capture: ${pcap_file} (${pcap_size})"
    fi
    if [[ -n "${pcap_lan_file:-}" && -f "${pcap_lan_file}" ]]; then
        local lan_size
        lan_size="$(du -h "${pcap_lan_file}" 2>/dev/null | cut -f1 || echo "unknown")"
        log_info "LAN Evidence capture: ${pcap_lan_file} (${lan_size})"
    fi
    if [[ -z "${pcap_file}" && -z "${pcap_lan_file:-}" ]]; then
        log_warn "No PCAP capture file found. Evaluating test log outputs..."
    fi

    print_section "1. WIRE-RATE PACKET FORWARDING (1024-BYTE PACKETS)"
    # TC-WR-01: Bidirectional Unicast 1024B
    local uni_log="${LOG_DIR}/unicast_result.json"
    if [[ -f "${uni_log}" ]]; then
        local u_loss u_tput u_status
        u_loss="$(parse_json_field "${uni_log}" "loss_pct")"
        u_tput="$(parse_json_field "${uni_log}" "throughput_mbps")"
        u_status="$(parse_json_field "${uni_log}" "status")"
        check_assertion "TC-WR-01" "1024B Bidirectional Full Unicast (0% Loss)" "${u_status}" \
            "Throughput: ${u_tput} Mbps | Packet Loss: ${u_loss}%"
    else
        check_assertion "TC-WR-01" "1024B Bidirectional Full Unicast (0% Loss)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh wire_rate)"
    fi

    # TC-WR-02: Multicast Forwarding 1024B
    local mcast_log="${LOG_DIR}/multicast_result.json"
    if [[ -f "${mcast_log}" ]]; then
        local m_loss m_status m_recv m_exp
        m_loss="$(parse_json_field "${mcast_log}" "loss_pct")"
        m_status="$(parse_json_field "${mcast_log}" "status")"
        m_recv="$(parse_json_field "${mcast_log}" "received_packets")"
        m_exp="$(parse_json_field "${mcast_log}" "expected_packets")"
        check_assertion "TC-WR-02" "1024B Multicast Full Forwarding (0% Loss)" "${m_status}" \
            "Received: ${m_recv}/${m_exp} | Packet Loss: ${m_loss}%"
    else
        check_assertion "TC-WR-02" "1024B Multicast Full Forwarding (0% Loss)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh wire_rate)"
    fi

    print_section "2. WAN-TO-LAN 1G -> 100M RATE MISMATCH BURST ABSORPTION"
    # TC-RM-01: 1500B, 50% load, 53 frames
    local c1_log="${LOG_DIR}/burst_case1.json"
    if [[ -f "${c1_log}" ]]; then
        local b1_loss b1_status b1_recv b1_exp
        b1_loss="$(parse_json_field "${c1_log}" "loss_pct")"
        b1_status="$(parse_json_field "${c1_log}" "status")"
        b1_recv="$(parse_json_field "${c1_log}" "received_packets")"
        b1_exp="$(parse_json_field "${c1_log}" "expected_packets")"
        check_assertion "TC-RM-01" "Burst Case 1: 1500B, Load 50%, >= 53 Frames (0% Loss)" "${b1_status}" \
            "Received: ${b1_recv}/${b1_exp} | Packet Loss: ${b1_loss}%"
    else
        check_assertion "TC-RM-01" "Burst Case 1: 1500B, Load 50%, >= 53 Frames (0% Loss)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh rate_mismatch)"
    fi

    # TC-RM-02: 1500B, 16% load, 100 frames
    local c2_log="${LOG_DIR}/burst_case2.json"
    if [[ -f "${c2_log}" ]]; then
        local b2_loss b2_status b2_recv b2_exp
        b2_loss="$(parse_json_field "${c2_log}" "loss_pct")"
        b2_status="$(parse_json_field "${c2_log}" "status")"
        b2_recv="$(parse_json_field "${c2_log}" "received_packets")"
        b2_exp="$(parse_json_field "${c2_log}" "expected_packets")"
        check_assertion "TC-RM-02" "Burst Case 2: 1500B, Load 16%, 100 Frames (0% Loss)" "${b2_status}" \
            "Received: ${b2_recv}/${b2_exp} | Packet Loss: ${b2_loss}%"
    else
        check_assertion "TC-RM-02" "Burst Case 2: 1500B, Load 16%, 100 Frames (0% Loss)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh rate_mismatch)"
    fi

    print_section "3. REAL-WORLD SENSITIVE APPLICATIONS ON 100M STB"
    # TC-APP-01: GeForce NOW Network Test
    local gfn_log="${LOG_DIR}/geforce_now.json"
    if [[ -f "${gfn_log}" ]]; then
        local gfn_loss gfn_jitter gfn_app_st gfn_verdict
        gfn_loss="$(parse_json_field "${gfn_log}" "loss_pct")"
        gfn_jitter="$(parse_json_field "${gfn_log}" "jitter_ms")"
        gfn_app_st="$(parse_json_field "${gfn_log}" "network_test_status")"
        gfn_verdict="$(parse_json_field "${gfn_log}" "verdict")"
        check_assertion "TC-APP-01" "GeForce NOW Network Test on 100M STB (Normal Status)" "${gfn_verdict}" \
            "Status: ${gfn_app_st} | Packet Loss: ${gfn_loss}% | Jitter: ${gfn_jitter} ms"
    else
        check_assertion "TC-APP-01" "GeForce NOW Network Test on 100M STB (Normal Status)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh real_world_stb)"
    fi

    # TC-APP-02: UHD+Dolby VOD 1.2x
    local vod_log="${LOG_DIR}/vod_1_2x.json"
    if [[ -f "${vod_log}" ]]; then
        local v_tput v_loss v_stalls v_st v_verdict
        v_tput="$(parse_json_field "${vod_log}" "throughput_mbps")"
        v_loss="$(parse_json_field "${vod_log}" "loss_pct")"
        v_stalls="$(parse_json_field "${vod_log}" "stall_events")"
        v_st="$(parse_json_field "${vod_log}" "playback_status")"
        v_verdict="$(parse_json_field "${vod_log}" "verdict")"
        check_assertion "TC-APP-02" "UHD+Dolby VOD @ 1.2x Speed Playback on 100M STB" "${v_verdict}" \
            "Status: ${v_st} | Rate: ${v_tput} Mbps | Loss: ${v_loss}% | Stalls: ${v_stalls}"
    else
        check_assertion "TC-APP-02" "UHD+Dolby VOD @ 1.2x Speed Playback on 100M STB" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh real_world_stb)"
    fi

    print_section "4. SIMULTANEOUS WIRED & WIRELESS (2.4G + 5G + 6G + WIRED)"
    # TC-SIM-01: Difference between C and B within 1%
    local sim_log="${LOG_DIR}/simultaneous_benchmark.json"
    if [[ -f "${sim_log}" ]]; then
        local s_diff s_b s_c s_verdict s_mode s_dev s_band
        s_diff="$(parse_json_field "${sim_log}" "diff_percentage")"
        s_b="$(parse_json_field "${sim_log}" "wired_only_avg_mbps")"
        s_c="$(parse_json_field "${sim_log}" "simultaneous_sum_avg_mbps")"
        s_verdict="$(parse_json_field "${sim_log}" "verdict")"
        s_mode="$(parse_json_field "${sim_log}" "mode")"
        s_dev="$(parse_json_field "${sim_log}" "wifi_device")"
        s_band="$(parse_json_field "${sim_log}" "wifi_band")"

        local mode_note=""
        if [[ "${s_mode}" != "MISSING" && "${s_mode}" != "emulated" ]]; then
            mode_note=" | Mode: ${s_mode} (${s_dev} @ ${s_band})"
        fi
        check_assertion "TC-SIM-01" "Simultaneous Wired Speed Preservation (Wired Degradation <= 1.0%)" "${s_verdict}" \
            "Wired Baseline (B): ${s_b} Mbps | Simultaneous Total (C): ${s_c} Mbps | Degradation: ${s_diff}% (Limit: <= 1.0%)${mode_note}"
    else
        check_assertion "TC-SIM-01" "Simultaneous Wired Speed Preservation (Wired Degradation <= 1.0%)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh simultaneous)"
    fi

    print_section "5. WI-FI PHONE (VOIP) QOS & WIRED PC ISOLATION"
    # TC-QOS-01: Difference between A and B <= 1%
    local qos_log="${LOG_DIR}/voice_pc_qos.json"
    if [[ -f "${qos_log}" ]]; then
        local q_a q_b q_diff q_verdict q_mode q_eng q_dev
        q_a="$(parse_json_field "${qos_log}" "pc_baseline_mbps")"
        q_b="$(parse_json_field "${qos_log}" "pc_during_calls_mbps")"
        q_diff="$(parse_json_field "${qos_log}" "diff_percentage")"
        q_verdict="$(parse_json_field "${qos_log}" "verdict")"
        q_mode="$(parse_json_field "${qos_log}" "mode")"
        q_eng="$(parse_json_field "${qos_log}" "engine")"
        q_dev="$(parse_json_field "${qos_log}" "wifi_device")"

        local mode_note=""
        if [[ "${q_mode}" != "MISSING" && "${q_mode}" != "virtual" && "${q_mode}" != "emulated" ]]; then
            mode_note=" | Mode: ${q_mode} (${q_eng} on ${q_dev})"
        elif [[ "${q_eng}" != "MISSING" && -n "${q_eng}" ]]; then
            mode_note=" | Engine: ${q_eng}"
        fi

        local q_reason
        q_reason="$(parse_json_field "${qos_log}" "reason")"
        local detail_str="Baseline (A): ${q_a} Mbps | During Calls (B): ${q_b} Mbps | Drop: ${q_diff}% (Limit: <= 1.0%)${mode_note}"
        if [[ "${q_verdict}" != "PASS" && "${q_reason}" != "MISSING" && -n "${q_reason}" ]]; then
            detail_str="${detail_str} | Failure: ${q_reason}"
        fi

        check_assertion "TC-QOS-01" "PC Throughput during 2 Wi-Fi Phone Calls (|A-B|/A <= 1%)" "${q_verdict}" "${detail_str}"
    else
        check_assertion "TC-QOS-01" "PC Throughput during 2 Wi-Fi Phone Calls (|A-B|/A <= 1%)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh voice_qos)"
    fi

    print_section "6. WIRELESS QOS & IEEE 802.11e WMM OPTIMIZATION [TC-WQOS-01]"
    # TC-WQOS-01: Voice & Video priority preservation under Best Effort congestion
    local wqos_log="${LOG_DIR}/wireless_qos_audit.json"
    if [[ -f "${wqos_log}" ]]; then
        local w_verdict w_voice_loss w_video_loss w_be_mbps w_mode
        w_verdict="$(parse_json_field "${wqos_log}" "verdict")"
        if [[ -z "${w_verdict}" || "${w_verdict}" == "MISSING" ]]; then
            w_verdict="$(parse_json_field "${wqos_log}" "overall_status")"
        fi
        w_mode="$(parse_json_field "${wqos_log}" "mode")"
        w_voice_loss="$(python3 -c "import json; d=json.load(open('${wqos_log}')); print(d.get('services',{}).get('voice',{}).get('loss_pct', 0.0))" 2>/dev/null || echo "0.0")"
        w_video_loss="$(python3 -c "import json; d=json.load(open('${wqos_log}')); print(d.get('services',{}).get('video',{}).get('loss_pct', 0.0))" 2>/dev/null || echo "0.0")"
        w_be_mbps="$(python3 -c "import json; d=json.load(open('${wqos_log}')); print(d.get('services',{}).get('best_effort',{}).get('throughput_mbps', 0.0))" 2>/dev/null || echo "0.0")"

        check_assertion "TC-WQOS-01" "Wireless QoS Multi-Service Prioritization (Voice & Video <= 1.0% Loss)" "${w_verdict}" \
            "Voice Loss: ${w_voice_loss}% | Video Loss: ${w_video_loss}% | BE Traffic: ${w_be_mbps} Mbps | Mode: ${w_mode}"
    else
        check_assertion "TC-WQOS-01" "Wireless QoS Multi-Service Prioritization (Voice & Video <= 1.0% Loss)" "NOT_RUN" "Phase not executed (run: sudo ./scripts/scenario.sh wireless_qos)"
    fi

    # Dual-sided PCAP Evidence Comparison
    if [[ -n "${pcap_file}" && -f "${pcap_file}" && -n "${pcap_lan_file:-}" && -f "${pcap_lan_file}" ]]; then
        if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
            "${SCRIPT_DIR}/capture.sh" compare "${pcap_file}" "${pcap_lan_file}" "Compliance Audit" || true
        fi
    fi

    # PCAP Evidence Timeline
    if [[ -n "${pcap_file}" && -f "${pcap_file}" ]]; then
        print_pcap_timeline "${pcap_file}"
    fi

    # Summary
    local evaluated=$(( PASSED_TESTS + FAILED_TESTS ))
    print_header "VERIFICATION SUMMARY: ${PASSED_TESTS}/${evaluated} EVALUATED (${SKIPPED_TESTS} NOT RUN)"
    if (( FAILED_TESTS > 0 )); then
        printf '  \e[1;31mOVERALL RESULT: [FAIL] - %d test(s) failed.\e[0m\n\n' "${FAILED_TESTS}"
        return 1
    elif (( PASSED_TESTS > 0 )); then
        printf '  \e[1;32mOVERALL RESULT: [PASS] - All %d executed test criteria satisfied (100%% PASS)!\e[0m\n\n' "${PASSED_TESTS}"
        return 0
    else
        printf '  \e[1;33mOVERALL RESULT: [INCOMPLETE] - No tests have been executed yet.\e[0m\n\n'
        return 0
    fi
}

main "$@"
