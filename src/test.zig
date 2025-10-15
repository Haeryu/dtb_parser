const std = @import("std");
const FDT = @import("fdt.zig").FDT;
const DTBConfig = @import("dtb.zig").DTBConfig;
const DTB = @import("dtb.zig").DTB;

test "comptime parse" {
    if (false) {
        const raw align(@alignOf(FDT.Header)) = @embedFile("test_res/bcm2712-rpi-5-b.dtb").*;

        // sorry compiler...
        @setEvalBranchQuota(999999);
        comptime var dtb_ct: DTB(.{}) = undefined;
        comptime dtb_ct.init(&raw);
        comptime dtb_ct.parse() catch unreachable;

        const node_depth_array = comptime dtb_ct.nodes_len;
        const property_depth_array = comptime dtb_ct.properties_len;

        var dtb: DTB(.{
            .node_depth_array = &node_depth_array,
            .property_depth_array = &property_depth_array,
        }) = undefined;
        dtb.init(&raw);
        try dtb.parse();

        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;

        try dtb.debugDump(&stderr_writer.interface);
        try stderr.print("{any}\n{any}\n", .{ node_depth_array, property_depth_array });

        try stderr.flush();
    }
}

test "parse root node" {
    const raw = @embedFile("test_res/bcm2712-rpi-5-b.dtb");

    var dtb: DTB(.{}) = undefined;
    dtb.init(raw);
    try dtb.parse();

    try std.testing.expectEqual(@as(u32, 1), dtb.nodes_len[0]);

    const root_name = dtb.getNodeName(0);
    try std.testing.expect(std.mem.eql(u8, root_name, ""));
}

test "find node by name" {
    const raw = @embedFile("test_res/bcm2712-rpi-5-b.dtb");

    var dtb: DTB(.{}) = undefined;
    dtb.init(raw);
    try dtb.parse();

    if (dtb.findNodeIndex("cpus")) |i| {
        const name = dtb.getNodeName(i);
        try std.testing.expect(std.mem.eql(u8, name, "cpus"));
    } else {
        unreachable;
    }

    if (dtb.findNodeIndex("clk_xosc")) |i| {
        const name = dtb.getNodeName(i);
        try std.testing.expect(std.mem.eql(u8, name, "clk_xosc"));
        if (dtb.findPropertyIndexInNode(i, "clock-frequency")) |prop_i| {
            const prop_name = dtb.getPropertyName(prop_i);
            const prop_val = dtb.getPropertyValue(prop_i);

            try std.testing.expect(std.mem.eql(u8, prop_name, "clock-frequency"));
            try std.testing.expect(std.mem.readInt(u32, @ptrCast(prop_val.ptr), .big) ==
                0x2faf080);
        }
    } else {
        unreachable;
    }

    if (dtb.findNodeIndex("pcie@1000110000")) |i| {
        const name = dtb.getNodeName(i);
        try std.testing.expect(std.mem.eql(u8, name, "pcie@1000110000"));
    } else {
        unreachable;
    }

    try std.testing.expectEqual(null, dtb.findNodeIndex("nonexistent_node"));
}
