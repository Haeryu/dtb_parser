const std = @import("std");
const FDT = @import("fdt.zig").FDT;
const DTBConfig = @import("dtb.zig").DTBConfig;
const DTB = @import("dtb.zig").DTB;

test "comptime parse" {
    if (false) {
        const raw align(@alignOf(FDT.Header)) = @embedFile("test_res/bcm2712-rpi-5-b.dtb");

        // sorry compiler...
        @setEvalBranchQuota(999999);
        comptime var dtb_ct: DTB(.{}) = undefined;
        comptime dtb_ct.init(raw);
        comptime try dtb_ct.parse();

        const node_depth_array = dtb_ct.nodes_len;
        const property_depth_array = dtb_ct.properties_len;

        var dtb: DTB(.{
            .node_depth_array = &node_depth_array,
            .property_depth_array = &property_depth_array,
        }) = undefined;
        dtb.init(raw);
        try dtb.parse();

        var stderr_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stdout_writer.interface;

        try dtb.debugDump(stderr);

        try stderr.flush();

        std.debug.print("{any}\n{any}\n", .{ node_depth_array, property_depth_array });
    }
}
