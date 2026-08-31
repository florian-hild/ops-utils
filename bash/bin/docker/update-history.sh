#!/usr/bin/env bash
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 21-11-2023
# Description: Show docker update history log
#              Renders the last entries of an update history JSONL log as table
#-------------------------------------------------------------------------------

export LANG=C

import() {
    local module="${1}"
    # shellcheck disable=SC2155
    local lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local lib_base_dir="${lib_dir}/../../lib"
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

# Constants
# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly DEFAULT_LOG_FILE="update_history_*_log.jsonl"

LOG_FILE="${1:-${DEFAULT_LOG_FILE}}"

if [[ -z "${LOG_FILE// /}" ]]; then
    echo "Usage:"
    echo "  ${SCRIPT_NAME} [update history JSON file]"
    exit 2
fi

# shellcheck disable=SC2086 # unquoted so the default glob pattern expands
if [ ! -f ${LOG_FILE} ]; then
    log "error" "File '${LOG_FILE}' not found"
    echo "Usage:"
    echo "  ${SCRIPT_NAME} [update history JSON file]"
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    log "error" "Command 'jq' not found"
    exit 1
fi

# shellcheck disable=SC2086 # unquoted so the default glob pattern expands
tail -n 5 ${LOG_FILE} | jq -r '.timestamp + ";" + .version + ";" + .image' | (
    printf "+-----------------------------------------------------+\n"
    printf "| %-19s | %-14s | %-12s |\n" "Timestamp" "Version" "Image"
    printf "+-----------------------------------------------------+\n"
    while IFS=';' read -r ts ver img; do
        printf "| %-19s | %-14s | %-12s |\n" "${ts}" "${ver}" "${img}"
    done
    printf "+-----------------------------------------------------+\n"
)
