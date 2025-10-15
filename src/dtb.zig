// reference
// https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html

const std = @import("std");
const FDT = @import("fdt.zig").FDT;

pub const DTBConfig = struct {
    node_depth_array: []const u32 = &.{ 1, 1024, 1024, 1024, 1024, 1024, 1024, 1024 },
    property_depth_array: []const u32 = &.{ 1, 1024, 1024, 1024, 1024, 1024, 1024, 1024 },

    max_name_len: u32 = 64,
    max_property_name_len: u32 = 64,
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

    comptime std.debug.assert(config.node_depth_array.len == config.property_depth_array.len);

    return struct {
        raw_bytes: []const u8,

        properties: [getPropertiesLen()]Property,
        properties_len: [config.property_depth_array.len]u32,

        nodes: [getNodesLen()]Node,
        nodes_len: [config.node_depth_array.len]u32,

        const DTBType = @This();

        pub const Node = struct {
            depth: u32,
            name_start_offset: u32,
            name_end_offset: u32,

            parent_index: ?u32,

            child_indices_start: u32,
            child_indices_end: u32,

            property_indices_start: u32,
            property_indices_end: u32,

            pub fn init(
                self: *Node,
                depth: u32,
                name_start_offset: u32,
                name_end_offset: u32,
                parent_index: ?u32,
            ) void {
                self.depth = depth;
                self.name_start_offset = name_start_offset;
                self.name_end_offset = name_end_offset;
                self.parent_index = parent_index;
                self.child_indices_start = 0;
                self.child_indices_end = 0;
                self.property_indices_start = 0;
                self.property_indices_end = 0;
            }
        };

        pub const Property = struct {
            name_start_offset: u32,
            name_end_offset: u32,
            val_start_offset: u32,
            val_end_offset: u32,
        };

        pub fn init(self: *DTBType, raw_bytes: []const u8) void {
            self.raw_bytes = raw_bytes;
            self.nodes_len = @splat(0);
            self.properties_len = @splat(0);

            // poison
            if (@import("builtin").mode == .Debug) {
                @memset(&self.nodes, undefined);
                @memset(&self.properties, undefined);
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

                const abs_struct_start = header_index + fdt_header.readOffDtStruct();
                const abs_struct_end = abs_struct_start + dt_struct_size;
                if (abs_struct_end > header_index + fdt_header.readTotalsize()) {
                    return FDT.Error.Truncated;
                }
                const structure_block =
                    self.raw_bytes[@intCast(abs_struct_start)..@intCast(abs_struct_end)];

                const abs_strings_start = header_index + fdt_header.readOffDtStrings();
                const abs_strings_end = abs_strings_start + fdt_header.readSizeDtStrings();
                if (abs_strings_end > header_index + fdt_header.readTotalsize()) {
                    return FDT.Error.Truncated;
                }
                const strings_block =
                    self.raw_bytes[@intCast(abs_strings_start)..@intCast(abs_strings_end)];

                var current_token_offset: u32 = 0;
                var current_node_index: ?u32 = null;
                var current_depth: u32 = 0;
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
                            const name_len: u32 =
                                loop: for (0..@min(
                                    name_slice.len,
                                    @as(usize, config.max_name_len),
                                )) |i| {
                                    if (name_slice[i] == 0) {
                                        break :loop @intCast(i);
                                    }
                                } else return FDT.Error.NonNullTerminatedName;
                            const name_end_offset = name_start_offset + name_len;

                            if (name_len == 0 and current_depth > 0) {
                                return FDT.Error.EmptyNodeName;
                            }

                            const parent_node_index = current_node_index;

                            const new_node_index = try self.createNode(
                                current_depth,
                                name_start_offset,
                                name_end_offset,
                                parent_node_index,
                            );

                            // push node
                            current_node_index = new_node_index;

                            const name_size: u32 =
                                @intCast(name_end_offset - name_start_offset + 1);
                            // | token | nul terminated c string | next ..
                            current_token_offset +=
                                @sizeOf(FDT.Token) + std.mem.alignForward(u32, name_size, 4);

                            if (current_depth + 1 >= config.node_depth_array.len) {
                                return DTBError.OOM;
                            }

                            current_depth += 1;
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
                            current_depth -= 1;
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
                            const val_start_offset = property_string_start_index;
                            const prop_len = property_struct_start_ptr.readlen();
                            const val_end_offset = val_start_offset + prop_len;
                            if (val_end_offset > dt_struct_size) {
                                return FDT.Error.Truncated;
                            }

                            const property_name_start_offset =
                                property_struct_start_ptr.readNameOff();
                            if (property_name_start_offset >= fdt_header.readSizeDtStrings()) {
                                return FDT.Error.Truncated;
                            }

                            const property_name_slice: []const u8 =
                                strings_block[property_name_start_offset..];
                            const property_name_len: u32 = loop: for (0..@min(
                                property_name_slice.len,
                                @as(usize, config.max_property_name_len),
                            )) |i| {
                                if (property_name_slice[i] == 0) {
                                    break :loop @intCast(i);
                                }
                            } else return FDT.Error.NonNullTerminatedName;
                            const property_name_end_offset =
                                property_name_start_offset + property_name_len;

                            if (property_name_len == 0) {
                                return FDT.Error.EmptyPropertyName;
                            }

                            _ = try self.createProperty(
                                current_depth,
                                current_node_index,
                                property_name_start_offset,
                                property_name_end_offset,
                                val_start_offset,
                                val_end_offset,
                            );

                            const property_string_len = val_end_offset - val_start_offset;
                            const value_size =
                                std.mem.alignForward(u32, @intCast(property_string_len), 4);

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

        } // fn parse end

        pub fn getNodeName(self: *const DTBType, node_idx: u32) []const u8 {
            const node = &self.nodes[node_idx];
            return self.raw_bytes[node.name_start_offset..node.name_end_offset];
        }

        pub fn getChildren(self: *const DTBType, node_idx: u32) []const Node {
            const node = &self.nodes[node_idx];
            if (node.depth + 1 >= config.node_depth_array.len) {
                return &.{};
            }
            const child_depth_start = getNodeDepthStart(node.depth + 1);

            return self
                .nodes[child_depth_start..][node.child_indices_start..node.child_indices_end];
        }

        pub fn getPropertyName(self: *const DTBType, prop_idx: u32) []const u8 {
            const property = &self.properties[prop_idx];
            return self.raw_bytes[property.name_start_offset..property.name_end_offset];
        }

        pub fn getPropertyValue(self: *const DTBType, prop_idx: u32) []const u8 {
            const property = &self.properties[prop_idx];
            return self.raw_bytes[property.val_start_offset..property.val_end_offset];
        }

        pub fn getProperties(self: *const DTBType, node_idx: u32) []const Property {
            const node = &self.nodes[node_idx];
            return self.properties[node.property_indices_start..node.property_indices_end];
        }

        pub fn findNodeIndex(self: *const DTBType, node_name: []const u8) ?u32 {
            for (&self.nodes_len, 0..) |len, depth| {
                const node_depth_start = getNodeDepthStart(depth);

                for (0..len) |i| {
                    const node_index = node_depth_start + i;
                    if (std.mem.eql(u8, self.getNodeName(node_index), node_name)) {
                        return node_index;
                    }
                }
            }

            return null;
        }

        fn getNodeDepthStart(i: u32) u32 {
            std.debug.assert(i < config.node_depth_array.len);

            const slice = config.node_depth_array[0..i];
            var depth: u32 = 0;

            for (slice) |d| {
                depth += d;
            }

            return depth;
        }

        fn getNodeDepthEnd(i: u32) u32 {
            std.debug.assert(i < config.node_depth_array.len);

            const slice = config.node_depth_array[0 .. i + 1];
            var depth: u32 = 0;

            for (slice) |d| {
                depth += d;
            }

            return depth;
        }

        fn getNodesLen() u32 {
            return comptime getNodeDepthEnd(config.node_depth_array.len - 1);
        }

        fn getPropertyDepthStart(i: u32) u32 {
            std.debug.assert(i < config.property_depth_array.len);

            const slice = config.property_depth_array[0..i];
            var depth: u32 = 0;

            for (slice) |d| {
                depth += d;
            }

            return depth;
        }

        fn getPropertyDepthEnd(i: u32) u32 {
            std.debug.assert(i < config.property_depth_array.len);

            const slice = config.property_depth_array[0 .. i + 1];
            var depth: u32 = 0;

            for (slice) |d| {
                depth += d;
            }

            return depth;
        }

        fn getPropertiesLen() u32 {
            return comptime getPropertyDepthEnd(config.property_depth_array.len - 1);
        }

        fn createNode(
            self: *DTBType,
            depth: u32,
            name_start_offset: u32,
            name_end_offset: u32,
            parent_index: ?u32,
        ) DTBError!u32 {
            if (depth >= config.node_depth_array.len) {
                return DTBError.OOM;
            }

            const node_depth_start = getNodeDepthStart(depth);
            const max_per_depth = config.node_depth_array[depth];
            if (self.nodes_len[depth] >= max_per_depth) {
                return DTBError.OOM;
            }

            const node_depth_len = self.nodes_len[depth];
            const new_node_index = node_depth_start + node_depth_len;

            // const node_depth_end = getNodeDepthEnd(depth);
            // if (new_node_index + 1 >= node_depth_end) {
            //     return DTBError.OOM;
            // }

            self.nodes_len[depth] += 1;
            self.nodes[@intCast(new_node_index)].init(
                depth,
                name_start_offset,
                name_end_offset,
                parent_index,
            );

            if (parent_index) |par_idx| {
                const parent = &self.nodes[par_idx];
                if (parent.child_indices_end == parent.child_indices_start) { // first child
                    parent.child_indices_start = new_node_index;
                    parent.child_indices_end = new_node_index + 1;
                } else {
                    parent.child_indices_end += 1;
                }
            }

            return new_node_index;
        }

        fn createProperty(
            self: *DTBType,
            depth: u32,
            current_node_index: ?u32,
            name_start_offset: u32,
            name_end_offset: u32,
            val_start_offset: u32,
            val_end_offset: u32,
        ) (FDT.Error || DTBError)!u32 {
            if (depth >= config.property_depth_array.len) {
                return DTBError.OOM;
            }

            const property_depth_start = getPropertyDepthStart(depth);
            const max_per_depth = config.property_depth_array[depth];
            if (self.properties_len[depth] >= max_per_depth) {
                return DTBError.OOM;
            }

            const property_depth_len = self.properties_len[depth];
            const new_property_index = property_depth_start + property_depth_len;

            // const property_depth_end = getPropertyDepthEnd(depth);
            // if (new_property_index + 1 >= property_depth_end) {
            //     return DTBError.OOM;
            // }

            self.properties_len[depth] += 1;
            self.properties[@intCast(new_property_index)].name_start_offset = name_start_offset;
            self.properties[@intCast(new_property_index)].name_end_offset = name_end_offset;
            self.properties[@intCast(new_property_index)].val_start_offset = val_start_offset;
            self.properties[@intCast(new_property_index)].val_end_offset = val_end_offset;

            if (current_node_index) |node_idx| {
                const current_node = &self.nodes[node_idx];
                // first property
                if (current_node.property_indices_end == current_node.property_indices_start) {
                    current_node.property_indices_start = new_property_index;
                    current_node.property_indices_end = new_property_index + 1;
                } else {
                    current_node.property_indices_end += 1;
                }
            } else {
                return FDT.Error.OrphanProperty;
            }

            return new_property_index;
        }
    };
}
