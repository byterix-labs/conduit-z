//! conduit-z: A Zig library for efficient data streaming with automatic storage management.
//!
//! This library provides a flexible Object type that automatically manages data storage,
//! seamlessly transitioning between in-memory and file system storage based on size
//! constraints. It's designed for scenarios where you need to handle data of varying
//! sizes without knowing the final size upfront.
//!
//! Example usage:
//! ```zig
//! var object = try conduit.Object.init(allocator, .{});
//! defer object.deinit();
//!
//! var writer = try object.writer();
//! try writer.writeAll("Hello, world!");
//!
//! var reader = try object.reader();
//! var buffer: [13]u8 = undefined;
//! _ = try reader.readAll(&buffer);
//! ```

const std = @import("std");

/// The main Object type that provides efficient data streaming with automatic storage management.
pub const Object = @import("Object.zig");

/// Configuration options for creating Object instances.
pub const ObjectOptions = Object.ObjectOptions;

test {
    std.testing.refAllDeclsRecursive(@This());
}
