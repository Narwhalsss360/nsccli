const std = @import("std");
const nstreamcom = @import("nstreamcom");

const GPA = std.heap.GeneralPurposeAllocator(.{});
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const OpenFlags = File.OpenFlags;
const OpenMode = File.OPenMode;
const Error = File.ReadError || File.WriteError || File.OpenError || Allocator.Error || nstreamcom.CollectorError || nstreamcom.DecoderError;
const CommandFunctionPointer = *const fn (Allocator, File) Error!void;
const StaticStringMap = std.static_string_map.StaticStringMap;


const CommandFunction = struct {
    ptr: CommandFunctionPointer,
    open_flags: OpenFlags
};

const argsWithAllocator = std.process.argsWithAllocator;
const panic = std.debug.panic;

const max_io_size = 1_000_000_000;

const command_map = StaticStringMap(CommandFunctionPointer).initComptime(.{
    .{
        "encode",
        encodeCommand,
    },
    .{
        "decode",
        decodeCommand
    },
    .{
        "encode-with-size",
        encodeWithSizeCommand
    },
    .{
        "collect",
        collectCommand
    }
});

pub fn main() Error!void {
    const stderr = std.io.getStdErr().writer();

    var gpa = GPA {};
    defer if (gpa.deinit() == .leak) panic("Memory leak detected by allocator\n", .{});

    const allocator = gpa.allocator();

    var cwd = std.fs.cwd();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next() orelse unreachable;

    const input_file_path = args.next() orelse {
        try stderr.print("Must specify an input file.\nusage: <path> <command>\n", .{});
        return;
    };

    const command_name = args.next() orelse {
        try stderr.print("Must specify a command.\nencode, decode\n", .{});
        return;
    };

    const command_function = command_map.get(command_name) orelse {
        try stderr.print("E: '{s}' is not a command", .{command_name});
        return;
    };

    const input_file = try cwd.openFile(input_file_path, .{});
    defer input_file.close();
    return command_function(allocator, input_file);
}

fn decodeCommand(allocator: Allocator, file: File) Error!void {
    const stdout = std.io.getStdOut().writer();

    const text = try file.readToEndAlloc(allocator, max_io_size);
    defer allocator.free(text);

    const decoded: []u8 = try allocator.alloc(u8, nstreamcom.asDataSize(@intCast(text.len)));
    defer allocator.free(decoded);
    nstreamcom.decode(text, decoded);
    _ = try stdout.write(decoded);
}

fn encodeCommand(allocator: Allocator, file: File) Error!void {
    const stdout = std.io.getStdOut().writer();

    const text = try file.readToEndAlloc(allocator, max_io_size);
    defer allocator.free(text);

    const encoded: []u8 = try allocator.alloc(u8, nstreamcom.asTransmissionSize(@intCast(text.len)));
    defer allocator.free(encoded);
    nstreamcom.encode(text, encoded);

    _ = try stdout.write(encoded);
}

fn encodeWithSizeCommand(allocator: Allocator, file: File) Error!void {
    const stdout = std.io.getStdOut().writer();

    const text = try file.readToEndAlloc(allocator, max_io_size);
    defer allocator.free(text);

    const encoded: []u8 = try allocator.alloc(u8, nstreamcom.asCollectedSize(@intCast(text.len)));
    defer allocator.free(encoded);
    nstreamcom.encodeWithSize(text, encoded);

    _ = try stdout.write(encoded);
}

fn collectCommand(allocator: Allocator, file: File) Error!void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const text = try file.readToEndAlloc(allocator, max_io_size);
    defer allocator.free(text);

    const decoded_buffer: []u8 = try allocator.alloc(u8, nstreamcom.asDataSize(@intCast(text.len)));
    defer allocator.free(decoded_buffer);
    var decoder = nstreamcom.Decoder { .buffer = decoded_buffer };
    var collector = nstreamcom.Collector { .decoder = &decoder };

    for (text) |byte| {
        try collector.collect(byte);
        if (collector.state == nstreamcom.CollectorState.Collected) {
            break;
        }
    }

    if (collector.state != nstreamcom.CollectorState.Collected) {
        try stderr.print("Did not collect, current state: {s}", .{@tagName(collector.state)});
        return;
    }

    _ = try stdout.write(decoded_buffer[0..collector.next_size]);
}
