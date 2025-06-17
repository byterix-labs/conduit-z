//! Object provides efficient data streaming with automatic storage management.
//!
//! This module implements a flexible data container that automatically switches
//! between in-memory and file system storage based on size constraints. It's
//! designed for scenarios where you need to handle data of varying sizes without
//! knowing the final size upfront.
//!
//! Key features:
//! - Automatic transition from memory to temporary files when size limits are exceeded
//! - Standard reader/writer interfaces compatible with Zig's I/O system
//! - Built-in MD5 hash computation during data operations
//! - Configurable memory limits and dynamic growth
//! - Efficient handling of both small and large data sets

const std = @import("std");
const Md5 = std.crypto.hash.Md5;
const TempFile = @import("temp").TempFile;

const Allocator = std.mem.Allocator;
const AnyReader = std.io.AnyReader;
const AnyWriter = std.io.AnyWriter;
const File = std.fs.File;
const Object = @This();

const logger = std.log.scoped(.ConduitObject);

const DEFAULT_IN_MEMORY_LIMIT: usize = 1024 * 1024 * 1024;
const DEFAULT_CAPACITY: usize = 1024;

const Mode = enum {
    inMemory,
    fileSystem,
};

const InMemoryStore = struct {
    data: std.ArrayListUnmanaged(u8),
    pos: usize = 0,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.data.deinit(allocator);
    }
};

const FileSystem = struct {
    temp_file: TempFile,
    file: ?File = null,

    pub fn deinit(self: *@This()) void {
        self.temp_file.deinit();

        if (self.file) |file| {
            file.close();
        }
    }
};

allocator: Allocator,
len: usize = 0,
capacity: usize = DEFAULT_CAPACITY,
in_memory_limit: usize = DEFAULT_IN_MEMORY_LIMIT,
mode: Mode,
data: *anyopaque,
md5: Md5,

pub const ObjectOptions = struct {
    initial_capacity: usize = DEFAULT_CAPACITY,
    in_memory_limit: usize = DEFAULT_IN_MEMORY_LIMIT,
};

/// Creates a new Object with the specified options.
///
/// The Object will start in memory mode if the initial capacity is within the memory limit,
/// otherwise it will start in file system mode using a temporary file.
///
/// Args:
///   - allocator: The allocator to use for memory management
///   - options: Configuration options for the Object
///
/// Returns:
///   A new Object instance
///
/// Errors:
///   Returns an error if memory allocation fails or temporary file creation fails
pub fn init(allocator: Allocator, options: ObjectOptions) !Object {
    const in_memory_limit = options.in_memory_limit;
    const mode: Mode = if (options.initial_capacity <= in_memory_limit) .inMemory else .fileSystem;

    const data: *anyopaque = switch (mode) {
        .fileSystem => @ptrCast(try createFileSystem(allocator)),
        .inMemory => @ptrCast(try createInMemoryStore(allocator, options.initial_capacity)),
    };

    return Object{
        .allocator = allocator,
        .capacity = options.initial_capacity,
        .in_memory_limit = in_memory_limit,
        .mode = mode,
        .data = data,
        .md5 = Md5.init(.{}),
    };
}

/// Creates a new Object initialized with data from the provided buffer.
///
/// The buffer contents are copied into the Object's internal storage. The Object
/// will always start in memory mode regardless of buffer size.
///
/// Args:
///   - allocator: The allocator to use for memory management
///   - buffer: The initial data to copy into the Object
///
/// Returns:
///   A new Object instance containing a copy of the buffer data
///
/// Errors:
///   Returns an error if memory allocation fails
pub fn initBuffer(allocator: Allocator, buffer: []const u8) !Object {
    const in_memory_store = try createInMemoryStore(allocator, buffer.len);
    try in_memory_store.data.appendSlice(allocator, buffer);

    return Object{
        .allocator = allocator,
        .len = buffer.len,
        .capacity = in_memory_store.data.capacity,
        .mode = .inMemory,
        .data = @ptrCast(in_memory_store),
        .md5 = Md5.init(.{}),
    };
}

/// Cleans up all resources used by the Object.
///
/// This method must be called to properly free memory and close any temporary files.
/// After calling deinit, the Object should not be used again.
pub fn deinit(self: *Object) void {
    switch (self.mode) {
        .inMemory => {
            const in_memory_store = self.getInMemoryStore();
            in_memory_store.deinit(self.allocator);
            self.allocator.destroy(in_memory_store);
        },
        .fileSystem => {
            var fs = self.getFileSystem();
            fs.deinit();
            self.allocator.destroy(fs);
        },
    }
}

fn getInMemoryStore(self: *Object) *InMemoryStore {
    return @ptrCast(@alignCast(self.data));
}

fn getFileSystem(self: *Object) *FileSystem {
    return @ptrCast(@alignCast(self.data));
}

fn createInMemoryStore(allocator: Allocator, len: usize) !*InMemoryStore {
    const in_memory_store = try allocator.create(InMemoryStore);

    in_memory_store.* = .{
        .data = try std.ArrayListUnmanaged(u8).initCapacity(allocator, len),
    };

    return in_memory_store;
}

