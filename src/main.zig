const std = @import("std");
pub const std_options = .{
    .log_level = .warn,
};

const config = struct {
    host: []const u8 = "localhost",
    port: u16 = 6005,
}{};
const Errors = error{
    NoContentLength,
    ReadBroken,
    PollingError,
};

const ByteArrayList = std.ArrayList(u8);
const StringList = std.ArrayList([]u8);
const RequestStream = std.io.FixedBufferStream([]const u8);
const Request = struct {
    const Self = @This();
    headers: StringList,
    data: ?[]u8,
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) Self {
        const headers = StringList.init(allocator);
        const data = null;
        return .{
            .headers = headers,
            .data = data,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: Self) void {
        for (self.headers.items) |header| {
            self.allocator.free(header);
        }
        self.headers.deinit();
        if (self.data) |data_present| {
            self.allocator.free(data_present);
        }
    }
    pub fn addHeader(self: *Self, header: []u8) !void {
        try self.headers.append(header);
    }

    pub fn setNewData(self: *Self, new_data: []u8) !void {
        if (self.data) |checked_data| {
            self.allocator.free(checked_data);
        }
        self.data = new_data;
    }

    pub fn log(self: Self, prefix: []const u8) void {
        if (self.data) |data| {
            std.log.info("{s}: length={d}\n", .{ prefix, data.len });
            if (data.len < 256) {
                std.log.info("content: {s}", .{data});
            }
            std.log.debug("content: {s}", .{data});
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const client_reader = std.io.getStdIn().reader().any();
    const client_writer = std.io.getStdOut().writer().any();

    const lsp_socket = try std.net.tcpConnectToHost(allocator, config.host, config.port);
    defer lsp_socket.close();

    const lsp_reader = lsp_socket.reader().any();
    const lsp_writer = lsp_socket.writer().any();

    const pfd_client = std.posix.pollfd{ .fd = std.io.getStdIn().handle, .events = std.posix.POLL.IN, .revents = undefined };
    const pfd_lsp = std.posix.pollfd{ .fd = lsp_socket.handle, .events = std.posix.POLL.IN, .revents = undefined };
    var fds = ([_]std.posix.pollfd{ pfd_lsp, pfd_client });
    while (true) {
        const res = try std.posix.poll(&fds, 1000);
        if (res < 0) {
            std.log.err("Something went wrong\n", .{});
            return Errors.PollingError;
        }
        if (res > 0) {
            if (fds[0].revents > 0) {
                if (!try handleLspResponse(allocator, lsp_reader, client_writer)) break;
            }
            if (fds[1].revents > 0) {
                if (!try handleClientRequest(allocator, client_reader, lsp_writer)) break;
            }
        }
        fds[0].revents = 0;
        fds[1].revents = 0;
    }
}
fn handleClientRequest(allocator: std.mem.Allocator, client_reader: std.io.AnyReader, lsp_writer: std.io.AnyWriter) !bool {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    std.log.info("ATTEMPT TO RECEIVE CLIENT MESSAGE", .{});
    const clientReqOpt = try readRequest(arena, client_reader);
    if (clientReqOpt != null) {
        var request: Request = clientReqOpt.?;
        request.log("CLIENT RAW REQUEST");
        if (request.data) |data| {
            const new_data = try convertLinuxToWindows(arena, data);
            try request.setNewData(new_data);
        }
        request.log("SENDING TO LSP");
        try writeRequest(request, lsp_writer);
    } else {
        std.log.warn("Cannot receive request from client\n", .{});
        return false;
    }
    return true;
}

fn handleLspResponse(allocator: std.mem.Allocator, lsp_reader: std.io.AnyReader, client_writer: std.io.AnyWriter) !bool {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    std.log.info("ATTEMPT TO RECEIVE LSP MESSAGE", .{});
    const lspResponseOpt = try readRequest(arena, lsp_reader);
    if (lspResponseOpt != null) {
        var request: Request = lspResponseOpt.?;
        request.log("LSP RAW RESPONSE");
        if (request.data) |data| {
            const new_data = try convertWindowsToLinux(arena, data);
            try request.setNewData(new_data);
        }
        request.log("SENDING TO CLIENT");
        try writeRequest(request, client_writer);
    } else {
        std.log.warn("Cannot receive response from LSP\n", .{});
        return false;
    }
    return true;
}

fn convertLinuxToWindows(arena: std.mem.Allocator, data: []u8) ![]u8 {
    var buffer = ByteArrayList.init(arena);
    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, data, start_index, "\"\\/mnt\\/")) |start| {
        if (std.mem.indexOfPos(u8, data, start + 1, "\"")) |end| {
            const intermediate_slice = data[start_index .. start + 1];
            const interesting_slice = data[start + 1 .. end + 1];
            try buffer.appendSlice(intermediate_slice);
            start_index = end + 1;

            var tokenizer = std.mem.tokenizeSequence(u8, interesting_slice, "\\/");
            _ = tokenizer.next(); // Skip /mnt part
            const drive_letter = tokenizer.next().?;
            const upper_letter = try std.ascii.allocUpperString(arena, drive_letter);
            try buffer.appendSlice(upper_letter);
            try buffer.append(':');
            while (tokenizer.next()) |part| {
                try buffer.append('/');
                try buffer.appendSlice(part);
            }
        }
    }
    try buffer.appendSlice(data[start_index..data.len]);
    const tmp_data = try buffer.toOwnedSlice();
    start_index = 0;
    while (std.mem.indexOfPos(u8, tmp_data, start_index, "\"file:\\/\\/\\/mnt\\/")) |start| {
        if (std.mem.indexOfPos(u8, tmp_data, start + 1, "\"")) |end| {
            const intermediate_slice = tmp_data[start_index .. start + 1];
            const interesting_slice = tmp_data[start + 1 .. end + 1];
            try buffer.appendSlice(intermediate_slice);
            start_index = end + 1;

            var tokenizer = std.mem.tokenizeSequence(u8, interesting_slice, "\\/");
            const file_part = tokenizer.next().?;
            try buffer.appendSlice(file_part);
            try buffer.appendSlice("///");
            _ = tokenizer.next(); // Skip /mnt part
            const drive_letter = tokenizer.next().?;
            const upper_letter = try std.ascii.allocUpperString(arena, drive_letter);
            try buffer.appendSlice(upper_letter);
            try buffer.append(':');
            while (tokenizer.next()) |part| {
                try buffer.append('/');
                try buffer.appendSlice(part);
            }
        }
    }
    try buffer.appendSlice(tmp_data[start_index..tmp_data.len]);
    return try buffer.toOwnedSlice();
}
fn convertWindowsToLinux(allocator: std.mem.Allocator, data: []u8) ![]u8 {
    var buffer = ByteArrayList.init(allocator);
    var splitIterator = std.mem.splitScalar(u8, data, '"');
    var first = true;
    while (splitIterator.next()) |part| {
        if (first) {
            first = false;
        } else {
            try buffer.append('"');
        }
        var step1_part: []const u8 = undefined;
        var is_file = false;
        if (std.mem.startsWith(u8, part, "file:///")) {
            try buffer.appendSlice("file://");
            step1_part = part[8..];
            is_file = true;
        } else {
            step1_part = part;
        }
        if (!is_file) {
            if (step1_part.len >= 3) {
                const has_letter = (step1_part[0] >= 'A') and (step1_part[0] <= 'Z');
                const has_path_pattern = (step1_part[1] == ':') and (step1_part[2] == '/');
                is_file = has_letter and has_path_pattern;
            }
        }
        if (!is_file) {
            try buffer.appendSlice(part);
            continue;
        }
        var tokenizer = std.mem.tokenizeSequence(u8, step1_part, ":");
        try buffer.appendSlice("/mnt/");
        const drive_letter = tokenizer.next().?[0];
        const lower_letter = std.ascii.toLower(drive_letter);
        try buffer.append(lower_letter);
        while (tokenizer.next()) |p| {
            try buffer.appendSlice(p);
        }
    }

    return try buffer.toOwnedSlice();
}

