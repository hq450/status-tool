const std = @import("std");
const build_options = @import("build_options");
const c = @cImport({
    @cInclude("time.h");
});

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
    legacy_file: ?[]const u8 = null,
    output: ?OutputFormat = null,
    probes: []ProbeSpec,
};

const ServeState = struct {
    cache_allocator: std.mem.Allocator,
    specs: []const ProbeSpec,
    state_file: ?[]const u8,
    legacy_file: ?[]const u8,
    format: OutputFormat,
    cached_json: ?[]u8 = null,
    cached_fancyss: ?[]u8 = null,
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

const ServeOptions = struct {
    socket_path: []const u8 = "/tmp/status-tool.sock",
    daemon: DaemonOptions,
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

fn statusCodeOk(code: u16) bool {
    return code == 200 or code == 204 or code == 301 or code == 302;
}

fn localTimeTextAlloc(allocator: std.mem.Allocator) ![]const u8 {
    var now: c.time_t = @intCast(std.time.timestamp());
    const tm_ptr = c.localtime(&now) orelse return error.LocalTimeFailed;
    var buf: [32]u8 = undefined;
    const len = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S", tm_ptr);
    if (len == 0) return error.LocalTimeFailed;
    return try allocator.dupe(u8, buf[0..len]);
}

fn findProbeResult(run_result: RunResult, name: []const u8) ?ProbeResult {
    for (run_result.results) |res| {
        if (std.mem.eql(u8, res.name, name)) return res;
    }
    return null;
}

fn appendFancyssLine(list: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, ts: []const u8, res: ?ProbeResult) !void {
    if (res) |item| {
        if (item.ok and statusCodeOk(item.status_code)) {
            try list.print(allocator, "{s} 【{s}】 ✓&nbsp;&nbsp;{d} ms", .{ label, ts, item.elapsed_ms });
            return;
        }
    }
    try list.print(allocator, "{s} 【{s}】 <font color=\"#FF0000\">X</font>", .{ label, ts });
}

fn printUsage() void {
    std.debug.print(
        \\status-tool {s}
        \\
        \\Usage:
        \\  status-tool once [options]
        \\  status-tool fancyss [options]
        \\  status-tool daemon --config <path> [--once]
        \\  status-tool serve [options]
        \\  status-tool client [options] <ping|get_cache|probe_once>
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
        \\  --china-url <http-url>
        \\  --foreign-url <http-url>
        \\  --proxy-ipv6 <0|1>
        \\  --foreign-proxy <socks5://host:port>
        \\  --state-file <path>
        \\  --legacy-file <path>
        \\  --interval-ms <ms>
        \\  --format <json|text>
        \\  --stdout
        \\  --once
        \\
        \\fancyss options:
        \\  same as daemon input options, but always runs one probe cycle
        \\  and prints the compact fancyss legacy line format
        \\
        \\serve options:
        \\  same as daemon input options
        \\  --socket-path <path>  unix socket path, default /tmp/status-tool.sock
        \\
        \\client options:
        \\  --socket-path <path>  unix socket path, default /tmp/status-tool.sock
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

fn jsonGetString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |v| v,
        else => error.InvalidConfig,
    };
}

fn jsonGetOptionalString(obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    if (obj.get(key)) |value| {
        return try jsonGetString(value);
    }
    return null;
}

fn jsonGetU32(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else error.InvalidConfig,
        .number_string => |v| try parseU32(v),
        else => error.InvalidConfig,
    };
}

fn jsonGetOptionalU32(obj: std.json.ObjectMap, key: []const u8) !?u32 {
    if (obj.get(key)) |value| {
        return try jsonGetU32(value);
    }
    return null;
}

fn jsonGetOptionalU8(obj: std.json.ObjectMap, key: []const u8) !?u8 {
    if (obj.get(key)) |value| {
        const parsed = try jsonGetU32(value);
        if (parsed > std.math.maxInt(u8)) return error.InvalidConfig;
        return @intCast(parsed);
    }
    return null;
}

fn jsonGetOptionalFamily(obj: std.json.ObjectMap, key: []const u8) !?Family {
    if (obj.get(key)) |value| {
        return try parseFamily(try jsonGetString(value));
    }
    return null;
}

fn jsonGetOptionalProbeMode(obj: std.json.ObjectMap, key: []const u8) !?ProbeMode {
    if (obj.get(key)) |value| {
        return try parseProbeMode(try jsonGetString(value));
    }
    return null;
}

fn jsonGetOptionalOutputFormat(obj: std.json.ObjectMap, key: []const u8) !?OutputFormat {
    if (obj.get(key)) |value| {
        return try parseOutputFormat(try jsonGetString(value));
    }
    return null;
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

fn runResultToFancyssAlloc(allocator: std.mem.Allocator, run_result: RunResult) ![]u8 {
    const ts = try localTimeTextAlloc(allocator);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const china = findProbeResult(run_result, "china");
    const foreign4 = findProbeResult(run_result, "foreign4");
    const foreign6 = findProbeResult(run_result, "foreign6");
    const has_ipv6 = foreign6 != null;

    if (has_ipv6) {
        try appendFancyssLine(&list, allocator, "国外IPv4", ts, foreign4);
        try list.appendSlice(allocator, "@@");
        try appendFancyssLine(&list, allocator, "国外IPv6", ts, foreign6);
    } else {
        try appendFancyssLine(&list, allocator, "国外链接", ts, foreign4);
    }
    try list.appendSlice(allocator, "@@");
    try appendFancyssLine(&list, allocator, "国内连接", ts, china);
    return try list.toOwnedSlice(allocator);
}

fn writeRunResultFile(allocator: std.mem.Allocator, path: []const u8, format: OutputFormat, run_result: RunResult) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    const output = switch (format) {
        .json => try runResultToJsonAlloc(allocator, run_result),
        .text => try runResultToTextAlloc(allocator, run_result),
    };
    defer allocator.free(output);
    try file.writeAll(output);
}

fn writeBytesFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    _ = allocator;
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) !ConfigFile {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    const root = parsed.value;
    if (root != .object) return error.InvalidConfig;

    const root_obj = root.object;
    var probe_list: std.ArrayList(ProbeSpec) = .empty;

    if (root_obj.get("probes")) |probes_value| {
        if (probes_value != .array) return error.InvalidConfig;
        for (probes_value.array.items) |item| {
            if (item != .object) return error.InvalidConfig;
            const obj = item.object;
            var probe = ProbeSpec{
                .url = try jsonGetString(obj.get("url") orelse return error.InvalidConfig),
            };
            probe.name = (try jsonGetOptionalString(obj, "name")) orelse probe.url;
            probe.family = (try jsonGetOptionalFamily(obj, "family")) orelse .auto;
            probe.mode = (try jsonGetOptionalProbeMode(obj, "mode")) orelse .direct;
            probe.proxy = try jsonGetOptionalString(obj, "proxy");
            probe.timeout_ms = (try jsonGetOptionalU32(obj, "timeout_ms")) orelse 3000;
            probe.warmup = (try jsonGetOptionalU8(obj, "warmup")) orelse 1;
            probe.attempts = (try jsonGetOptionalU8(obj, "attempts")) orelse 2;
            probe.user_agent = try jsonGetOptionalString(obj, "user_agent");
            try probe_list.append(allocator, probe);
        }
    } else {
        return error.InvalidConfig;
    }

    return .{
        .interval_ms = try jsonGetOptionalU32(root_obj, "interval_ms"),
        .state_file = try jsonGetOptionalString(root_obj, "state_file"),
        .legacy_file = try jsonGetOptionalString(root_obj, "legacy_file"),
        .output = try jsonGetOptionalOutputFormat(root_obj, "output"),
        .probes = try probe_list.toOwnedSlice(allocator),
    };
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
    config_path: []const u8 = "",
    china_url: ?[]const u8 = null,
    foreign_url: ?[]const u8 = null,
    proxy_ipv6: bool = false,
    foreign_proxy: ?[]const u8 = null,
    state_file: ?[]const u8 = null,
    legacy_file: ?[]const u8 = null,
    interval_ms: ?u32 = null,
    format: ?OutputFormat = null,
    stdout: bool = false,
    once: bool = false,
};

