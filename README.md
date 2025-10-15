# Zig DTB Parser

Experimental zero-allocation DTB parser for Zig. Parses Flattened Device Tree (FDT) format using fixed-size buffers.

Tested with `bcm2712-rpi-5-b.dtb` from [Raspberry Pi firmware](https://github.com/raspberrypi/firmware). Sample dump: `dtb_dump_example.txt`.

Based on [Device Tree Specification](https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html).

## Installation
Add to `build.zig.zon`:
```zig
.{
    .name = "your-app",
    .version = "0.1.0",
    .dependencies = .{
        .dtb_parser = .{
            .url = "https://github.com/Haeryu/dtb_parser/archive/refs/heads/main.zip",
            .hash = "<hash>",  // Use `zig fetch --save <url>`
        },
    },
}
```

In `build.zig`:
```zig
const dtb = b.dependency("dtb_parser", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("dtb_parser", dtb.module("dtb_parser"));
```

## Usage
### Parse DTB
```zig
const std = @import("std");
const DTB = @import("dtb_parser").dtb.DTB;

pub fn main() !void {
    const raw = ...; // Load your DTB bytes

    var dtb: DTB(.{}) = undefined;
    dtb.init(raw);
    try dtb.parse();

    // Query example
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
    } 
}
```

### Dump
```zig
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    try dtb.debugDump(&stderr_writer.interface);

    try stderr.flush();
```

[bcm2712-rpi-5-b.dtb example](https://github.com/Haeryu/dtb_parser/blob/5755a7b57160ccc1fb70449c401a5de847dd3ba8/dtb_dump_example.txt)

## Limitations
- Fixed-size only (risk OOM on large DTBs). Need a heuristic.

     -> or do thing like this
``` zig
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
```
  result
```
...
    aux = "/dummy";
    dummy = "/dummy";
    i2c0if = "/i2c0if";
    i2c0mux = "/i2c0mux";
    rp1_firmware = "/rp1_firmware";
    rp1_vdd_3v3 = "/rp1_vdd_3v3";
    chosen = "/chosen";
    aliases = "/aliases";
    fan = "/cooling_fan";
    pwr_key = "/pwr_button/pwr";
  };
};

{ 1, 35, 92, 36, 66, 63, 26 }
{ 5, 601, 668, 143, 590, 242, 90 }
```

- Parse-only, no builder.