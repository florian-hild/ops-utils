#!/usr/bin/env bash

################################################################################
# Developer ......: F.Hild
# Created ........: 09.08.2023
# Description ....: Test script for logger/lib
################################################################################

export LANG=C.UTF-8
declare -r __SCRIPT_VERSION__='1.1.0'

declare -r message="Hello World!"

# shellcheck disable=SC1091
source ./lib

function print_logs() {
    log "trace" "${message}"
    log "debug" "${message}"
    log "info" "${message}"
    log "warn" "${message}"
    log "error" "${message}"
    log "fatal" "${message}"
}

echo '{"Logger settings":"defaults"}'
print_logs

# shellcheck disable=SC2034
declare log_no_timestamp="True"
echo
echo '{"Logger settings":"log_no_timestamp=True"}'
print_logs

unset log_no_timestamp
# shellcheck disable=SC2034
declare log_no_loglevel="True"
echo
echo '{"Logger settings":"log_no_loglevel=True"}'
print_logs

unset log_no_loglevel
# shellcheck disable=SC2034
declare log_no_stacktrace="True"
echo
echo '{"Logger settings":"log_no_stacktrace=True"}'
print_logs

echo
echo '{"Logger settings":"Test wrong log level"}'
unset log_no_stacktrace
log "test" "This is a test message"
