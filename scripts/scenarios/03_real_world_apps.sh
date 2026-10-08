#!/usr/bin/env bash
# ==============================================================================
# SCENARIO MODULE: REAL-WORLD APPLICATIONS (STB GAMING & 4K VOD)
# [TC-APP-01] GeForce NOW Cloud Gaming Network Test Simulation (60/120 FPS)
# [TC-APP-02] UHD+Dolby VOD @ 1.2x Speed Playback Simulation (42 Mbps)
# Refactored with Defensive Bash Programming Patterns
# ==============================================================================

# Canonical constants
readonly APP_DEFAULT_DURATION="5.0"
readonly APP_DEFAULT_GFN_FPS=60
readonly APP_DEFAULT_GFN_60FPS_BITRATE="25.0"
readonly APP_DEFAULT_GFN_60FPS_JITTER="2.0"
readonly APP_DEFAULT_GFN_120FPS_BITRATE="50.0"
readonly APP_DEFAULT_GFN_120FPS_JITTER="1.5"
readonly APP_DEFAULT_GFN_MAX_LOSS="0.0"
readonly APP_DEFAULT_GFN_PORT=5004
readonly APP_DEFAULT_VOD_PORT=5005
readonly APP_DEFAULT_VOD_BASE_BITRATE="35.0"
readonly APP_DEFAULT_VOD_SPEED_MULTIPLIER="1.2"

usage_block_app01() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-APP-01] GEFORCE NOW CLOUD GAMING NETWORK TEST                |
+------------------------------------------------------------------+
  Scenario Aliases : geforce, tc_app_01
  Objective        : Evaluate real-time cloud gaming streaming on STB
  Traffic Profile  : 60 FPS (25 Mbps) or 120 FPS (50 Mbps) UDP stream
  Pass Criteria    : 0% frame loss, Jitter <= 2.0ms (60 FPS) / <= 1.5ms (120 FPS)

  Supported Options:
    --fps, -F <rate>         Target frame rate (default: 60, e.g. 60, 120)
    --gfn-bitrate <mbps>     Target bitrate in Mbps (default: 25.0 for 60fps, 50.0 for 120fps)
    --gfn-jitter <ms>        Max permissible jitter in ms (default: 2.0 for 60fps, 1.5 for 120fps)
    --duration, -d <sec>     Stream duration in seconds (default: 5.0)
    --stability, --soak      Extended soak run without packet capture (duration: 60s)
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh geforce
    sudo ./scripts/scenario.sh -F 120 tc_app_01
    sudo ./scripts/scenario.sh -d 30 --stability geforce

EOF
}

usage_block_app02() {
    cat <<'EOF'
+------------------------------------------------------------------+
| [TC-APP-02] UHD+DOLBY VOD @ 1.2X SPEED PLAYBACK                  |
+------------------------------------------------------------------+
  Scenario Aliases : vod, tc_app_02
  Objective        : Benchmark high-bitrate 4K OTT VOD playback under trick-play
  Traffic Profile  : 35 Mbps base x 1.2 speed = 42 Mbps UDP stream
  Pass Criteria    : 0% frame loss forwarded across STB LAN bridge

  Supported Options:
    --duration, -d <sec>     Stream duration in seconds (default: 5.0)
    --stability, --soak      Extended soak run without packet capture (duration: 60s)
    --debug, -v              Show exact commands executed at each step
    --snaplen, -s <bytes>    Packet capture snaplen in bytes (default: 96)
    --no-capture, -C         Disable packet capture during test
    --collect-artifacts, -A  Package run deliverables into artifacts/
    --log, -l [file]         Mirror console output to a log file
    --dry-run, -n            Preview parameters without sending traffic

  Examples:
    sudo ./scripts/scenario.sh vod
    sudo ./scripts/scenario.sh -d 15 tc_app_02
    sudo ./scripts/scenario.sh -C -d 60 vod

EOF
}

