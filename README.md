# sqlite-mcp

[![CI](https://github.com/PaytonWebber/sqlite-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/PaytonWebber/sqlite-mcp/actions/workflows/ci.yml)

Point Claude at any SQLite database with a single 1 MB binary.

```bash
claude mcp add my-db /path/to/sqlite-mcp /path/to/database.db
```

No Python, no Node, no runtime. One statically linked executable with SQLite compiled in: about 1 MB stripped. A full cold-process session (initialize, handshake, one SELECT) completes in about 2 ms with 2.9 MB peak memory; the reference Python server takes about 410 ms and 64 MB for the same session, the most-used npm server about 210 ms and 84 MB.

The database is opened **read-only**. Writes fail at the SQLite layer, so it is safe to hand an LLM.

## What it exposes

| | |
|---|---|
| `query` tool | Run SQL, get rows back as pipe-separated text with a header. `max_rows` defaults to 100; truncation is reported. SQL errors come back as tool errors with the SQLite message. |
| `list_tables` tool | Enumerate tables. |
| `sqlite://table/<name>` resources | Each table's CREATE statement, so the model can read schemas before writing queries. |

## Install

Download a binary from [releases](https://github.com/PaytonWebber/sqlite-mcp/releases) (Linux x86_64/aarch64 static, macOS x86_64/aarch64, Windows x86_64), or build from source:

```bash
zig build -Doptimize=ReleaseSmall   # requires Zig 0.16.0
```

The build fetches the SQLite amalgamation and the [zig-mcp-sdk](https://github.com/PaytonWebber/zig-mcp-sdk) through the Zig package manager; there are no system dependencies.

### Claude Code

```bash
claude mcp add my-db /path/to/sqlite-mcp /path/to/database.db
```

### Claude Desktop / Cursor

```json
{
  "mcpServers": {
    "my-db": {
      "command": "/path/to/sqlite-mcp",
      "args": ["/path/to/database.db"]
    }
  }
}
```

## Example session

```
> what tables are in this database?
  list_tables -> orders, users

> who spent the most?
  query("SELECT u.name, SUM(o.total) AS spent FROM users u
         JOIN orders o ON o.user_id = u.id
         GROUP BY u.id ORDER BY spent DESC LIMIT 1")
  -> Alan Turing | 42.0
```

## How it works

Built with [zig-mcp-sdk](https://github.com/PaytonWebber/zig-mcp-sdk). The tool schemas are generated at compile time from the argument structs, the SQLite amalgamation is compiled into the binary by Zig's C compiler, and every release is conformance-tested in CI: handshake, queries, NULL rendering, truncation, write rejection, schema resources.

## License

MIT
