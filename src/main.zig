const std = @import("std");
const build_options = @import("build_options");

const version = build_options.version;

const Family = enum {
    auto,
    ipv4,
    ipv6,
};

const ProbeMode = enum {
    direct,
    socks5,
};

const OutputFormat = enum {
    json,
    text,
};

const ProbeMethod = enum {
    head,
};

const ProbeSpec = struct {
    name: []const u8 = "",
    url: []const u8,
    family: Family = .auto,
    mode: ProbeMode = .direct,
    proxy: ?[]const u8 = null,
    timeout_ms: u32 = 3000,
    warmup: u8 = 1,
    attempts: u8 = 2,
    method: ProbeMethod = .head,
    user_agent: ?[]const u8 = null,
};

const ProbeResult = struct {
    name: []const u8,
    url: []const u8,
    ok: bool,
    status_code: u16,
    elapsed_ms: u32,
    remote_addr: []const u8,
    @"error": []const u8,
    attempts: u8,
    warmup: u8,
};

const RunResult = struct {
    updated_at_ms: i64,
    results: []ProbeResult,
};

const ConfigFile = struct {
    interval_ms: ?u32 = null,
    state_file: ?[]const u8 = null,
    output: ?OutputFormat = null,
    probes: []ProbeSpec,
};

const ParsedUrl = struct {
    raw: []const u8,
    host: []const u8,
    port: u16,
    target: []const u8,
};

const OpenedStream = struct {
    stream: std.net.Stream,
    remote_addr: []const u8,
};

const ProxyEndpoint = struct {
    host: []const u8,
    port: u16,
};

const ProbeError = error{
    UnsupportedScheme,
    MissingHost,
    MissingProxy,
    InvalidProxy,
    InvalidPort,
    UnsupportedMethod,
    NoAddressMatchedFamily,
    InvalidStatusLine,
    SocksVersion,
    SocksAuth,
    SocksConnect,
    HeaderTooLarge,
    UnexpectedEof,
};

fn printUsage() void {
    std.debug.print(
        \\status-tool {s}
        \\
        \\Usage:
        \\  status-tool once [options]
        \\  status-tool daemon --config <path> [--once]
        \\  status-tool --help
        \\  status-tool --version
        \\
        \\once options:
        \\  --url <http-url>
        \\  --config <path>
        \\  --name <label>
        \\  --family <auto|ipv4|ipv6>
        \\  --mode <direct|socks5>
        \\  --proxy <socks5://host:port>
        \\  --timeout-ms <ms>
        \\  --warmup <count>
        \\  --attempts <count>
        \\  --format <json|text>
        \\
        \\daemon options:
        \\  --config <path>
        \\  --state-file <path>
        \\  --interval-ms <ms>
        \\  --format <json|text>
        \\  --stdout
        \\  --once
        \\
    , .{version});
}

fn parseFamily(text: []const u8) !Family {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "ipv4")) return .ipv4;
    if (std.mem.eql(u8, text, "ipv6")) return .ipv6;
    return error.InvalidArgument;
}

fn parseProbeMode(text: []const u8) !ProbeMode {
    if (std.mem.eql(u8, text, "direct")) return .direct;
    if (std.mem.eql(u8, text, "socks5")) return .socks5;
    return error.InvalidArgument;
}

fn parseOutputFormat(text: []const u8) !OutputFormat {
    if (std.mem.eql(u8, text, "json")) return .json;
    if (std.mem.eql(u8, text, "text")) return .text;
    return error.InvalidArgument;
}

fn parseU32(text: []const u8) !u32 {
    return try std.fmt.parseInt(u32, text, 10);
}

fn parseU8(text: []const u8) !u8 {
    return try std.fmt.parseInt(u8, text, 10);
}

