# conduit-z

A Zig library for efficient data streaming with automatic memory management and file system fallback.

## Overview

conduit-z provides a flexible `Object` type that can store and stream data efficiently, automatically switching between in-memory and file system storage based on size constraints. It's designed for scenarios where you need to handle data of varying sizes without knowing the final size upfront.

## Features

- **Automatic Storage Management**: Starts with in-memory storage and automatically falls back to temporary files when size limits are exceeded
- **Stream Interface**: Provides both reader and writer interfaces compatible with Zig's standard I/O
- **MD5 Hashing**: Built-in MD5 hash computation during read/write operations
- **Memory Efficient**: Configurable memory limits and dynamic growth

## Installation

Add conduit-z to your project:

```bash
zig fetch --save git+https://github.com/byterix-labs/conduit-z.git
```

Then in your `build.zig`:

```zig
const conduit = b.dependency("conduit", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("conduit", conduit.module("conduit"));
```

## Usage

### Basic Usage

```zig
const std = @import("std");
const conduit = @import("conduit");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create an object with default settings
    var object = try conduit.Object.init(allocator, .{});
    defer object.deinit();

    // Write data
    var writer = try object.writer();
    try writer.writeAll("Hello, world!");

    // Read data back
    var reader = try object.reader();
    var buffer: [13]u8 = undefined;
    _ = try reader.readAll(&buffer);

    std.debug.print("Data: {s}\n", .{buffer});
}
```

### Initialize from Buffer

```zig
const data = "Hello, world!";
var object = try conduit.Object.initBuffer(allocator, data);
defer object.deinit();

// Read the data
const result = try object.toOwnedSlice(allocator);
defer allocator.free(result);
```

### Custom Configuration

```zig
var object = try conduit.Object.init(allocator, .{
    .initial_capacity = 4096,        // Start with 4KB capacity
    .in_memory_limit = 1024 * 1024,  // Switch to file after 1MB
});
defer object.deinit();
```

### MD5 Hashing

```zig
var object = try conduit.Object.init(allocator, .{});
defer object.deinit();

// Write some data
var writer = try object.writer();
try writer.writeAll("Hello, world!");

// Get MD5 hash
const hash = try object.md5HashOwned(allocator);
defer allocator.free(hash);
```

## API Reference

### Object

The main type that manages data storage and streaming.

#### Creation

- `init(allocator, options)` - Create a new object with specified options
- `initBuffer(allocator, buffer)` - Create an object initialized with existing data

#### Options

```zig
pub const ObjectOptions = struct {
    initial_capacity: usize = 1024,           // Initial buffer size
    in_memory_limit: usize = 1024 * 1024 * 1024, // 1GB default limit
};
```

#### Methods

- `deinit()` - Clean up resources
- `writer()` - Get a writer interface
- `reader()` - Get a reader interface
- `toOwnedSlice(allocator)` - Get all data as an owned slice
- `md5HashOwned(allocator)` - Get MD5 hash of the data

## Storage Modes

conduit-z automatically manages two storage modes:

1. **In-Memory Mode**: Fast access using dynamic arrays
2. **File System Mode**: Uses temporary files for large data

The library automatically transitions from in-memory to file system storage when:
- Initial capacity exceeds the in-memory limit, or
- Data growth exceeds the in-memory limit during writing

## Requirements

- Zig 0.14.1 or later
- [temp.zig](https://github.com/abhinav/temp.zig) dependency (automatically managed)

## Development

### Building

```bash
zig build
```

### Testing

```bash
zig build test
```

### Tools

This project uses:
- `zig` 0.14.1
- `zls` 0.14.0 (Zig Language Server)
- `pre-commit` for code quality
- `zlint` for additional linting

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Please ensure all tests pass and follow the existing code style.
