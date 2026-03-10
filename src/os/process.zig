const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.process);

/// Get the current working directory of a process given its PID.
/// Returns null if the CWD cannot be determined.
/// The caller owns the returned memory.
pub fn getCwd(alloc: std.mem.Allocator, pid: posix.pid_t) ?[]u8 {
    return switch (builtin.os.tag) {
        .macos => getCwdMacos(alloc, pid),
        .linux => getCwdLinux(alloc, pid),
        else => null,
    };
}

/// macOS implementation using proc_pidinfo with PROC_PIDVNODEPATHINFO.
fn getCwdMacos(alloc: std.mem.Allocator, pid: posix.pid_t) ?[]u8 {
    const c = @cImport({
        @cInclude("libproc.h");
    });

    var vpi: c.proc_vnodepathinfo = undefined;
    const size = c.proc_pidinfo(
        pid,
        c.PROC_PIDVNODEPATHINFO,
        0,
        &vpi,
        @sizeOf(c.proc_vnodepathinfo),
    );

    if (size <= 0) {
        log.debug("proc_pidinfo failed for pid={}", .{pid});
        return null;
    }

    const path = std.mem.sliceTo(&vpi.pvi_cdir.vip_path, 0);
    if (path.len == 0) return null;

    return alloc.dupe(u8, path) catch null;
}

/// Linux implementation reading /proc/PID/cwd symlink.
fn getCwdLinux(alloc: std.mem.Allocator, pid: posix.pid_t) ?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_path = std.fmt.bufPrint(&buf, "/proc/{d}/cwd", .{pid}) catch return null;

    var result_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fs.readLinkAbsolute(link_path, &result_buf) catch |err| {
        log.debug("failed to read /proc/{d}/cwd: {}", .{ pid, err });
        return null;
    };

    if (path.len == 0) return null;

    return alloc.dupe(u8, path) catch null;
}

/// Get the foreground process group ID for a given PTY master fd.
/// This can be used to find the PID of the process the user is
/// currently interacting with (e.g., after running `cd`).
pub fn getForegroundPid(fd: posix.fd_t) ?posix.pid_t {
    if (comptime builtin.os.tag == .windows) return null;

    const c = @cImport({
        @cInclude("unistd.h");
    });

    const pgid = c.tcgetpgrp(fd);
    if (pgid < 0) return null;
    return pgid;
}