fn parseHttpUrl(arena: std.mem.Allocator, raw_url: []const u8) !ParsedUrl {
    const uri = try std.Uri.parse(raw_url);
    if (!std.mem.eql(u8, uri.scheme, "http")) return ProbeError.UnsupportedScheme;
    const host = try uri.getHostAlloc(arena);
    if (host.len == 0) return ProbeError.MissingHost;

    var target: std.ArrayList(u8) = .empty;
    defer target.deinit(arena);

    const path_text = switch (uri.path) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    if (path_text.len == 0) {
        try target.append(arena, '/');
    } else {
        try target.appendSlice(arena, path_text);
    }
    if (uri.query) |query| {
        try target.append(arena, '?');
        switch (query) {
            .raw => |v| try target.appendSlice(arena, v),
            .percent_encoded => |v| try target.appendSlice(arena, v),
        }
    }

    return .{
        .raw = raw_url,
        .host = host,
        .port = uri.port orelse 80,
        .target = try arena.dupe(u8, target.items),
    };
}

fn parseProxyEndpoint(proxy_text: []const u8) !ProxyEndpoint {
    if (!std.mem.startsWith(u8, proxy_text, "socks5://")) return ProbeError.InvalidProxy;
    const rest = proxy_text["socks5://".len..];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return ProbeError.InvalidProxy;
    const host = rest[0..colon];
    const port_text = rest[colon + 1 ..];
    if (host.len == 0 or port_text.len == 0) return ProbeError.InvalidProxy;
    return .{
        .host = host,
        .port = try std.fmt.parseInt(u16, port_text, 10),
    };
}

fn addressFamilyMatches(addr: std.net.Address, family: Family) bool {
    return switch (family) {
        .auto => true,
        .ipv4 => addr.any.family == std.posix.AF.INET,
        .ipv6 => addr.any.family == std.posix.AF.INET6,
    };
}

fn addressToOwnedString(allocator: std.mem.Allocator, addr: std.net.Address) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{addr});
}

fn openDirectStream(allocator: std.mem.Allocator, parsed: ParsedUrl, family: Family) !OpenedStream {
    const list = try std.net.getAddressList(allocator, parsed.host, parsed.port);
    defer list.deinit();

    var last_err: ?anyerror = null;
    for (list.addrs) |addr| {
        if (!addressFamilyMatches(addr, family)) continue;
        const stream = std.net.tcpConnectToAddress(addr) catch |err| {
            last_err = err;
            continue;
        };
        return .{
            .stream = stream,
            .remote_addr = try addressToOwnedString(allocator, addr),
        };
    }

    if (last_err) |err| return err;
    return ProbeError.NoAddressMatchedFamily;
}

fn writeAll(stream: std.net.Stream, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = try stream.write(bytes[sent..]);
        if (n == 0) return error.WriteFailed;
        sent += n;
    }
}

fn readExact(stream: std.net.Stream, buf: []u8) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = try stream.read(buf[offset..]);
        if (n == 0) return ProbeError.UnexpectedEof;
        offset += n;
    }
}