fn parseDaemonOptions(argv: []const [:0]u8) !DaemonOptions {
    var opts = DaemonOptions{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.config_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--china-url")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.china_url = argv[i];
        } else if (std.mem.eql(u8, arg, "--foreign-url")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.foreign_url = argv[i];
        } else if (std.mem.eql(u8, arg, "--proxy-ipv6")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.proxy_ipv6 = std.mem.eql(u8, argv[i], "1") or std.mem.eql(u8, argv[i], "true");
        } else if (std.mem.eql(u8, arg, "--foreign-proxy")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.foreign_proxy = argv[i];
        } else if (std.mem.eql(u8, arg, "--state-file")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.state_file = argv[i];
        } else if (std.mem.eql(u8, arg, "--legacy-file")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.legacy_file = argv[i];
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
    if (opts.config_path.len == 0 and (opts.china_url == null or opts.foreign_url == null)) return error.InvalidArgument;
    return opts;
}

fn parseServeOptions(argv: []const [:0]u8) !ServeOptions {
    var opts = ServeOptions{ .daemon = .{} };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--socket-path")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.socket_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.config_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--china-url")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.china_url = argv[i];
        } else if (std.mem.eql(u8, arg, "--foreign-url")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.foreign_url = argv[i];
        } else if (std.mem.eql(u8, arg, "--proxy-ipv6")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.proxy_ipv6 = std.mem.eql(u8, argv[i], "1") or std.mem.eql(u8, argv[i], "true");
        } else if (std.mem.eql(u8, arg, "--foreign-proxy")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.foreign_proxy = argv[i];
        } else if (std.mem.eql(u8, arg, "--state-file")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.state_file = argv[i];
        } else if (std.mem.eql(u8, arg, "--legacy-file")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.legacy_file = argv[i];
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.interval_ms = try parseU32(argv[i]);
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            opts.daemon.format = try parseOutputFormat(argv[i]);
        } else {
            return error.InvalidArgument;
        }
    }
    if (opts.daemon.config_path.len == 0 and (opts.daemon.china_url == null or opts.daemon.foreign_url == null)) return error.InvalidArgument;
    return opts;
}

