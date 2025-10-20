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
        try stderr.print(
            \\total memory usage of dtb parser = {}
            // \\dtb input bytes (raw_bytes.len)  = {}
            \\node_depth_array                 = {any}
            \\property_depth_array             = {any}
        , .{
            @sizeOf(@TypeOf(dtb)),
            // dtb.raw_bytes.len,
            node_depth_array,
            property_depth_array,
        });

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

var g_dtb: DTB(.{}) = undefined;

//  serial@7d001000 {
//       compatible = "arm,pl011", "arm,primecell";
//       reg = <0x7d001000 0x200>;
//       interrupts = <0x0 0x79 0x4>;
//       clocks = <0xe 0xf>;
//       clock-names = "uartclk", "apb_pclk";
//       arm,primecell-periphid = <0x341011>;
//       status = "okay";
//       phandle = <0x86>;
// };

fn be32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @ptrCast(&bytes[offset]), .big);
}

fn parseCellsToU64(buf: []const u8, cells: usize) u64 {
    var v: u64 = 0;
    for (0..cells) |i| {
        v = (v << 32) | be32(buf, i * 4);
    }
    return v;
}

fn readReg(reg_raw: []const u8, addr_cells: usize, size_cells: usize) !struct {
    base: u64,
    size: u64,
} {
    const need = (addr_cells + size_cells) * 4;
    if (reg_raw.len < need) return error.DTBMalformed;

    const base = parseCellsToU64(reg_raw[0 .. addr_cells * 4], addr_cells);
    const size = parseCellsToU64(reg_raw[addr_cells * 4 .. need], size_cells);
    return .{ .base = base, .size = size };
}

fn parseNthU64FromCells(buf: []const u8, n: usize) ?u64 {
    if (buf.len % 4 != 0) return null;

    const off8 = n * 8;
    if ((buf.len % 8 == 0) and (buf.len >= off8 + 8)) {
        const hi = be32(buf, off8);
        const lo = be32(buf, off8 + 4);
        return (@as(u64, hi) << 32) | @as(u64, lo);
    }

    const off4 = n * 4;
    if (buf.len >= off4 + 4) {
        return @as(u64, be32(buf, off4));
    }

    return null;
}

fn findNodeByPhandle(ph: u32) ?u32 {
    for (0..g_dtb.nodes.len) |i| {
        if (g_dtb.findPropertyIndexInNode(@intCast(i), "phandle")) |phandle_i| {
            const raw = g_dtb.getPropertyValue(phandle_i);
            if (raw.len >= 4 and be32(raw, 0) == ph) {
                return @intCast(i);
            }
        }

        if (g_dtb.findPropertyIndexInNode(@intCast(i), "linux,phandle")) |phandle_i| {
            const raw = g_dtb.getPropertyValue(@intCast(phandle_i));
            if (raw.len >= 4 and be32(raw, 0) == ph) {
                return @intCast(i);
            }
        }
    }
    return null;
}

fn propContainsCStringList(buf: []const u8, needle: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const end = std.mem.indexOfScalarPos(u8, buf, off, 0) orelse buf.len;
        const str = buf[off..end];
        if (std.mem.eql(u8, str, needle)) return true;
        if (end == buf.len) break;
        off = end + 1;
    }
    return false;
}

fn getUartClkHz(uart_i: u32) ?u64 {
    const names_i = g_dtb.findPropertyIndexInNode(uart_i, "clock-names") orelse return null;
    const names_raw = g_dtb.getPropertyValue(names_i);
    const idx = std.mem.findPos(u8, names_raw, 0, "uartclk") orelse return null;

    const clocks_i = g_dtb.findPropertyIndexInNode(uart_i, "clocks") orelse return null;
    const clocks_raw = g_dtb.getPropertyValue(clocks_i);

    var off: usize = 0;
    var cur_idx: usize = 0;
    while (off < clocks_raw.len) : (cur_idx += 1) {
        const ph = be32(clocks_raw, off);
        off += 4;

        const provider_node_i = findNodeByPhandle(ph) orelse return null;
        const cells_i = g_dtb.findPropertyIndexInNode(provider_node_i, "#clock-cells") orelse
            return null;
        const cells_raw = g_dtb.getPropertyValue(cells_i);
        const cells = be32(cells_raw, 0);

        if (cur_idx == idx) {
            if (g_dtb.findPropertyIndexInNode(uart_i, "assigned-clock-rates")) |acr_i| {
                const acr = g_dtb.getPropertyValue(acr_i);
                const hz = parseNthU64FromCells(acr, idx);
                if (hz) |val| {
                    return val;
                }
            }
            if (g_dtb.findPropertyIndexInNode(provider_node_i, "clock-frequency")) |frequency_i| {
                const frequency = g_dtb.getPropertyValue(frequency_i);
                if (frequency.len >= 4) {
                    return @intCast(be32(frequency, 0));
                }
            }

            if (g_dtb.findPropertyIndexInNode(uart_i, "clock-frequency")) |u_cf_i| {
                const u_cf = g_dtb.getPropertyValue(u_cf_i);
                if (u_cf.len >= 4) {
                    return @intCast(be32(u_cf, 0));
                }
            }
            return null;
        }

        off += cells * 4;
    }
    return null;
}