fn openSocks5Stream(allocator: std.mem.Allocator, parsed: ParsedUrl, proxy_text: []const u8) !OpenedStream {
    const proxy = try parseProxyEndpoint(proxy_text);
    var opened = try openDirectStream(allocator, .{
        .raw = proxy_text,
        .host = proxy.host,
        .port = proxy.port,
        .target = "",
    }, .auto);
    errdefer opened.stream.close();

    try writeAll(opened.stream, &[_]u8{ 0x05, 0x01, 0x00 });
    var greeting: [2]u8 = undefined;
    try readExact(opened.stream, &greeting);
    if (greeting[0] != 0x05) return ProbeError.SocksVersion;
    if (greeting[1] != 0x00) return ProbeError.SocksAuth;

    if (parsed.host.len > 255) return ProbeError.InvalidProxy;
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);
    try request.appendSlice(allocator, &[_]u8{ 0x05, 0x01, 0x00, 0x03, @intCast(parsed.host.len) });
    try request.appendSlice(allocator, parsed.host);
    try request.append(allocator, @intCast((parsed.port >> 8) & 0xff));
    try request.append(allocator, @intCast(parsed.port & 0xff));
    try writeAll(opened.stream, request.items);

    var header: [4]u8 = undefined;
    try readExact(opened.stream, &header);
    if (header[0] != 0x05) return ProbeError.SocksVersion;
    if (header[1] != 0x00) return ProbeError.SocksConnect;

    switch (header[3]) {
        0x01 => {
            var skip: [6]u8 = undefined;
            try readExact(opened.stream, &skip);
        },
        0x03 => {
            var size_buf: [1]u8 = undefined;
            try readExact(opened.stream, &size_buf);
            const host_len = size_buf[0];
            const skip = try allocator.alloc(u8, host_len + 2);
            defer allocator.free(skip);
            try readExact(opened.stream, skip);
        },
        0x04 => {
            var skip: [18]u8 = undefined;
            try readExact(opened.stream, &skip);
        },
        else => return ProbeError.SocksConnect,
    }

    allocator.free(opened.remote_addr);
    opened.remote_addr = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ proxy.host, proxy.port });
    return opened;
}

fn readHttpResponseHead(allocator: std.mem.Allocator, stream: std.net.Stream) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var temp: [1024]u8 = undefined;
    while (buf.items.len < 16 * 1024) {
        const n = try stream.read(&temp);
        if (n == 0) break;
        try buf.appendSlice(allocator, temp[0..n]);
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n") != null) break;
    }
    if (std.mem.indexOf(u8, buf.items, "\r\n\r\n") == null) return ProbeError.HeaderTooLarge;
    return try buf.toOwnedSlice(allocator);
}

fn parseStatusCode(head: []const u8) !u16 {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return ProbeError.InvalidStatusLine;
    const line = head[0..line_end];
    var iter = std.mem.splitScalar(u8, line, ' ');
    _ = iter.next() orelse return ProbeError.InvalidStatusLine;
    const code_text = iter.next() orelse return ProbeError.InvalidStatusLine;
    return try std.fmt.parseInt(u16, code_text, 10);
}

