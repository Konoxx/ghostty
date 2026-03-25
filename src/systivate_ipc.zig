//! Systivate IPC command channel — Unix domain socket for runtime control.
//!
//! Runs a dedicated thread that listens on ~/.ccs/ghostty-ipc.sock.
//! External tools send newline-delimited text commands and receive JSON responses.
//! Commands dispatch to renderer/IO threads via atomic flags and mailboxes.
//!
//! Usage: echo "get health" | nc -U ~/.ccs/ghostty-ipc.sock

const std = @import("std");
const posix = std.posix;
const log = std.log.scoped(.systivate_ipc);

const commands = @import("systivate_ipc_commands.zig");

// ── Configuration ──

const MAX_CLIENTS = 8;
const READ_BUF_SIZE = 4096;
const CLIENT_TIMEOUT_MS = 30_000;
const SOCKET_BACKLOG = 4;

// ── State ──

var listen_fd: posix.fd_t = -1;
var thread_handle: ?std.Thread = null;
var shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var shutdown_pipe: [2]posix.fd_t = .{ -1, -1 };
var socket_path_buf: [256]u8 = undefined;
var socket_path_z: [*:0]u8 = undefined;
var socket_path_len: usize = 0;

pub fn getClientCount() usize {
    return client_count;
}

// ── Client tracking ──

const Client = struct {
    fd: posix.fd_t,
    buf: [READ_BUF_SIZE]u8,
    buf_len: usize,
    last_activity_ms: i64,
};

var clients: [MAX_CLIENTS]?Client = .{null} ** MAX_CLIENTS;
var client_count: usize = 0;

// ── Public API ──

pub fn init() void {
    // Runtime kill switch: GHOSTTY_IPC=0 disables the IPC channel entirely.
    // Also disabled by touching ~/.ccs/ghostty-ipc.disabled
    if (posix.getenv("GHOSTTY_IPC")) |val| {
        if (std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "off")) {
            log.info("IPC disabled via GHOSTTY_IPC=0", .{});
            return;
        }
    }

    const home = posix.getenv("HOME") orelse {
        log.warn("HOME not set, IPC disabled", .{});
        return;
    };

    // Check for disable sentinel file
    var disable_buf: [256]u8 = undefined;
    const disable_path = std.fmt.bufPrintZ(&disable_buf, "{s}/.ccs/ghostty-ipc.disabled", .{home}) catch null;
    if (disable_path) |dp| {
        if (std.fs.accessAbsolute(std.mem.sliceTo(dp, 0), .{})) {
            log.info("IPC disabled via ~/.ccs/ghostty-ipc.disabled sentinel", .{});
            return;
        } else |_| {}
    }

    // Build socket path
    const path_slice = std.fmt.bufPrintZ(&socket_path_buf, "{s}/.ccs/ghostty-ipc.sock", .{home}) catch {
        log.warn("socket path too long, IPC disabled", .{});
        return;
    };
    socket_path_z = path_slice.ptr;
    socket_path_len = path_slice.len;

    // Ensure directory exists
    const dir_end = std.mem.lastIndexOfScalar(u8, path_slice, '/') orelse return;
    var dir_buf: [256]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}", .{path_slice[0..dir_end]}) catch return;
    std.fs.makeDirAbsolute(std.mem.sliceTo(dir_path, 0)) catch {};

    // Handle stale socket: try connect, if ECONNREFUSED → unlink
    if (tryConnect(path_slice)) {
        log.warn("another Ghostty instance owns the socket, IPC disabled", .{});
        return;
    }

    // Unlink any stale socket
    posix.unlink(std.mem.sliceTo(socket_path_z, 0)) catch {};

    // Create socket
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| {
        log.warn("socket() failed: {}", .{err});
        return;
    };

    // Bind
    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    const path_bytes = std.mem.sliceTo(socket_path_z, 0);
    if (path_bytes.len >= addr.path.len) {
        log.warn("socket path too long for sockaddr_un", .{});
        posix.close(fd);
        return;
    }
    @memcpy(addr.path[0..path_bytes.len], path_bytes);

    posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
        log.warn("bind() failed: {}", .{err});
        posix.close(fd);
        return;
    };

    // Listen
    posix.listen(fd, SOCKET_BACKLOG) catch |err| {
        log.warn("listen() failed: {}", .{err});
        posix.close(fd);
        posix.unlink(std.mem.sliceTo(socket_path_z, 0)) catch {};
        return;
    };

    listen_fd = fd;

    // Create shutdown pipe
    const pipe_result = posix.pipe() catch {
        log.warn("pipe() failed for shutdown, IPC disabled", .{});
        posix.close(fd);
        posix.unlink(std.mem.sliceTo(socket_path_z, 0)) catch {};
        listen_fd = -1;
        return;
    };
    shutdown_pipe = pipe_result;

    // Spawn IPC thread
    thread_handle = std.Thread.spawn(.{}, threadMain, .{}) catch |err| {
        log.warn("thread spawn failed: {}", .{err});
        posix.close(fd);
        posix.unlink(std.mem.sliceTo(socket_path_z, 0)) catch {};
        posix.close(shutdown_pipe[0]);
        posix.close(shutdown_pipe[1]);
        listen_fd = -1;
        return;
    };

    log.info("IPC channel listening on {s}", .{path_slice});
}

