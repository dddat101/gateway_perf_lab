#!/usr/bin/env bash
# ==============================================================================
# GATEWAY PERFORMANCE LAB - DECLARATIVE STATION ADAPTER
# Module: station_adapter.sh
# Encapsulates host routing, DSCP mangle marking, remote client coordination,
# and RAII-style scoped resource lifecycle management for wireless stations.
# ==============================================================================

# Guard against duplicate inclusion
if [[ -n "${_GWLAB_STATION_ADAPTER_LOADED:-}" ]]; then
    return 0
fi
readonly _GWLAB_STATION_ADAPTER_LOADED=1

STATION_ROUTE_ACTIVE=0
STATION_MANGLE_ACTIVE=0
STATION_ACTIVE_DEV=""
STATION_ACTIVE_PORTS=""
STATION_ACTIVE_DSCP=""

# ------------------------------------------------------------------------------
# Routing Seam: Host Route via DUT LAN Gateway
# ------------------------------------------------------------------------------

station_adapter_bind_route() {
    local dev="${1:-}"
    local wan_ip="${2:-${WAN_SERVER_IP:-10.10.0.1}}"
    local dut_ip="${3:-${DUT_LAN_IP:-192.168.1.1}}"

    if [[ -z "${dev}" ]]; then
        return 0
    fi

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would bind host route ${wan_ip} via ${dut_ip} dev ${dev}"
        return 0
    fi

    log_cmd "ip route replace ${wan_ip} via ${dut_ip} dev ${dev}"
    ip route replace "${wan_ip}" via "${dut_ip}" dev "${dev}" 2>/dev/null || true

    CLEANUP_WIFI_ROUTE="${wan_ip} via ${dut_ip} dev ${dev}"
    STATION_ROUTE_ACTIVE=1
    STATION_ACTIVE_DEV="${dev}"
    return 0
}

station_adapter_unbind_route() {
    if (( STATION_ROUTE_ACTIVE == 1 )) && [[ -n "${CLEANUP_WIFI_ROUTE:-}" ]]; then
        log_cmd "ip route del ${CLEANUP_WIFI_ROUTE}"
        ip route del ${CLEANUP_WIFI_ROUTE} 2>/dev/null || true
        CLEANUP_WIFI_ROUTE=""
        STATION_ROUTE_ACTIVE=0
    fi
    return 0
}

# ------------------------------------------------------------------------------
# QoS Seam: Netfilter Mangle DSCP Tagging
# ------------------------------------------------------------------------------

station_adapter_apply_mangle() {
    local dev="${1:-}"
    local ports_list="${2:-}"
    local dscp_mark="${3:-}"

    if [[ -z "${dev}" || -z "${ports_list}" || -z "${dscp_mark}" ]]; then
        return 0
    fi

    if (( DRY_RUN == 1 )); then
        log_info "[DRY-RUN] Would apply DSCP ${dscp_mark} mangle rules on dev ${dev} (ports: ${ports_list})"
        return 0
    fi

    log_cmd "iptables -t mangle -A POSTROUTING -o ${dev} -p udp -m multiport --dports ${ports_list} -j DSCP --set-dscp ${dscp_mark}"
    iptables -t mangle -A POSTROUTING -o "${dev}" -p udp -m multiport --dports "${ports_list}" -j DSCP --set-dscp "${dscp_mark}" 2>/dev/null || true

    log_cmd "iptables -t mangle -A POSTROUTING -o ${dev} -p udp -m multiport --sports ${ports_list} -j DSCP --set-dscp ${dscp_mark}"
    iptables -t mangle -A POSTROUTING -o "${dev}" -p udp -m multiport --sports "${ports_list}" -j DSCP --set-dscp "${dscp_mark}" 2>/dev/null || true

    CLEANUP_IPTABLES_MANGLE="iptables -t mangle -D POSTROUTING -o ${dev} -p udp -m multiport --dports ${ports_list} -j DSCP --set-dscp ${dscp_mark} 2>/dev/null || true; iptables -t mangle -D POSTROUTING -o ${dev} -p udp -m multiport --sports ${ports_list} -j DSCP --set-dscp ${dscp_mark} 2>/dev/null || true"
    STATION_MANGLE_ACTIVE=1
    STATION_ACTIVE_PORTS="${ports_list}"
    STATION_ACTIVE_DSCP="${dscp_mark}"
    return 0
}

station_adapter_revert_mangle() {
    if (( STATION_MANGLE_ACTIVE == 1 )) && [[ -n "${STATION_ACTIVE_DEV:-}" && -n "${STATION_ACTIVE_PORTS:-}" && -n "${STATION_ACTIVE_DSCP:-}" ]]; then
        log_cmd "iptables -t mangle -D POSTROUTING -o ${STATION_ACTIVE_DEV} -p udp -m multiport --dports ${STATION_ACTIVE_PORTS} -j DSCP --set-dscp ${STATION_ACTIVE_DSCP}"
        iptables -t mangle -D POSTROUTING -o "${STATION_ACTIVE_DEV}" -p udp -m multiport --dports "${STATION_ACTIVE_PORTS}" -j DSCP --set-dscp "${STATION_ACTIVE_DSCP}" 2>/dev/null || true
        iptables -t mangle -D POSTROUTING -o "${STATION_ACTIVE_DEV}" -p udp -m multiport --sports "${STATION_ACTIVE_PORTS}" -j DSCP --set-dscp "${STATION_ACTIVE_DSCP}" 2>/dev/null || true

        CLEANUP_IPTABLES_MANGLE=""
        STATION_MANGLE_ACTIVE=0
        STATION_ACTIVE_PORTS=""
        STATION_ACTIVE_DSCP=""
    fi
    return 0
}

# ------------------------------------------------------------------------------
# High-Leverage Lifecycle Entry & Exit (RAII Pattern)
# ------------------------------------------------------------------------------

# Acquire network configuration dictated by the Execution Plan
station_adapter_acquire() {
    local target_dev="${PLAN_PRIMARY_WIFI_IF:-}"
    local req_route="${PLAN_REQUIRES_HOST_ROUTE:-0}"

    if (( req_route == 1 )) && [[ -n "${target_dev}" ]]; then
        station_adapter_bind_route "${target_dev}" "${WAN_SERVER_IP:-10.10.0.1}" "${DUT_LAN_IP:-192.168.1.1}"
    fi

    return 0
}

# Release all active network modifications atomically
station_adapter_release() {
    station_adapter_revert_mangle
    station_adapter_unbind_route
    STATION_ACTIVE_DEV=""
    return 0
}
