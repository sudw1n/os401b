see the commit description of the feature where I added the heap expansion feature

Source code for kernel lives at the kernel/src/ directory. All of the paths below are relative to
kernel/src/lib/.

You should start with documenting the memory management system, which is the probably the most complex part of
the kernel right now.

Refer to the OSDev Notes PDF (see the part about memory management), as I have followed and
implemented the concepts described there.

1. implementation of PhysicalMemoryManager -> memory/pmm.zig
2. paging related code, such as mapping virtual addresses to physical addresses (mapRange(), mapPage() functions) by creating and doing the page table hierarchy walk as described in our report. I have also now added logic to unmap pages, and memory ranges. -> memory/paging.zig
3. implementation of VirtualMemoryManager. -> memory/vmm.zig
4. Heap allocator (almost finished) -> memory/allocator.zig
5. This might be a bit confusing but I use a fixed buffer allocator provided by the Zig standard library to allocate memory in the VMM itself. This is used to allocate VmObjects dynamically. The VmObjects are used by the VMM to manage virtual memory mappings. There is a small piece of code that initializes the Fixed Buffer Allocator (to be used only by the VMM) and that lives at: -> memory/vmm_heap.zig
