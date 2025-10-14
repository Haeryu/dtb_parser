const std = @import("std");

// https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html

pub const FDT = struct {
    pub const Error = error{
        BadMagic,
        Truncated,
        UnsupportedVersion,
        UnknownToken,
        NonNullTerminatedName,
        NonNullTerminatedPropertyName,
        PropNextEndNode,
        EndIsNotLastToken,
        EmptyNodeName,
        UnendedNodeExist,
        OrphanProperty,
        EmptyPropertyName,
    };

    pub const Token = enum(u32) {
        begin_node = 1,
        end_node = 2,
        prop = 3,
        nop = 4,
        end = 9,
    };

    pub const Header = extern struct {
        magic: u32,
        totalsize: u32,
        off_dt_struct: u32,
        off_dt_strings: u32,
        off_mem_rsvmap: u32,
        version: u32,
        last_comp_version: u32,
        boot_cpuid_phys: u32,
        size_dt_strings: u32,
        size_dt_struct: u32,

        pub fn fromBytes(raw_bytes: []const u8) Error!*const Header {
            if (raw_bytes.len < @sizeOf(Header)) {
                return Error.Truncated;
            }

            const header: *const Header =
                @alignCast(std.mem.bytesAsValue(Header, raw_bytes[0..@sizeOf(Header)]));
            if (header.readMagic() != 0xd00dfeed) {
                return Error.BadMagic;
            }

            return header;
        }

        fn readField(
            self: *const Header,
            comptime field_name: []const u8,
        ) @FieldType(Header, field_name) {
            return std.mem.bigToNative(@FieldType(Header, field_name), @field(self, field_name));
        }

        pub fn readMagic(self: *const Header) u32 {
            return self.readField("magic");
        }

        pub fn readTotalsize(self: *const Header) u32 {
            return self.readField("totalsize");
        }

        pub fn readOffDtStruct(self: *const Header) u32 {
            return self.readField("off_dt_struct");
        }

        pub fn readOffDtStrings(self: *const Header) u32 {
            return self.readField("off_dt_strings");
        }

        pub fn readOffMemRsvmap(self: *const Header) u32 {
            return self.readField("off_mem_rsvmap");
        }

        pub fn readVersion(self: *const Header) u32 {
            return self.readField("version");
        }

        pub fn readLastCompVersion(self: *const Header) u32 {
            return self.readField("last_comp_version");
        }

        pub fn readBootCpuidPhys(self: *const Header) u32 {
            return self.readField("boot_cpuid_phys");
        }

        pub fn readSizeDtStrings(self: *const Header) u32 {
            return self.readField("size_dt_strings");
        }

        pub fn readSizeDtStruct(self: *const Header) u32 {
            return self.readField("size_dt_struct");
        }
    };

    pub const ReserveEntry = extern struct {
        address: u64,
        size: u64,

        pub fn readAddress(self: ReserveEntry) u64 {
            return std.mem.bigToNative(u64, self.address);
        }

        pub fn readSize(self: ReserveEntry) u64 {
            return std.mem.bigToNative(u64, self.size);
        }
    };

    pub const Prop = extern struct {
        len: u32,
        name_off: u32,

        pub fn readlen(self: Prop) u32 {
            return std.mem.bigToNative(u32, self.len);
        }

        pub fn readNameOff(self: Prop) u32 {
            return std.mem.bigToNative(u32, self.name_off);
        }
    };
};
