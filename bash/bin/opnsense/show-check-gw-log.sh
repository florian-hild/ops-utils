#!/usr/bin/env bash
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 15-12-2023
# Description: Show Check Gateway status logfile
#-------------------------------------------------------------------------------

export LANG=C

LOGFILE="${1:-}"

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

if ! command -v jq >> /dev/null; then
    log "error" "Required command 'jq' not found in PATH"
    exit 1
fi

if [[ -z "${LOGFILE// }" ]]; then
  echo "Usage:"
  echo "  $0 [jsonl-logfile]"
  exit 2
fi

if [[ -r ${LOGFILE} ]]; then
  jq '.timestamp + " | Status: " + .status + " | Loss: " + .loss' "${LOGFILE}"
else
  log "error" "File not found or not readable at path: '${LOGFILE}'"
  exit 1
fi
