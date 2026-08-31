#!/usr/bin/env bash
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 09.08.2023
# Description: Create and prune backups with borgbackup
#              Reads its configuration from an env file with pre/post hooks
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
[[ -n "${DEBUG// /}" ]] && export LOGGER_DEBUG_MODE="true"

# Constants
# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Defaults (can be overridden in the env file)
borg_logfile="${HOME}/local/log/borg_backup_$(hostname -s)_$(date +'%Y-%m').log"
borg_tmp_logfile="/tmp/borg_backup_$(hostname -s)_$(date +'%Y-%m').log"
BORG_EXCLUDE=''
BORG_PREFIX=''
BORG_PRUNE_KEEP_LAST='4'
BORG_PRUNE_KEEP_DAILY='0'
BORG_PRUNE_KEEP_WEEKLY='4'
BORG_PRUNE_KEEP_MONTHLY='6'
BORG_PRUNE_KEEP_YEARLY='2'

# Pre commands (override in env file)
run_pre() {
    :
}

# Post commands (override in env file)
run_post() {
    :
}

# Displays help information
# Arguments:
#   $1 - Exit code (default: 0)
print_help() {
    local exit_code="${1:-0}"

    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Description:
  Creates or prunes backups with borgbackup.
  Configuration is loaded from an env file.

Options:
  -e, --env FILE    Path to borg backup env file (required)
  -h, --help        Display this help message and exit
  -p, --prune       Prune borg backups instead of creating one
  -v, --verbose     Enable verbose debugging output

Configuration File Variables:
  BORG_PASSPHRASE           Passphrase for the borg repository (required)
  BORG_REPO                 Borg repository (required)
  BORG_DIR_LIST             Directories to back up (required)
  BORG_PREFIX               Archive name prefix
  BORG_EXCLUDE              Exclude pattern for borg create
  BORG_PRUNE_KEEP_*         Prune retention values
  run_pre / run_post        Hook functions run around the backup

Examples:
  Create backup:
    ${SCRIPT_NAME} --env borg_backup.env

  Prune backups:
    ${SCRIPT_NAME} --env borg_backup.env --prune

EOF
    exit "${exit_code}"
}

# Creates a new borg backup archive
# Returns:
#   Borg return code
borg_backup() {
    local rc=0
    local -a borg_dir_list=()

    # Split directory list into an array
    read -r -a borg_dir_list <<<"${BORG_DIR_LIST}"

    log "info" "Start backup script"
    log "info" "Run pre commands"
    run_pre

    log "info" "Start backup to ${BORG_REPO}"
    export BORG_PASSPHRASE
    borg create \
        --filter AME \
        --list \
        --stats \
        --compression zlib,5 \
        --exclude-caches \
        --exclude "${BORG_EXCLUDE}" \
        "${BORG_REPO}::${BORG_PREFIX:+${BORG_PREFIX}_}{hostname}_{now:%Y-%m-%d}_{now:%H:%M}" \
        "${borg_dir_list[@]}"
    rc=${?}

    # https://borgbackup.readthedocs.io/en/stable/usage/general.html#return-codes
    if [[ "${rc}" -eq 1 ]]; then
        log "warn" "Return code: '${rc}'"
    elif [[ "${rc}" -eq 2 ]]; then
        log "error" "Return code: '${rc}'"
    elif [[ "${rc}" -gt 2 ]]; then
        log "fatal" "Return code: '${rc}'"
    fi

    log "info" "Run post commands"
    run_post

    log "info" "End backup script"
    return "${rc}"
}

# Prunes old borg backup archives
# Returns:
#   Borg return code
borg_prune() {
    local rc=0

    log "info" "Start backup script (prune)"
    log "info" "Start prune to ${BORG_REPO}"
    export BORG_PASSPHRASE
    borg prune \
        --list \
        --glob-archives "${BORG_PREFIX:+${BORG_PREFIX}_}{hostname}_" \
        --keep-last "${BORG_PRUNE_KEEP_LAST}" \
        --keep-daily "${BORG_PRUNE_KEEP_DAILY}" \
        --keep-weekly "${BORG_PRUNE_KEEP_WEEKLY}" \
        --keep-monthly "${BORG_PRUNE_KEEP_MONTHLY}" \
        --keep-yearly "${BORG_PRUNE_KEEP_YEARLY}" \
        "${BORG_REPO}"
    rc=${?}

    # https://borgbackup.readthedocs.io/en/stable/usage/general.html#return-codes
    if [[ "${rc}" -eq 1 ]]; then
        log "warn" "Return code: '${rc}'"
    elif [[ "${rc}" -eq 2 ]]; then
        log "error" "Return code: '${rc}'"
    elif [[ "${rc}" -gt 2 ]]; then
        log "fatal" "Return code: '${rc}'"
    fi

    log "info" "End backup script (prune)"
    return "${rc}"
}

# Main function - orchestrates backup process
main() {
    local env_file=""
    local prune=""
    local rc=0

    log "debug" "Starting ${SCRIPT_NAME}"

    # Parse command-line arguments
    if [[ ${#} -eq 0 ]] || [[ "${1:-}" == "-" ]] || [[ "${1:-}" == "--" ]]; then
        log "error" "No arguments provided"
        print_help 1
    fi

    local opts=""
    if ! opts="$(getopt -o 'e:phv' --long 'env:,prune,help,verbose' -n "${SCRIPT_NAME}" -- "$@" 2>&1)"; then
        log "error" "Invalid command-line arguments"
        print_help 1
    fi

    eval set -- "${opts}"

    while true; do
        case "${1}" in
        -e | --env)
            env_file="${2}"
            shift 2
            ;;
        -p | --prune)
            prune="1"
            shift
            ;;
        -h | --help)
            print_help 0
            ;;
        -v | --verbose)
            export LOGGER_DEBUG_MODE="true"
            set -xv
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            log "error" "Unrecognized option: ${1}"
            print_help 1
            ;;
        esac
    done

    # Validate env file argument
    if [[ -z "${env_file// /}" ]]; then
        log "error" "Env file not specified (use -e or --env)"
        print_help 1
    fi

    if [[ ! -f "${env_file}" ]]; then
        log "fatal" "Env file '${env_file}' not found"
        exit 1
    fi

    # Source env file
    # shellcheck disable=SC1090
    source "${env_file}"

    # Create path to logfile
    mkdir -p "${borg_logfile%/*}"

    # Validate required configuration
    if [[ -z "${BORG_REPO// /}" ]]; then
        log "fatal" "BORG_REPO not specified"
        exit 1
    fi

    if [[ -z "${BORG_PASSPHRASE// /}" ]]; then
        log "fatal" "BORG_PASSPHRASE not specified"
        exit 1
    fi

    if [[ -z "${BORG_DIR_LIST// /}" ]]; then
        log "fatal" "BORG_DIR_LIST not specified"
        exit 1
    fi

    # Define a trap to run when the script exits
    trap '{
        # Append the content of the log file to the backup file
        cat "${borg_tmp_logfile}" >>"${borg_logfile}"

        # Remove the original log file
        rm -f "${borg_tmp_logfile}"
    }' EXIT

    exec > >(tee -a "${borg_tmp_logfile}") 2>&1

    if [[ -z "${prune// /}" ]]; then
        borg_backup
        rc=${?}
    else
        borg_prune
        rc=${?}
    fi

    return "${rc}"
}

# Entry point
main "$@"