fn parseClientOptions(argv: []const [:0]u8) !struct { socket_path: []const u8, command: []const u8 } {
    var socket_path: []const u8 = "/tmp/status-tool.sock";
    var command: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--socket-path")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArgument;
            socket_path = argv[i];
        } else {
            command = arg;
        }
    }
    return .{
        .socket_path = socket_path,
        .command = command orelse return error.InvalidArgument,
    };
}

fn buildFancyssProbeSpecs(allocator: std.mem.Allocator, opts: DaemonOptions) ![]ProbeSpec {
    var list: std.ArrayList(ProbeSpec) = .empty;
    const china_url = opts.china_url orelse return error.InvalidArgument;
    const foreign_url = opts.foreign_url orelse return error.InvalidArgument;
    try list.append(allocator, .{
        .name = "china",
        .url = china_url,
        .family = .ipv4,
        .mode = .direct,
        .warmup = 0,
        .attempts = 1,
        .timeout_ms = 3000,
    });
    if (opts.proxy_ipv6) {
        try list.append(allocator, .{
            .name = "foreign4",
            .url = foreign_url,
            .family = .ipv4,
            .mode = .direct,
            .warmup = 1,
            .attempts = 2,
            .timeout_ms = 3000,
        });
        try list.append(allocator, .{
            .name = "foreign6",
            .url = foreign_url,
            .family = .ipv6,
            .mode = .direct,
            .warmup = 1,
            .attempts = 2,
            .timeout_ms = 3000,
        });
    } else {
        try list.append(allocator, .{
            .name = "foreign4",
            .url = foreign_url,
            .family = .ipv4,
            .mode = .socks5,
            .proxy = opts.foreign_proxy orelse "socks5://127.0.0.1:23456",
            .warmup = 1,
            .attempts = 2,
            .timeout_ms = 3000,
        });
    }
    return try list.toOwnedSlice(allocator);
}