fn writeRequest(request: Request, writer: std.io.AnyWriter) !void {
    for (request.headers.items) |header| {
        try writer.print("{s}\r\n", .{header});
    }
    if (request.data) |data| {
        try writer.print("Content-Length: {d}\r\n\r\n", .{data.len});
        try writer.writeAll(data);
    } else {
        try writer.print("Content-Length: 0\r\n\r\n", .{});
    }
}

fn readRequest(arena: std.mem.Allocator, reader: std.io.AnyReader) !?Request {
    var request = Request.init(arena);
    var content_length: ?usize = null;
    while (true) {
        var buffer = ByteArrayList.init(arena);
        try reader.streamUntilDelimiter(buffer.writer(), '\n', null);
        const rawData = try buffer.toOwnedSlice();
        const trimData = std.mem.trim(u8, rawData, &std.ascii.whitespace);
        const data = try arena.dupe(u8, trimData);
        if (data.len == 0) {
            break;
        }
        if (std.ascii.startsWithIgnoreCase(data, "Content-Length:")) {
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, data[15..], &std.ascii.whitespace), 10);
        } else {
            try request.addHeader(data);
        }
    }
    if (content_length == null) {
        return Errors.NoContentLength;
    }
    const length = content_length.?;
    const data = try arena.alloc(u8, length);
    const size = try reader.readAtLeast(data, length);
    request.data = data;
    if (size < length) {
        return Errors.ReadBroken;
    }
    return request;
}

