#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - AUTOMATED SCENARIO RUNNER
# Evaluates Wire-rate, Rate Mismatch Bursts, STB Gaming/VOD, Simultaneous Use, QoS
# Supports Per-Test-Case Independent Runs & Dual-Sided (WAN/LAN) Captures
# Modularized Architecture: Core Runner + Sub-modules in scripts/scenarios/
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly LAB_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/scenario_common.sh
source "${SCRIPT_DIR}/lib/scenario_common.sh"

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
CUSTOM_BITRATE=""
CUSTOM_BE_PROTO=""
CUSTOM_CONGESTION_SOURCE=""
AUTO_ADAPT_BURST_SPEED="${AUTO_ADAPT_BURST_SPEED:-1}"
ADAPTED_NIC=""
ORIGINAL_NIC_SPEED=""
CUSTOM_GFN_FPS=""
CUSTOM_GFN_BITRATE=""
CUSTOM_GFN_JITTER=""

# ------------------------------------------------------------------------------
# Load Scenario Sub-modules from scripts/scenarios/
# ------------------------------------------------------------------------------
for scn_file in "${SCRIPT_DIR}/scenarios"/*.sh; do
    if [[ -f "${scn_file}" ]]; then
        # shellcheck source=/dev/null
        source "${scn_file}"
    fi
done

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
  --ota, --ota-capture     Enable Over-The-Air (OTA) 802.11 monitor capture on Remote PC
  --no-ota                 Disable Over-The-Air (OTA) monitor capture
  --collect-artifacts, -A  Bundle PCAPs, logs, JSON metrics & state into artifacts/
  --log, -l [file]         Mirror console output to log file (default: logs/scenario_*.log)
  --dry-run, -n            Dry-run mode (validate configs/parameters without traffic)
  -h, --help [scenario]    Show this help menu (or details for a specific scenario)

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
        wireless_qos|tc_wqos_01|wmm_qos|wmm_dscp|wqos|wireless_qos_remote|tc_wqos_remote)
            usage_block_wqos
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
            usage_block_wqos
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
            usage_block_wqos
            usage_block_composite
            ;;
    esac
}


execute_scenario() {
    local scn="$1"
    case "${scn}" in
        unicast|tc_wr_01)
            run_with_dual_capture "tc_wr_01_unicast" "${PC_NS:-ns-pc}" "udp port 5002 or udp port 5012" run_subphase_unicast
            ;;
        unicast_remote|tc_wr_01_remote)
            CUSTOM_CLIENT_MODE="remote"
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
        wireless_qos|tc_wqos_01|wmm_qos|wmm_dscp|wqos)
            run_with_dual_capture "tc_wqos_01" "${PC_NS:-ns-pc}" "tcp port 5201 or udp port 5201 or udp port 5005 or udp port 10000 or udp port 10002" run_phase_wireless_qos
            ;;
        wireless_qos_remote|tc_wqos_remote)
            CUSTOM_WIFI_MODE="remote"
            run_with_dual_capture "tc_wqos_01" "${PC_NS:-ns-pc}" "tcp port 5201 or udp port 5201 or udp port 5005 or udp port 10000 or udp port 10002" run_phase_wireless_qos
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
                CUSTOM_BITRATE="$2"
                shift 2
                ;;
            --be-proto|--be-protocol)
                [[ $# -ge 2 ]] || die "Option --be-proto requires a protocol argument (tcp, udp)"
                CUSTOM_BE_PROTO="${2,,}"
                export CUSTOM_BE_PROTO
                shift 2
                ;;
            --be-rate)
                [[ $# -ge 2 ]] || die "Option --be-rate requires a rate argument (e.g. 400M, 500M, auto)"
                CUSTOM_BITRATE="$2"
                export CUSTOM_BITRATE
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
                CUSTOM_CLIENT_MODE="remote"
                shift
                ;;
            --remote)
                CUSTOM_WIFI_MODE="remote"
                CUSTOM_CLIENT_MODE="remote"
                shift
                ;;
            --client-mode)
                [[ $# -ge 2 ]] || die "Option --client-mode requires a mode argument (local, remote)"
                CUSTOM_CLIENT_MODE="$2"
                shift 2
                ;;
            --remote-dev)
                [[ $# -ge 2 ]] || die "Option --remote-dev requires an interface name (e.g. eno1, wlp3s0)"
                CUSTOM_REMOTE_DEV="$2"
                shift 2
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
            --congestion-source|--congestion-target)
                [[ $# -ge 2 ]] || die "Option --congestion-source requires an argument (wifi, wired)"
                CUSTOM_CONGESTION_SOURCE="$2"
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
            --ota|--ota-capture)
                CUSTOM_OTA_CAPTURE=1
                export CUSTOM_OTA_CAPTURE
                shift
                ;;
            --no-ota)
                CUSTOM_OTA_CAPTURE=0
                export CUSTOM_OTA_CAPTURE
                shift
                ;;
            --stability|--soak)
                NO_CAPTURE=1
                CUSTOM_DURATION="${CUSTOM_DURATION:-60}"
                shift
                ;;
            --log|-l)
                ENABLE_LOG_TEE=1
                if [[ $# -ge 2 && ! "$2" =~ ^- && ! "$2" =~ ^(unicast|tc_wr_01|unicast_remote|tc_wr_01_remote|multicast|tc_wr_02|wire_rate|burst_case1|tc_rm_01|burst_case2|tc_rm_02|rate_mismatch|geforce|tc_app_01|vod|tc_app_02|real_world_stb|simultaneous|tc_sim_01|sequential|tc_sim_seq|multiband|remote|tc_sim_remote|distributed|tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way|voice_qos|tc_qos_01|wireless_qos|tc_wqos_01|wireless_qos_remote|tc_wqos_remote|wmm_qos|wmm_dscp|wqos|all)$ ]]; then
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
            unicast|tc_wr_01|unicast_remote|tc_wr_01_remote|multicast|tc_wr_02|wire_rate|burst_case1|tc_rm_01|burst_case2|tc_rm_02|rate_mismatch|geforce|tc_app_01|vod|tc_app_02|real_world_stb|simultaneous|tc_sim_01|sequential|tc_sim_seq|multiband|remote|tc_sim_remote|distributed|tri_station|tri_stream|concurrent|tc_sim_tri|distributed_3way|voice_qos|tc_qos_01|wireless_qos|tc_wqos_01|wireless_qos_remote|tc_wqos_remote|wmm_qos|wmm_dscp|wqos|all)
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
    export CUSTOM_CLIENT_MODE="${CUSTOM_CLIENT_MODE:-}"
    export CUSTOM_REMOTE_DEV="${CUSTOM_REMOTE_DEV:-}"

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
