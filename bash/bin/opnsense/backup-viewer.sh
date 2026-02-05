#!/usr/bin/env bash
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 19-06-2024
# Description: OPNsense backup viewer
#              Decrypts and decompresses OPNsense backup files for inspection
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
export LOGGER_COLOR="true"
[[ -n "${DEBUG// }" ]] && export LOGGER_DEBUG_MODE="true"

# Constants
# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# Displays help information
# Arguments:
#   $1 - Exit code (default: 0)
print_help() {
    local exit_code="${1:-0}"

    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Description:
  Decrypts and decompresses OPNsense backup files for viewing.
  Supports encrypted (OpenSSL AES-256-CBC), gzip-compressed, and plain text formats.

Options:
  -f, --file FILE      Path to OPNsense backup file (Required)
  -h, --help           Display this help message and exit
  -v, --verbose        Enable verbose debugging output

Supported Formats:
  - Encrypted + gzipped (.xml.xz with OpenSSL encryption)
  - Encrypted only (OpenSSL AES-256-CBC base64 encoded)
  - Gzipped only (.xml.xz, .xml.gz)
  - Plain text XML

Examples:
  View encrypted backup:
    ${SCRIPT_NAME} --file opnsense-backup-2024-06-19_encrypted.xml.xz

  View plain backup:
    ${SCRIPT_NAME} --file opnsense-backup-2024-06-19.xml

EOF
    exit "${exit_code}"
}

# Validates required dependencies are available
# Returns:
#   0 - All dependencies found
#   1 - Missing dependencies
validate_dependencies() {
    local -a missing_deps=()

    local -a required_cmds=("openssl" "gzip" "file" "sed")
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

# Prompts for decryption password with validation
# Returns:
#   Password via stdout
prompt_password() {
    local password=""

    while true; do
        read -r -p "Enter decryption password: " password
        if [[ -n "${password}" ]]; then
            echo "${password}"
            return 0
        fi
        log "warn" "Password cannot be empty, please try again"
    done
}

# Decrypts backup file using OpenSSL AES-256-CBC
# Arguments:
#   $1 - Backup file path
#   $2 - File type
#   $3 - File MIME type
# Returns:
#   0 - Success
#   1 - Decryption failed
decrypt_file() {
    local backup_file="${1}"
    local file_type="${2}"
    local file_mime_type="${3}"
    local password=""

    log "info" "Backup file is encrypted - password required"
    password="$(prompt_password)"

    log "debug" "Decrypting with OpenSSL AES-256-CBC"

    if [[ "${file_mime_type}" == "application/gzip" ]]; then
        # Gzipped + encrypted
        if ! gzip --decompress --stdout "${backup_file}" | \
            openssl enc -d -base64 -aes-256-cbc -pbkdf2 -md sha512 -iter 100000 -pass "pass:${password}" 2>/dev/null; then
            log "error" "Decryption failed - incorrect password or corrupted file"
            return 1
        fi
    elif [[ "${file_type}" =~ ^openssl ]]; then
        # Encrypted only
        if ! openssl enc -d -base64 -aes-256-cbc -pbkdf2 -md sha512 -iter 100000 \
            -pass "pass:${password}" -in "${backup_file}" 2>/dev/null; then
            log "error" "Decryption failed - incorrect password or corrupted file"
            return 1
        fi
    else
        log "error" "Unknown encrypted file format"
        return 1
    fi

    return 0
}

# Processes and displays backup file content
# Arguments:
#   $1 - Backup file path
# Returns:
#   0 - Success
#   1 - Processing failed
process_backup_file() {
    local backup_file="${1}"
    local file_type=""
    local file_mime_type=""
    local inner_file_type=""

    log "debug" "Detecting file format for '${backup_file}'"

    # Extract content without OpenSSL headers/footers for detection
    file_type="$(sed -e '/--- /d; /: /d; /^$/d;' "${backup_file}" | file --brief - 2>/dev/null || echo "unknown")"
    file_mime_type="$(sed -e '/--- /d; /: /d; /^$/d;' "${backup_file}" | file --mime-type --brief - 2>/dev/null || echo "unknown")"

    log "debug" "File type:      '${file_type}'"
    log "debug" "File MIME type: '${file_mime_type}'"

    # Process based on detected format
    if [[ "${file_mime_type}" == "application/gzip" ]]; then
        # Check if gzipped content is encrypted
        inner_file_type="$(gzip --decompress --stdout "${backup_file}" | sed -e '/--- BEGIN/d; /--- END/d' | file --brief - 2>/dev/null || echo "unknown")"

        if [[ "${inner_file_type}" =~ ^openssl ]]; then
            log "info" "Format: Encrypted + gzipped"
            decrypt_file "${backup_file}" "${file_type}" "${file_mime_type}"
        else
            log "info" "Format: Gzipped only"
            gzip --decompress --stdout "${backup_file}"
        fi
    elif [[ "${file_type}" =~ ^openssl ]]; then
        log "info" "Format: Encrypted only"
        decrypt_file "${backup_file}" "${file_type}" "${file_mime_type}"
    elif [[ "${file_mime_type}" == "text/plain" ]]; then
        log "info" "Format: Plain text"
        cat "${backup_file}"
    else
        log "error" "Unknown or unsupported file format"
        log "error" "Detected type: '${file_type}'"
        log "error" "Detected MIME: '${file_mime_type}'"
        return 1
    fi

    return 0
}

# Main function - orchestrates backup file viewing
main() {
    local backup_file=""

    log "debug" "Starting ${SCRIPT_NAME}"

    # Parse command-line arguments
    if [[ ${#} -eq 0 ]] || [[ "${1:-}" == "-" ]] || [[ "${1:-}" == "--" ]]; then
        log "error" "No arguments provided"
        print_help 1
    fi

    local opts=""
    if ! opts="$(getopt -o 'f:hv' --long 'file:,help,verbose' -n "${SCRIPT_NAME}" -- "$@" 2>&1)"; then
        log "error" "Invalid command-line arguments"
        print_help 1
    fi

    eval set -- "${opts}"

    while true; do
        case "${1}" in
            -f | --file)
                backup_file="${2}"
                shift 2
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

    # Validate dependencies
    if ! validate_dependencies; then
        exit 1
    fi

    # Validate backup file argument
    if [[ -z "${backup_file}" ]]; then
        log "error" "Backup file path is required (use -f or --file)"
        print_help 1
    fi

    if [[ ! -f "${backup_file}" ]]; then
        log "error" "Backup file not found: '${backup_file}'"
        exit 1
    fi

    if [[ ! -r "${backup_file}" ]]; then
        log "error" "Backup file not readable: '${backup_file}'"
        exit 1
    fi

    log "info" "Processing backup file: '${backup_file}'"

    # Process and display backup content
    if ! process_backup_file "${backup_file}"; then
        log "error" "Failed to process backup file"
        exit 1
    fi

    log "debug" "Completed ${SCRIPT_NAME}"
}

# Entry point
main "$@"
