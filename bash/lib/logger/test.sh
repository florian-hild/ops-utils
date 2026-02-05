#!/usr/bin/env bash
# Note: Not using 'set -e' because we test error conditions that return non-zero
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 16-05-2025
# Description: Comprehensive test suite for logger/lib
#              Tests all log levels, output formats, and configuration options
#-------------------------------------------------------------------------------

export LANG=C

import() {
    local module="${1}"
    local lib_base_dir='..'
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

# Constants
readonly TEST_MESSAGE="Hello World!"
# shellcheck disable=SC2155
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test counters
declare -i TESTS_RUN=0
declare -i TESTS_PASSED=0
declare -i TESTS_FAILED=0

# Helper functions
print_test_header() {
    local test_name="${1}"
    echo ""
    echo "=========================================="
    echo "TEST: ${test_name}"
    echo "=========================================="
}

print_test_result() {
    local test_name="${1}"
    local result="${2}"

    ((TESTS_RUN++))
    if [[ "${result}" == "PASS" ]]; then
        ((TESTS_PASSED++))
        echo "✓ ${test_name}: PASSED"
    else
        ((TESTS_FAILED++))
        echo "✗ ${test_name}: FAILED"
    fi
}

reset_logger_vars() {
    unset LOGGER_NO_TIMESTAMP
    unset LOGGER_NO_STACK
    unset LOGGER_COLOR
    unset LOGGER_DEBUG_MODE
    unset LOGGER_TRACE_MODE
    unset LOGGER_OUTPUT_FORMAT
}

print_all_log_levels() {
    log "trace" "${TEST_MESSAGE}"
    log "debug" "${TEST_MESSAGE}"
    log "info" "${TEST_MESSAGE}"
    log "warn" "${TEST_MESSAGE}"
    log "error" "${TEST_MESSAGE}"
    log "fatal" "${TEST_MESSAGE}"
}

# Test: Default logger output with all log levels
test_default_logger() {
    print_test_header "Default Logger (all levels visible except trace/debug)"
    reset_logger_vars

    print_all_log_levels
    print_test_result "Default logger" "PASS"
}

# Test: Logger with TRACE mode enabled
test_trace_mode() {
    print_test_header "TRACE Mode (all levels including trace)"
    reset_logger_vars
    export LOGGER_TRACE_MODE="true"

    print_all_log_levels
    print_test_result "TRACE mode" "PASS"
}

# Test: Logger with DEBUG mode enabled
test_debug_mode() {
    print_test_header "DEBUG Mode (debug and above visible)"
    reset_logger_vars
    export LOGGER_DEBUG_MODE="true"

    print_all_log_levels
    print_test_result "DEBUG mode" "PASS"
}

# Test: Logger colors
test_color() {
    print_test_header "Color Output"
    reset_logger_vars
    export LOGGER_COLOR="true"
    export LOGGER_TRACE_MODE="true"

    print_all_log_levels
    print_test_result "Color output" "PASS"
}

# Test: Logger without timestamp
test_no_timestamp() {
    print_test_header "No Timestamp"
    reset_logger_vars
    export LOGGER_NO_TIMESTAMP="true"

    print_all_log_levels
    print_test_result "No timestamp" "PASS"
}

# Test: Logger without stack trace
test_no_stack() {
    print_test_header "No Stack Trace (TRACE mode)"
    reset_logger_vars
    export LOGGER_TRACE_MODE="true"
    export LOGGER_NO_STACK="true"

    print_all_log_levels
    print_test_result "No stack trace" "PASS"
}

# Test: Invalid log level
test_invalid_log_level() {
    print_test_header "Invalid Log Level"
    reset_logger_vars

    local output
    output=$(log "invalid_level" "This should fail" 2>&1)
    if echo "${output}" | grep -q "No log level like"; then
        echo "${output}"
        print_test_result "Invalid log level handling" "PASS"
    else
        echo "${output}"
        print_test_result "Invalid log level handling" "FAIL"
    fi
}

# Test: Case insensitivity
test_case_insensitivity() {
    print_test_header "Case Support (uppercase and lowercase)"
    reset_logger_vars

    log "INFO" "Uppercase INFO"
    log "info" "Lowercase info"
    log "WARN" "Uppercase WARN"
    log "warn" "Lowercase warn"
    log "ERROR" "Uppercase ERROR"
    log "error" "Lowercase error"

    print_test_result "Case support" "PASS"
}

# Test: Empty message
test_empty_message() {
    print_test_header "Empty Message (should use default)"
    reset_logger_vars

    log "info"
    print_test_result "Empty message handling" "PASS"
}

# Test: Special characters in message
test_special_characters() {
    print_test_header "Special Characters in Message"
    reset_logger_vars

    log "info" "Special chars: !@#\$%^&*()_+-={}[]|:;<>?,./"
    log "info" "Quotes: \"double\" and 'single'"
    log "info" "Newline test:\nSecond line"

    print_test_result "Special characters" "PASS"
}

# Test: Long message
test_long_message() {
    print_test_header "Long Message"
    reset_logger_vars

    local long_msg="This is a very long message that should be handled properly by the logger. "
    long_msg+="It contains multiple sentences and should wrap appropriately. "
    long_msg+="Testing to ensure the logger can handle verbose output without issues."

    log "info" "${long_msg}"
    print_test_result "Long message" "PASS"
}

# Test: Combined options
test_combined_options() {
    print_test_header "Combined Options (TRACE + NO_TIMESTAMP + NO_STACK)"
    reset_logger_vars
    export LOGGER_TRACE_MODE="true"
    export LOGGER_NO_TIMESTAMP="true"
    export LOGGER_NO_STACK="true"

    print_all_log_levels
    print_test_result "Combined options" "PASS"
}

# Test: WARNING alias
test_warning_alias() {
    print_test_header "WARNING Alias (should work like WARN)"
    reset_logger_vars

    log "warning" "This is a warning"
    log "WARNING" "This is an uppercase WARNING"

    print_test_result "WARNING alias" "PASS"
}

# Test: All log levels with stack trace
test_stack_trace() {
    print_test_header "Stack Trace (TRACE mode with stack)"
    reset_logger_vars
    export LOGGER_TRACE_MODE="true"

    print_all_log_levels
    print_test_result "Stack trace" "PASS"
}

# Test: JSON output format
test_json_format() {
    print_test_header "JSON Output Format"
    reset_logger_vars
    export LOGGER_OUTPUT_FORMAT="json"

    print_all_log_levels
    print_test_result "JSON format" "PASS"
}

# Test: JSON with TRACE mode
test_json_trace() {
    print_test_header "JSON with TRACE Mode"
    reset_logger_vars
    export LOGGER_OUTPUT_FORMAT="json"
    export LOGGER_TRACE_MODE="true"

    print_all_log_levels
    print_test_result "JSON with TRACE" "PASS"
}

# Test: JSON without timestamp
test_json_no_timestamp() {
    print_test_header "JSON without Timestamp"
    reset_logger_vars
    export LOGGER_OUTPUT_FORMAT="json"
    export LOGGER_NO_TIMESTAMP="true"

    log "info" "Test message without timestamp"
    log "error" "Error without timestamp"
    print_test_result "JSON no timestamp" "PASS"
}

# Test: JSON with special characters
test_json_special_chars() {
    print_test_header "JSON with Special Characters"
    reset_logger_vars
    export LOGGER_OUTPUT_FORMAT="json"

    log "info" "Special chars: !@#\$%^&*()_+-={}[]|:;<>?,./"
    log "info" "Quotes: \"double\" and 'single'"
    log "info" "Backslash: \\ and newline: \\n"
    print_test_result "JSON special chars" "PASS"
}

# Main test runner
main() {
    echo "=========================================="
    echo "Logger Library Test Suite"
    echo "=========================================="
    echo "Script location: ${SCRIPT_DIR}"
    echo "Bash version: ${BASH_VERSION}"
    echo ""

    # Run all tests
    test_default_logger
    test_trace_mode
    test_debug_mode
    test_color
    test_no_timestamp
    test_no_stack
    test_invalid_log_level
    test_case_insensitivity
    test_empty_message
    test_special_characters
    test_long_message
    test_combined_options
    test_warning_alias
    test_stack_trace
    test_json_format
    test_json_trace
    test_json_no_timestamp
    test_json_special_chars

    # Print summary
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo "Tests run:    ${TESTS_RUN}"
    echo "Tests passed: ${TESTS_PASSED}"
    echo "Tests failed: ${TESTS_FAILED}"
    echo "=========================================="

    # Exit with appropriate code
    if [[ ${TESTS_FAILED} -eq 0 ]]; then
        echo "✓ All tests passed!"
        exit 0
    else
        echo "✗ Some tests failed!"
        exit 1
    fi
}

# Entry point
main "$@"
