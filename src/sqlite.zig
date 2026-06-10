//! Minimal SQLite bindings: hand-declared externs for the handful of
//! functions this server needs, plus thin Zig-friendly wrappers. No
//! translate-c, no @cImport.

const std = @import("std");

pub const Db = opaque {};
pub const Stmt = opaque {};

pub const OK: c_int = 0;
pub const ROW: c_int = 100;
pub const DONE: c_int = 101;

pub const OPEN_READONLY: c_int = 0x1;
pub const OPEN_READWRITE: c_int = 0x2;
pub const OPEN_CREATE: c_int = 0x4;

const COLUMN_NULL: c_int = 5;

const Destructor = ?*const fn (?*anyopaque) callconv(.c) void;
/// SQLITE_TRANSIENT: sqlite copies the buffer before returning.
const TRANSIENT: Destructor = @ptrFromInt(std.math.maxInt(usize));

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Db, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close(db: ?*Db) c_int;
extern fn sqlite3_errmsg(db: ?*Db) [*:0]const u8;
extern fn sqlite3_exec(db: ?*Db, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: ?*Db, sql: [*]const u8, len: c_int, stmt: *?*Stmt, tail: ?*[*]const u8) c_int;
extern fn sqlite3_step(stmt: ?*Stmt) c_int;
extern fn sqlite3_finalize(stmt: ?*Stmt) c_int;
extern fn sqlite3_column_count(stmt: ?*Stmt) c_int;
extern fn sqlite3_column_name(stmt: ?*Stmt, col: c_int) ?[*:0]const u8;
extern fn sqlite3_column_type(stmt: ?*Stmt, col: c_int) c_int;
extern fn sqlite3_column_text(stmt: ?*Stmt, col: c_int) ?[*:0]const u8;
extern fn sqlite3_bind_text(stmt: ?*Stmt, index: c_int, text: [*]const u8, len: c_int, destructor: Destructor) c_int;

pub fn open(path: [*:0]const u8, flags: c_int) error{OpenFailed}!*Db {
    var db: ?*Db = null;
    const rc = sqlite3_open_v2(path, &db, flags, null);
    if (rc != OK) {
        if (db) |d| _ = sqlite3_close(d);
        return error.OpenFailed;
    }
    return db.?;
}

pub fn close(db: *Db) void {
    _ = sqlite3_close(db);
}

pub fn errmsg(db: *Db) []const u8 {
    return std.mem.span(sqlite3_errmsg(db));
}

/// Execute one or more statements that produce no result rows.
pub fn exec(db: *Db, sql: [*:0]const u8) error{ExecFailed}!void {
    if (sqlite3_exec(db, sql, null, null, null) != OK) return error.ExecFailed;
}

pub fn prepare(db: *Db, sql: []const u8) error{PrepareFailed}!Statement {
    var stmt: ?*Stmt = null;
    const rc = sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
    if (rc != OK or stmt == null) return error.PrepareFailed;
    return .{ .stmt = stmt.? };
}

pub const Statement = struct {
    stmt: *Stmt,

    pub fn finalize(self: Statement) void {
        _ = sqlite3_finalize(self.stmt);
    }

    pub fn step(self: Statement) c_int {
        return sqlite3_step(self.stmt);
    }

    pub fn bindText(self: Statement, index: c_int, text: []const u8) error{BindFailed}!void {
        if (sqlite3_bind_text(self.stmt, index, text.ptr, @intCast(text.len), TRANSIENT) != OK) {
            return error.BindFailed;
        }
    }

    pub fn columnCount(self: Statement) usize {
        return @intCast(sqlite3_column_count(self.stmt));
    }

    pub fn columnName(self: Statement, col: usize) []const u8 {
        const name = sqlite3_column_name(self.stmt, @intCast(col)) orelse return "?";
        return std.mem.span(name);
    }

    /// Text representation of the column in the current row; null for SQL NULL.
    /// The slice is valid only until the next step/finalize.
    pub fn columnText(self: Statement, col: usize) ?[]const u8 {
        if (sqlite3_column_type(self.stmt, @intCast(col)) == COLUMN_NULL) return null;
        const text = sqlite3_column_text(self.stmt, @intCast(col)) orelse return null;
        return std.mem.span(text);
    }
};
