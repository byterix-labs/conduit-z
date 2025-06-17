const std = @import("std");

pub const Object = @import("Object.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
