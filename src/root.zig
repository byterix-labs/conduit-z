const std = @import("std");

pub const Object = @import("Object.zig");
pub const ObjectOptions = Object.ObjectOptions;

test {
    std.testing.refAllDeclsRecursive(@This());
}
