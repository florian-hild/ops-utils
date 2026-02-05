# Bash Library: notify_gotify/lib

This Bash library provides the `send_alert` function to send structured notifications to a Gotify server from Bash scripts with automatic priority mapping and logging support.

## Features
- **Multiple priority levels**: INFO, WARN, ERROR, CRITICAL
- **Automatic priority mapping**: Text priorities converted to Gotify numeric values
- **Markdown support**: Rich formatting for notification messages
- **Multiline messages**: Properly formatted multi-line text
- **Integrated logging**: Uses logger/lib for consistent output
- **ShellCheck compliant**: Passes `shellcheck -x` with no warnings
- **Comprehensive tests**: Full test suite with 10 test cases

## Available Priority Levels

| Priority | Gotify Value | Description |
|----------|--------------|-------------|
| `info` | 0 | Informational notifications (lowest) |
| `warn` / `warning` | 3 | Warning notifications |
| `error` | 7 | Error notifications |
| `critical` | 10 | Critical notifications (highest) |

Priority values are automatically mapped to Gotify's numeric scale (0-10), where higher values indicate greater urgency.

## Usage
Once you have cloned this repository into your project, source the library in your Bash script:

```bash
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
[[ -n "${DEBUG// }" ]] && export LOGGER_DEBUG_MODE="true"

# Set Gotify server URL (optional - defaults to https://gotify.lan.florian-hild.de)
export GOTIFY_SERVER_URL="https://your-gotify-server.com"

# Set Gotify API key (required)
export GOTIFY_API_KEY="your-api-key-here"
```

## Configuration Options

Control notify_gotify behavior using environment variables:

```bash
# Gotify server URL (required)
export GOTIFY_SERVER_URL="https://gotify.example.com"

# Gotify API key (required)
export GOTIFY_API_KEY="AbCdEfGhIjKlMnOpQrStUvWxYz"
```

**Note**: The library requires both `GOTIFY_SERVER_URL` and `GOTIFY_API_KEY` to be set. If not provided via environment variables, the test suite will prompt for the API key interactively.

## Function Signature

```bash
send_alert <priority> <title> <message>
```

### Parameters
- `priority` - Notification priority: `info`, `warn`, `error`, or `critical` (case-insensitive)
- `title` - Notification title (appears as notification heading)
- `message` - Notification message body (supports Markdown and multiline text)

## Examples

### Basic Usage

```bash
#!/usr/bin/env bash
# shellcheck disable=SC1091
source "${BASH_LIB_DIR}/notify_gotify/lib"

# Set credentials
export GOTIFY_SERVER_URL="https://gotify.example.com"
export GOTIFY_API_KEY="your-api-key"

# Send notifications
send_alert "info" "Deployment Started" "Application deployment initiated"
send_alert "warn" "High Memory Usage" "Memory usage at 85%"
send_alert "error" "Service Failure" "Database connection failed"
send_alert "critical" "System Down" "Production server unreachable"
```

### Example Output

```log
2026-02-05T16:54:03+0100 INFO  Sending notification to Gotify server: 'https://gotify.lan.florian-hild.de'
2026-02-05T16:54:03+0100 INFO  Notification sent successfully
```

### Markdown Messages

```bash
# Send rich formatted notification
ALERT_MESSAGE=$(cat <<EOF
**Critical System Alert**

- Server: prod-web-01
- Service: nginx
- Status: DOWN
- Timestamp: $(date)

**Action Required**: Immediate investigation needed
EOF
)

send_alert "critical" "Service Outage" "${ALERT_MESSAGE}"
```

### Multiline Messages

```bash
# Build multiline message
BACKUP_REPORT=$'Backup Summary:\nDatabase: SUCCESS\nFiles: SUCCESS\nDuration: 15 minutes'
send_alert "info" "Backup Complete" "${BACKUP_REPORT}"
```

### In Scripts with Error Handling

