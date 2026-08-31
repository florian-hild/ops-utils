#!/usr/bin/env bash
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 21-12-2022
# Description: Update docker containers from a compose file
#              Pulls images, rebuilds and recreates containers on change,
#              and records version history in a JSONL log
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
[[ -n "${DEBUG// /}" ]] && export LOGGER_DEBUG_MODE="true"

# Constants
# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly DEFAULT_COMPOSE_FILE="docker-compose.yml"

# Displays help information
# Arguments:
#   $1 - Exit code (default: 0)
print_help() {
    local exit_code="${1:-0}"

    cat <<EOF
Usage: ${SCRIPT_NAME} [compose file]

Description:
  Updates all containers defined in a compose file.
  Pulls images, rebuilds and recreates containers when the image changed,
  and appends the new version to an update history log.

Examples:
  Update all containers from the default compose file:
    ${SCRIPT_NAME}

  Update all containers from a specific compose file:
    ${SCRIPT_NAME} docker-compose.yml

EOF
    exit "${exit_code}"
}

# Updates a single container
# Arguments:
#   $1 - Container name
#   $2 - Compose file
update_container() {
    local container="${1}"
    local compose_file="${2}"
    local current_image=""
    local current_version=""
    local image_name=""
    local new_image=""
    local new_version=""
    local history_log=""

    log "info" "Start update container: ${container}"
    current_image="$(docker inspect --format '{{ index .Image }}' "${container}" | cut -c8-19)"
    current_version="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version"}}' "${container}")"
    log "debug" "Current container image: ${current_image}"
    log "debug" "Current container version: ${current_version}"

    docker compose --file "${compose_file}" pull

    # Derive the image name from the container to detect changes
    image_name="$(docker inspect --format '{{ index .Config.Image }}' "${container}")"
    new_image="$(docker image ls --format '{{.ID}}' "${image_name}" | awk 'NR==1')"

    if [[ "${new_image}" != "${current_image}" ]]; then
        docker compose --file "${compose_file}" build --no-cache
        docker compose --file "${compose_file}" up \
            --force-recreate \
            --detach \
            --remove-orphans
        new_version="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version"}}' "${container}")"
        log "debug" "New container image: ${new_image}"
        log "debug" "New container version: ${new_version}"

        history_log="$(dirname "$(realpath -s "${compose_file}")")/update_history_${container%%;*}_log.jsonl"
        log "info" "Image version has changed"
        log "debug" "Write in log file: '${history_log}'"
        echo "{\"timestamp\": \"$(date +'%F %H:%M:%S')\", \"version\": \"${new_version}\", \"image\": \"${new_image}\"}" >>"${history_log}"
    fi

    log "info" "Finished update container: ${container}"
}

# Main function - orchestrates update process
main() {
    local compose_file="${1:-${DEFAULT_COMPOSE_FILE}}"
    local -a containers=()

    log "debug" "Starting ${SCRIPT_NAME}"

    if [[ ! -f "${compose_file}" ]]; then
        log "error" "File '${compose_file}' not found"
        print_help 1
    fi

    readarray -t containers < <(grep -w "^\s*container_name:" "${compose_file}" | awk '{print $2}')
    for container in "${containers[@]}"; do
        update_container "${container}" "${compose_file}"
    done
}

# Entry point
main "$@"