fn createFileSystem(allocator: Allocator) !*FileSystem {
    const fs = try allocator.create(FileSystem);
    fs.* = .{
        .temp_file = try TempFile.create(allocator, .{}),
    };

    return fs;
}

fn readInMemory(ctx: *const anyopaque, dest: []u8) anyerror!usize {
    const self: *Object = @constCast(@ptrCast(@alignCast(ctx)));
    var in_memory_store = self.getInMemoryStore();

    const buffer = in_memory_store.data.items;
    const pos = in_memory_store.pos;
    const size = @min(dest.len, buffer.len - pos);
    const end = pos + size;

    @memcpy(dest[0..size], buffer[pos..end]);
    in_memory_store.pos = end;

    return size;
}

fn writeInMemory(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
    const self: *Object = @constCast(@ptrCast(@alignCast(ctx)));
    var in_memory_store = self.getInMemoryStore();

    const new_len: usize = in_memory_store.pos + bytes.len;
    if (new_len > self.capacity) {
        try self.grow(new_len);

        if (self.mode == .fileSystem) {
            return writeFile(ctx, bytes);
        }
    }

    if (bytes.len == 0) return 0;

    try in_memory_store.data.appendSlice(self.allocator, bytes);
    in_memory_store.pos = new_len;

    self.len += bytes.len;

    return bytes.len;
}

fn readFile(ctx: *const anyopaque, dest: []u8) anyerror!usize {
    const self: *Object = @constCast(@ptrCast(@alignCast(ctx)));
    var fs = self.getFileSystem();

    if (fs.file == null) {
        fs.file = try fs.temp_file.open(.{ .mode = .read_write });
    }

    return fs.file.?.read(dest);
}

fn writeFile(ctx: *const anyopaque, src: []const u8) anyerror!usize {
    const self: *Object = @constCast(@ptrCast(@alignCast(ctx)));
    var fs = self.getFileSystem();

    if (fs.file == null) {
        fs.file = try fs.temp_file.open(.{ .mode = .read_write });
    }

    const bytes_written = try fs.file.?.write(src);

    self.len += bytes_written;

    return bytes_written;
}

fn write(ctx: *const anyopaque, src: []const u8) anyerror!usize {
    const self: *Object = @constCast(@ptrCast(@alignCast(ctx)));

    self.md5.update(src);

    return switch (self.mode) {
        .fileSystem => writeFile(ctx, src),
        .inMemory => writeInMemory(ctx, src),
    };
}

fn read(ctx: *const anyopaque, dest: []u8) anyerror!usize {
    const self: *Object = @constCast(@ptrCast(@alignCast(ctx)));

    const bytes_read = try switch (self.mode) {
        .fileSystem => readFile(ctx, dest),
        .inMemory => readInMemory(ctx, dest),
    };

    self.md5.update(dest[0..bytes_read]);

    return bytes_read;
}

fn resetStream(self: *Object) !void {
    self.md5 = Md5.init(.{});

    switch (self.mode) {
        .inMemory => {
            var in_memory_stream = self.getInMemoryStore();
            in_memory_stream.pos = 0;
        },
        .fileSystem => {
            const fs = self.getFileSystem();

            if (fs.file) |file| {
                try file.seekTo(0);
            }
        },
    }
}

/// Returns a reader interface for reading data from the Object.
///
/// The reader will start from the beginning of the data. Each call to reader()
/// resets the read position to the start and reinitializes the MD5 hash state.
///
/// Returns:
///   An AnyReader that can be used to read data from the Object
///
/// Errors:
///   Returns an error if the stream cannot be reset (e.g., file seek fails)
pub fn reader(self: *Object) !AnyReader {
    try self.resetStream();

    return AnyReader{
        .context = @ptrCast(self),
        .readFn = read,
    };
}

/// Returns a writer interface for writing data to the Object.
///
/// The writer will start from the beginning, overwriting any existing data.
/// Each call to writer() resets the write position to the start and reinitializes the MD5 hash state.
///
/// Returns:
///   An AnyWriter that can be used to write data to the Object
///
/// Errors:
///   Returns an error if the stream cannot be reset (e.g., file seek fails)
pub fn writer(self: *Object) !AnyWriter {
    try self.resetStream();

    return AnyWriter{
        .context = @ptrCast(self),
        .writeFn = write,
    };
}

/// Returns all data in the Object as an owned slice.
///
/// This method allocates a new buffer and copies all data from the Object into it.
/// The caller is responsible for freeing the returned slice.
///
/// Args:
///   - allocator: The allocator to use for the returned slice
///
/// Returns:
///   An owned slice containing a copy of all data in the Object
///
/// Errors:
///   Returns an error if memory allocation fails or reading fails
pub fn toOwnedSlice(self: *Object, allocator: Allocator) ![]const u8 {
    var rdr = try self.reader();
    const buffer = try allocator.alloc(u8, self.len);
    _ = try rdr.readAll(buffer);
    return buffer;
}

