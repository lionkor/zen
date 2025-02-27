const interrupt = @import("interrupt.zig");
const isr = @import("isr.zig");
const layout = @import("layout.zig");
const pmem = @import("pmem.zig");
const scheduler = @import("scheduler.zig");
const tty = @import("tty.zig");
const x86 = @import("x86.zig");
const assert = @import("std").debug.assert;

// A single entry in a page table.
const PageEntry = usize;

// Page table structures (mapped with the recursive PD trick).
const PD = @intToPtr([*]PageEntry, layout.PD);
const PTs = @intToPtr([*]PageEntry, layout.PTs);

// Page mapping flags. Refer to the official Intel manual.
pub const PAGE_PRESENT = (1 << 0);
pub const PAGE_WRITE = (1 << 1);
pub const PAGE_USER = (1 << 2);
pub const PAGE_4MB = (1 << 7);
pub const PAGE_GLOBAL = (1 << 8);
pub const PAGE_ALLOCATED = (1 << 9);

// Calculate the PD and PT indexes given a virtual address.
fn pdIndex(v_addr: usize) usize {
    return v_addr >> 22;
}
fn ptIndex(v_addr: usize) usize {
    return (v_addr >> 12) & 0x3FF;
}

// Return pointers to the PD and PT entries given a virtual address.
fn pdEntry(v_addr: usize) *PageEntry {
    return &PD[pdIndex(v_addr)];
}
fn ptEntry(v_addr: usize) *PageEntry {
    return &PTs[(pdIndex(v_addr) * 0x400) + ptIndex(v_addr)];
}

////
// Convert a virtual address to the physical address
// it maps to (in the current address space).
//
// Arguments:
//     v_addr: Virtual address to be converted.
//
// Returns:
//     The physical address (if map exists), or null otherwise.
//
pub fn virtualToPhysical(v_addr: usize) ?usize {
    const pd_entry = pdEntry(v_addr);
    if (pd_entry.* == 0) return null;
    const pt_entry = ptEntry(v_addr);

    return x86.pageBase(pt_entry.*);
}

////
// Map a virtual page to a physical one with the given flags.
//
// Arguments:
//     v_addr: Virtual address of the page to be mapped.
//     p_addr: Physical address to map the page to (or null to allocate it).
//     flags: Paging flags (protection etc.).
//
pub fn map(v_addr: usize, p_addr: ?usize, flags: u32) void {
    // Do not touch the identity mapped area.
    assert(v_addr >= layout.IDENTITY);

    const pd_entry = pdEntry(v_addr);
    const pt_entry = ptEntry(v_addr);

    // If the relevant Page Directory entry is empty, we need a new Page Table.
    if (pd_entry.* == 0) {
        // Allocate the new Page Table and point the Page Directory entry to it.
        // Permissive flags are set in the PD, as restrictions are set in the PT entry.
        pd_entry.* = pmem.allocate() | flags | PAGE_PRESENT | PAGE_WRITE | PAGE_USER;
        x86.invlpg(@ptrToInt(pt_entry));

        const pt = @ptrCast([*]PageEntry, x86.pageBase(pt_entry));
        zeroPageTable(pt);
    }

    if (p_addr) |p| {
        // If the currently mapped physical page was allocated, free it.
        if (pt_entry.* & PAGE_ALLOCATED != 0) pmem.free(pt_entry.*);

        // Point the Page Table entry to the specified physical page.
        pt_entry.* = x86.pageBase(p) | flags | PAGE_PRESENT;
    } else {
        if (pt_entry.* & PAGE_ALLOCATED != 0) {
            // Reuse the existing allocated page.
            pt_entry.* = x86.pageBase(pt_entry.*) | flags | PAGE_PRESENT | PAGE_ALLOCATED;
        } else {
            // Allocate a new physical page.
            pt_entry.* = pmem.allocate() | flags | PAGE_PRESENT | PAGE_ALLOCATED;
        }
    }

    x86.invlpg(v_addr);
}

////
// Unmap a virtual page.
//
// Arguments:
//     v_addr: Virtual address of the page to be unmapped.
//
pub fn unmap(v_addr: usize) void {
    assert(v_addr >= layout.IDENTITY);

    const pd_entry = pdEntry(v_addr);
    if (pd_entry.* == 0) return;
    const pt_entry = ptEntry(v_addr);

    // Deallocate the physical page if it was allocated during mapping.
    if (pt_entry.* & PAGE_ALLOCATED != 0) pmem.free(pt_entry.*);

    pt_entry.* = 0;
    x86.invlpg(v_addr);
}

