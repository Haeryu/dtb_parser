// reference
// https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html

const std = @import("std");
const FDT = @import("fdt.zig").FDT;

pub const DTBConfig = struct {
    max_nodes: u32 = 512,
    max_roots: u32 = 32,
    max_properties: u32 = 4096,
    max_childs_per_node: u32 = 32,
    max_properties_per_node: u32 = 512,

    max_name_len: u32 = 32,
    max_property_name_len: u32 = 32,
};

pub const DTBError = error{
    OOM,
    // OutOfLoopBound,
};

pub fn DTB(comptime config: DTBConfig) type {
    inline for (@typeInfo(DTBConfig).@"struct".fields) |field| {
        const field_val = @field(config, field.name);
        const FieldType = @FieldType(DTBConfig, field.name);

        if (@typeInfo(FieldType) == .int) {
            comptime std.debug.assert(field_val < std.math.maxInt(FieldType));
        }
    }

    comptime std.debug.assert(config.max_roots <= config.max_nodes);

    return struct {
        raw_bytes: []const u8,

        properties: [config.max_properties]Property,
        properties_len: u32,

        nodes: [config.max_nodes]Node,
        nodes_len: u32,

        root_indices: [config.max_roots]u32,
        root_indices_len: u32,

        const DTBType = @This();

        pub const Node = struct {
            name: []const u8,

            parent_index: ?u32,

            child_indices: [config.max_childs_per_node]u32,
            child_indices_len: u32,

            property_indices: [config.max_properties_per_node]u32,
            property_indices_len: u32,

            pub fn init(self: *Node, name: []const u8, parent_index: ?u32) void {
                self.name = name;
                self.parent_index = parent_index;
                self.child_indices_len = 0;
                self.property_indices_len = 0;
            }

            pub fn createChildIndex(self: *Node) DTBError!*u32 {
                return try createUndefinedItemInFixedArray(
                    "child_indices",
                    "child_indices_len",
                    self,
                );
            }

            pub fn createEnsureChildIndex(self: *Node) *u32 {
                return createEnsureUndefinedItemInFixedArray(
                    "child_indices",
                    "child_indices_len",
                    self,
                );
            }

            pub fn createPropertyIndex(self: *Node) DTBError!*u32 {
                return try createUndefinedItemInFixedArray(
                    "property_indices",
                    "property_indices_len",
                    self,
                );
            }

            pub fn createEnsurePropertyIndex(self: *Node) *u32 {
                return createEnsureUndefinedItemInFixedArray(
                    "property_indices",
                    "property_indices_len",
                    self,
                );
            }
        };

        pub const Property = struct {
            name: []const u8,
            val: []const u8,
        };

        pub fn init(self: *DTBType, raw_bytes: []const u8) void {
            self.raw_bytes = raw_bytes;
            self.nodes_len = 0;
            self.properties_len = 0;
            self.root_indices_len = 0;

            // poison
            if (@import("builtin").mode == .Debug) {
                @memset(&self.nodes, undefined);
                @memset(&self.properties, undefined);
                @memset(&self.root_indices, undefined);
            }
        }

        pub fn reset(self: *DTBType, raw_bytes: []const u8) void {
            self.init(raw_bytes);
        }

        pub fn parse(self: *DTBType) (DTBError || FDT.Error)!void {
            var header_index: u32 = 0;
            while (@as(usize, @intCast(header_index)) < self.raw_bytes.len) {
                const fdt_header =
                    try FDT.Header.fromBytes(self.raw_bytes[@intCast(header_index)..]);

                const remaining_size = self.raw_bytes.len - header_index;
                if (remaining_size < fdt_header.readTotalsize()) {
                    return FDT.Error.Truncated;
                }

                if (fdt_header.readVersion() != 17 or fdt_header.readLastCompVersion() != 16) {
                    return FDT.Error.UnsupportedVersion;
                }

                const dt_struct_size = fdt_header.readSizeDtStruct();

                const structure_block_start = fdt_header.readOffDtStruct();
                const structure_block_end = structure_block_start + dt_struct_size;

                if (structure_block_end > fdt_header.readTotalsize()) {
                    return FDT.Error.Truncated;
                }

                const structure_block =
                    self.raw_bytes[@intCast(structure_block_start)..@intCast(structure_block_end)];

                const strings_block_start = fdt_header.readOffDtStrings();
                const strings_block_end = strings_block_start + fdt_header.readSizeDtStrings();

                if (strings_block_end > fdt_header.readTotalsize()) {
                    return FDT.Error.Truncated;
                }

                const strings_block =
                    self.raw_bytes[@intCast(strings_block_start)..@intCast(strings_block_end)];

                var current_token_offset: u32 = 0;
                var current_node_index: ?u32 = null;
                while (current_token_offset < dt_struct_size) {
                    current_token_offset = std.mem.alignForward(u32, current_token_offset, 4);
                    if (current_token_offset + @sizeOf(FDT.Token) > dt_struct_size) {
                        return FDT.Error.Truncated;
                    }
                    const token_raw = std.mem.readInt(
                        u32,
                        structure_block[@intCast(current_token_offset)..][0..4],
                        .big,
                    );
                    const token = std.enums.fromInt(FDT.Token, token_raw) orelse
                        return FDT.Error.UnknownToken;

                    switch (token) {
                        .begin_node => {
                            const name_start_offset = current_token_offset + @sizeOf(FDT.Token);
                            if (name_start_offset >= dt_struct_size) {
                                return FDT.Error.Truncated;
                            }

                            const name_slice = structure_block[name_start_offset..];
                            const name: []const u8 =
                                loop: for (0..@min(
                                    name_slice.len,
                                    @as(usize, config.max_name_len),
                                )) |i| {
                                    if (name_slice[i] == 0) {
                                        break :loop name_slice[0..i];
                                    }
                                } else return FDT.Error.NonNullTerminatedName;

                            if (name.len == 0 and current_node_index != null) {
                                return FDT.Error.EmptyNodeName;
                            }

                            const parent_node_index = current_node_index;

                            const new_node_index = self.nodes_len;
                            const new_node = try self.createNode();
                            new_node.init(name, parent_node_index);

                            if (parent_node_index) |par_idx| {
                                const parent_node = &self.nodes[@intCast(par_idx)];
                                (try parent_node.createChildIndex()).* = new_node_index;
                            } else {
                                (try self.createRootIndices()).* = new_node_index;
                            }

                            // push node
                            current_node_index = new_node_index;

                            const name_size: u32 = @intCast(name.len + 1);
                            // | token | nul terminated c string | next ..
                            current_token_offset +=
                                @sizeOf(FDT.Token) + std.mem.alignForward(u32, name_size, 4);
                        },
                        .end_node => {
                            if (current_node_index == null) {
                                return FDT.Error.UnendedNodeExist;
                            }
                            const current_node = &self.nodes[@intCast(current_node_index.?)];

                            const next_token_start_offset =
                                current_token_offset + @sizeOf(FDT.Token); // already aligned
                            if (next_token_start_offset + @sizeOf(u32) > dt_struct_size) {
                                return FDT.Error.Truncated;
                            }

                            const next_token_raw = std.mem.readInt(
                                u32,
                                structure_block[next_token_start_offset..][0..4],
                                .big,
                            );
                            const next_token = std.enums.fromInt(FDT.Token, next_token_raw) orelse
                                return FDT.Error.UnknownToken;

                            if (next_token == .prop) {
                                return FDT.Error.PropNextEndNode;
                            }

                            // pop node
                            current_node_index = current_node.parent_index;

                            // | token | next ..
                            current_token_offset += @sizeOf(FDT.Token);
                        },
                        .prop => {
                            const property_struct_start_offset =
                                current_token_offset + @sizeOf(FDT.Token);
                            if (property_struct_start_offset + @sizeOf(FDT.Prop) > dt_struct_size) {
                                return FDT.Error.Truncated;
                            }

                            const property_struct_start_ptr: *const FDT.Prop =
                                @ptrCast(@alignCast(
                                    &structure_block[@intCast(property_struct_start_offset)],
                                ));
                            const property_string_start_index =
                                property_struct_start_offset + @sizeOf(FDT.Prop);
                            // empty property string is allowed
                            const val_start = property_string_start_index;
                            const prop_len = property_struct_start_ptr.readlen();
                            if (val_start + prop_len > dt_struct_size) {
                                return FDT.Error.Truncated;
                            }
                            const property_string = structure_block[val_start..][0..prop_len];

                            const name_off = property_struct_start_ptr.readNameOff();
                            if (name_off >= fdt_header.readSizeDtStrings()) {
                                return FDT.Error.Truncated;
                            }

                            const property_name_slice: []const u8 = strings_block[name_off..];
                            const property_name: []const u8 = loop: for (0..@min(
                                property_name_slice.len,
                                @as(usize, config.max_property_name_len),
                            )) |i| {
                                if (property_name_slice[i] == 0) {
                                    break :loop property_name_slice[0..i];
                                }
                            } else return FDT.Error.NonNullTerminatedName;

                            if (property_name.len == 0) {
                                return FDT.Error.EmptyPropertyName;
                            }

                            const property_index = self.properties_len;
                            const property = try self.createProperty();
                            property.name = property_name;
                            property.val = property_string;

                            if (current_node_index == null) {
                                return FDT.Error.OrphanProperty;
                            }

                            const current_node = &self.nodes[@intCast(current_node_index.?)];
                            (try current_node.createPropertyIndex()).* = property_index;

                            const value_size =
                                std.mem.alignForward(u32, @intCast(property_string.len), 4);

                            // | token | prop | property_string | next...
                            current_token_offset += @sizeOf(FDT.Token) +
                                @sizeOf(FDT.Prop) + value_size;
                        },
                        .nop => {
                            // | token | next ..
                            current_token_offset += @sizeOf(FDT.Token);
                        },
                        .end => {
                            // | token | end.
                            const end_offset = current_token_offset + @sizeOf(FDT.Token);

                            if (end_offset != dt_struct_size) {
                                return FDT.Error.EndIsNotLastToken;
                            }

                            if (current_node_index != null) {
                                return FDT.Error.UnendedNodeExist;
                            }

                            current_token_offset = end_offset; // while loop end
                        },
                    }
                } // while of one tree end

                header_index += fdt_header.readTotalsize();
            } // while of whole tree end
        }

        fn findProperty(self: *const DTBType, property_name: []const u8) ?u32 {
            for (self.properties[0..self.properties_len], 0..) |*property, i| {
                if (std.mem.eql(u8, property.name, property_name)) {
                    return @intCast(i);
                }
            }

            return null;
        }

        fn createProperty(self: *DTBType) DTBError!*Property {
            return try createUndefinedItemInFixedArray(
                "properties",
                "properties_len",
                self,
            );
        }

        fn createEnsureProperty(self: *DTBType) *Property {
            return createEnsureUndefinedItemInFixedArray(
                "properties",
                "properties_len",
                self,
            );
        }

        pub fn findNode(self: *const DTBType, node_name: []const u8) ?u32 {
            for (self.nodes[0..self.nodes_len], 0..) |*node, i| {
                if (std.mem.eql(u8, node.name, node_name)) {
                    return @intCast(i);
                }
            }

            return null;
        }

        fn createNode(self: *DTBType) DTBError!*Node {
            return try createUndefinedItemInFixedArray(
                "nodes",
                "nodes_len",
                self,
            );
        }

        fn createEnsureNode(self: *DTBType) *Node {
            return createEnsureUndefinedItemInFixedArray(
                "nodes",
                "nodes_len",
                self,
            );
        }

        fn createRootIndices(self: *DTBType) DTBError!*u32 {
            return try createUndefinedItemInFixedArray(
                "root_indices",
                "root_indices_len",
                self,
            );
        }

        fn createEnsureRootIndices(self: *DTBType) *u32 {
            return createEnsureUndefinedItemInFixedArray(
                "root_indices",
                "root_indices_len",
                self,
            );
        }

        pub fn debugDump(
            self: *const DTBType,
            writer: *std.Io.Writer,
        ) !void {
            try writer.print("/dtb/;\n", .{});

            for (self.root_indices[0..self.root_indices_len]) |root_idx| {
                try self.printNode(writer, @intCast(root_idx), 0);
            }

            try writer.print("\n", .{});
        }

        fn printNode(
            self: *const DTBType,
            writer: *std.Io.Writer,
            node_idx: u32,
            indent_level: u32,
        ) !void {
            const node = &self.nodes[node_idx];

            const spaces: [512]u8 = @splat(' ');
            const indent = spaces[0..@min(indent_level * 2, spaces.len)];

            try writer.print("{s}{s} {{\n", .{ indent, node.name });

            for (node.property_indices[0..node.property_indices_len]) |prop_idx| {
                const prop = &self.properties[@intCast(prop_idx)];

                if (prop.val.len == 0) {
                    try writer.print("{s}  {s};\n", .{ indent, prop.name });
                    continue;
                }

                if (isStringListProperty(prop.val)) {
                    try writer.print("{s}  {s} = ", .{ indent, prop.name });
                    try printStringList(writer, prop.val);
                } else if (isStringProperty(prop)) {
                    try writer.print("{s}  {s} = ", .{ indent, prop.name });
                    const trimmed = std.mem.trimRight(u8, prop.val, "\x00");
                    if (std.mem.eql(u8, trimmed, "<NULL>")) {
                        try writer.print("<null>;\n", .{});
                    } else {
                        try writer.print("\"{s}\";\n", .{trimmed});
                    }
                } else {
                    try writer.print("{s}  {s} = <", .{ indent, prop.name });
                    const val_len = prop.val.len;
                    var i: usize = 0;
                    while (i < val_len) : (i += 4) {
                        if (i > 0) try writer.print(" ", .{});
                        const remaining = val_len - i;
                        if (remaining >= 4) {
                            const word = std.mem.readInt(
                                u32,
                                @ptrCast(prop.val[i .. i + 4].ptr),
                                .big,
                            );
                            try writer.print("0x{x}", .{word});
                        } else {
                            var buf: [4]u8 = undefined;
                            @memcpy(buf[0..remaining], prop.val[i..]);
                            @memset(buf[remaining..], 0);
                            const word = std.mem.readInt(u32, &buf, .big);
                            try writer.print("0x{x}", .{word});
                        }
                    }
                    try writer.print(">;\n", .{});
                }
            }

            for (node.child_indices[0..node.child_indices_len]) |child_idx| {
                try self.printNode(writer, @intCast(child_idx), indent_level + 1);
            }

            try writer.print("{s}}};\n", .{indent});
        }

        fn isStringProperty(prop: *const Property) bool {
            if (prop.val.len == 0) return false;
            if (prop.val[prop.val.len - 1] != 0) return false;
            for (prop.val[0 .. prop.val.len - 1]) |byte| {
                if (byte < 32 or byte > 126) return false;
            }
            return true;
        }

        fn isStringListProperty(val: []const u8) bool {
            if (val.len == 0 or val[val.len - 1] != 0) return false;
            var has_non_null = false;
            var i: usize = 0;
            while (i < val.len) : (i += 1) {
                if (val[i] == 0) continue;
                has_non_null = true;
                if (val[i] < 32 or val[i] > 126) return false;
            }
            return has_non_null and (val.len > 1);
        }

        fn printStringList(writer: anytype, val: []const u8) !void {
            var i: usize = 0;
            var first = true;
            while (i < val.len) {
                const start = i;
                while (i < val.len and val[i] != 0) : (i += 1) {}
                if (i == start) {
                    i += 1;
                    continue;
                }
                if (!first) try writer.print(", ", .{});
                try writer.print("\"{s}\"", .{val[start..i]});
                first = false;
                i += 1;
            }
            try writer.print(";\n", .{});
        }
    };
}

