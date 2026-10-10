#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - RUNNING MODE ORCHESTRATOR
# Module: orchestrator_mode.sh
# Bridge between scenario runners and RunningContextResolver.
# Evaluates invariants, exports the Execution Plan, and prepares Station Adapters.
# ==============================================================================

# Guard against duplicate inclusion
if [[ -n "${_NWLAB_ORCHESTRATOR_MODE_LOADED:-}" ]]; then
    return 0
fi
readonly _NWLAB_ORCHESTRATOR_MODE_LOADED=1

_ORCH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -f "${_ORCH_DIR}/common.sh" ]]; then
    # shellcheck source=lib/common.sh
    source "${_ORCH_DIR}/common.sh"
fi
if [[ -f "${_ORCH_DIR}/station_adapter.sh" ]]; then
    # shellcheck source=lib/station_adapter.sh
    source "${_ORCH_DIR}/station_adapter.sh"
fi
unset _ORCH_DIR

orchestrator_resolve_context() {
    local script_dir="${SCRIPT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
    local lab_dir="${LAB_DIR:-$(cd -- "${script_dir}/.." && pwd -P)}"
    local tools_dir="${lab_dir}/tools"
    local resolver_script="${tools_dir}/running_context.py"

    if [[ ! -x "${resolver_script}" ]]; then
        log_warn "orchestrator_resolve_context: resolver script not found at ${resolver_script}; fallback to emulated"
        export PLAN_TOPOLOGY_MODE="${TOPOLOGY_MODE:-virtual}"
        export PLAN_EXECUTION_MODE="emulated_virtual"
        export PLAN_IS_VIRTUAL="1"
        export PLAN_REQUIRES_HOST_ROUTE="0"
        export PLAN_REQUIRES_REMOTE_CLIENT="0"
        export PLAN_REQUIRES_IPTABLES_MANGLE="0"
        export PLAN_PRIMARY_WIFI_IF="eth0"
        export PLAN_PRIMARY_WIFI_NS="ns-wlan5g"
        export PLAN_PRIMARY_WIFI_IP="192.168.1.32"
        export PLAN_PRIMARY_WIFI_SSID="virtual-ssid-5g"
        export PLAN_PRIMARY_WIFI_BAND="5GHz"
        export PLAN_REASON="Fallback: running_context.py not executable"
        export PLAN_IS_FORCED_OVERRIDE="0"
        export PLAN_SIM_MODE="emulated"
        export PLAN_VOIP_MODE="virtual"
        export PLAN_WQOS_MODE="virtual"
        return 0
    fi

    # 1. Inspect hardware state once if not already available
    if [[ -z "${DETECTED_WIFI_STATUS:-}" ]] && [[ -x "${tools_dir}/wifi_inspector.py" ]]; then
        local env_tmp
        env_tmp="$(mktemp "${TMPDIR:-/tmp}/wifi_env_XXXXXX.env" 2>/dev/null || mktemp)"
        if "${tools_dir}/wifi_inspector.py" export-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" > "${env_tmp}" 2>/dev/null; then
            if [[ -s "${env_tmp}" ]]; then
                # shellcheck disable=SC1090
                source "${env_tmp}"
            fi
        fi
        rm -f "${env_tmp}"
    fi

    # 2. Check remote client Wi-Fi state if configured
    local rem_ok=0
    if [[ -n "${REMOTE_CLIENT_HOST:-}" ]] && [[ -x "${script_dir}/remote_client.sh" ]]; then
        if [[ -z "${REMOTE_WIFI_STATUS:-}" ]]; then
            local rem_tmp
            rem_tmp="$(mktemp "${TMPDIR:-/tmp}/rem_env_XXXXXX.env" 2>/dev/null || mktemp)"
            if "${script_dir}/remote_client.sh" wifi-env --check-ping "${DUT_LAN_IP:-192.168.1.1}" > "${rem_tmp}" 2>/dev/null; then
                if [[ -s "${rem_tmp}" ]]; then
                    # shellcheck disable=SC1090
                    source "${rem_tmp}"
                fi
            fi
            rm -f "${rem_tmp}"
        fi
        if [[ "${REMOTE_WIFI_PING_OK:-0}" == "1" ]]; then
            rem_ok=1
        fi
    fi

    # 3. Invoke deep domain resolver to generate Execution Plan
    local plan_tmp
    plan_tmp="$(mktemp "${TMPDIR:-/tmp}/plan_env_XXXXXX.env" 2>/dev/null || mktemp)"
    local -a resolver_args=(
        "--topology-mode" "${TOPOLOGY_MODE:-virtual}"
        "--cli-wifi-mode" "${CUSTOM_WIFI_MODE:-}"
        "--config-wifi-mode" "${WIFI_TEST_MODE:-auto}"
        "--wifi-card-count" "${WIFI_CARD_COUNT:-0}"
        "--wifi-if" "${DETECTED_WIFI_IF:-}"
        "--wifi-ssid" "${DETECTED_WIFI_SSID:-}"
        "--wifi-band" "${DETECTED_WIFI_BAND:-}"
        "--wifi-ip" "${DETECTED_WIFI_IP:-}"
        "--remote-host" "${REMOTE_CLIENT_HOST:-}"
        "--remote-wifi-if" "${REMOTE_WIFI_IF:-}"
        "--remote-wifi-ip" "${REMOTE_WIFI_IP:-}"
        "--remote-wifi-ssid" "${REMOTE_WIFI_SSID:-}"
        "--remote-wifi-band" "${REMOTE_WIFI_BAND:-}"
    )
    if (( rem_ok == 1 )); then
        resolver_args+=("--remote-wifi-ok")
    fi

    if python3 "${resolver_script}" export-env "${resolver_args[@]}" > "${plan_tmp}" 2>/dev/null; then
        if [[ -s "${plan_tmp}" ]]; then
            # shellcheck disable=SC1090
            source "${plan_tmp}"
        fi
    fi
    rm -f "${plan_tmp}"

    # Export plan variables to current shell and subshells
    export PLAN_TOPOLOGY_MODE="${PLAN_TOPOLOGY_MODE:-virtual}"
    export PLAN_EXECUTION_MODE="${PLAN_EXECUTION_MODE:-emulated_virtual}"
    export PLAN_IS_VIRTUAL="${PLAN_IS_VIRTUAL:-1}"
    export PLAN_REQUIRES_HOST_ROUTE="${PLAN_REQUIRES_HOST_ROUTE:-0}"
    export PLAN_REQUIRES_REMOTE_CLIENT="${PLAN_REQUIRES_REMOTE_CLIENT:-0}"
    export PLAN_REQUIRES_IPTABLES_MANGLE="${PLAN_REQUIRES_IPTABLES_MANGLE:-0}"
    export PLAN_PRIMARY_WIFI_IF="${PLAN_PRIMARY_WIFI_IF:-eth0}"
    export PLAN_PRIMARY_WIFI_NS="${PLAN_PRIMARY_WIFI_NS:-ns-wlan5g}"
    export PLAN_PRIMARY_WIFI_IP="${PLAN_PRIMARY_WIFI_IP:-}"
    export PLAN_PRIMARY_WIFI_SSID="${PLAN_PRIMARY_WIFI_SSID:-}"
    export PLAN_PRIMARY_WIFI_BAND="${PLAN_PRIMARY_WIFI_BAND:-}"
    export PLAN_REASON="${PLAN_REASON:-}"
    export PLAN_IS_FORCED_OVERRIDE="${PLAN_IS_FORCED_OVERRIDE:-0}"
    export PLAN_SIM_MODE="${PLAN_SIM_MODE:-emulated}"
    export PLAN_VOIP_MODE="${PLAN_VOIP_MODE:-virtual}"
    export PLAN_WQOS_MODE="${PLAN_WQOS_MODE:-virtual}"

    # 4. Atomically persist execution plan for non-bash tools
    if declare -F write_state_env >/dev/null 2>&1 && [[ -d "${lab_dir}/state" ]]; then
        write_state_env "${lab_dir}/state/execution_plan.env" \
            PLAN_TOPOLOGY_MODE="${PLAN_TOPOLOGY_MODE}" \
            PLAN_EXECUTION_MODE="${PLAN_EXECUTION_MODE}" \
            PLAN_IS_VIRTUAL="${PLAN_IS_VIRTUAL}" \
            PLAN_REQUIRES_HOST_ROUTE="${PLAN_REQUIRES_HOST_ROUTE}" \
            PLAN_REQUIRES_REMOTE_CLIENT="${PLAN_REQUIRES_REMOTE_CLIENT}" \
            PLAN_REQUIRES_IPTABLES_MANGLE="${PLAN_REQUIRES_IPTABLES_MANGLE}" \
            PLAN_PRIMARY_WIFI_IF="${PLAN_PRIMARY_WIFI_IF}" \
            PLAN_PRIMARY_WIFI_NS="${PLAN_PRIMARY_WIFI_NS}" \
            PLAN_PRIMARY_WIFI_IP="${PLAN_PRIMARY_WIFI_IP}" \
            PLAN_PRIMARY_WIFI_SSID="${PLAN_PRIMARY_WIFI_SSID}" \
            PLAN_PRIMARY_WIFI_BAND="${PLAN_PRIMARY_WIFI_BAND}" \
            PLAN_REASON="${PLAN_REASON}"
    fi

    return 0
}

