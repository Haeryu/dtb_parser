const std = @import("std");
const FDT = @import("fdt.zig").FDT;
const DTBConfig = @import("dtb.zig").DTBConfig;
const DTB = @import("dtb.zig").DTB;

test "parse bcm2712-rpi-5-b DTB" {
    const raw = @embedFile("test_res/bcm2712-rpi-5-b.dtb");

    var dtb: DTB(.{
        .max_nodes = 1024,
        .max_roots = 1,
        .max_properties = 4096,
        .max_childs_per_node = 128,
        .max_properties_per_node = 1024,
        .max_name_len = 128,
        .max_property_name_len = 128,
    }) = undefined;
    dtb.init(raw);
    try dtb.parse();

    // var stderr_buffer: [1024]u8 = undefined;
    // var stdout_writer = std.fs.File.stderr().writer(&stderr_buffer);
    // const stderr = &stdout_writer.interface;

    // try dtb.debugDump(stderr);

    // try stderr.flush();

    try std.testing.expectEqual(@as(u32, 1), dtb.root_indices_len);
    const root_idx = dtb.root_indices[0];
    try std.testing.expect(root_idx < dtb.nodes_len);
    const root = &dtb.nodes[@intCast(root_idx)];
    try std.testing.expectEqualStrings("", root.name);
    try std.testing.expect(root.parent_index == null);

    try std.testing.expect(dtb.properties_len >= 1000);

    try std.testing.expect(root.property_indices_len >= 2);
    var has_model = false;
    var has_compatible = false;
    for (root.property_indices[0..root.property_indices_len]) |prop_idx| {
        const prop = &dtb.properties[@intCast(prop_idx)];
        if (std.mem.eql(u8, prop.name, "model")) {
            has_model = true;
            const trimmed_model = std.mem.trimRight(u8, prop.val, "\x00");
            try std.testing.expectEqualStrings("Raspberry Pi 5", trimmed_model);
        } else if (std.mem.eql(u8, prop.name, "compatible")) {
            has_compatible = true;
            try std.testing.expect(std.mem.startsWith(u8, prop.val, "raspberrypi,5-model-b"));
            try std.testing.expect(std.mem.containsAtLeast(u8, prop.val, 1, "brcm,bcm2712"));
        }
    }
    try std.testing.expect(has_model);
    try std.testing.expect(has_compatible);

    if (dtb.findNode("memory")) |mem_idx| {
        const mem_node = &dtb.nodes[@intCast(mem_idx)];
        try std.testing.expect(mem_node.property_indices_len >= 1);
        var has_device_type = false;
        for (mem_node.property_indices[0..mem_node.property_indices_len]) |prop_idx| {
            const prop = &dtb.properties[@intCast(prop_idx)];
            if (std.mem.eql(u8, prop.name, "device_type")) {
                has_device_type = true;
                const trimmed = std.mem.trimRight(u8, prop.val, "\x00");
                try std.testing.expectEqualStrings("memory", trimmed);
                break;
            }
        }
        try std.testing.expect(has_device_type);
    }

    if (dtb.findNode("cpus")) |cpus_idx| {
        const cpus_node = &dtb.nodes[@intCast(cpus_idx)];
        try std.testing.expectEqual(@as(u32, 5), cpus_node.child_indices_len);
        var cpu_count: u32 = 0;
        for (cpus_node.child_indices[0..cpus_node.child_indices_len]) |child_idx| {
            const cpu_node = &dtb.nodes[@intCast(child_idx)];
            if (std.mem.startsWith(u8, cpu_node.name, "cpu@")) {
                try std.testing.expect(cpu_node.property_indices_len >= 2);
                cpu_count += 1;
            } else if (std.mem.eql(u8, cpu_node.name, "l3-cache")) {
                try std.testing.expect(cpu_node.property_indices_len >= 1);
            } else {
                std.debug.panic("Unexpected child: {s}", .{cpu_node.name});
            }
        }
        try std.testing.expectEqual(@as(u32, 4), cpu_count);
    }

    if (dtb.findNode("soc")) |soc_idx| {
        const soc_node = &dtb.nodes[@intCast(soc_idx)];
        try std.testing.expect(soc_node.property_indices_len >= 1);
        var has_ranges = false;
        for (soc_node.property_indices[0..soc_node.property_indices_len]) |prop_idx| {
            const prop = &dtb.properties[@intCast(prop_idx)];
            if (std.mem.eql(u8, prop.name, "ranges")) {
                has_ranges = true;
                try std.testing.expect(prop.val.len >= 16);
                break;
            }
        }
        try std.testing.expect(has_ranges);
    }
}
