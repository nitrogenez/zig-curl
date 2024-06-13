const std = @import("std");
const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("curl/curl.h");
    @cInclude("string.h");
});

pub const Callback = *const fn ([]const u8) anyerror!usize;
pub const FnType = *const fn ([:0]const u8, usize, usize, *Context) usize;
pub const Headers = std.StringHashMapUnmanaged([]const u8);

pub const Response = struct {
    gpa: std.mem.Allocator,
    status: f64 = 0,
    headers: Headers = .{},

    pub fn deinit(self: *Response) void {
        var it = self.headers.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr);
            self.gpa.free(kv.value_ptr);
        }
        self.headers.deinit(self.gpa);
    }
};

pub const Context = struct {
    handle: ?*c.CURL,
    response: Response,
    callback: ?Callback,
};

pub const Request = struct {
    gpa: std.mem.Allocator,
    callback: ?Callback = null,
    headers: ?*Headers = null,
    body: ?[]const u8 = null,
    timeout: i32 = -1,
    ssl_verify: bool = true,
    cainfo: union(enum) { none, data: []const u8 } = .none,
    response: ?*Response = null,
};

fn header(ptr: [:0]const u8, size: usize, nmemb: usize, ctx: *Context) callconv(.C) usize {
    const bytes = size * nmemb;
    const data = ptr[0..bytes];

    if (ctx.response.status == 0) _ = c.curl_easy_getinfo(ctx.handle, c.CURLINFO_RESPONSE_CODE, &ctx.response.status);

    for (data, 0..) |j, i| {
        if (j == ':') {
            var split = std.mem.splitScalar(u8, data[i..], ' ');
            const gpa = ctx.response.gpa;
            const name = split.first();
            const value = split.next() orelse @panic("Invalid header format received");
            ctx.response.headers.put(gpa, gpa.dupe(u8, name) catch @panic("OOM"), gpa.dupe(u8, value) catch @panic("OOM"));
            break;
        }
    }
    return bytes;
}

fn write(ptr: [:0]const u8, size: usize, nmemb: usize, ctx: *Context) callconv(.C) usize {
    return ctx.callback.?(ptr[0 .. size * nmemb]) catch 0;
}

pub fn setOptLong(handle: *c.CURL, opt: i32, value: f64) void {
    _ = c.curl_easy_setopt(handle, @intCast(opt), @as(c_long, value));
}

pub fn setOptStr(handle: *c.CURL, opt: i32, value: [:0]const u8) void {
    _ = c.curl_easy_setopt(handle, @intCast(opt), @as([*c]const u8, @ptrCast(value.ptr)));
}

pub fn setOptFn(handle: *c.CURL, opt: i32, value: FnType) void {
    _ = c.curl_easy_setopt(handle, @intCast(opt), value);
}

pub fn setOptAny(handle: *c.CURL, opt: i32, value: *const anyopaque) void {
    _ = c.curl_easy_setopt(handle, @intCast(opt), value);
}

pub fn send(method: std.http.Method, url: []const u8, request: Request) !u32 {
    const handle = c.curl_easy_init() orelse return error.CurlInitError;
    defer c.curl_easy_cleanup(handle);

    switch (method) {
        .POST => setOptLong(handle, c.CURLOPT_POST, 1),
        else => {},
    }

    if (request.ssl_verify) setOptLong(handle, c.CURLOPT_SSL_VERIFYPEER, 1);
    if (request.timeout >= 0) setOptLong(handle, c.CURLOPT_TIMEOUT, 1);

    switch (request.cainfo) {
        .none => setOptLong(handle, c.CURLOPT_CAINFO, 0),
        .data => |data| setOptStr(handle, c.CURLOPT_CAINFO, data),
    }

    var ctx = Context{
        .response = .{ .gpa = request.gpa },
        .handle = handle,
        .callback = request.callback,
    };
    defer {
        if (request.response == null) {
            var it = ctx.response.headers.iterator();
            while (it.next()) |kv| {
                request.gpa.free(kv.key_ptr);
                request.gpa.free(kv.value_ptr);
            }
            ctx.response.headers.deinit(request.gpa);
        } else {
            request.response.?.* = ctx.response;
        }
    }

    setOptStr(handle, c.CURLOPT_URL, url);
    setOptLong(handle, c.CURLOPT_FOLLOWLOCATION, 1);
    setOptFn(handle, c.CURLOPT_HEADERFUNCTION, &header);
    setOptAny(handle, c.CURLOPT_HEADERDATA, &ctx);

    if (request.callback) |_| {
        setOptFn(handle, c.CURLOPT_WRITEFUNCTION, &write);
        setOptAny(handle, c.CURLOPT_WRITEDATA, &ctx);
    }

    if (request.headers) |headers| {
        var header_list: *c.curl_slist = undefined;
        defer c.curl_slist_free_all(header_list);

        var it = headers.iterator();

        while (it.next()) |kv| {
            var bytes = std.ArrayList(u8).init(request.gpa);
            try bytes.writer().print("{s}: {s}", .{ kv.key_ptr, kv.value_ptr });
            header_list = c.curl_slist_append(header_list, @as([*c]const u8, @ptrCast(bytes.items.ptr)));
            bytes.deinit();
        }
        setOptAny(handle, c.CURLOPT_HTTPHEADER, header_list);
    }

    if (request.body) |body| {
        setOptLong(handle, c.CURLOPT_POST, 1);
        setOptStr(handle, c.CURLOPT_POSTFIELDS, body);
    }
    return @intCast(c.curl_easy_perform(handle));
}
