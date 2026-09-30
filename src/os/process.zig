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
///
/// libproc.h is declared by hand rather than @cImport'ed: translating it pulls
/// in mach message headers whose bitfield structs Zig's translate-c can't
/// represent (they become opaque and fail the SDK's size assertions).
fn getCwdMacos(alloc: std.mem.Allocator, pid: posix.pid_t) ?[]u8 {
    const PROC_PIDVNODEPATHINFO = 9;
    const MAXPATHLEN = 1024;

    // struct vnode_info_path { struct vnode_info vip_vi; char vip_path[MAXPATHLEN]; }
    // where struct vnode_info is 152 bytes (vinfo_stat + type + pad + fsid).
    const VnodeInfoPath = extern struct {
        vip_vi: [152]u8,
        vip_path: [MAXPATHLEN]u8,
    };
    // struct proc_vnodepathinfo { vnode_info_path pvi_cdir, pvi_rdir; }
    const ProcVnodePathInfo = extern struct {
        pvi_cdir: VnodeInfoPath,
        pvi_rdir: VnodeInfoPath,
    };
    comptime std.debug.assert(@sizeOf(ProcVnodePathInfo) == 2352);

    const proc_pidinfo = @extern(
        *const fn (c_int, c_int, u64, ?*anyopaque, c_int) callconv(.c) c_int,
        .{ .name = "proc_pidinfo" },
    );

    var vpi: ProcVnodePathInfo = undefined;
    const size = proc_pidinfo(
        pid,
        PROC_PIDVNODEPATHINFO,
        0,
        &vpi,
        @sizeOf(ProcVnodePathInfo),
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