```bash
#!/usr/bin/env bash
set -euo pipefail

source "${BASH_LIB_DIR}/notify_gotify/lib"

export GOTIFY_SERVER_URL="https://gotify.example.com"
export GOTIFY_API_KEY="${GOTIFY_API_KEY}"

backup_database() {
    local db_name="${1}"

    log "info" "Starting backup of ${db_name}"

    if pg_dump "${db_name}" > "/backups/${db_name}.sql"; then
        send_alert "info" "Backup Success" "Database ${db_name} backed up successfully"
        return 0
    else
        send_alert "error" "Backup Failed" "Failed to backup database ${db_name}"
        return 1
    fi
}

# Main execution
if ! backup_database "production"; then
    send_alert "critical" "Backup Failure" "Critical backup operation failed"
    exit 1
fi
```

## Testing

The library includes a comprehensive test suite that validates all functionality.

### Run Tests Locally

```bash
cd bash/lib/notify_gotify
bash test.sh
```

The test suite validates:
- Info, warn, error, and critical priority levels
- Markdown message formatting
- Multiline message handling
- Invalid priority error handling
- Invalid server URL error handling
- Case sensitivity support (uppercase/lowercase)
- Special characters in messages
- All priority levels in sequence

### Test Output

```
==========================================
Notify Gotify Library Test Suite
==========================================
Script location: /path/to/bash/lib/notify_gotify
Bash version: 5.2.32(1)-release

Using Gotify server: https://gotify.lan.florian-hild.de

==========================================
TEST: Simple Info Alert
==========================================
2026-02-05T12:00:00+0100 INFO  Sending notification to Gotify server: https://gotify.lan.florian-hild.de
2026-02-05T12:00:00+0100 INFO  Notification sent successfully (HTTP 200)
✓ Simple Info Alert: PASSED

[... additional tests ...]

==========================================
Test Summary
==========================================
Tests run:    10
Tests passed: 10
Tests failed: 0
==========================================
✓ All tests passed!
Check Gotify server for 10 notifications.
```

## Best Practices

1. **Use appropriate priorities**:
   - `info` - Routine notifications (deployments, backups, scheduled tasks)
   - `warn` - Issues requiring awareness (high resource usage, deprecations)
   - `error` - Failures requiring investigation (service failures, errors)
   - `critical` - Urgent problems requiring immediate action (outages, security issues)

2. **Include context**: Provide relevant details (server names, service names, error messages)

3. **Use Markdown formatting**: Leverage Gotify's Markdown support for readable alerts:
   ```bash
   MESSAGE="**Server**: prod-01
   **Status**: DOWN
   **Action**: Investigate immediately"
   send_alert "critical" "Server Outage" "${MESSAGE}"
   ```

4. **Quote variables**: Always quote variables to handle spaces and special characters:
   ```bash
   send_alert "error" "Backup Failed" "Database: '${db_name}'"
   ```

5. **Test connectivity**: Verify Gotify server is reachable before critical operations

6. **Secure credentials**: Store `GOTIFY_API_KEY` securely (environment variables, secrets management)

## Error Handling

The library includes comprehensive error handling:

- **Invalid priority**: Returns error if priority is not `info`, `warn`, `error`, or `critical`
- **Missing parameters**: Validates all required parameters are provided
- **Connection failures**: Logs curl errors and HTTP response codes
- **Server errors**: Reports HTTP error codes (4xx, 5xx)

Example error output:
```log
2026-02-05T12:00:00+0100 ERROR Error: Invalid priority 'invalid'. Valid values are: info, warn, error, critical
```

## ShellCheck Compliance

The library passes ShellCheck validation:

```bash
shellcheck -x bash/lib/notify_gotify/lib
shellcheck -x bash/lib/notify_gotify/test.sh
```

ShellCheck directives used are documented with justification in the code.

## Dependencies

- **curl**: Required for HTTP requests to Gotify API
- **logger/lib**: Required for structured logging
- **jq**: Optional, used in tests for JSON validation

## Gotify Server Setup

This library requires a Gotify server. For setup instructions, see:
- Official documentation: https://gotify.net/docs/
- Docker setup: `docker run -p 80:80 gotify/server`

## License
Refer to the repository's license file for details.