pub fn deinit() void {
    if (listen_fd == -1) return;

    // Signal thread to exit
    shutdown_requested.store(true, .release);
    _ = posix.write(shutdown_pipe[1], "x") catch {};

    // Join thread
    if (thread_handle) |t| {
        t.join();
        thread_handle = null;
    }

    // Close all client fds
    for (&clients) |*slot| {
        if (slot.*) |c| {
            posix.close(c.fd);
            slot.* = null;
        }
    }
    client_count = 0;

    // Cleanup
    posix.close(listen_fd);
    posix.close(shutdown_pipe[0]);
    posix.close(shutdown_pipe[1]);
    posix.unlink(std.mem.sliceTo(socket_path_z, 0)) catch {};
    listen_fd = -1;

    log.info("IPC channel shut down", .{});
}

/// Request graceful IPC shutdown from a command handler.
/// Signals the thread to exit; deinit runs on the IPC thread.
pub fn requestShutdown() void {
    shutdown_requested.store(true, .release);
    _ = posix.write(shutdown_pipe[1], "x") catch {};
    log.info("IPC shutdown requested via command", .{});
}

/// Called from crash handler — async-signal-safe socket cleanup.
pub fn crashCleanup() void {
    if (socket_path_len > 0) {
        // Use raw syscall for async-signal-safety (unlink is safe)
        _ = std.c.unlink(socket_path_z);
    }
}

// ── Thread main ──