# ------------------------------------------------------------------------------
# Process Termination & Clean-up Helpers
# ------------------------------------------------------------------------------
_app_terminate_pids() {
    local pids=("$@")
    if (( ${#pids[@]} == 0 )); then
        return 0
    fi

    for pid in "${pids[@]}"; do
        if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done

    sleep 0.2

    for pid in "${pids[@]}"; do
        if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
}

_app_clean_stale() {
    local pattern="$1"
    if ns_exists "${STB_NS:-ns-stb}"; then
        ip netns exec "${STB_NS:-ns-stb}" pkill -TERM -f "${pattern}" 2>/dev/null || true
    fi
    if ns_exists "${WAN_NS:-ns-wan}"; then
        ip netns exec "${WAN_NS:-ns-wan}" pkill -TERM -f "${pattern}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Sub-phase 3A: GeForce NOW Network Test Simulation (TC-APP-01)
# ------------------------------------------------------------------------------
run_subphase_geforce() {
    log_step "[TC-APP-01] GeForce NOW Cloud Gaming Network Test Simulation"
    local tools_dir="${LAB_DIR}/tools"
    local gfn_json="${LOG_DIR}/geforce_now.json"

    # Validate FPS and determine defaults
    local eff_fps="${CUSTOM_GFN_FPS:-${GEFORCE_NOW_FPS:-${APP_DEFAULT_GFN_FPS}}}"
    if [[ ! "${eff_fps}" =~ ^[0-9]+$ || "${eff_fps}" -le 0 ]]; then
        eff_fps="${APP_DEFAULT_GFN_FPS}"
    fi

    local default_bitrate="${APP_DEFAULT_GFN_60FPS_BITRATE}"
    local default_jitter="${APP_DEFAULT_GFN_60FPS_JITTER}"
    if (( eff_fps >= 120 )); then
        default_bitrate="${GEFORCE_NOW_120FPS_BITRATE_MBPS:-${APP_DEFAULT_GFN_120FPS_BITRATE}}"
        default_jitter="${GEFORCE_NOW_120FPS_MAX_JITTER_MS:-${APP_DEFAULT_GFN_120FPS_JITTER}}"
    else
        default_bitrate="${GEFORCE_NOW_BITRATE_MBPS:-${APP_DEFAULT_GFN_60FPS_BITRATE}}"
        default_jitter="${GEFORCE_NOW_MAX_JITTER_MS:-${APP_DEFAULT_GFN_60FPS_JITTER}}"
    fi

    local eff_bitrate="${CUSTOM_GFN_BITRATE:-${default_bitrate}}"
    local eff_max_jitter="${CUSTOM_GFN_JITTER:-${default_jitter}}"

    # Validate duration defensively
    local gfn_srv_duration="${CUSTOM_DURATION:-${APP_DEFAULT_DURATION}}"
    if [[ ! "${gfn_srv_duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_warn "Invalid duration '${gfn_srv_duration}'. Defaulting to ${APP_DEFAULT_DURATION}s."
        gfn_srv_duration="${APP_DEFAULT_DURATION}"
    fi

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test GeForce NOW UDP game streaming (${eff_fps} FPS, ${eff_bitrate} Mbps, max jitter ${eff_max_jitter} ms, duration ${gfn_srv_duration}s) on ns-stb"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local gfn_rx_log="${SCENARIO_TMP_DIR}/gfn_rx.log"
    local gfn_cli_duration
    gfn_cli_duration="$(awk -v d="${gfn_srv_duration}" 'BEGIN { printf "%.1f", d + 3.0 }')"

    # Clean any stale GeForce tester instances
    _app_clean_stale "geforce_now_tester.py"
    sleep 0.1

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/geforce_now_tester.py client --bind-ip 0.0.0.0 --bind-port ${APP_DEFAULT_GFN_PORT} --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${APP_DEFAULT_GFN_PORT} --duration ${gfn_cli_duration} --max-loss-pct ${GEFORCE_NOW_MAX_LOSS_PCT:-${APP_DEFAULT_GFN_MAX_LOSS}} --max-jitter-ms ${eff_max_jitter} --fps ${eff_fps} --target-mbps ${eff_bitrate} --output-json ${gfn_json} > ${gfn_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/geforce_now_tester.py" client \
        --bind-ip "0.0.0.0" --bind-port "${APP_DEFAULT_GFN_PORT}" \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${APP_DEFAULT_GFN_PORT}" \
        --duration "${gfn_cli_duration}" \
        --max-loss-pct "${GEFORCE_NOW_MAX_LOSS_PCT:-${APP_DEFAULT_GFN_MAX_LOSS}}" \
        --max-jitter-ms "${eff_max_jitter}" \
        --fps "${eff_fps}" \
        --target-mbps "${eff_bitrate}" \
        --output-json "${gfn_json}" > "${gfn_rx_log}" 2>&1 &
    local gfn_rx_pid=$!
    ACTIVE_BG_PIDS+=("${gfn_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/geforce_now_tester.py server --dest-ip ${STB_IP:-192.168.1.20} --dest-port ${APP_DEFAULT_GFN_PORT} --wait-handshake --duration ${gfn_srv_duration} --frame-rate ${eff_fps} --bitrate-mbps ${eff_bitrate}"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/geforce_now_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port "${APP_DEFAULT_GFN_PORT}" \
        --wait-handshake \
        --duration "${gfn_srv_duration}" \
        --frame-rate "${eff_fps}" --bitrate-mbps "${eff_bitrate}" || true

    wait "${gfn_rx_pid}" 2>/dev/null || true
    _app_terminate_pids "${gfn_rx_pid}"

    if [[ -f "${gfn_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${gfn_json}"
        "${tools_dir}/metric_parser.py" format-card "${gfn_json}"
    else
        log_warn "GeForce NOW receiver log output:"
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

    # Validate duration defensively
    local vod_srv_duration="${CUSTOM_DURATION:-${APP_DEFAULT_DURATION}}"
    if [[ ! "${vod_srv_duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        log_warn "Invalid duration '${vod_srv_duration}'. Defaulting to ${APP_DEFAULT_DURATION}s."
        vod_srv_duration="${APP_DEFAULT_DURATION}"
    fi

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would test UHD+Dolby VOD @ 1.2x playback (35 Mbps x 1.2 = 42 Mbps, duration ${vod_srv_duration}s) on ns-stb"
        return 0
    fi

    ensure_client_endpoint "${STB_NS:-ns-stb}" "${STB_IP:-192.168.1.20}"
    local vod_rx_log="${SCENARIO_TMP_DIR}/vod_rx.log"
    local vod_cli_duration
    vod_cli_duration="$(awk -v d="${vod_srv_duration}" 'BEGIN { printf "%.1f", d + 4.0 }')"

    # Clean any stale VOD tester instances
    _app_clean_stale "vod_stream_tester.py"
    sleep 0.1

    log_cmd "ip netns exec ${STB_NS:-ns-stb} ${tools_dir}/vod_stream_tester.py client --bind-ip 0.0.0.0 --bind-port ${APP_DEFAULT_VOD_PORT} --server-ip ${WAN_SERVER_IP:-10.10.0.1} --server-port ${APP_DEFAULT_VOD_PORT} --duration ${vod_cli_duration} --output-json ${vod_json} > ${vod_rx_log} 2>&1 &"
    ip netns exec "${STB_NS:-ns-stb}" "${tools_dir}/vod_stream_tester.py" client \
        --bind-ip "0.0.0.0" --bind-port "${APP_DEFAULT_VOD_PORT}" \
        --server-ip "${WAN_SERVER_IP:-10.10.0.1}" --server-port "${APP_DEFAULT_VOD_PORT}" \
        --duration "${vod_cli_duration}" \
        --output-json "${vod_json}" > "${vod_rx_log}" 2>&1 &
    local vod_rx_pid=$!
    ACTIVE_BG_PIDS+=("${vod_rx_pid}")
    sleep 0.3

    log_cmd "ip netns exec ${WAN_NS:-ns-wan} ${tools_dir}/vod_stream_tester.py server --dest-ip ${STB_IP:-192.168.1.20} --dest-port ${APP_DEFAULT_VOD_PORT} --wait-handshake --duration ${vod_srv_duration} --base-bitrate-mbps ${VOD_BASE_BITRATE_MBPS:-${APP_DEFAULT_VOD_BASE_BITRATE}} --playback-speed ${VOD_SPEED_MULTIPLIER:-${APP_DEFAULT_VOD_SPEED_MULTIPLIER}}"
    ip netns exec "${WAN_NS:-ns-wan}" "${tools_dir}/vod_stream_tester.py" server \
        --dest-ip "${STB_IP:-192.168.1.20}" --dest-port "${APP_DEFAULT_VOD_PORT}" \
        --wait-handshake \
        --duration "${vod_srv_duration}" \
        --base-bitrate-mbps "${VOD_BASE_BITRATE_MBPS:-${APP_DEFAULT_VOD_BASE_BITRATE}}" \
        --playback-speed "${VOD_SPEED_MULTIPLIER:-${APP_DEFAULT_VOD_SPEED_MULTIPLIER}}" || true

    wait "${vod_rx_pid}" 2>/dev/null || true
    _app_terminate_pids "${vod_rx_pid}"

    if [[ -f "${vod_json}" ]]; then
        log_cmd "${tools_dir}/metric_parser.py format-card ${vod_json}"
        "${tools_dir}/metric_parser.py" format-card "${vod_json}"
    else
        log_warn "VOD receiver log output:"
        cat "${vod_rx_log}" 2>/dev/null || true
    fi
}