fn calcDividers(uartclk_hz: u64, baud: u32) struct {
    ibrd: u16,
    fbrd: u8,
} {
    const denom = 16 * @as(u64, baud);
    const bauddiv_fp = uartclk_hz * 64 / denom;
    const ibrd: u16 = @intCast(bauddiv_fp / 64);
    const fbrd: u8 = @intCast(bauddiv_fp % 64);
    return .{
        .ibrd = ibrd,
        .fbrd = fbrd,
    };
}

fn getUART() !void {
    const raw = @embedFile("test_res/bcm2712-rpi-5-b.dtb");
    g_dtb.init(raw);
    try g_dtb.parse();

    const chosen_i = g_dtb.findNodeIndex("chosen") orelse return error.NoNode;
    const stdout_path_i = g_dtb.findPropertyIndexInNode(chosen_i, "stdout-path") orelse
        return error.NoProperty;

    const stdout_path = g_dtb.getPropertyValue(stdout_path_i);
    const colon_i = std.mem.findScalar(u8, stdout_path, ':') orelse stdout_path.len;

    const serial_name = stdout_path[0..colon_i];
    const cfg_str = if (colon_i < stdout_path.len) stdout_path[colon_i + 1 ..] else "";
    var baud: u32 = 115200;
    var parity: u8 = 'n';
    var bits: u8 = 8;
    var flow: bool = false;

    if (cfg_str.len > 0) {
        var i: usize = 0;
        while (i < cfg_str.len and std.ascii.isDigit(cfg_str[i])) : (i += 1) {}
        if (i > 0) {
            baud = std.fmt.parseInt(u32, cfg_str[0..i], 10) catch 115200;
        }

        if (i < cfg_str.len) {
            const c = std.ascii.toLower(cfg_str[i]);
            if (c == 'n' or c == 'o' or c == 'e' or c == 'p') parity = c;
            i += 1;
        }

        if (i < cfg_str.len and std.ascii.isDigit(cfg_str[i])) {
            bits = cfg_str[i] - '0';
            i += 1;
        }

        if (i < cfg_str.len and std.ascii.toLower(cfg_str[i]) == 'r') {
            flow = true;
        }
    }

    const aliases_i = g_dtb.findNodeIndex("aliases") orelse return error.NoNode;
    const serial_name_i = g_dtb.findPropertyIndexInNode(aliases_i, serial_name) orelse
        return error.NoProperty;
    const uart_name = g_dtb.getPropertyValue(serial_name_i);

    const slash_i = std.mem.findScalarLast(u8, uart_name, '/') orelse 0;

    const uart_i =
        g_dtb.findNodeIndex(std.mem.trimRight(u8, uart_name[slash_i + 1 ..], &.{0})) orelse
        return error.NoNode;
    const status_i = g_dtb.findPropertyIndexInNode(uart_i, "status") orelse
        return error.NoProperty;
    const okay_or_disabled = std.mem.trimRight(u8, g_dtb.getPropertyValue(status_i), &.{0});
    if (!std.mem.eql(u8, okay_or_disabled, "okay")) {
        return error.DisabledPropertySelected;
    }

    const uart_node = &g_dtb.nodes[@intCast(uart_i)];
    const uart_parent_i = uart_node.parent_index;
    std.debug.assert(uart_parent_i != std.math.maxInt(u32));

    const address_cells_i = g_dtb.findPropertyIndexInNode(uart_parent_i, "#address-cells") orelse
        return error.NoProperty;
    const addr_cells = be32(g_dtb.getPropertyValue(address_cells_i), 0);

    const size_cells_i = g_dtb.findPropertyIndexInNode(uart_parent_i, "#size-cells") orelse
        return error.NoProperty;
    const size_cells = be32(g_dtb.getPropertyValue(size_cells_i), 0);

    const compatible_i = g_dtb.findPropertyIndexInNode(uart_i, "compatible") orelse
        return error.NoProperty;

    const reg_i = g_dtb.findPropertyIndexInNode(uart_i, "reg") orelse
        return error.NoProperty;
    const reg = g_dtb.getPropertyValue(reg_i);
    const reg_val = try readReg(reg, addr_cells, size_cells);
    if (reg_val.size < 0x100) {
        return error.RegionTooSmall;
    }

    // const base_ptr: [*]volatile u8 = @ptrFromInt(@as(usize, @intCast(reg_val.base)));

    const uartclk_hz = getUartClkHz(uart_i) orelse return error.MissingClockFrequency;

    // TODO: GIC
    // const interrupts_i = g_dtb.findPropertyIndexInNode(uart_i, "interrupts") orelse
    //     return error.NoProperty;
    // const interrupts = g_dtb.getPropertyValue(interrupts_i);
    // const ty = be32(interrupts, 0);
    // const id = be32(interrupts, 4);
    // const flags = be32(interrupts, 8);
    // if (ty > 2) {
    //     return error.UnsupportedInterruptType;
    // }
    // const gic_irq = id + 32 >> ty;
    // const level_high = (flags & 0xF) == 4;

    std.debug.print("{s}\n", .{g_dtb.getPropertyValue(compatible_i)});
    if (std.mem.find(
        u8,
        g_dtb.getPropertyValue(compatible_i),
        "pl011",
    ) != null) {
        std.debug.print(
            \\clock_hz = {},
            \\baud = {},
            \\parity = {},
            \\bits = {},
            \\flow = {},
        , .{
            uartclk_hz,
            baud,
            parity,
            bits,
            flow,
        });
    } else {
        return error.Unsupported;
    }
}

test "get uart" {
    if (false) {
        getUART() catch unreachable;
    }
}
