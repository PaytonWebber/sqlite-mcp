//! Creates a small test database for the conformance script.

const std = @import("std");
const sqlite = @import("sqlite.zig");

pub fn main(init: std.process.Init) !void {
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // program name
    const path = args_it.next() orelse {
        std.debug.print("usage: make-fixture <database-file>\n", .{});
        return error.MissingDatabasePath;
    };

    const db = try sqlite.open(path, sqlite.OPEN_READWRITE | sqlite.OPEN_CREATE);
    defer sqlite.close(db);

    try sqlite.exec(db,
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT);
        \\CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), total REAL, note TEXT);
        \\INSERT INTO users (name, email) VALUES
        \\  ('Ada Lovelace', 'ada@example.com'),
        \\  ('Alan Turing', 'alan@example.com'),
        \\  ('Grace Hopper', NULL);
        \\INSERT INTO orders (user_id, total, note) VALUES
        \\  (1, 19.99, 'difference engine parts'),
        \\  (1, 5.00, NULL),
        \\  (2, 42.00, 'tape');
    );
}