////
// Map a virtual memory zone.
//
// Arguments:
//     v_addr: Beginning of the virtual memory zone.
//     p_addr: Beginning of the physical memory zone (or null to allocate it).
//     size: Size of the memory zone.
//     flags: Paging flags (protection etc.)
//
pub fn mapZone(v_addr: usize, p_addr: ?usize, size: usize, flags: u32) void {
    var i: usize = 0;
    while (i < size) : (i += x86.PAGE_SIZE) {
        map(v_addr + i, if (p_addr) |p| p + i else null, flags);
    }
}

////
// Unmap a virtual memory zone.
//
// Arguments:
//     v_addr: Beginning of the virtual memory zone.
//     size: Size of the memory zone.
//
pub fn unmapZone(v_addr: usize, size: usize) void {
    var i: usize = 0;
    while (i < size) : (i += x86.PAGE_SIZE) {
        unmap(v_addr + i);
    }
}

////
// Enable the paging system (defined in assembly).
//
// Arguments:
//     phys_pd: Physical pointer to the page directory.
//
extern fn setupPaging(phys_pd: usize) void;

////
// Fill a page table with zeroes.
//
// Arguments:
//     page_table: The address of the table.
//
fn zeroPageTable(page_table: [*]PageEntry) void {
    const pt = @ptrCast([*]u8, page_table);
    @memset(pt, 0, x86.PAGE_SIZE);
}

////
// Initialize a new address space.
//
// Returns:
//     The address of the new Page Directory.
//
pub fn createAddressSpace() usize {
    // Allocate space for a new Page Directory.
    const phys_pd = pmem.allocate();
    const virt_pd = @intToPtr([*]PageEntry, layout.TMP);
    // Map it somewhere and initialize it.
    map(@ptrToInt(virt_pd), phys_pd, PAGE_WRITE);
    zeroPageTable(virt_pd);

    // Copy the kernel space of the original address space.
    var i: usize = 0;
    while (i < pdIndex(layout.USER)) : (i += 1) {
        virt_pd[i] = PD[i];
    }
    // Last PD entry -> PD itself (to map page tables at the end of memory).
    virt_pd[1023] = phys_pd | PAGE_PRESENT | PAGE_WRITE;

    return phys_pd;
}

////
// Unmap and deallocate all userspace in the current address space.
//
pub fn destroyAddressSpace() void {
    var i: usize = pdIndex(layout.USER);

    // NOTE: Preserve 1024th entry (contains the page tables).
    while (i < 1023) : (i += 1) {
        const v_addr = i * 0x400000;
        const pd_entry = pdEntry(v_addr);
        if (pd_entry.* == 0) continue;

        unmapZone(v_addr, 0x400000);
    }

    // TODO: deallocate page directory.
    // TODO: deallocate page tables.
}

////
// Handler for page faults interrupts.
//
fn pageFault() void {
    // Get the faulting address from the CR2 register.
    const address = x86.readCR2();
    // Get the error code from the interrupt stack.
    const code = isr.context.error_code;

    const err = if (code & PAGE_PRESENT != 0) "protection" else "non-present";
    const operation = if (code & PAGE_WRITE != 0) "write" else "read";
    const privilege = if (code & PAGE_USER != 0) "user" else "kernel";

    // Handle return from thread.
    if (address == layout.THREAD_DESTROY) {
        const thread = scheduler.current().?;
        return thread.destroy();
    }

    // Trigger a kernel panic with details about the error.
    tty.panic(
        \\page fault
        \\  address:    0x{X}
        \\  error:      {}
        \\  operation:  {}
        \\  privilege:  {}
    , address, err, operation, privilege);
}

////
// Initialize the virtual memory system.
//
pub fn initialize() void {
    tty.step("Initializing Paging", .{});

    // Ensure we map all the page stack.
    assert(pmem.stack_end < layout.IDENTITY);

    // Allocate a page for the Page Directory.
    const pd = @intToPtr([*]PageEntry, pmem.allocate());
    zeroPageTable(pd);

    // Identity map the kernel (first 8 MB) and point last entry of PD to the PD itself.
    pd[0] = 0x000000 | PAGE_PRESENT | PAGE_WRITE | PAGE_4MB | PAGE_GLOBAL;
    pd[1] = 0x400000 | PAGE_PRESENT | PAGE_WRITE | PAGE_4MB | PAGE_GLOBAL;
    pd[1023] = @ptrToInt(pd) | PAGE_PRESENT | PAGE_WRITE;
    // The recursive PD trick maps the whole paging hierarchy at the end of the address space.

    interrupt.register(14, pageFault); // Register the page fault handler.
    setupPaging(@ptrToInt(pd)); // Enable paging.

    tty.stepOK();
}