test "Simple Request Reading" {
    const allocator = std.testing.allocator;
    const requestData = "Content-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"qwerty\": \"something\"}";
    var requestStream = RequestStream{ .buffer = requestData, .pos = 0 };
    const requestReader = requestStream.reader().any();
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const maybeRequest = try readRequest(arena, requestReader);
    const request = maybeRequest.?;
    try std.testing.expectEqual(1, request.headers.items.len);
    try std.testing.expectEqual(23, request.data.?.len);
    try std.testing.expectEqualStrings("{\"qwerty\": \"something\"}", request.data.?);
}

test "Simple Linux to Windows Paths/Uri Conversion" {
    const allocator = std.testing.allocator;
    const data = "{\"file\": \"\\/mnt\\/c\\/Users\\/test\\/projects\\/godot\\/test_project\\/\", \"uri\": \"file:\\/\\/\\/mnt\\/c\\/Users\\/test\\/projects\\/godot\\/test_project\\/character.gd\"}";
    const expected_data = "{\"file\": \"C:/Users/test/projects/godot/test_project/\", \"uri\": \"file:///C:/Users/test/projects/godot/test_project/character.gd\"}";
    const request_data = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ data.len, data });
    const response_data = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ expected_data.len, expected_data });
    var request_stream = RequestStream{ .buffer = request_data, .pos = 0 };
    const request_reader = request_stream.reader().any();
    var response_buffer = ByteArrayList.init(allocator);
    defer response_buffer.deinit();
    const response_writer = response_buffer.writer().any();
    const res = try handleClientRequest(allocator, request_reader, response_writer);
    try std.testing.expect(res);
    const actual_data = try response_buffer.toOwnedSlice();
    defer allocator.free(actual_data);
    try std.testing.expectEqualStrings(response_data, actual_data);
}

test "Simple Windows to Linux Paths/Uri Conversion" {
    const allocator = std.testing.allocator;
    const data = "{\"file\": \"C:/Users/test/projects/godot/test_project/\", \"uri\": \"file:///C:/Users/test/projects/godot/test_project/character.gd\"}";
    const expected_data = "{\"file\": \"/mnt/c/Users/test/projects/godot/test_project/\", \"uri\": \"file:///mnt/c/Users/test/projects/godot/test_project/character.gd\"}";
    const request_data = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ data.len, data });
    const response_data = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ expected_data.len, expected_data });
    var request_stream = RequestStream{ .buffer = request_data, .pos = 0 };
    const request_reader = request_stream.reader().any();
    var response_buffer = ByteArrayList.init(allocator);
    defer response_buffer.deinit();
    const response_writer = response_buffer.writer().any();
    const res = try handleLspResponse(allocator, request_reader, response_writer);
    try std.testing.expect(res);
    const actual_data = try response_buffer.toOwnedSlice();
    defer allocator.free(actual_data);
    try std.testing.expectEqualStrings(response_data, actual_data);
}