fn threadMain() void {
    log.info("IPC thread started", .{});

    while (!shutdown_requested.load(.acquire)) {
        // Build pollfd array: [shutdown_pipe, listen_fd, ...client_fds]
        var pollfds: [2 + MAX_CLIENTS]posix.pollfd = undefined;
        var nfds: usize = 0;

        // Shutdown pipe (index 0)
        pollfds[0] = .{ .fd = shutdown_pipe[0], .events = posix.POLL.IN, .revents = 0 };
        nfds += 1;

        // Listen socket (index 1)
        pollfds[1] = .{ .fd = listen_fd, .events = posix.POLL.IN, .revents = 0 };
        nfds += 1;

        // Client fds
        var client_poll_map: [MAX_CLIENTS]usize = undefined; // maps pollfd index → client slot
        for (clients, 0..) |slot, i| {
            if (slot) |c| {
                client_poll_map[nfds - 2] = i;
                pollfds[nfds] = .{ .fd = c.fd, .events = posix.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }

        // Poll with 5s timeout (for idle client cleanup)
        const n = posix.poll(pollfds[0..nfds], 5000) catch |err| {
            if (err == error.Interrupted) continue;
            log.warn("poll() error: {}", .{err});
            continue;
        };
        if (n == 0) {
            // Timeout — check for idle clients
            evictIdleClients();
            continue;
        }

        // Check shutdown
        if (pollfds[0].revents & posix.POLL.IN != 0) break;

        // Check new connections
        if (pollfds[1].revents & posix.POLL.IN != 0) {
            acceptClient();
        }

        // Check client data
        var poll_idx: usize = 2;
        for (clients, 0..) |slot, i| {
            if (slot != null) {
                if (poll_idx < nfds and pollfds[poll_idx].revents & posix.POLL.IN != 0) {
                    handleClientData(i);
                }
                poll_idx += 1;
            }
        }
    }

    log.info("IPC thread exiting", .{});
}

fn acceptClient() void {
    const client_fd = posix.accept(listen_fd, null, null, 0) catch {
        return;
    };

    if (client_count >= MAX_CLIENTS) {
        // Reject — too many clients
        const msg = "{\"ok\":false,\"error\":\"too many clients\"}\n";
        _ = posix.write(client_fd, msg) catch {};
        posix.close(client_fd);
        return;
    }

    // Find empty slot
    for (&clients) |*slot| {
        if (slot.* == null) {
            slot.* = Client{
                .fd = client_fd,
                .buf = undefined,
                .buf_len = 0,
                .last_activity_ms = std.time.milliTimestamp(),
            };
            client_count += 1;
            return;
        }
    }
}

fn handleClientData(slot_idx: usize) void {
    var client = &(clients[slot_idx] orelse return);

    const space = client.buf[client.buf_len..];
    if (space.len == 0) {
        // Buffer full with no newline — discard and disconnect
        removeClient(slot_idx);
        return;
    }

    const n = posix.read(client.fd, space) catch {
        removeClient(slot_idx);
        return;
    };

    if (n == 0) {
        // EOF
        removeClient(slot_idx);
        return;
    }

    client.buf_len += n;
    client.last_activity_ms = std.time.milliTimestamp();

    // Process complete lines
    while (true) {
        const line_end = std.mem.indexOfScalar(u8, client.buf[0..client.buf_len], '\n') orelse break;
        const line = client.buf[0..line_end];

        // Execute command
        var resp_buf: [4096]u8 = undefined;
        const response = commands.execute(line, &resp_buf);

        // Write response (non-blocking — drop if would block)
        _ = posix.write(client.fd, response) catch {};
        _ = posix.write(client.fd, "\n") catch {};

        // Shift buffer
        const remaining = client.buf_len - line_end - 1;
        if (remaining > 0) {
            std.mem.copyForwards(u8, &client.buf, client.buf[line_end + 1 .. client.buf_len]);
        }
        client.buf_len = remaining;
    }
}

fn removeClient(slot_idx: usize) void {
    if (clients[slot_idx]) |c| {
        posix.close(c.fd);
        clients[slot_idx] = null;
        client_count -= 1;
    }
}

fn evictIdleClients() void {
    const now = std.time.milliTimestamp();
    for (&clients, 0..) |*slot, i| {
        if (slot.*) |c| {
            if (now - c.last_activity_ms > CLIENT_TIMEOUT_MS) {
                log.info("evicting idle IPC client (slot {})", .{i});
                removeClient(i);
            }
        }
    }
}

fn tryConnect(path: [*:0]const u8) bool {
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    const path_bytes = std.mem.sliceTo(path, 0);
    if (path_bytes.len >= addr.path.len) return false;
    @memcpy(addr.path[0..path_bytes.len], path_bytes);

    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        return false; // ECONNREFUSED or other — socket is stale
    };
    return true; // Connected — another instance owns it
}