fn resolveSpecsForDaemonLike(allocator: std.mem.Allocator, opts: DaemonOptions) !struct {
    specs: []const ProbeSpec,
    owned: ?[]ProbeSpec,
    state_file: ?[]const u8,
    legacy_file: ?[]const u8,
    format: OutputFormat,
    interval_ms: u32,
} {
    var cfg: ?ConfigFile = null;
    var owned_specs: ?[]ProbeSpec = null;
    if (opts.config_path.len != 0) {
        cfg = try readConfigFile(allocator, opts.config_path);
    } else {
        owned_specs = try buildFancyssProbeSpecs(allocator, opts);
    }

    const interval_ms = opts.interval_ms orelse if (cfg) |cfg_file| cfg_file.interval_ms orelse 5000 else 5000;
    const format = opts.format orelse if (cfg) |cfg_file| cfg_file.output orelse .json else .json;
    const state_file = opts.state_file orelse if (cfg) |cfg_file| cfg_file.state_file else null;
    const legacy_file = opts.legacy_file orelse if (cfg) |cfg_file| cfg_file.legacy_file else null;
    const specs = if (cfg) |cfg_file| cfg_file.probes else owned_specs.?;
    return .{
        .specs = specs,
        .owned = owned_specs,
        .state_file = state_file,
        .legacy_file = legacy_file,
        .format = format,
        .interval_ms = interval_ms,
    };
}

fn refreshServeCache(allocator: std.mem.Allocator, state: *ServeState) !void {
    const run_result = try runProbeList(allocator, state.specs);
    const legacy = try runResultToFancyssAlloc(allocator, run_result);
    if (state.state_file) |path| {
        try writeRunResultFile(allocator, path, state.format, run_result);
    }
    if (state.legacy_file) |path| {
        try writeBytesFile(allocator, path, legacy);
    }
    if (state.cached_fancyss) |old| state.cache_allocator.free(old);
    state.cached_fancyss = try state.cache_allocator.dupe(u8, legacy);
    const json_out = try runResultToJsonAlloc(allocator, run_result);
    if (state.cached_json) |old_json| state.cache_allocator.free(old_json);
    state.cached_json = try state.cache_allocator.dupe(u8, json_out);
}

fn handleServeCommand(allocator: std.mem.Allocator, state: *ServeState, command: []const u8) ![]const u8 {
    if (std.mem.eql(u8, command, "ping")) {
        return try allocator.dupe(u8, "pong\n");
    }
    if (std.mem.eql(u8, command, "get_cache")) {
        if (state.cached_fancyss) |cache| {
            return try std.fmt.allocPrint(allocator, "{s}\n", .{cache});
        }
        return try allocator.dupe(u8, "cache-miss\n");
    }
    if (std.mem.eql(u8, command, "probe_once")) {
        try refreshServeCache(allocator, state);
        if (state.cached_fancyss) |cache| {
            return try std.fmt.allocPrint(allocator, "{s}\n", .{cache});
        }
        return try allocator.dupe(u8, "cache-miss\n");
    }
    return try allocator.dupe(u8, "unknown-command\n");
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
    const resolved = try resolveSpecsForDaemonLike(allocator, opts);
    defer if (resolved.owned) |items| allocator.free(items);

    while (true) {
        {
            var cycle_arena_state = std.heap.ArenaAllocator.init(allocator);
            defer cycle_arena_state.deinit();
            const cycle_alloc = cycle_arena_state.allocator();
            const run_result = try runProbeList(cycle_alloc, resolved.specs);

            if (resolved.state_file) |path| {
                try writeRunResultFile(cycle_alloc, path, resolved.format, run_result);
            }
            if (resolved.legacy_file) |path| {
                const legacy = try runResultToFancyssAlloc(cycle_alloc, run_result);
                try writeBytesFile(cycle_alloc, path, legacy);
            }
            if (opts.stdout or opts.once) {
                const output = switch (resolved.format) {
                    .json => try runResultToJsonAlloc(cycle_alloc, run_result),
                    .text => try runResultToTextAlloc(cycle_alloc, run_result),
                };
                try std.fs.File.stdout().writeAll(output);
            }
            if (opts.once) return;
        }
        std.Thread.sleep(@as(u64, resolved.interval_ms) * std.time.ns_per_ms);
    }
}

