# Bash Library: logger/lib

This Bash library provides the `log` function for structured logging to `stdout` with support for multiple log levels, colorized output, and optional stack traces.

## Features
- **Multiple log levels**: TRACE, DEBUG, INFO, WARN, ERROR, FATAL
- **Colorized output**: Automatic terminal detection with fallback
- **Stack traces**: Optional call stack information for TRACE level
- **Flexible configuration**: Environment variables for behavior control
- **ShellCheck compliant**: Passes `shellcheck -x` with no warnings
- **Comprehensive tests**: Full test suite with GitHub Actions integration

## Available Log Levels

| Level | Description | Default Visibility |
|-------|-------------|-------------------|
| `trace` | Detailed diagnostic info with stack traces | Hidden (requires `LOGGER_TRACE_MODE`) |
| `debug` | Debug information | Hidden (requires `LOGGER_DEBUG_MODE` or `LOGGER_TRACE_MODE`) |
| `info` | Informational messages | Visible |
| `warn` / `warning` | Warning messages | Visible |
| `error` | Error messages | Visible |
| `fatal` | Fatal errors | Visible |

## Usage
Once you have cloned this repository into your project, source the library in your Bash script:

```bash
import() {
    local module="${1}"
    local lib_base_dir='../..'
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

export LOGGER_COLOR="true"
[[ -n "${DEBUG// }" ]] && export LOGGER_DEBUG_MODE="true"
```

## Configuration Options

Control logger behavior using environment variables (set these **before** sourcing the library):

```bash
# Output format: "plain" (default) or "json"
export LOGGER_OUTPUT_FORMAT="json"

# Enable TRACE level (also enables DEBUG)
export LOGGER_TRACE_MODE="true"

# Enable DEBUG level
export LOGGER_DEBUG_MODE="true"

# Disable timestamps
export LOGGER_NO_TIMESTAMP="true"

# Disable stack traces (even for TRACE level)
export LOGGER_NO_STACK="true"

# Force no colors (useful for CI/CD or file output, plain format only)
export LOGGER_COLOR=""
```

**Note**: Variable names have been updated from the old format (`log_no_*`) to the new format (`LOGGER_*`). The library uses proper UPPER_CASE for exported environment variables following Bash best practices.

## Example

```bash
#!/usr/bin/env bash
# shellcheck disable=SC1091
source "${BASH_LIB_DIR}/logger/lib"

log "info" "Starting script..."
log "debug" "Configuration file: /etc/app.conf"
log "warn" "Disk space below threshold"
log "error" "An error occurred!"
log "fatal" "Cannot continue, exiting"
```

### Example Output

Default output (INFO and above):
```log
2026-02-05T12:00:00+0100 INFO  Starting script...
2026-02-05T12:00:00+0100 WARN  Disk space below threshold
2026-02-05T12:00:00+0100 ERROR An error occurred!
2026-02-05T12:00:00+0100 FATAL Cannot continue, exiting
```

With TRACE mode enabled:
```log
2026-02-05T12:00:00+0100 TRACE [at script.sh.main.process_data:42] Processing record
2026-02-05T12:00:00+0100 DEBUG Configuration file: /etc/app.conf
2026-02-05T12:00:00+0100 INFO  Starting script...
2026-02-05T12:00:00+0100 WARN  Disk space below threshold
2026-02-05T12:00:00+0100 ERROR An error occurred!
2026-02-05T12:00:00+0100 FATAL Cannot continue, exiting
```

### JSON Output Format

Enable JSON format for structured logging (perfect for log aggregation systems like ELK, Splunk, or CloudWatch):

```bash
export LOGGER_OUTPUT_FORMAT="json"
source ./lib

log "info" "Service started"
log "error" "Connection failed"
```

Output:
```json
{"timestamp":"2026-02-05T12:00:00+0100","level":"INFO","message":"Service started"}
{"timestamp":"2026-02-05T12:00:00+0100","level":"ERROR","message":"Connection failed"}
```

With TRACE mode and stack traces:
```json
{"timestamp":"2026-02-05T12:00:00+0100","level":"TRACE","stacktrace":"at script.sh.main.process_data:42","message":"Processing record"}
{"timestamp":"2026-02-05T12:00:00+0100","level":"DEBUG","message":"Configuration loaded"}
```

JSON output automatically:
- Escapes special characters (quotes, backslashes)
- Respects `LOGGER_NO_TIMESTAMP` and `LOGGER_NO_STACK` options
- Omits color codes (colors only apply to plain format)
- Produces valid, parseable JSON (verified with `jq`)

## Testing

The library includes a comprehensive test suite that validates all functionality.

### Run Tests Locally

```bash
cd bash/lib/logger
bash test.sh
```

The test suite validates:
- All log levels and their visibility rules
- Configuration options (TRACE mode, DEBUG mode, no timestamp, no stack, etc.)
- JSON output format with various configurations
- Case sensitivity support (uppercase/lowercase level names)
- Invalid log level handling
- Special characters and long messages
- Stack trace generation
- Edge cases (empty messages, etc.)

### Automated Testing

Tests run automatically via GitHub Actions on:
- Push to `main` branch
- Pull requests
- Manual workflow dispatch

See [.github/workflows/test-bash-logger.yml](../../../.github/workflows/test-bash-logger.yml) for the workflow configuration.

## Best Practices

1. **Source early**: Load the logger at the beginning of your script
2. **Use appropriate levels**:
   - `trace` - Detailed function entry/exit and variable dumps
   - `debug` - Diagnostic information for troubleshooting
   - `info` - General progress and status messages
   - `warn` - Recoverable issues or deprecation notices
   - `error` - Failures requiring attention
   - `fatal` - Unrecoverable errors before exit
3. **Include context**: Add relevant details (file paths, values, error codes)
4. **Quote variables**: Always quote in log messages: `"Value: '${var}'"`
5. **Align output**: For multi-line dumps, align values for readability

Example with alignment:
```bash
log "info" "Database configuration:"
log "info" "  Host:     '${DB_HOST}'"
log "info" "  Port:     '${DB_PORT}'"
log "info" "  Database: '${DB_NAME}'"
```

## ShellCheck Compliance

The library passes ShellCheck validation with minimal exceptions:

```bash
shellcheck -x bash/lib/logger/lib
shellcheck -x bash/lib/logger/test.sh
```

ShellCheck directives used are documented with justification in the code.

## JSON Output
To enable JSON-formatted logs, replace `logger/lib` with `logger_json/lib`:

```bash
source "${BASH_LIB_DIR}/logger_json/lib"
```

## License
Refer to the repository's license file for details.