orchestrator_show_plan() {
    local scenario_title="${1:-PERFORMANCE BENCHMARK}"
    log_info "Execution Plan for [${scenario_title}]:"
    log_info "  -> Topology Mode    : [${PLAN_TOPOLOGY_MODE^^}]"
    log_info "  -> Canonical Mode   : [${PLAN_EXECUTION_MODE^^}]"
    log_info "  -> Virtual Emulated : $( (( PLAN_IS_VIRTUAL == 1 )) && echo 'YES (Software namespaces)' || echo 'NO (Over-The-Air Hardware)' )"
    if (( PLAN_REQUIRES_REMOTE_CLIENT == 1 )); then
        log_info "  -> Remote Station   : ${REMOTE_CLIENT_HOST:-not_configured} (Dev: ${REMOTE_WIFI_IF:-wlan0})"
    fi
    if (( PLAN_REQUIRES_HOST_ROUTE == 1 )); then
        log_info "  -> Physical Wi-Fi   : ${PLAN_PRIMARY_WIFI_IF} (Host route to ${WAN_SERVER_IP:-10.10.0.1} required)"
    elif [[ -n "${PLAN_PRIMARY_WIFI_NS:-}" ]]; then
        log_info "  -> Emulated Station : ${PLAN_PRIMARY_WIFI_NS} (${PLAN_PRIMARY_WIFI_IF})"
    fi
    if (( ${PLAN_IS_FORCED_OVERRIDE:-0} == 1 )); then
        log_warn "  -> FORCED OVERRIDE  : Physical hardware requested inside virtual topology."
    fi
    log_info "  -> Reason           : ${PLAN_REASON}"
}