fn runServeCommand(allocator: std.mem.Allocator, argv: []const [:0]u8) !void {
    const opts = try parseServeOptions(argv);
    const resolved = try resolveSpecsForDaemonLike(allocator, opts.daemon);
    defer if (resolved.owned) |items| allocator.free(items);

    if (opts.socket_path.len != 0) {
        std.fs.cwd().deleteFile(opts.socket_path) catch {};
    }

    var addr = try std.net.Address.initUnix(opts.socket_path);
    var server = try addr.listen(.{});
    defer {
        server.deinit();
        std.fs.cwd().deleteFile(opts.socket_path) catch {};
    }

    var state = ServeState{
        .cache_allocator = allocator,
        .specs = resolved.specs,
        .state_file = resolved.state_file,
        .legacy_file = resolved.legacy_file,
        .format = resolved.format,
    };

    while (true) {
        var conn = try server.accept();
        defer conn.stream.close();

        var read_buf: [256]u8 = undefined;
        const n = conn.stream.read(&read_buf) catch continue;
        if (n == 0) continue;
        const command = std.mem.trim(u8, read_buf[0..n], " \r\n\t");
        if (command.len == 0) continue;

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const response = handleServeCommand(arena, &state, command) catch |err| {
            _ = conn.stream.write("error: ") catch {};
            _ = conn.stream.write(@errorName(err)) catch {};
            _ = conn.stream.write("\n") catch {};
            continue;
        };
        conn.stream.writeAll(response) catch continue;
    }
}

fn runClientCommand(allocator: std.mem.Allocator, argv: []const [:0]u8) !void {
    const opts = try parseClientOptions(argv);
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

        stream.writeAll(opts.command) catch |err| {
            if (err == error.BrokenPipe and attempt == 0) {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        stream.writeAll("\n") catch |err| {
            if (err == error.BrokenPipe and attempt == 0) {
                std.Thread.sleep(200 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);
        var buf: [512]u8 = undefined;
        while (true) {
            const n = try stream.read(&buf);
            if (n == 0) break;
            try list.appendSlice(allocator, buf[0..n]);
        }
        const out = try list.toOwnedSlice(allocator);
        defer allocator.free(out);
        try std.fs.File.stdout().writeAll(out);
        return;
    }
}

fn runFancyssCommand(allocator: std.mem.Allocator, argv: []const [:0]u8) !void {
    const opts = try parseDaemonOptions(argv);
    var cfg: ?ConfigFile = null;
    var owned_specs: ?[]ProbeSpec = null;
    defer if (owned_specs) |items| allocator.free(items);

    if (opts.config_path.len != 0) {
        cfg = try readConfigFile(allocator, opts.config_path);
    } else {
        owned_specs = try buildFancyssProbeSpecs(allocator, opts);
    }

    const specs = if (cfg) |cfg_file| cfg_file.probes else owned_specs.?;
    const run_result = try runProbeList(allocator, specs);
    const output = try runResultToFancyssAlloc(allocator, run_result);
    defer allocator.free(output);
    try std.fs.File.stdout().writeAll(output);
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
    if (std.mem.eql(u8, cmd, "fancyss")) {
        try runFancyssCommand(gpa, argv[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "daemon")) {
        try runDaemonCommand(gpa, argv[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "serve")) {
        try runServeCommand(gpa, argv[2..]);
        return;
    }
    if (std.mem.eql(u8, cmd, "client")) {
        try runClientCommand(gpa, argv[2..]);
        return;
    }

    printUsage();
    return error.InvalidArgument;
}