/// Grows the Object's capacity to accommodate at least the specified size.
///
/// If the Object is in memory mode and the new size exceeds the memory limit,
/// it will automatically transition to file system mode by copying existing
/// data to a temporary file. If already in file system mode, this method
/// logs a warning and returns without action.
///
/// Args:
///   - new_min_size: The minimum capacity required
///
/// Errors:
///   Returns an error if memory allocation or file operations fail
pub fn grow(self: *Object, new_min_size: usize) !void {
    if (self.mode == .fileSystem) {
        logger.warn("Can't grow Object in fileSystem mode.", .{});
        return;
    }

    std.debug.assert(new_min_size > self.capacity);

    var in_memory_store = self.getInMemoryStore();
    const current_pos = in_memory_store.pos;

    if (new_min_size > self.in_memory_limit) {
        var fs = try createFileSystem(self.allocator);
        fs.file = try fs.temp_file.open(.{ .mode = .read_write });

        // copy current buffer to file
        try fs.file.?.writeAll(in_memory_store.data.items[0..self.len]);

        in_memory_store.deinit(self.allocator);
        self.allocator.destroy(in_memory_store);

        self.data = @ptrCast(fs);
        self.mode = .fileSystem;

        return;
    }

    self.capacity = @min(
        try std.math.ceilPowerOfTwo(usize, new_min_size),
        self.in_memory_limit,
    );

    try in_memory_store.data.ensureTotalCapacityPrecise(self.allocator, self.capacity);
    in_memory_store.pos = current_pos;
}

/// Returns the MD5 hash of all data that has been read from or written to the Object.
///
/// The hash is computed incrementally as data flows through the Object's reader/writer
/// interfaces. This method allocates a new buffer for the hash bytes.
/// The caller is responsible for freeing the returned slice.
///
/// Args:
///   - allocator: The allocator to use for the returned hash buffer
///
/// Returns:
///   An owned slice containing the 16-byte MD5 hash
///
/// Errors:
///   Returns an error if memory allocation fails
pub fn md5HashOwned(self: Object, allocator: Allocator) ![]const u8 {
    const buffer = try allocator.alloc(u8, Md5.digest_length);

    var md5 = self.md5;
    md5.final(buffer[0..Md5.digest_length]);

    return buffer;
}

const testing = std.testing;

test "init from buffer" {
    const in_buffer = "Hello, world!";

    var object = try Object.initBuffer(testing.allocator, in_buffer[0..]);
    defer object.deinit();

    var out_buffer: [in_buffer.len]u8 = undefined;
    var rdr = try object.reader();
    _ = try rdr.readAll(&out_buffer);

    try testing.expectEqualStrings(in_buffer, &out_buffer);
}

test "write to buffer" {
    const in_buffer = "Hello, world";

    var object = try Object.init(testing.allocator, .{ .initial_capacity = in_buffer.len });
    defer object.deinit();

    var wtr = try object.writer();
    _ = try wtr.writeAll(in_buffer[0..]);

    const out_buffer = try object.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(out_buffer);

    try testing.expectEqualStrings(in_buffer, out_buffer);
}

test "write to file" {
    const len: usize = 1024;

    var object = try Object.init(testing.allocator, .{ .initial_capacity = len, .in_memory_limit = 512 });
    defer object.deinit();

    var buf: [len]u8 = undefined;
    std.crypto.random.bytes(&buf);

    var counting_writer = std.io.countingWriter(try object.writer());

    var wtr = counting_writer.writer().any();
    try wtr.writeAll(&buf);

    try testing.expectEqual(counting_writer.bytes_written, len);

    const out_buffer = try object.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(out_buffer);

    try testing.expectEqualSlices(u8, buf[0..], out_buffer);
}

test "dynamic growth" {
    var object = try Object.init(testing.allocator, .{ .initial_capacity = 64, .in_memory_limit = 1024 });
    defer object.deinit();

    var wtr = try object.writer();

    // Write beyond initial capacity
    const data = try testing.allocator.alloc(u8, 512);
    defer testing.allocator.free(data);
    @memset(data, 'A');

    try wtr.writeAll(data);

    // Verify data
    const result = try object.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqual(result.len, 512);
    try testing.expectEqualSlices(u8, data, result);
    try testing.expectEqual(.inMemory, object.mode);

    // Grow beyond in-memory limit
    try wtr.writeAll(data);
    try wtr.writeAll(data);

    try testing.expectEqual(data.len * 3, object.len);
    try testing.expectEqual(.fileSystem, object.mode);
}

test "md5 hash" {
    var object = try Object.init(testing.allocator, .{});
    defer object.deinit();

    var wtr = try object.writer();

    const data = try testing.allocator.alloc(u8, 512);
    defer testing.allocator.free(data);
    @memset(data, 'A');

    try wtr.writeAll(data);

    // Verify data
    const result = try object.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(result);

    const hash = try object.md5HashOwned(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqual(hash.len, Md5.digest_length);

    var actual_hash: [16]u8 = undefined;
    Md5.hash(result, &actual_hash, .{});

    try testing.expectEqualSlices(u8, &actual_hash, hash);
}
