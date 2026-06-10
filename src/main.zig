//! sqlite-mcp: a read-only SQLite MCP server in a single static binary.
//!
//! Tools (via mcp.ToolPack): `query` runs SQL, `list_tables` enumerates
//! tables. Table schemas are exposed as MCP resources under
//! `sqlite://table/<name>`. The database is opened read-only; writes fail
//! at the SQLite layer.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const mcp = @import("zig_mcp_sdk");
const types = mcp.types;
const sqlite = @import("sqlite.zig");

// The stdio server is single-threaded; one global handle keeps the
// ToolPack handlers free of state plumbing.
var db: *sqlite.Db = undefined;

const QueryArgs = struct {
    sql: []const u8,
    max_rows: u32 = 100,
    pub const descriptions = .{
        .sql = "SQL to run. The database is read-only; statements that modify it fail.",
        .max_rows = "Maximum number of rows to return",
    };
};

const Tools = mcp.ToolPack(.{
    .query = .{
        .description = "Run a SQL query and return rows as pipe-separated text with a header row. The database is read-only.",
        .handler = query,
        .annotations = .{ .readOnlyHint = true },
    },
    .list_tables = .{
        .description = "List all tables in the database. Read each table's schema via the sqlite://table/<name> resources.",
        .handler = listTables,
        .annotations = .{ .readOnlyHint = true },
    },
});

fn query(allocator: Allocator, args: QueryArgs) !types.CallToolResult {
    const stmt = sqlite.prepare(db, args.sql) catch {
        return sqlError(allocator);
    };
    defer stmt.finalize();

    var out: std.ArrayList(u8) = .empty;
    const ncols = stmt.columnCount();

    if (ncols == 0) {
        // Statements without result columns (e.g. PRAGMA writes) either
        // succeed silently or fail; surface which.
        return switch (stmt.step()) {
            sqlite.DONE => types.CallToolResult.text(allocator, "OK (statement returned no rows)"),
            else => sqlError(allocator),
        };
    }

    for (0..ncols) |col| {
        if (col != 0) try out.appendSlice(allocator, " | ");
        try out.appendSlice(allocator, stmt.columnName(col));
    }
    try out.append(allocator, '\n');

    var rows: u32 = 0;
    var truncated = false;
    while (true) {
        const rc = stmt.step();
        if (rc == sqlite.DONE) break;
        if (rc != sqlite.ROW) return sqlError(allocator);
        if (rows == args.max_rows) {
            truncated = true;
            break;
        }
        for (0..ncols) |col| {
            if (col != 0) try out.appendSlice(allocator, " | ");
            try out.appendSlice(allocator, stmt.columnText(col) orelse "NULL");
        }
        try out.append(allocator, '\n');
        rows += 1;
    }

    if (truncated) {
        try out.appendSlice(allocator, try std.fmt.allocPrint(
            allocator,
            "({d} rows shown, output truncated; refine the query or raise max_rows)",
            .{rows},
        ));
    } else {
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "({d} row{s})", .{
            rows,
            if (rows == 1) "" else "s",
        }));
    }
    return types.CallToolResult.text(allocator, out.items);
}

fn listTables(allocator: Allocator, _: struct {}) !types.CallToolResult {
    return query(allocator, .{
        .sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    });
}

fn sqlError(allocator: Allocator) !types.CallToolResult {
    return types.CallToolResult.err(allocator, try std.fmt.allocPrint(
        allocator,
        "SQL error: {s}",
        .{sqlite.errmsg(db)},
    ));
}

const resource_prefix = "sqlite://table/";

const Handler = struct {
    tools: Tools = .{},

    pub fn listTools(self: *Handler, allocator: Allocator) !types.ListToolsResult {
        return self.tools.listTools(allocator);
    }

    pub fn callTool(self: *Handler, allocator: Allocator, ctx: mcp.Context, params: types.CallToolParams) !types.CallToolResult {
        return self.tools.callTool(allocator, ctx, params);
    }

    pub fn listResources(_: *Handler, allocator: Allocator) !types.ListResourcesResult {
        const stmt = sqlite.prepare(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") catch
            return error.QueryFailed;
        defer stmt.finalize();

        var resources: std.ArrayList(types.Resource) = .empty;
        while (stmt.step() == sqlite.ROW) {
            const name = stmt.columnText(0) orelse continue;
            try resources.append(allocator, .{
                .uri = try std.fmt.allocPrint(allocator, "{s}{s}", .{ resource_prefix, name }),
                .name = try allocator.dupe(u8, name),
                .description = "Table schema (CREATE statement)",
                .mimeType = "text/plain",
            });
        }
        return .{ .resources = resources.items };
    }

    pub fn readResource(_: *Handler, allocator: Allocator, params: types.ReadResourceParams) !types.ReadResourceResult {
        if (!mem.startsWith(u8, params.uri, resource_prefix)) return error.ResourceNotFound;
        const table = params.uri[resource_prefix.len..];

        const stmt = sqlite.prepare(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?1") catch
            return error.QueryFailed;
        defer stmt.finalize();
        try stmt.bindText(1, table);

        if (stmt.step() != sqlite.ROW) return error.ResourceNotFound;
        const schema = stmt.columnText(0) orelse return error.ResourceNotFound;

        const contents = try allocator.alloc(types.ResourceContents, 1);
        contents[0] = .{ .text = .{
            .uri = params.uri,
            .mimeType = "text/plain",
            .text = try allocator.dupe(u8, schema),
        } };
        return .{ .contents = contents };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // program name
    const db_path = args_it.next() orelse {
        std.debug.print("usage: sqlite-mcp <database-file>\n", .{});
        return error.MissingDatabasePath;
    };

    db = sqlite.open(db_path, sqlite.OPEN_READONLY) catch {
        std.debug.print("error: cannot open '{s}' as an SQLite database\n", .{db_path});
        return error.OpenFailed;
    };
    defer sqlite.close(db);

    var handler = Handler{};
    var server = mcp.Server(Handler).init(allocator, &handler, .{
        .server_info = .{ .name = "sqlite-mcp", .version = "0.1.0" },
        .capabilities = .{ .tools = .{}, .resources = .{} },
        .instructions = "Read-only access to an SQLite database. Use list_tables to discover tables, read sqlite://table/<name> resources for schemas, and query to run SQL.",
    });

    try server.start(init.io);
}
