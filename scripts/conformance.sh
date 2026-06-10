#!/usr/bin/env bash
# Drives sqlite-mcp through a full stdio session against a generated fixture
# database and asserts on the wire responses.
#
# Usage: scripts/conformance.sh   (requires zig build first)
set -euo pipefail

BIN="./zig-out/bin/sqlite-mcp"
FIXTURE="./zig-out/bin/make-fixture"

for f in "$BIN" "$FIXTURE"; do
    if [[ ! -x "$f" ]]; then
        echo "error: $f not found (run 'zig build' first)" >&2
        exit 1
    fi
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
DB="$tmpdir/test.db"
"$FIXTURE" "$DB"

input=$(cat <<'EOF'
{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"conformance","version":"1.0"}},"id":1}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","method":"tools/list","id":2}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"list_tables"},"id":3}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"query","arguments":{"sql":"SELECT name, email FROM users ORDER BY id"}},"id":4}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"query","arguments":{"sql":"SELECT id FROM orders ORDER BY id","max_rows":2}},"id":5}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"query","arguments":{"sql":"DELETE FROM users"}},"id":6}
{"jsonrpc":"2.0","method":"tools/call","params":{"name":"query","arguments":{"sql":"SELECT nope FROM nowhere"}},"id":7}
{"jsonrpc":"2.0","method":"resources/list","id":8}
{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"sqlite://table/users"},"id":9}
EOF
)

output="$(printf '%s\n' "$input" | "$BIN" "$DB")"

failures=0
expect() {
    local desc="$1" pattern="$2"
    if grep -qE -- "$pattern" <<<"$output"; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        echo "      missing pattern: $pattern" >&2
        failures=$((failures + 1))
    fi
}

expect "initialize returns serverInfo" '"serverInfo".*"name":"sqlite-mcp"'
expect "tools/list carries generated schemas" '"inputSchema":\{"type":"object"'
expect "tools/list includes max_rows with default" '"max_rows":\{"type":"integer".*"default":100'
expect "list_tables finds the fixture tables" 'orders\\nusers'
expect "query returns rows with header" 'name \| email\\nAda Lovelace \| ada@example.com'
expect "NULL columns render as NULL" 'Grace Hopper \| NULL'
expect "max_rows truncates output" 'output truncated'
expect "writes are rejected as isError" '"id":6.*"isError":true|"isError":true.*"id":6'
expect "write rejection mentions readonly" 'readonly'
expect "bad SQL is an isError result with the message" 'SQL error: no such table: nowhere'
expect "resources/list exposes table schemas" '"uri":"sqlite://table/users"'
expect "resources/read returns the CREATE statement" 'CREATE TABLE users'

if [[ "$failures" -gt 0 ]]; then
    echo "$failures conformance check(s) failed" >&2
    exit 1
fi
echo "all conformance checks passed"
