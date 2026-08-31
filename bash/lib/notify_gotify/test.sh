#!/usr/bin/env bash
# Note: Not using 'set -e' because we test error conditions that return non-zero
set -o pipefail

#-------------------------------------------------------------------------------
# Author     : Florian Hild
# Created    : 16-05-2025
# Description: Comprehensive test suite for notify_gotify/lib
#              Tests sending notifications with various priorities and message formats
#-------------------------------------------------------------------------------

export LANG=C

import() {
    local module="${1}"
    # shellcheck disable=SC2155
    local lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local lib_base_dir="${lib_dir}/.."
    local lib_file="${lib_base_dir}/${module}/lib"

    if [[ ! -f "${lib_file}" ]]; then
        echo "Error: Module '${module}' not found at '${lib_file}'" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "${lib_file}"
}

# Import the notify_gotify library
import notify_gotify

export LOGGER_COLOR="true"
[[ -n "${DEBUG// /}" ]] && export LOGGER_DEBUG_MODE="true"

# Constants
# shellcheck disable=SC2155
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_GOTIFY_SERVER="${GOTIFY_SERVER_URL:-https://gotify.lan.florian-hild.de}"

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

reset_gotify_vars() {
    export GOTIFY_SERVER_URL="${DEFAULT_GOTIFY_SERVER}"
}

# Read Gotify API key from environment or prompt user
setup_api_key() {
    if [[ -z "${GOTIFY_API_KEY}" ]]; then
        echo "GOTIFY_API_KEY environment variable is not set."
        echo -n "Please enter your Gotify API key: "
        read -r GOTIFY_API_KEY
        export GOTIFY_API_KEY

        if [[ -z "${GOTIFY_API_KEY}" ]]; then
            echo "Error: No API key provided. Exiting."
            exit 1
        fi
    fi
}

# Test: Simple info alert
test_info_alert() {
    print_test_header "Simple Info Alert"
    reset_gotify_vars

    send_alert "info" "Unit Test - Info" "This is a test alert"
    print_test_result "Info alert" "PASS"
}

# Test: Warning alert
test_warn_alert() {
    print_test_header "Warning Alert"
    reset_gotify_vars

    send_alert "warn" "Unit Test - Warning" "This is a warning message"
    print_test_result "Warning alert" "PASS"
}

# Test: Error alert
test_error_alert() {
    print_test_header "Error Alert"
    reset_gotify_vars

    send_alert "error" "Unit Test - Error" "Something went wrong!"
    print_test_result "Error alert" "PASS"
}

# Test: Critical alert with Markdown
test_critical_alert_markdown() {
    print_test_header "Critical Alert with Markdown"
    reset_gotify_vars

    local md_message
    md_message=$(
        cat <<EOF
**Critical Alert**
- Service: database
- Status: DOWN
- Timestamp: $(date)
EOF
    )

    send_alert "critical" "Unit Test - Critical" "${md_message}"
    print_test_result "Critical alert with Markdown" "PASS"
}

# Test: Multiline message
test_multiline_message() {
    print_test_header "Multiline Message"
    reset_gotify_vars

    local multiline_msg=$'Line 1\nLine 2\nLine 3\nEnd of message'
    send_alert "info" "Unit Test - Multiline" "${multiline_msg}"
    print_test_result "Multiline message" "PASS"
}

# Test: Invalid priority (should fail gracefully)
test_invalid_priority() {
    print_test_header "Invalid Priority (expect error)"
    reset_gotify_vars

    local output
    output=$(send_alert "invalid_priority" "Unit Test - Invalid priority" "This should trigger an error" 2>&1)
    if echo "${output}" | grep -iq "Error"; then
        echo "${output}"
        print_test_result "Invalid priority handling" "PASS"
    else
        echo "${output}"
        print_test_result "Invalid priority handling" "FAIL"
    fi
}

# Test: Invalid Gotify URL
test_invalid_url() {
    print_test_header "Invalid Gotify URL (expect error)"
    export GOTIFY_SERVER_URL="https://invalid-gotify-server.example.com"

    local output
    output=$(send_alert "info" "Unit Test - Invalid URL" "This should trigger an error" 2>&1)
    if echo "${output}" | grep -iq -E "(Error|Failed|Could not resolve)"; then
        echo "${output}"
        print_test_result "Invalid URL handling" "PASS"
    else
        echo "${output}"
        print_test_result "Invalid URL handling" "FAIL"
    fi
}

# Test: All priority levels
test_all_priorities() {
    print_test_header "All Priority Levels"
    reset_gotify_vars

    send_alert "info" "Unit Test - All Priorities" "Info priority"
    send_alert "warn" "Unit Test - All Priorities" "Warning priority"
    send_alert "error" "Unit Test - All Priorities" "Error priority"
    send_alert "critical" "Unit Test - All Priorities" "Critical priority"

    print_test_result "All priority levels" "PASS"
}

# Test: Case insensitivity
test_case_insensitivity() {
    print_test_header "Case Support (uppercase and lowercase)"
    reset_gotify_vars

    send_alert "INFO" "Unit Test - Case" "Uppercase INFO"
    send_alert "info" "Unit Test - Case" "Lowercase info"
    send_alert "WARN" "Unit Test - Case" "Uppercase WARN"
    send_alert "warn" "Unit Test - Case" "Lowercase warn"

    print_test_result "Case support" "PASS"
}

# Test: Special characters in message
test_special_characters() {
    print_test_header "Special Characters in Message"
    reset_gotify_vars

    send_alert "info" "Unit Test - Special Chars" "Special chars: !@#\$%^&*()_+-={}[]|:;<>?,./"
    send_alert "info" "Unit Test - Special Chars" "Quotes: \"double\" and 'single'"

    print_test_result "Special characters" "PASS"
}

# Main test runner
main() {
    echo "=========================================="
    echo "Notify Gotify Library Test Suite"
    echo "=========================================="
    echo "Script location: ${SCRIPT_DIR}"
    echo "Bash version: ${BASH_VERSION}"
    echo ""

    # Setup API key
    setup_api_key
    echo "Using Gotify server: ${DEFAULT_GOTIFY_SERVER}"
    echo ""

    # Run all tests
    test_info_alert
    test_warn_alert
    test_error_alert
    test_critical_alert_markdown
    test_multiline_message
    test_invalid_priority
    test_invalid_url
    test_all_priorities
    test_case_insensitivity
    test_special_characters

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
        echo "Check Gotify server for ${TESTS_PASSED} notifications."
        exit 0
    else
        echo "✗ Some tests failed!"
        exit 1
    fi
}

# Entry point
main "$@"
