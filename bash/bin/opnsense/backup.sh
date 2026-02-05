#!/usr/bin/env bash
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 17-06-2024
# Description: Create OPNsense backup from config.xml
#              Downloads, optionally encrypts, and manages backup retention
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
# Import the notify-gotify library
import notify_gotify

export LOGGER_NO_TIMESTAMP="true"
export LOGGER_COLOR="true"
[[ -n "${DEBUG// }" ]] && export LOGGER_DEBUG_MODE="true"

# Constants
# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly DEFAULT_BACKUP_DAYS_KEEP=30

# Configuration variables (loaded from config file)
export GOTIFY_API_KEY=""
export GOTIFY_SERVER_URL=""
BACKUP_API_HOST=""
BACKUP_API_PORT=""
BACKUP_API_KEY=""
BACKUP_API_SECRET=""
BACKUP_DESTINATION_PATH=""
BACKUP_ENCRYPTION_PASS=""
BACKUP_DAYS_KEEP="${DEFAULT_BACKUP_DAYS_KEEP}"

# Displays help information
# Arguments:
#   $1 - Exit code (default: 0)
print_help() {
    local exit_code="${1:-0}"

    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Description:
  Downloads OPNsense configuration backup via API.
  Optionally encrypts backup and manages retention policy.

Options:
  -c, --config_path FILE    Path to configuration file (Required)
  -e, --encrypt             Encrypt backup file with AES-256-CBC
  -h, --help                Display this help message and exit
  -v, --verbose             Enable verbose debugging output

Configuration File Variables:
  GOTIFY_API_KEY              API key for Gotify notifications (required)
  GOTIFY_SERVER_URL           Gotify server URL (default: https://gotify.lan
  BACKUP_API_HOST             OPNsense host or IP address (required)
  BACKUP_API_PORT             API port (required)
  BACKUP_API_KEY              API key for authentication (required)
  BACKUP_API_SECRET           API secret for authentication (required)
  BACKUP_DESTINATION_PATH     Directory to save backups (required)
  BACKUP_ENCRYPTION_PASS      Password for encryption (required with -e)
  BACKUP_DAYS_KEEP            Days to keep old backups (default: ${DEFAULT_BACKUP_DAYS_KEEP})

Examples:
  Create unencrypted backup:
    ${SCRIPT_NAME} --config_path /usr/local/etc/opnsense_fw_backup.env

  Create encrypted backup:
    ${SCRIPT_NAME} --encrypt --config_path /usr/local/etc/opnsense_fw_backup.env

EOF
    exit "${exit_code}"
}

# Validates required dependencies are available
# Returns:
#   0 - All dependencies found
#   1 - Missing dependencies
validate_dependencies() {
    local -a missing_deps=()

    local -a required_cmds=("curl" "gzip" "find")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" &> /dev/null; then
            missing_deps+=("${cmd}")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "error" "Missing required commands: ${missing_deps[*]}"
        return 1
    fi

    log "debug" "All dependencies validated successfully"
    return 0
}

# Validates configuration file and loads variables
# Arguments:
#   $1 - Path to configuration file
# Returns:
#   0 - Configuration valid
#   1 - Configuration validation failed
validate_and_load_config() {
    local config_file="${1}"

    if [[ ! -f "${config_file}" ]]; then
        log "error" "Configuration file not found: '${config_file}'"
        return 1
    fi

    if [[ ! -r "${config_file}" ]]; then
        log "error" "Configuration file not readable: '${config_file}'"
        return 1
    fi

    log "debug" "Loading configuration from '${config_file}'"

    # shellcheck disable=SC1090
    source "${config_file}"

    # Validate required variables
    local -a missing_vars=()

    [[ -z "${GOTIFY_API_KEY:-}" ]] && missing_vars+=("GOTIFY_API_KEY")
    [[ -z "${BACKUP_API_HOST:-}" ]] && missing_vars+=("BACKUP_API_HOST")
    [[ -z "${BACKUP_API_PORT:-}" ]] && missing_vars+=("BACKUP_API_PORT")
    [[ -z "${BACKUP_API_KEY:-}" ]] && missing_vars+=("BACKUP_API_KEY")
    [[ -z "${BACKUP_API_SECRET:-}" ]] && missing_vars+=("BACKUP_API_SECRET")
    [[ -z "${BACKUP_DESTINATION_PATH:-}" ]] && missing_vars+=("BACKUP_DESTINATION_PATH")

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log "error" "Missing required configuration variables: ${missing_vars[*]}"
        return 1
    fi

    # Validate destination path exists
    if [[ ! -d "${BACKUP_DESTINATION_PATH}" ]]; then
        log "error" "Backup destination path does not exist: '${BACKUP_DESTINATION_PATH}'"
        return 1
    fi

    # Use default retention if not specified
    BACKUP_DAYS_KEEP="${BACKUP_DAYS_KEEP:-${DEFAULT_BACKUP_DAYS_KEEP}}"

    log "debug" "Configuration loaded successfully"
    log "debug" "API Host: '${BACKUP_API_HOST}'"
    log "debug" "API Port: '${BACKUP_API_PORT}'"
    log "debug" "Destination: '${BACKUP_DESTINATION_PATH}'"
    log "debug" "Retention: '${BACKUP_DAYS_KEEP}' days"

    return 0
}

# Validates encryption requirements
# Arguments:
#   $1 - Encrypt flag (1 or empty)
# Returns:
#   0 - Validation passed
#   1 - Validation failed
validate_encryption() {
    local encrypt_enabled="${1}"

    if [[ -n "${encrypt_enabled}" ]] && [[ -z "${BACKUP_ENCRYPTION_PASS:-}" ]]; then
        log "error" "BACKUP_ENCRYPTION_PASS required when encryption is enabled"
        return 1
    fi

    if [[ -n "${encrypt_enabled}" ]]; then
        if ! command -v openssl &> /dev/null; then
            log "error" "OpenSSL not found - required for encryption"
            return 1
        fi
    fi

    return 0
}

# Downloads OPNsense backup file via API
# Arguments:
#   $1 - Encrypt flag (1 or empty)
# Returns:
#   0 - Backup successful
#   1 - Backup failed
get_backup_file() {
    local encrypt_enabled="${1}"
    local api_url="https://${BACKUP_API_HOST}:${BACKUP_API_PORT}/api/core/backup/download/this"
    local timestamp=""
    local backup_filename=""
    local exit_code=0

    timestamp="$(date +'%F_%H-%M')"

    # Set restrictive permissions for backup files (0640)
    umask 0137

    log "info" "Downloading OPNsense configuration from '${api_url}'"

    if [[ -n "${encrypt_enabled}" ]]; then
        backup_filename="opnsense-backup-${timestamp}_encrypted.xml.gz"
        log "info" "Encryption enabled - using AES-256-CBC"
        log "debug" "Output file: '${BACKUP_DESTINATION_PATH}/${backup_filename}'"

        if ! curl --silent --insecure \
            --user "${BACKUP_API_KEY}:${BACKUP_API_SECRET}" \
            "${api_url}" | \
            openssl enc -e -base64 -aes-256-cbc -pbkdf2 -md sha512 -iter 100000 \
            -pass "pass:${BACKUP_ENCRYPTION_PASS}" | \
            gzip --stdout - > "${BACKUP_DESTINATION_PATH}/${backup_filename}"; then

            exit_code=${PIPESTATUS[0]}
            log "error" "Backup download failed with exit code: ${exit_code}"
            return 1
        fi
    else
        backup_filename="opnsense-backup-${timestamp}.xml.gz"
        log "debug" "Output file: '${BACKUP_DESTINATION_PATH}/${backup_filename}'"

        if ! curl --silent --insecure \
            --user "${BACKUP_API_KEY}:${BACKUP_API_SECRET}" \
            "${api_url}" | \
            gzip --stdout - > "${BACKUP_DESTINATION_PATH}/${backup_filename}"; then

            exit_code=${PIPESTATUS[0]}
            log "error" "Backup download failed with exit code: ${exit_code}"
            return 1
        fi
    fi

    log "info" "Backup saved successfully: '${backup_filename}'"
    return 0
}

# Purges old backup files based on retention policy
# Returns:
#   0 - Purge successful
#   1 - Purge failed
purge_backup_files() {
    local file_count=0

    log "info" "Purging backups older than ${BACKUP_DAYS_KEEP} days"
    log "debug" "Searching in: '${BACKUP_DESTINATION_PATH}'"

    # Count files to be deleted
    file_count=$(find "${BACKUP_DESTINATION_PATH}" \
        -name "opnsense-backup-*.xml.gz" \
        -type f \
        -mtime "+${BACKUP_DAYS_KEEP}" \
        2>/dev/null | wc -l | tr -d ' ')

    if [[ "${file_count}" -gt 0 ]]; then
        log "debug" "Found ${file_count} backup(s) to delete"

        if ! find "${BACKUP_DESTINATION_PATH}" \
            -name "opnsense-backup-*.xml.gz" \
            -type f \
            -mtime "+${BACKUP_DAYS_KEEP}" \
            -delete 2>&1; then
            log "error" "Failed to delete old backup files"
            return 1
        fi

        log "info" "Deleted ${file_count} old backup file(s)"
    else
        log "debug" "No old backups to delete"
    fi

    return 0
}

# Main function - orchestrates backup process
main() {
    local config_path=""
    local encrypt=""

    log "debug" "Starting ${SCRIPT_NAME}"

    # Parse command-line arguments
    if [[ ${#} -eq 0 ]] || [[ "${1:-}" == "-" ]] || [[ "${1:-}" == "--" ]]; then
        log "error" "No arguments provided"
        print_help 1
    fi

    local opts=""
    if ! opts="$(getopt -o 'c:hev' --long 'config_path:,help,encrypt,verbose' -n "${SCRIPT_NAME}" -- "$@" 2>&1)"; then
        log "error" "Invalid command-line arguments"
        print_help 1
    fi

    eval set -- "${opts}"

    while true; do
        case "${1}" in
            -c | --config_path)
                config_path="${2}"
                shift 2
                ;;
            -h | --help)
                print_help 0
                ;;
            -e | --encrypt)
                encrypt="1"
                shift
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

    # Validate dependencies
    if ! validate_dependencies; then
        exit 1
    fi

    # Validate configuration file argument
    if [[ -z "${config_path}" ]]; then
        log "error" "Configuration file path is required (use -c or --config_path)"
        print_help 1
    fi

    # Load and validate configuration
    if ! validate_and_load_config "${config_path}"; then
        exit 1
    fi

    # Validate encryption requirements
    if ! validate_encryption "${encrypt}"; then
        exit 1
    fi

    # Download backup
    if ! get_backup_file "${encrypt}"; then
        log "error" "Backup operation failed"
        alert_message=$(cat <<EOF
**OPNsense Backup Failed**

Failed to download OPNsense backup from API. Please investigate the issue.

- Server: ${BACKUP_API_HOST}
- Service: OPNsense Backup
- Status: FAILED
- Timestamp: $(date)
- Execution Host: $(hostname)
EOF
)
        send_alert "error" "OPNsense Backup Failed" "${alert_message}"
        exit 1
    fi

    # Purge old backups
    if ! purge_backup_files; then
        log "warn" "Failed to purge old backups (non-fatal)"
    fi

    log "info" "Backup completed successfully"
    log "debug" "Completed ${SCRIPT_NAME}"
}

# Entry point
main "$@"