fn doSingleAttempt(allocator: std.mem.Allocator, spec: ProbeSpec) !ProbeResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseHttpUrl(arena, spec.url);
    var opened = if (spec.mode == .direct)
        try openDirectStream(allocator, parsed, spec.family)
    else
        try openSocks5Stream(allocator, parsed, spec.proxy orelse return ProbeError.MissingProxy);
    defer opened.stream.close();

    var timer = try std.time.Timer.start();
    const ua = spec.user_agent orelse "status-tool/" ++ version;
    const request = try std.fmt.allocPrint(arena,
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nConnection: close\r\nAccept: */*\r\n\r\n",
        .{ "HEAD", parsed.target, parsed.host, ua },
    );
    try writeAll(opened.stream, request);
    const head = try readHttpResponseHead(arena, opened.stream);
    const elapsed_ms: u32 = @intCast(@min(timer.read() / std.time.ns_per_ms, std.math.maxInt(u32)));
    const status_code = try parseStatusCode(head);

    return .{
        .name = try allocator.dupe(u8, spec.name),
        .url = try allocator.dupe(u8, spec.url),
        .ok = status_code >= 200 and status_code < 400,
        .status_code = status_code,
        .elapsed_ms = elapsed_ms,
        .remote_addr = opened.remote_addr,
        .@"error" = try allocator.dupe(u8, "ok"),
        .attempts = spec.attempts,
        .warmup = spec.warmup,
    };
}

fn probeSpec(allocator: std.mem.Allocator, spec: ProbeSpec) !ProbeResult {
    const effective_attempts: u8 = if (spec.attempts == 0) 1 else spec.attempts;
    const total_rounds: usize = @as(usize, spec.warmup) + @as(usize, effective_attempts);
    var best: ?ProbeResult = null;
    var last_failure: ?ProbeResult = null;

    var round: usize = 0;
    while (round < total_rounds) : (round += 1) {
        const res = doSingleAttempt(allocator, spec) catch |err| blk: {
            break :blk ProbeResult{
                .name = try allocator.dupe(u8, spec.name),
                .url = try allocator.dupe(u8, spec.url),
                .ok = false,
                .status_code = 0,
                .elapsed_ms = 0,
                .remote_addr = try allocator.dupe(u8, ""),
                .@"error" = try allocator.dupe(u8, @errorName(err)),
                .attempts = effective_attempts,
                .warmup = spec.warmup,
            };
        };

        const is_warmup = round < spec.warmup;
        if (is_warmup) continue;

        if (res.ok) {
            if (best == null or res.elapsed_ms < best.?.elapsed_ms) {
                best = res;
            }
        } else {
            last_failure = res;
        }
    }

    if (best) |res| return res;
    if (last_failure) |res| return res;
    return ProbeResult{
        .name = try allocator.dupe(u8, spec.name),
        .url = try allocator.dupe(u8, spec.url),
        .ok = false,
        .status_code = 0,
        .elapsed_ms = 0,
        .remote_addr = try allocator.dupe(u8, ""),
        .@"error" = try allocator.dupe(u8, "NoAttempt"),
        .attempts = effective_attempts,
        .warmup = spec.warmup,
    };
}

fn runProbeList(allocator: std.mem.Allocator, specs: []const ProbeSpec) !RunResult {
    var results = try allocator.alloc(ProbeResult, specs.len);
    const updated_at_ms = std.time.milliTimestamp();
    for (specs, 0..) |spec, i| {
        results[i] = try probeSpec(allocator, spec);
    }
    return .{
        .updated_at_ms = updated_at_ms,
        .results = results,
    };
}

fn runResultToJsonAlloc(allocator: std.mem.Allocator, run_result: RunResult) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(run_result, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return try allocator.dupe(u8, out.written());
}

fn runResultToTextAlloc(allocator: std.mem.Allocator, run_result: RunResult) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    for (run_result.results) |res| {
        try list.print(allocator,
            "{s}\t{s}\t{d}\t{d}\t{s}\t{s}\n",
            .{
                if (res.name.len == 0) "-" else res.name,
                if (res.ok) "ok" else "fail",
                res.status_code,
                res.elapsed_ms,
                if (res.remote_addr.len == 0) "-" else res.remote_addr,
                res.@"error",
            },
        );
    }
    return try list.toOwnedSlice(allocator);
}

fn writeRunResultFile(allocator: std.mem.Allocator, path: []const u8, format: OutputFormat, run_result: RunResult) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.time.milliTimestamp() });
    defer allocator.free(tmp_path);

    var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .read = true });
    defer file.close();
    const output = switch (format) {
        .json => try runResultToJsonAlloc(allocator, run_result),
        .text => try runResultToTextAlloc(allocator, run_result),
    };
    defer allocator.free(output);
    try file.writeAll(output);
    try file.sync();
    try std.fs.cwd().rename(tmp_path, path);
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) !ConfigFile {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(ConfigFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

const OnceOptions = struct {
    config_path: ?[]const u8 = null,
    format: OutputFormat = .json,
    specs: []ProbeSpec,
};

fn parseOnceOptions(allocator: std.mem.Allocator, argv: []const [:0]u8) !OnceOptions {
    var list: std.ArrayList(ProbeSpec) = .empty;
    var current = ProbeSpec{ .url = "" };
    var format: OutputFormat = .json;
    var config_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            config_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.url = argv[i];
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.name = argv[i];
        } else if (std.mem.eql(u8, arg, "--family")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.family = try parseFamily(argv[i]);
        } else if (std.mem.eql(u8, arg, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.mode = try parseProbeMode(argv[i]);
        } else if (std.mem.eql(u8, arg, "--proxy")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.proxy = argv[i];
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.timeout_ms = try parseU32(argv[i]);
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.warmup = try parseU8(argv[i]);
        } else if (std.mem.eql(u8, arg, "--attempts")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            current.attempts = try parseU8(argv[i]);
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            format = try parseOutputFormat(argv[i]);
        } else {
            return error.InvalidArgument;
        }
    }

    if (config_path == null) {
        if (current.url.len == 0) return error.InvalidArgument;
        if (current.name.len == 0) current.name = current.url;
        try list.append(allocator, current);
    }

    return .{
        .config_path = config_path,
        .format = format,
        .specs = try list.toOwnedSlice(allocator),
    };
}

const DaemonOptions = struct {
    config_path: []const u8,
    state_file: ?[]const u8 = null,
    interval_ms: ?u32 = null,
    format: ?OutputFormat = null,
    stdout: bool = false,
    once: bool = false,
};

fn parseDaemonOptions(argv: []const [:0]u8) !DaemonOptions {
    var opts = DaemonOptions{ .config_path = "" };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.config_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--state-file")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.state_file = argv[i];
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.interval_ms = try parseU32(argv[i]);
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.format = try parseOutputFormat(argv[i]);
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            opts.stdout = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            opts.once = true;
        } else {
            return error.InvalidArgument;
        }
    }
    if (opts.config_path.len == 0) return error.InvalidArgument;
    return opts;
}

fn runOnceCommand(allocator: std.mem.Allocator, argv: []const [:0]u8) !void {
    const opts = try parseOnceOptions(allocator, argv);
    var format = opts.format;
    var specs = opts.specs;
    if (opts.config_path) |path| {
        const cfg = try readConfigFile(allocator, path);
        specs = cfg.probes;
        format = cfg.output orelse format;
    }
    const run_result = try runProbeList(allocator, specs);
    const output = switch (format) {
        .json => try runResultToJsonAlloc(allocator, run_result),
        .text => try runResultToTextAlloc(allocator, run_result),
    };
    defer allocator.free(output);
    try std.fs.File.stdout().writeAll(output);
}

fn runDaemonCommand(allocator: std.mem.Allocator, argv: []const [:0]u8) !void {
    const opts = try parseDaemonOptions(argv);
    const cfg = try readConfigFile(allocator, opts.config_path);
    const interval_ms = opts.interval_ms orelse cfg.interval_ms orelse 5000;
    const format = opts.format orelse cfg.output orelse .json;
    const state_file = opts.state_file orelse cfg.state_file;

    while (true) {
        {
            var cycle_arena_state = std.heap.ArenaAllocator.init(allocator);
            defer cycle_arena_state.deinit();
            const cycle_alloc = cycle_arena_state.allocator();
            const run_result = try runProbeList(cycle_alloc, cfg.probes);

            if (state_file) |path| {
                try writeRunResultFile(cycle_alloc, path, format, run_result);
            }
            if (opts.stdout or opts.once) {
                const output = switch (format) {
                    .json => try runResultToJsonAlloc(cycle_alloc, run_result),
                    .text => try runResultToTextAlloc(cycle_alloc, run_result),
                };
                try std.fs.File.stdout().writeAll(output);
            }
            if (opts.once) return;
        }
        std.Thread.sleep(@as(u64, interval_ms) * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    const argv = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, argv);

    if (argv.len <= 1) {
        printUsage();
        return;
    }

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
        return;
    }
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "-V")) {
        std.debug.print("{s}\n", .{version});
        return;
    }
    if (std.mem.eql(u8, cmd, "once")) {
        try runOnceCommand(gpa, argv[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "daemon")) {
        try runDaemonCommand(gpa, argv[2..]);
        return;
    }

    printUsage();
    return error.InvalidArgument;
}