inline fn createUndefinedItemInFixedArray(
    comptime item_field_name: []const u8,
    comptime item_field_len_name: []const u8,
    self: anytype,
) !*std.meta.Child(@FieldType(@TypeOf(self.*), item_field_name)) {
    std.debug.assert(@field(self, item_field_len_name) <= @field(self, item_field_name).len);

    if (@field(self, item_field_len_name) >= @field(self, item_field_name).len) {
        return DTBError.OOM;
    }

    const ptr = createEnsureUndefinedItemInFixedArray(item_field_name, item_field_len_name, self);

    std.debug.assert(@field(self, item_field_len_name) <= @field(self, item_field_name).len);

    return ptr;
}

inline fn createEnsureUndefinedItemInFixedArray(
    comptime item_field_name: []const u8,
    comptime item_field_len_name: []const u8,
    self: anytype,
) *std.meta.Child(@FieldType(@TypeOf(self.*), item_field_name)) {
    std.debug.assert(@field(self, item_field_len_name) < @field(self, item_field_name).len);

    const old_len = @field(self, item_field_len_name);
    @field(self, item_field_len_name) += 1;

    // poison
    if (@import("builtin").mode == .Debug) {
        @field(self, item_field_name)[@intCast(old_len)] = undefined;
    }

    std.debug.assert(@field(self, item_field_len_name) <= @field(self, item_field_name).len);

    return &@field(self, item_field_name)[@intCast(old_len)];
}
