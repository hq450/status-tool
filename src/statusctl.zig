const std = @import("std");
const build_options = @import("build_options");

const version = build_options.version;

const Options = struct {
    socket_path: []const u8 = "/tmp/status-tool.sock",
    command: []const u8,
    timeout_ms: u32 = 10000,
};

fn printUsage() void {
    std.debug.print(
        \\statusctl {s}
        \\
        \\Usage:
        \\  statusctl [--socket-path <path>] probe-once
        \\  statusctl [--socket-path <path>] get-cache
        \\  statusctl [--socket-path <path>] ping
        \\  statusctl [--socket-path <path>] send <raw-command>
        \\  --timeout-ms <ms>  read/write timeout, default 10000
        \\  statusctl --help
        \\  statusctl --version
        \\
    , .{version});
}

fn mapCommand(cmd: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, cmd, "probe-once")) return "probe_once";
    if (std.mem.eql(u8, cmd, "get-cache")) return "get_cache";
    if (std.mem.eql(u8, cmd, "ping")) return "ping";
    return null;
}

fn parseOptions(allocator: std.mem.Allocator, argv: []const [:0]u8) !Options {
    var socket_path: []const u8 = "/tmp/status-tool.sock";
    var timeout_ms: u32 = 10000;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--socket-path")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            socket_path = argv[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--timeout-ms")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            timeout_ms = try std.fmt.parseInt(u32, argv[i], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "send")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            return .{
                .socket_path = socket_path,
                .command = try allocator.dupe(u8, argv[i]),
                .timeout_ms = timeout_ms,
            };
        }
        if (mapCommand(arg)) |mapped| {
            return .{
                .socket_path = socket_path,
                .command = mapped,
                .timeout_ms = timeout_ms,
            };
        }
        return error.InvalidArgument;
    }
    return error.InvalidArgument;
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = try stream.write(bytes[sent..]);
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
}

fn timeoutTimeval(timeout_ms: u32) std.posix.timeval {
    return .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
}

fn setStreamTimeout(stream: std.net.Stream, timeout_ms: u32) void {
    if (timeout_ms == 0) return;
    const tv = timeoutTimeval(timeout_ms);
    const bytes = std.mem.asBytes(&tv);
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

fn readAndPrintAll(stream: std.net.Stream) !void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (n == 0) break;
        try stdout.writeAll(buf[0..n]);
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    if (argv.len <= 1) {
        printUsage();
        return;
    }

    if (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
        printUsage();
        return;
    }
    if (std.mem.eql(u8, argv[1], "--version")) {
        try std.fs.File.stdout().writeAll(version ++ "\n");
        return;
    }

    const opts = parseOptions(gpa, argv[1..]) catch {
        printUsage();
        return error.InvalidArgument;
    };

    var attempt: usize = 0;
    while (attempt < 2) : (attempt += 1) {
        var stream = std.net.connectUnixSocket(opts.socket_path) catch |err| {
            if ((err == error.ConnectionRefused or err == error.FileNotFound) and attempt == 0) {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        defer stream.close();
        setStreamTimeout(stream, opts.timeout_ms);

        writeAll(stream, opts.command) catch |err| {
            if (err == error.BrokenPipe and attempt == 0) {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        writeAll(stream, "\n") catch |err| {
            if (err == error.BrokenPipe and attempt == 0) {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        try readAndPrintAll(stream);
        return;
    }
}
