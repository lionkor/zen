const tty = @import("tty.zig");
const x86 = @import("x86.zig");

// GDT segment selectors.
pub const KERNEL_CODE = 0x08;
pub const KERNEL_DATA = 0x10;
pub const USER_CODE = 0x18;
pub const USER_DATA = 0x20;
pub const TSS_DESC = 0x28;

// Privilege level of segment selector.
pub const KERNEL_RPL = 0b00;
pub const USER_RPL = 0b11;

// Access byte values.
const KERNEL = 0x90;
const USER = 0xF0;
const CODE = 0x0A;
const DATA = 0x02;
const TSS_ACCESS = 0x89;

// Segment flags.
const PROTECTED = (1 << 2);
const BLOCKS_4K = (1 << 3);

// Structure representing an entry in the GDT.
const GDTEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_high: u4,
    flags: u4,
    base_high: u8,
};

// GDT descriptor register.
const GDTRegister = packed struct {
    limit: u16,
    base: *const GDTEntry,
};

// Task State Segment.
const TSS = packed struct {
    unused1: u32,
    esp0: u32, // Stack to use when coming to ring 0 from ring > 0.
    ss0: u32, // Segment to use when coming to ring 0 from ring > 0.
    unused2: [22]u32,
    unused3: u16,
    iomap_base: u16, // Base of the IO bitmap.
};

////
// Generate a GDT entry structure.
//
// Arguments:
//     base: Beginning of the segment.
//     limit: Size of the segment.
//     access: Access byte.
//     flags: Segment flags.
//
fn makeEntry(base: usize, limit: usize, access: u8, flags: u4) GDTEntry {
    return GDTEntry{
        .limit_low = @truncate(u16, limit),
        .base_low = @truncate(u16, base),
        .base_mid = @truncate(u8, base >> 16),
        .access = @truncate(u8, access),
        .limit_high = @truncate(u4, limit >> 16),
        .flags = @truncate(u4, flags),
        .base_high = @truncate(u8, base >> 24),
    };
}

// Fill in the GDT.
var gdt align(4) = [_]GDTEntry{
    makeEntry(0, 0, 0, 0),
    makeEntry(0, 0xFFFFF, KERNEL | CODE, PROTECTED | BLOCKS_4K),
    makeEntry(0, 0xFFFFF, KERNEL | DATA, PROTECTED | BLOCKS_4K),
    makeEntry(0, 0xFFFFF, USER | CODE, PROTECTED | BLOCKS_4K),
    makeEntry(0, 0xFFFFF, USER | DATA, PROTECTED | BLOCKS_4K),
    makeEntry(0, 0, 0, 0), // TSS (fill in at runtime).
};

// GDT descriptor register pointing at the GDT.
var gdtr = GDTRegister{
    .limit = @sizeOf(@TypeOf(gdt)),
    .base = &gdt[0],
};

// Instance of the Task State Segment.
var tss = TSS{
    .unused1 = 0,
    .esp0 = undefined,
    .ss0 = KERNEL_DATA,
    .unused2 = [_]u32{0} ** 22,
    .unused3 = 0,
    .iomap_base = @sizeOf(TSS),
};

////
// Set the kernel stack to use when interrupting user mode.
//
// Arguments:
//     esp0: Stack for Ring 0.
//
pub fn setKernelStack(esp0: usize) void {
    tss.esp0 = esp0;
}

////
// Load the GDT into the system registers (defined in assembly).
//
// Arguments:
//     gdtr: Pointer to the GDTR.
//
extern fn loadGDT(gdtr: *const GDTRegister) void;

////
// Initialize the Global Descriptor Table.
//
pub fn initialize() void {
    tty.step("Setting up the Global Descriptor Table", .{});

    // Initialize GDT.
    loadGDT(&gdtr);

    // Initialize TSS.
    const tss_entry = makeEntry(@ptrToInt(&tss), @sizeOf(TSS) - 1, TSS_ACCESS, PROTECTED);
    gdt[TSS_DESC / @sizeOf(GDTEntry)] = tss_entry;
    x86.ltr(TSS_DESC);

    tty.stepOK();
}
