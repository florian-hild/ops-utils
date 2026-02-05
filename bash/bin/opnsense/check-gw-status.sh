#!/usr/bin/env bash
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 15-12-2023
# Description: Check OPNsense gateway status and log failures
#              Queries gateway status via pluginctl and records downtime events
#-------------------------------------------------------------------------------

export LANG=C

import() {
    local module="${1}"
    local lib_base_dir='../../lib'
    local lib_file="${lib_base_dir}/${module}/lib"

    if [[ ! -f "${lib_file}" ]]; then
        echo "Error: Module '${module}' not found at '${lib_file}'" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${lib_file}"
}

# Import the logger library
import logger

export LOGGER_NO_TIMESTAMP="true"
export LOGGER_COLOR="true"
[[ -n "${DEBUG// }" ]] && export LOGGER_DEBUG_MODE="true"

# Constants
readonly PLUGINCTL_CMD='/usr/local/sbin/pluginctl'
readonly LOGFILE_PATH="${HOME}/local/log"

if ! command -v jq &> /dev/null; then
    log "error" "Required command 'jq' not found in PATH"
    exit 1
fi

if [[ ! -x "${PLUGINCTL_CMD}" ]]; then
    log "error" "Required command '${PLUGINCTL_CMD}' not found or not executable"
    exit 1
fi

if [[ ! -d "${LOGFILE_PATH}" ]]; then
    log "debug" "Creating log directory: '${LOGFILE_PATH}'"
    if ! mkdir -p "${LOGFILE_PATH}"; then
        log "error" "Failed to create log directory: '${LOGFILE_PATH}'"
        exit 1
    fi
    log "info" "Created log directory: '${LOGFILE_PATH}'"
else
    log "debug" "Log directory exists: '${LOGFILE_PATH}'"
fi

# Normalizes gateway status values
# Arguments:
#   $1 - Raw status value
# Returns:
#   Normalized status (replaces 'none' with 'up')
normalize_status() {
    local status="${1}"
    if [[ "${status}" == "none" ]]; then
        echo "up"
    else
        echo "${status}"
    fi
}

# Processes a single gateway status entry
# Arguments:
#   $1 - Gateway JSON object
# Returns:
#   0 - Success
#   1 - Processing failed
process_gateway() {
    local gateway_json="${1}"
    local gateway_name=""
    local gateway_status=""
    local normalized_status=""
    local timestamp=""
    local logfile=""

    # Extract gateway information
    gateway_name="$(echo "${gateway_json}" | jq -r '.name')"
    if [[ -z "${gateway_name}" || "${gateway_name}" == "null" ]]; then
        log "warn" "Skipping gateway entry with missing name"
        return 1
    fi

    gateway_status="$(echo "${gateway_json}" | jq -r '.status')"
    normalized_status="$(normalize_status "${gateway_status}")"

    log "info" "Gateway '${gateway_name}' status: '${normalized_status}'"

    # Log downtime events
    if [[ "${normalized_status}" == "down" ]]; then
        timestamp="$(date +'%F %T')"
        logfile="${LOGFILE_PATH}/check_gw_${gateway_name}.jsonl"

        log "warn" "Gateway '${gateway_name}' is DOWN - logging to '${logfile}'"

        # Add timestamp and normalize status in JSON output
        # shellcheck disable=SC2001
        echo "${gateway_json}" | \
            sed "s/{/{\"timestamp\":\"${timestamp}\",/" | \
            jq -c | \
            sed 's/"status":"none"/"status":"up"/g' >> "${logfile}"

        log "debug" "Downtime event recorded for '${gateway_name}'"
    fi

    return 0
}

# Main execution
log "debug" "Querying gateway status via '${PLUGINCTL_CMD}'"

gateway_json_data="$("${PLUGINCTL_CMD}" -r return_gateways_status 2>&1)" || {
    log "error" "Failed to query gateway status"
    exit 1
}

# Extract gateway data
gateway_list="$(echo "${gateway_json_data}" | jq -c '.dpinger.[]' 2>&1)" || {
    log "error" "Failed to parse gateway data with jq"
    exit 1
}

if [[ -z "${gateway_list}" ]]; then
    log "warn" "No gateway data found in pluginctl output"
    exit 0
fi

# Process each gateway
gateway_count=0
while IFS= read -r gateway_json; do
    [[ -z "${gateway_json}" ]] && continue
    ((gateway_count++))
    if ! process_gateway "${gateway_json}"; then
        log "warn" "Failed to process gateway entry #${gateway_count}"
    fi
done <<< "${gateway_list}"

log "info" "Processed ${gateway_count} gateway(s)"
