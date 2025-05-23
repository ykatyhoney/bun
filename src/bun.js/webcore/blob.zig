const std = @import("std");
const Api = @import("../../api/schema.zig").Api;
const bun = @import("root").bun;
const MimeType = http.MimeType;
const ZigURL = @import("../../url.zig").URL;
const http = bun.http;
const JSC = bun.JSC;
const io = bun.io;
const Method = @import("../../http/method.zig").Method;
const FetchHeaders = JSC.FetchHeaders;
const ObjectPool = @import("../../pool.zig").ObjectPool;
const SystemError = JSC.SystemError;
const Output = bun.Output;
const MutableString = bun.MutableString;
const strings = bun.strings;
const string = bun.string;
const default_allocator = bun.default_allocator;
const FeatureFlags = bun.FeatureFlags;
const ArrayBuffer = @import("../base.zig").ArrayBuffer;
const Properties = @import("../base.zig").Properties;
const getAllocator = @import("../base.zig").getAllocator;
const JSError = bun.JSError;

const Environment = @import("../../env.zig");
const ZigString = JSC.ZigString;
const IdentityContext = @import("../../identity_context.zig").IdentityContext;
const JSPromise = JSC.JSPromise;
const JSValue = JSC.JSValue;
const JSGlobalObject = JSC.JSGlobalObject;
const NullableAllocator = bun.NullableAllocator;

const VirtualMachine = JSC.VirtualMachine;
const Task = JSC.Task;
const JSPrinter = bun.js_printer;
const picohttp = bun.picohttp;
const StringJoiner = bun.StringJoiner;
const uws = bun.uws;

const invalid_fd = bun.invalid_fd;
const Response = JSC.WebCore.Response;
const Body = JSC.WebCore.Body;
const Request = JSC.WebCore.Request;

const libuv = bun.windows.libuv;

const S3 = bun.S3;
const S3Credentials = S3.S3Credentials;
const PathOrBlob = JSC.Node.PathOrBlob;
const PathLike = JSC.Node.PathLike;
const WriteFilePromise = @import("blob/WriteFile.zig").WriteFilePromise;
const WriteFileWaitFromLockedValueTask = @import("blob/WriteFile.zig").WriteFileWaitFromLockedValueTask;
const NewReadFileHandler = @import("blob/ReadFile.zig").NewReadFileHandler;

const S3File = @import("S3File.zig");

pub const Blob = struct {
    const bloblog = Output.scoped(.Blob, false);

    pub const new = bun.TrivialNew(@This());
    pub const js = JSC.Codegen.JSBlob;
    // NOTE: toJS is overridden
    pub const fromJS = js.fromJS;
    pub const fromJSDirect = js.fromJSDirect;

    const rf = @import("blob/ReadFile.zig");
    pub const ReadFile = rf.ReadFile;
    pub const ReadFileUV = rf.ReadFileUV;
    pub const ReadFileTask = rf.ReadFileTask;
    pub const ReadFileResultType = rf.ReadFileResultType;

    const wf = @import("blob/WriteFile.zig");
    pub const WriteFile = wf.WriteFile;
    pub const WriteFileWindows = wf.WriteFileWindows;
    pub const WriteFileTask = wf.WriteFileTask;

    pub const ClosingState = enum(u8) {
        running,
        closing,
    };

    reported_estimated_size: usize = 0,

    size: SizeType = 0,
    offset: SizeType = 0,
    /// When set, the blob will be freed on finalization callbacks
    /// If the blob is contained in Response or Request, this must be null
    allocator: ?std.mem.Allocator = null,
    store: ?*Store = null,
    content_type: string = "",
    content_type_allocated: bool = false,
    content_type_was_set: bool = false,

    /// JavaScriptCore strings are either latin1 or UTF-16
    /// When UTF-16, they're nearly always due to non-ascii characters
    is_all_ascii: ?bool = null,

    /// Was it created via file constructor?
    is_jsdom_file: bool = false,

    globalThis: *JSGlobalObject = undefined,

    last_modified: f64 = 0.0,
    /// Blob name will lazy initialize when getName is called, but
    /// we must be able to set the name, and we need to keep the value alive
    /// https://github.com/oven-sh/bun/issues/10178
    name: bun.String = bun.String.dead,

    /// Max int of double precision
    /// 9 petabytes is probably enough for awhile
    /// We want to avoid coercing to a BigInt because that's a heap allocation
    /// and it's generally just harder to use
    pub const SizeType = u52;
    pub const max_size = std.math.maxInt(SizeType);

    /// 1: Initial
    /// 2: Added byte for whether it's a dom file, length and bytes for `stored_name`,
    ///    and f64 for `last_modified`. Removed reserved bytes, it's handled by version
    ///    number.
    const serialization_version: u8 = 2;

    pub fn getFormDataEncoding(this: *Blob) ?*bun.FormData.AsyncFormData {
        var content_type_slice: ZigString.Slice = this.getContentType() orelse return null;
        defer content_type_slice.deinit();
        const encoding = bun.FormData.Encoding.get(content_type_slice.slice()) orelse return null;
        return bun.FormData.AsyncFormData.init(this.allocator orelse bun.default_allocator, encoding) catch bun.outOfMemory();
    }

    pub fn hasContentTypeFromUser(this: *const Blob) bool {
        return this.content_type_was_set or (this.store != null and (this.store.?.data == .file or this.store.?.data == .s3));
    }

    pub fn contentTypeOrMimeType(this: *const Blob) ?[]const u8 {
        if (this.content_type.len > 0) {
            return this.content_type;
        }
        if (this.store) |store| {
            switch (store.data) {
                .file => |file| {
                    return file.mime_type.value;
                },
                .s3 => |s3| {
                    return s3.mime_type.value;
                },
                else => return null,
            }
        }
        return null;
    }

    pub fn isBunFile(this: *const Blob) bool {
        const store = this.store orelse return false;

        return store.data == .file;
    }

    pub fn doReadFromS3(this: *Blob, comptime Function: anytype, global: *JSGlobalObject) JSValue {
        bloblog("doReadFromS3", .{});

        const WrappedFn = struct {
            pub fn wrapped(b: *Blob, g: *JSGlobalObject, by: []u8) JSC.JSValue {
                return JSC.toJSHostValue(g, Function(b, g, by, .clone));
            }
        };
        return S3BlobDownloadTask.init(global, this, WrappedFn.wrapped);
    }
    pub fn doReadFile(this: *Blob, comptime Function: anytype, global: *JSGlobalObject) JSValue {
        bloblog("doReadFile", .{});

        const Handler = NewReadFileHandler(Function);

        var handler = bun.new(Handler, .{
            .context = this.*,
            .globalThis = global,
        });

        if (Environment.isWindows) {
            var promise = JSPromise.create(global);
            const promise_value = promise.asValue(global);
            promise_value.ensureStillAlive();
            handler.promise.strong.set(global, promise_value);

            ReadFileUV.start(handler.globalThis.bunVM().uvLoop(), this.store.?, this.offset, this.size, Handler, handler);

            return promise_value;
        }

        const file_read = ReadFile.create(
            bun.default_allocator,
            this.store.?,
            this.offset,
            this.size,
            *Handler,
            handler,
            Handler.run,
        ) catch bun.outOfMemory();
        var read_file_task = ReadFileTask.createOnJSThread(bun.default_allocator, global, file_read) catch bun.outOfMemory();

        // Create the Promise only after the store has been ref()'d.
        // The garbage collector runs on memory allocations
        // The JSPromise is the next GC'd memory allocation.
        // This shouldn't really fix anything, but it's a little safer.
        var promise = JSPromise.create(global);
        const promise_value = promise.asValue(global);
        promise_value.ensureStillAlive();
        handler.promise.strong.set(global, promise_value);

        read_file_task.schedule();

        bloblog("doReadFile: read_file_task scheduled", .{});
        return promise_value;
    }

    pub fn NewInternalReadFileHandler(comptime Context: type, comptime Function: anytype) type {
        return struct {
            pub fn run(handler: *anyopaque, bytes_: ReadFileResultType) void {
                Function(bun.cast(Context, handler), bytes_);
            }
        };
    }

    pub fn doReadFileInternal(this: *Blob, comptime Handler: type, ctx: Handler, comptime Function: anytype, global: *JSGlobalObject) void {
        if (Environment.isWindows) {
            const ReadFileHandler = NewInternalReadFileHandler(Handler, Function);
            return ReadFileUV.start(libuv.Loop.get(), this.store.?, this.offset, this.size, ReadFileHandler, ctx);
        }
        const file_read = ReadFile.createWithCtx(
            bun.default_allocator,
            this.store.?,
            ctx,
            NewInternalReadFileHandler(Handler, Function).run,
            this.offset,
            this.size,
        ) catch bun.outOfMemory();
        var read_file_task = ReadFileTask.createOnJSThread(bun.default_allocator, global, file_read) catch bun.outOfMemory();
        read_file_task.schedule();
    }

    const FormDataContext = struct {
        allocator: std.mem.Allocator,
        joiner: StringJoiner,
        boundary: []const u8,
        failed: bool = false,
        globalThis: *JSC.JSGlobalObject,

        pub fn onEntry(this: *FormDataContext, name: ZigString, entry: JSC.DOMFormData.FormDataEntry) void {
            if (this.failed) return;
            var globalThis = this.globalThis;

            const allocator = this.allocator;
            const joiner = &this.joiner;
            const boundary = this.boundary;

            joiner.pushStatic("--");
            joiner.pushStatic(boundary); // note: "static" here means "outlives the joiner"
            joiner.pushStatic("\r\n");

            joiner.pushStatic("Content-Disposition: form-data; name=\"");
            const name_slice = name.toSlice(allocator);
            joiner.push(name_slice.slice(), name_slice.allocator.get());

            switch (entry) {
                .string => |value| {
                    joiner.pushStatic("\"\r\n\r\n");
                    const value_slice = value.toSlice(allocator);
                    joiner.push(value_slice.slice(), value_slice.allocator.get());
                },
                .file => |value| {
                    joiner.pushStatic("\"; filename=\"");
                    const filename_slice = value.filename.toSlice(allocator);
                    joiner.push(filename_slice.slice(), filename_slice.allocator.get());
                    joiner.pushStatic("\"\r\n");

                    const blob = value.blob;
                    const content_type = if (blob.content_type.len > 0) blob.content_type else "application/octet-stream";
                    joiner.pushStatic("Content-Type: ");
                    joiner.pushStatic(content_type);
                    joiner.pushStatic("\r\n\r\n");

                    if (blob.store) |store| {
                        if (blob.size == Blob.max_size) {
                            blob.resolveSize();
                        }
                        switch (store.data) {
                            .s3 => |_| {
                                // TODO: s3
                                // we need to make this async and use download/downloadSlice
                            },
                            .file => |file| {

                                // TODO: make this async + lazy
                                const res = JSC.Node.NodeFS.readFile(
                                    globalThis.bunVM().nodeFS(),
                                    .{
                                        .encoding = .buffer,
                                        .path = file.pathlike,
                                        .offset = blob.offset,
                                        .max_size = blob.size,
                                    },
                                    .sync,
                                );

                                switch (res) {
                                    .err => |err| {
                                        globalThis.throwValue(err.toJSC(globalThis)) catch {};
                                        this.failed = true;
                                    },
                                    .result => |result| {
                                        joiner.push(result.slice(), result.buffer.allocator);
                                    },
                                }
                            },
                            .bytes => |_| {
                                joiner.pushStatic(blob.sharedView());
                            },
                        }
                    }
                },
            }

            joiner.pushStatic("\r\n");
        }
    };

    pub fn getContentType(
        this: *Blob,
    ) ?ZigString.Slice {
        if (this.content_type.len > 0)
            return ZigString.Slice.fromUTF8NeverFree(this.content_type);

        return null;
    }

    const StructuredCloneWriter = struct {
        ctx: *anyopaque,
        impl: *const fn (*anyopaque, ptr: [*]const u8, len: u32) callconv(JSC.conv) void,

        pub const WriteError = error{};
        pub fn write(this: StructuredCloneWriter, bytes: []const u8) WriteError!usize {
            this.impl(this.ctx, bytes.ptr, @as(u32, @truncate(bytes.len)));
            return bytes.len;
        }
    };

    fn _onStructuredCloneSerialize(
        this: *Blob,
        comptime Writer: type,
        writer: Writer,
    ) !void {
        try writer.writeInt(u8, serialization_version, .little);

        try writer.writeInt(u64, @intCast(this.offset), .little);

        try writer.writeInt(u32, @truncate(this.content_type.len), .little);
        try writer.writeAll(this.content_type);
        try writer.writeInt(u8, @intFromBool(this.content_type_was_set), .little);

        const store_tag: Store.SerializeTag = if (this.store) |store|
            if (store.data == .file) .file else .bytes
        else
            .empty;

        try writer.writeInt(u8, @intFromEnum(store_tag), .little);

        this.resolveSize();
        if (this.store) |store| {
            try store.serialize(Writer, writer);
        }

        try writer.writeInt(u8, @intFromBool(this.is_jsdom_file), .little);
        try writeFloat(f64, this.last_modified, Writer, writer);
    }

    pub fn onStructuredCloneSerialize(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        ctx: *anyopaque,
        writeBytes: *const fn (*anyopaque, ptr: [*]const u8, len: u32) callconv(JSC.conv) void,
    ) void {
        _ = globalThis;

        const Writer = std.io.Writer(StructuredCloneWriter, StructuredCloneWriter.WriteError, StructuredCloneWriter.write);
        const writer = Writer{
            .context = .{
                .ctx = ctx,
                .impl = writeBytes,
            },
        };

        try _onStructuredCloneSerialize(this, Writer, writer);
    }

    pub fn onStructuredCloneTransfer(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        ctx: *anyopaque,
        write: *const fn (*anyopaque, ptr: [*]const u8, len: usize) callconv(.C) void,
    ) void {
        _ = write;
        _ = ctx;
        _ = this;
        _ = globalThis;
    }

    fn writeFloat(
        comptime FloatType: type,
        value: FloatType,
        comptime Writer: type,
        writer: Writer,
    ) !void {
        const bytes: [@sizeOf(FloatType)]u8 = @bitCast(value);
        try writer.writeAll(&bytes);
    }

    fn readFloat(
        comptime FloatType: type,
        comptime Reader: type,
        reader: Reader,
    ) !FloatType {
        const bytes = try reader.readBoundedBytes(@sizeOf(FloatType));
        return @bitCast(bytes.slice()[0..@sizeOf(FloatType)].*);
    }

    fn readSlice(
        reader: anytype,
        len: usize,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        var slice = try allocator.alloc(u8, len);
        slice = slice[0..try reader.read(slice)];
        if (slice.len != len) return error.TooSmall;
        return slice;
    }

    fn _onStructuredCloneDeserialize(
        globalThis: *JSC.JSGlobalObject,
        comptime Reader: type,
        reader: Reader,
    ) !JSValue {
        const allocator = bun.default_allocator;

        const version = try reader.readInt(u8, .little);

        const offset = try reader.readInt(u64, .little);

        const content_type_len = try reader.readInt(u32, .little);

        const content_type = try readSlice(reader, content_type_len, allocator);

        const content_type_was_set: bool = try reader.readInt(u8, .little) != 0;

        const store_tag = try reader.readEnum(Store.SerializeTag, .little);

        const blob: *Blob = switch (store_tag) {
            .bytes => bytes: {
                const bytes_len = try reader.readInt(u32, .little);
                const bytes = try readSlice(reader, bytes_len, allocator);

                const blob = Blob.init(bytes, allocator, globalThis);

                versions: {
                    if (version == 1) break :versions;

                    const name_len = try reader.readInt(u32, .little);
                    const name = try readSlice(reader, name_len, allocator);

                    if (blob.store) |store| switch (store.data) {
                        .bytes => |*bytes_store| bytes_store.stored_name = bun.PathString.init(name),
                        else => {},
                    };

                    if (version == 2) break :versions;
                }

                break :bytes Blob.new(blob);
            },
            .file => file: {
                const pathlike_tag = try reader.readEnum(JSC.Node.PathOrFileDescriptor.SerializeTag, .little);

                switch (pathlike_tag) {
                    .fd => {
                        const fd = try reader.readStruct(bun.FD);

                        var path_or_fd = JSC.Node.PathOrFileDescriptor{
                            .fd = fd,
                        };
                        const blob = Blob.new(Blob.findOrCreateFileFromPath(
                            &path_or_fd,
                            globalThis,
                            true,
                        ));

                        break :file blob;
                    },
                    .path => {
                        const path_len = try reader.readInt(u32, .little);

                        const path = try readSlice(reader, path_len, default_allocator);
                        var dest = JSC.Node.PathOrFileDescriptor{
                            .path = .{
                                .string = bun.PathString.init(path),
                            },
                        };
                        const blob = Blob.new(Blob.findOrCreateFileFromPath(
                            &dest,
                            globalThis,
                            true,
                        ));

                        break :file blob;
                    },
                }

                return .zero;
            },
            .empty => Blob.new(Blob.initEmpty(globalThis)),
        };

        versions: {
            if (version == 1) break :versions;

            blob.is_jsdom_file = try reader.readInt(u8, .little) != 0;
            blob.last_modified = try readFloat(f64, Reader, reader);

            if (version == 2) break :versions;
        }

        blob.allocator = allocator;
        blob.offset = @as(u52, @intCast(offset));
        if (content_type.len > 0) {
            blob.content_type = content_type;
            blob.content_type_allocated = true;
            blob.content_type_was_set = content_type_was_set;
        }

        return blob.toJS(globalThis);
    }

    pub fn onStructuredCloneDeserialize(globalThis: *JSC.JSGlobalObject, ptr: [*]u8, end: [*]u8) bun.JSError!JSValue {
        const total_length: usize = @intFromPtr(end) - @intFromPtr(ptr);
        var buffer_stream = std.io.fixedBufferStream(ptr[0..total_length]);
        const reader = buffer_stream.reader();

        return _onStructuredCloneDeserialize(globalThis, @TypeOf(reader), reader) catch |err| switch (err) {
            error.EndOfStream, error.TooSmall, error.InvalidValue => {
                return globalThis.throw("Blob.onStructuredCloneDeserialize failed", .{});
            },
            error.OutOfMemory => {
                return globalThis.throwOutOfMemory();
            },
        };
    }

    const URLSearchParamsConverter = struct {
        allocator: std.mem.Allocator,
        buf: []u8 = "",
        globalThis: *JSC.JSGlobalObject,
        pub fn convert(this: *URLSearchParamsConverter, str: ZigString) void {
            var out = str.toSlice(this.allocator).cloneIfNeeded(this.allocator) catch bun.outOfMemory();
            this.buf = @constCast(out.slice());
        }
    };

    pub fn fromURLSearchParams(
        globalThis: *JSC.JSGlobalObject,
        allocator: std.mem.Allocator,
        search_params: *JSC.URLSearchParams,
    ) Blob {
        var converter = URLSearchParamsConverter{
            .allocator = allocator,
            .globalThis = globalThis,
        };
        search_params.toString(URLSearchParamsConverter, &converter, URLSearchParamsConverter.convert);
        var store = Blob.Store.init(converter.buf, allocator);
        store.mime_type = MimeType.all.@"application/x-www-form-urlencoded";

        var blob = Blob.initWithStore(store, globalThis);
        blob.content_type = store.mime_type.value;
        blob.content_type_was_set = true;
        return blob;
    }

    pub fn fromDOMFormData(
        globalThis: *JSC.JSGlobalObject,
        allocator: std.mem.Allocator,
        form_data: *JSC.DOMFormData,
    ) Blob {
        var arena = bun.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var stack_allocator = std.heap.stackFallback(1024, arena.allocator());
        const stack_mem_all = stack_allocator.get();

        var hex_buf: [70]u8 = undefined;
        const boundary = brk: {
            var random = globalThis.bunVM().rareData().nextUUID().bytes;
            const formatter = std.fmt.fmtSliceHexLower(&random);
            break :brk std.fmt.bufPrint(&hex_buf, "-WebkitFormBoundary{any}", .{formatter}) catch unreachable;
        };

        var context = FormDataContext{
            .allocator = allocator,
            .joiner = .{ .allocator = stack_mem_all },
            .boundary = boundary,
            .globalThis = globalThis,
        };

        form_data.forEach(FormDataContext, &context, FormDataContext.onEntry);
        if (context.failed) {
            return Blob.initEmpty(globalThis);
        }

        context.joiner.pushStatic("--");
        context.joiner.pushStatic(boundary);
        context.joiner.pushStatic("--\r\n");

        const store = Blob.Store.init(context.joiner.done(allocator) catch bun.outOfMemory(), allocator);
        var blob = Blob.initWithStore(store, globalThis);
        blob.content_type = std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary}) catch bun.outOfMemory();
        blob.content_type_allocated = true;
        blob.content_type_was_set = true;

        return blob;
    }

    pub fn contentType(this: *const Blob) string {
        return this.content_type;
    }

    pub fn isDetached(this: *const Blob) bool {
        return this.store == null;
    }

    export fn Blob__dupeFromJS(value: JSC.JSValue) ?*Blob {
        const this = Blob.fromJS(value) orelse return null;
        return Blob__dupe(this);
    }

    export fn Blob__setAsFile(this: *Blob, path_str: *bun.String) *Blob {
        this.is_jsdom_file = true;

        // This is not 100% correct...
        if (this.store) |store| {
            if (store.data == .bytes) {
                if (store.data.bytes.stored_name.len == 0) {
                    var utf8 = path_str.toUTF8WithoutRef(bun.default_allocator).clone(bun.default_allocator) catch unreachable;
                    store.data.bytes.stored_name = bun.PathString.init(utf8.slice());
                }
            }
        }

        return this;
    }

    export fn Blob__dupe(ptr: *anyopaque) *Blob {
        const this = bun.cast(*Blob, ptr);
        const new_ptr = new(this.dupeWithContentType(true));
        new_ptr.allocator = bun.default_allocator;
        return new_ptr;
    }

    export fn Blob__destroy(this: *Blob) void {
        this.finalize();
    }

    export fn Blob__getFileNameString(this: *Blob) callconv(.C) bun.String {
        if (this.getFileName()) |filename| {
            return bun.String.fromBytes(filename);
        }

        return bun.String.empty;
    }

    comptime {
        _ = Blob__dupeFromJS;
        _ = Blob__destroy;
        _ = Blob__dupe;
        _ = Blob__setAsFile;
        _ = Blob__getFileNameString;
    }

    pub fn writeFormatForSize(is_jdom_file: bool, size: usize, writer: anytype, comptime enable_ansi_colors: bool) !void {
        if (is_jdom_file) {
            try writer.writeAll(comptime Output.prettyFmt("<r>File<r>", enable_ansi_colors));
        } else {
            try writer.writeAll(comptime Output.prettyFmt("<r>Blob<r>", enable_ansi_colors));
        }
        try writer.print(
            comptime Output.prettyFmt(" (<yellow>{any}<r>)", enable_ansi_colors),
            .{
                bun.fmt.size(size, .{}),
            },
        );
    }

    pub fn writeFormat(this: *Blob, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
        const Writer = @TypeOf(writer);

        if (this.isDetached()) {
            if (this.is_jsdom_file) {
                try writer.writeAll(comptime Output.prettyFmt("<d>[<r>File<r> detached<d>]<r>", enable_ansi_colors));
            } else {
                try writer.writeAll(comptime Output.prettyFmt("<d>[<r>Blob<r> detached<d>]<r>", enable_ansi_colors));
            }
            return;
        }

        {
            const store = this.store.?;
            switch (store.data) {
                .s3 => |*s3| {
                    try S3File.writeFormat(s3, Formatter, formatter, writer, enable_ansi_colors, this.content_type, this.offset);
                },
                .file => |file| {
                    try writer.writeAll(comptime Output.prettyFmt("<r>FileRef<r>", enable_ansi_colors));
                    switch (file.pathlike) {
                        .path => |path| {
                            try writer.print(
                                comptime Output.prettyFmt(" (<green>\"{s}\"<r>)<r>", enable_ansi_colors),
                                .{
                                    path.slice(),
                                },
                            );
                        },
                        .fd => |fd| {
                            if (Environment.isWindows) {
                                switch (fd.decodeWindows()) {
                                    .uv => |uv_file| try writer.print(
                                        comptime Output.prettyFmt(" (<r>fd<d>:<r> <yellow>{d}<r>)<r>", enable_ansi_colors),
                                        .{uv_file},
                                    ),
                                    .windows => |handle| {
                                        if (Environment.isDebug) {
                                            @panic("this shouldn't be reachable.");
                                        }
                                        try writer.print(
                                            comptime Output.prettyFmt(" (<r>fd<d>:<r> <yellow>0x{x}<r>)<r>", enable_ansi_colors),
                                            .{@intFromPtr(handle)},
                                        );
                                    },
                                }
                            } else {
                                try writer.print(
                                    comptime Output.prettyFmt(" (<r>fd<d>:<r> <yellow>{d}<r>)<r>", enable_ansi_colors),
                                    .{fd.native()},
                                );
                            }
                        },
                    }
                },
                .bytes => {
                    try writeFormatForSize(this.is_jsdom_file, this.size, writer, enable_ansi_colors);
                },
            }
        }

        const show_name = (this.is_jsdom_file and this.getNameString() != null) or (!this.name.isEmpty() and this.store != null and this.store.?.data == .bytes);
        if (!this.isS3() and (this.content_type.len > 0 or this.offset > 0 or show_name or this.last_modified != 0.0)) {
            try writer.writeAll(" {\n");
            {
                formatter.indent += 1;
                defer formatter.indent -= 1;

                if (show_name) {
                    try formatter.writeIndent(Writer, writer);

                    try writer.print(
                        comptime Output.prettyFmt("name<d>:<r> <green>\"{}\"<r>", enable_ansi_colors),
                        .{
                            this.getNameString() orelse bun.String.empty,
                        },
                    );

                    if (this.content_type.len > 0 or this.offset > 0 or this.last_modified != 0) {
                        try formatter.printComma(Writer, writer, enable_ansi_colors);
                    }

                    try writer.writeAll("\n");
                }

                if (this.content_type.len > 0) {
                    try formatter.writeIndent(Writer, writer);
                    try writer.print(
                        comptime Output.prettyFmt("type<d>:<r> <green>\"{s}\"<r>", enable_ansi_colors),
                        .{
                            this.content_type,
                        },
                    );

                    if (this.offset > 0 or this.last_modified != 0) {
                        try formatter.printComma(Writer, writer, enable_ansi_colors);
                    }

                    try writer.writeAll("\n");
                }

                if (this.offset > 0) {
                    try formatter.writeIndent(Writer, writer);

                    try writer.print(
                        comptime Output.prettyFmt("offset<d>:<r> <yellow>{d}<r>\n", enable_ansi_colors),
                        .{
                            this.offset,
                        },
                    );

                    if (this.last_modified != 0) {
                        try formatter.printComma(Writer, writer, enable_ansi_colors);
                    }

                    try writer.writeAll("\n");
                }

                if (this.last_modified != 0) {
                    try formatter.writeIndent(Writer, writer);

                    try writer.print(
                        comptime Output.prettyFmt("lastModified<d>:<r> <yellow>{d}<r>\n", enable_ansi_colors),
                        .{
                            this.last_modified,
                        },
                    );
                }
            }

            try formatter.writeIndent(Writer, writer);
            try writer.writeAll("}");
        }
    }

    const Retry = enum { @"continue", fail, no };

    // we choose not to inline this so that the path buffer is not on the stack unless necessary.
    noinline fn mkdirIfNotExists(this: anytype, err: bun.sys.Error, path_string: [:0]const u8, err_path: []const u8) Retry {
        if (err.getErrno() == .NOENT and this.mkdirp_if_not_exists) {
            if (std.fs.path.dirname(path_string)) |dirname| {
                var node_fs: JSC.Node.NodeFS = .{};
                switch (node_fs.mkdirRecursive(
                    JSC.Node.Arguments.Mkdir{
                        .path = .{ .string = bun.PathString.init(dirname) },
                        .recursive = true,
                        .always_return_none = true,
                    },
                )) {
                    .result => {
                        this.mkdirp_if_not_exists = false;
                        return .@"continue";
                    },
                    .err => |err2| {
                        if (comptime @hasField(@TypeOf(this.*), "errno")) {
                            this.errno = bun.errnoToZigErr(err2.errno);
                        }
                        this.system_error = err.withPath(err_path).toSystemError();
                        if (comptime @hasField(@TypeOf(this.*), "opened_fd")) {
                            this.opened_fd = invalid_fd;
                        }
                        return .fail;
                    },
                }
            }
        }
        return .no;
    }

    /// Write an empty string to a file by truncating it.
    ///
    /// This behavior matches what we do with the fast path.
    ///
    /// Returns an encoded `*JSPromise` that resolves if the file
    /// - doesn't exist and is created
    /// - exists and is truncated
    fn writeFileWithEmptySourceToDestination(
        ctx: *JSC.JSGlobalObject,
        destination_blob: *Blob,
        options: WriteFileOptions,
    ) JSC.JSValue {
        // SAFETY: null-checked by caller
        const destination_store = destination_blob.store.?;
        defer destination_blob.detach();

        switch (destination_store.data) {
            .file => |file| {
                // TODO: make this async
                const node_fs = ctx.bunVM().nodeFS();
                var result = node_fs.truncate(.{
                    .path = file.pathlike,
                    .len = 0,
                    .flags = bun.O.CREAT,
                }, .sync);

                if (result == .err) {
                    const errno = result.err.getErrno();
                    var was_eperm = false;
                    err: switch (errno) {
                        // truncate might return EPERM when the parent directory doesn't exist
                        // #6336
                        .PERM => {
                            was_eperm = true;
                            result.err.errno = @intCast(@intFromEnum(bun.C.E.NOENT));
                            continue :err .NOENT;
                        },
                        .NOENT => {
                            if (options.mkdirp_if_not_exists == false) break :err;
                            // NOTE: if .err is PERM, it ~should~ really is a
                            // permissions issue
                            const dirpath: []const u8 = switch (file.pathlike) {
                                .path => |path| std.fs.path.dirname(path.slice()) orelse break :err,
                                .fd => {
                                    // NOTE: if this is an fd, it means the file
                                    // exists, so we shouldn't try to mkdir it
                                    // also means PERM is _actually_ a
                                    // permissions issue
                                    if (was_eperm) result.err.errno = @intCast(@intFromEnum(bun.C.E.PERM));
                                    break :err;
                                },
                            };
                            const mkdir_result = node_fs.mkdirRecursive(.{
                                .path = .{ .string = bun.PathString.init(dirpath) },
                                // TODO: Do we really want .mode to be 0o777?
                                .recursive = true,
                                .always_return_none = true,
                            });
                            if (mkdir_result == .err) {
                                result.err = mkdir_result.err;
                                break :err;
                            }

                            // SAFETY: we check if `file.pathlike` is an fd or
                            // not above, returning if it is.
                            var buf: bun.PathBuffer = undefined;
                            // TODO: respect `options.mode`
                            const mode: bun.Mode = JSC.Node.default_permission;
                            while (true) {
                                const open_res = bun.sys.open(file.pathlike.path.sliceZ(&buf), bun.O.CREAT | bun.O.TRUNC, mode);
                                switch (open_res) {
                                    // errors fall through and are handled below
                                    .err => |err| {
                                        if (err.getErrno() == .INTR) continue;
                                        result.err = open_res.err;
                                        break :err;
                                    },
                                    .result => |fd| {
                                        fd.close();
                                        return JSC.JSPromise.resolvedPromiseValue(ctx, .jsNumber(0));
                                    },
                                }
                            }
                        },
                        else => {},
                    }

                    result.err = result.err.withPathLike(file.pathlike);
                    return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(ctx, result.toJS(ctx));
                }
            },
            .s3 => |*s3| {

                // create empty file
                var aws_options = s3.getCredentialsWithOptions(options.extra_options, ctx) catch |err| {
                    return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(ctx, ctx.takeException(err));
                };
                defer aws_options.deinit();

                const Wrapper = struct {
                    promise: JSC.JSPromise.Strong,
                    store: *Store,
                    global: *JSC.JSGlobalObject,

                    pub const new = bun.TrivialNew(@This());

                    pub fn resolve(result: S3.S3UploadResult, opaque_this: *anyopaque) void {
                        const this: *@This() = @ptrCast(@alignCast(opaque_this));
                        switch (result) {
                            .success => this.promise.resolve(this.global, JSC.jsNumber(0)),
                            .failure => |err| this.promise.reject(this.global, err.toJS(this.global, this.store.getPath())),
                        }
                        this.deinit();
                    }

                    fn deinit(this: *@This()) void {
                        this.promise.deinit();
                        this.store.deref();
                        bun.destroy(this);
                    }
                };

                const promise = JSC.JSPromise.Strong.init(ctx);
                const promise_value = promise.value();
                const proxy = ctx.bunVM().transpiler.env.getHttpProxy(true, null);
                const proxy_url = if (proxy) |p| p.href else null;
                destination_store.ref();
                S3.upload(
                    &aws_options.credentials,
                    s3.path(),
                    "",
                    destination_blob.contentTypeOrMimeType(),
                    aws_options.acl,
                    proxy_url,
                    aws_options.storage_class,
                    Wrapper.resolve,
                    Wrapper.new(.{
                        .promise = promise,
                        .store = destination_store,
                        .global = ctx,
                    }),
                );
                return promise_value;
            },
            // Writing to a buffer-backed blob should be a type error,
            // making this unreachable. TODO: `{}` -> `unreachable`
            .bytes => {},
        }

        return JSC.JSPromise.resolvedPromiseValue(ctx, JSC.JSValue.jsNumber(0));
    }

    pub fn writeFileWithSourceDestination(
        ctx: *JSC.JSGlobalObject,
        source_blob: *Blob,
        destination_blob: *Blob,
        options: WriteFileOptions,
    ) JSC.JSValue {
        const destination_store = destination_blob.store orelse Output.panic("Destination blob is detached", .{});
        const destination_type = std.meta.activeTag(destination_store.data);

        // TODO: make sure this invariant isn't being broken elsewhere (outside
        // its usage from `Blob.writeFileInternal`), then upgrade this to
        // Environment.allow_assert
        if (Environment.isDebug) {
            bun.assertf(destination_type != .bytes, "Cannot write to a Blob backed by a Buffer or TypedArray. This is a bug in the caller. Please report it to the Bun team.", .{});
        }

        const source_store = source_blob.store orelse return writeFileWithEmptySourceToDestination(ctx, destination_blob, options);
        const source_type = std.meta.activeTag(source_store.data);

        if (destination_type == .file and source_type == .bytes) {
            var write_file_promise = bun.new(WriteFilePromise, .{
                .globalThis = ctx,
            });

            if (comptime Environment.isWindows) {
                var promise = JSPromise.create(ctx);
                const promise_value = promise.asValue(ctx);
                promise_value.ensureStillAlive();
                write_file_promise.promise.strong.set(ctx, promise_value);
                _ = WriteFileWindows.create(
                    ctx.bunVM().eventLoop(),
                    destination_blob.*,
                    source_blob.*,
                    *WriteFilePromise,
                    write_file_promise,
                    &WriteFilePromise.run,
                    options.mkdirp_if_not_exists orelse true,
                );
                return promise_value;
            }

            const file_copier = WriteFile.create(
                destination_blob.*,
                source_blob.*,
                *WriteFilePromise,
                write_file_promise,
                WriteFilePromise.run,
                options.mkdirp_if_not_exists orelse true,
            ) catch unreachable;
            var task = WriteFileTask.createOnJSThread(bun.default_allocator, ctx, file_copier) catch bun.outOfMemory();
            // Defer promise creation until we're just about to schedule the task
            var promise = JSC.JSPromise.create(ctx);
            const promise_value = promise.asValue(ctx);
            write_file_promise.promise.strong.set(ctx, promise_value);
            promise_value.ensureStillAlive();
            task.schedule();
            return promise_value;
        }
        // If this is file <> file, we can just copy the file
        else if (destination_type == .file and source_type == .file) {
            if (comptime Environment.isWindows) {
                return Store.CopyFileWindows.init(
                    destination_store,
                    source_store,
                    ctx.bunVM().eventLoop(),
                    options.mkdirp_if_not_exists orelse true,
                    destination_blob.size,
                );
            }
            var file_copier = Store.CopyFile.create(
                bun.default_allocator,
                destination_store,
                source_store,
                destination_blob.offset,
                destination_blob.size,
                ctx,
                options.mkdirp_if_not_exists orelse true,
            ) catch unreachable;
            file_copier.schedule();
            return file_copier.promise.value();
        } else if (destination_type == .file and source_type == .s3) {
            const s3 = &source_store.data.s3;
            if (JSC.WebCore.ReadableStream.fromJS(JSC.WebCore.ReadableStream.fromBlob(
                ctx,
                source_blob,
                @truncate(s3.options.partSize),
            ), ctx)) |stream| {
                return destination_blob.pipeReadableStreamToBlob(ctx, stream, options.extra_options);
            } else {
                return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(ctx, ctx.createErrorInstance("Failed to stream bytes from s3 bucket", .{}));
            }
        } else if (destination_type == .bytes and source_type == .bytes) {
            // If this is bytes <> bytes, we can just duplicate it
            // this is an edgecase
            // it will happen if someone did Bun.write(new Blob([123]), new Blob([456]))
            // eventually, this could be like Buffer.concat
            var clone = source_blob.dupe();
            clone.allocator = bun.default_allocator;
            const cloned = Blob.new(clone);
            cloned.allocator = bun.default_allocator;
            return JSPromise.resolvedPromiseValue(ctx, cloned.toJS(ctx));
        } else if (destination_type == .bytes and (source_type == .file or source_type == .s3)) {
            const blob_value = source_blob.getSliceFrom(ctx, 0, 0, "", false);

            return JSPromise.resolvedPromiseValue(
                ctx,
                blob_value,
            );
        } else if (destination_type == .s3) {
            const s3 = &destination_store.data.s3;
            var aws_options = s3.getCredentialsWithOptions(options.extra_options, ctx) catch |err| {
                return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(ctx, ctx.takeException(err));
            };
            defer aws_options.deinit();
            const proxy = ctx.bunVM().transpiler.env.getHttpProxy(true, null);
            const proxy_url = if (proxy) |p| p.href else null;
            switch (source_store.data) {
                .bytes => |bytes| {
                    if (bytes.len > S3.MultiPartUploadOptions.MAX_SINGLE_UPLOAD_SIZE) {
                        if (JSC.WebCore.ReadableStream.fromJS(JSC.WebCore.ReadableStream.fromBlob(
                            ctx,
                            source_blob,
                            @truncate(s3.options.partSize),
                        ), ctx)) |stream| {
                            return S3.uploadStream(
                                (if (options.extra_options != null) aws_options.credentials.dupe() else s3.getCredentials()),
                                s3.path(),
                                stream,
                                ctx,
                                aws_options.options,
                                aws_options.acl,
                                aws_options.storage_class,
                                destination_blob.contentTypeOrMimeType(),
                                proxy_url,
                                null,
                                undefined,
                            );
                        } else {
                            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(ctx, ctx.createErrorInstance("Failed to stream bytes to s3 bucket", .{}));
                        }
                    } else {
                        const Wrapper = struct {
                            store: *Store,
                            promise: JSC.JSPromise.Strong,
                            global: *JSC.JSGlobalObject,

                            pub const new = bun.TrivialNew(@This());

                            pub fn resolve(result: S3.S3UploadResult, opaque_self: *anyopaque) void {
                                const this: *@This() = @ptrCast(@alignCast(opaque_self));
                                switch (result) {
                                    .success => this.promise.resolve(this.global, JSC.jsNumber(this.store.data.bytes.len)),
                                    .failure => |err| this.promise.reject(this.global, err.toJS(this.global, this.store.getPath())),
                                }
                                this.deinit();
                            }

                            fn deinit(this: *@This()) void {
                                this.promise.deinit();
                                this.store.deref();
                            }
                        };
                        source_store.ref();
                        const promise = JSC.JSPromise.Strong.init(ctx);
                        const promise_value = promise.value();

                        S3.upload(
                            &aws_options.credentials,
                            s3.path(),
                            bytes.slice(),
                            destination_blob.contentTypeOrMimeType(),
                            aws_options.acl,
                            proxy_url,
                            aws_options.storage_class,
                            Wrapper.resolve,
                            Wrapper.new(.{
                                .store = source_store,
                                .promise = promise,
                                .global = ctx,
                            }),
                        );
                        return promise_value;
                    }
                },
                .file, .s3 => {
                    // stream
                    if (JSC.WebCore.ReadableStream.fromJS(JSC.WebCore.ReadableStream.fromBlob(
                        ctx,
                        source_blob,
                        @truncate(s3.options.partSize),
                    ), ctx)) |stream| {
                        return S3.uploadStream(
                            (if (options.extra_options != null) aws_options.credentials.dupe() else s3.getCredentials()),
                            s3.path(),
                            stream,
                            ctx,
                            s3.options,
                            aws_options.acl,
                            aws_options.storage_class,
                            destination_blob.contentTypeOrMimeType(),
                            proxy_url,
                            null,
                            undefined,
                        );
                    } else {
                        return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(ctx, ctx.createErrorInstance("Failed to stream bytes to s3 bucket", .{}));
                    }
                },
            }
        }

        unreachable;
    }

    const WriteFileOptions = struct {
        mkdirp_if_not_exists: ?bool = null,
        extra_options: ?JSValue = null,
    };

    /// ## Errors
    /// - If `path_or_blob` is a detached blob
    /// ## Panics
    /// - If `path_or_blob` is a `Blob` backed by a byte store
    pub fn writeFileInternal(globalThis: *JSC.JSGlobalObject, path_or_blob_: *PathOrBlob, data: JSC.JSValue, options: WriteFileOptions) bun.JSError!JSC.JSValue {
        if (data.isEmptyOrUndefinedOrNull()) {
            return globalThis.throwInvalidArguments("Bun.write(pathOrFdOrBlob, blob) expects a Blob-y thing to write", .{});
        }
        var path_or_blob = path_or_blob_.*;
        if (path_or_blob == .blob) {
            const blob_store = path_or_blob.blob.store orelse {
                return globalThis.throwInvalidArguments("Blob is detached", .{});
            };
            bun.assertWithLocation(blob_store.data != .bytes, @src());
            // TODO only reset last_modified on success paths instead of
            // resetting last_modified at the beginning for better performance.
            if (blob_store.data == .file) {
                // reset last_modified to force getLastModified() to reload after writing.
                blob_store.data.file.last_modified = JSC.init_timestamp;
            }
        }

        const input_store: ?*Store = if (path_or_blob == .blob) path_or_blob.blob.store else null;
        if (input_store) |st| st.ref();
        defer if (input_store) |st| st.deref();

        var needs_async = false;

        if (options.mkdirp_if_not_exists) |mkdir| {
            if (mkdir and
                path_or_blob == .blob and
                path_or_blob.blob.store != null and
                path_or_blob.blob.store.?.data == .file and
                path_or_blob.blob.store.?.data.file.pathlike == .fd)
            {
                return globalThis.throwInvalidArguments("Cannot create a directory for a file descriptor", .{});
            }
        }

        // If you're doing Bun.write(), try to go fast by writing short input on the main thread.
        // This is a heuristic, but it's a good one.
        //
        // except if you're on Windows. Windows I/O is slower. Let's not even try.
        if (comptime !Environment.isWindows) {
            if (path_or_blob == .path or
                // If they try to set an offset, its a little more complicated so let's avoid that
                (path_or_blob.blob.offset == 0 and !path_or_blob.blob.isS3() and
                    // Is this a file that is known to be a pipe? Let's avoid blocking the main thread on it.
                    !(path_or_blob.blob.store != null and
                        path_or_blob.blob.store.?.data == .file and
                        path_or_blob.blob.store.?.data.file.mode != 0 and
                        bun.isRegularFile(path_or_blob.blob.store.?.data.file.mode))))
            {
                if (data.isString()) {
                    const len = data.getLength(globalThis);

                    if (len < 256 * 1024) {
                        const str = try data.toBunString(globalThis);
                        defer str.deref();

                        const pathlike: JSC.Node.PathOrFileDescriptor = if (path_or_blob == .path)
                            path_or_blob.path
                        else
                            path_or_blob.blob.store.?.data.file.pathlike;

                        if (pathlike == .path) {
                            const result = writeStringToFileFast(
                                globalThis,
                                pathlike,
                                str,
                                &needs_async,
                                true,
                            );
                            if (!needs_async) {
                                return result;
                            }
                        } else {
                            const result = writeStringToFileFast(
                                globalThis,
                                pathlike,
                                str,
                                &needs_async,
                                false,
                            );
                            if (!needs_async) {
                                return result;
                            }
                        }
                    }
                } else if (data.asArrayBuffer(globalThis)) |buffer_view| {
                    if (buffer_view.byte_len < 256 * 1024) {
                        const pathlike: JSC.Node.PathOrFileDescriptor = if (path_or_blob == .path)
                            path_or_blob.path
                        else
                            path_or_blob.blob.store.?.data.file.pathlike;

                        if (pathlike == .path) {
                            const result = writeBytesToFileFast(
                                globalThis,
                                pathlike,
                                buffer_view.byteSlice(),
                                &needs_async,
                                true,
                            );

                            if (!needs_async) {
                                return result;
                            }
                        } else {
                            const result = writeBytesToFileFast(
                                globalThis,
                                pathlike,
                                buffer_view.byteSlice(),
                                &needs_async,
                                false,
                            );

                            if (!needs_async) {
                                return result;
                            }
                        }
                    }
                }
            }
        }

        // if path_or_blob is a path, convert it into a file blob
        var destination_blob: Blob = if (path_or_blob == .path) brk: {
            const new_blob = Blob.findOrCreateFileFromPath(&path_or_blob_.path, globalThis, true);
            if (new_blob.store == null) {
                return globalThis.throwInvalidArguments("Writing to an empty blob is not implemented yet", .{});
            }
            break :brk new_blob;
        } else path_or_blob.blob.dupe();

        if (bun.Environment.allow_assert and path_or_blob == .blob) {
            // sanity check. Should never happen because
            // 1. destination blobs passed via path_or_blob are null checked at the very start
            // 2. newly created blobs from paths get null checked immediately after creation.
            bun.unsafeAssert(path_or_blob.blob.store != null);
        }

        // TODO: implement a writeev() fast path
        var source_blob: Blob = brk: {
            if (data.as(Response)) |response| {
                switch (response.body.value) {
                    .WTFStringImpl,
                    .InternalBlob,
                    .Used,
                    .Empty,
                    .Blob,
                    .Null,
                    => {
                        break :brk response.body.use();
                    },
                    .Error => |*err_ref| {
                        destination_blob.detach();
                        _ = response.body.value.use();
                        return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err_ref.toJS(globalThis));
                    },
                    .Locked => |*locked| {
                        if (destination_blob.isS3()) {
                            const s3 = &destination_blob.store.?.data.s3;
                            var aws_options = try s3.getCredentialsWithOptions(options.extra_options, globalThis);
                            defer aws_options.deinit();
                            _ = response.body.value.toReadableStream(globalThis);
                            if (locked.readable.get(globalThis)) |readable| {
                                if (readable.isDisturbed(globalThis)) {
                                    destination_blob.detach();
                                    return globalThis.throwInvalidArguments("ReadableStream has already been used", .{});
                                }
                                const proxy = globalThis.bunVM().transpiler.env.getHttpProxy(true, null);
                                const proxy_url = if (proxy) |p| p.href else null;

                                return S3.uploadStream(
                                    (if (options.extra_options != null) aws_options.credentials.dupe() else s3.getCredentials()),
                                    s3.path(),
                                    readable,
                                    globalThis,
                                    aws_options.options,
                                    aws_options.acl,
                                    aws_options.storage_class,
                                    destination_blob.contentTypeOrMimeType(),
                                    proxy_url,
                                    null,
                                    undefined,
                                );
                            }
                            destination_blob.detach();
                            return globalThis.throwInvalidArguments("ReadableStream has already been used", .{});
                        }
                        var task = bun.new(WriteFileWaitFromLockedValueTask, .{
                            .globalThis = globalThis,
                            .file_blob = destination_blob,
                            .promise = JSC.JSPromise.Strong.init(globalThis),
                            .mkdirp_if_not_exists = options.mkdirp_if_not_exists orelse true,
                        });

                        response.body.value.Locked.task = task;
                        response.body.value.Locked.onReceiveValue = WriteFileWaitFromLockedValueTask.thenWrap;
                        return task.promise.value();
                    },
                }
            }

            if (data.as(Request)) |request| {
                switch (request.body.value) {
                    .WTFStringImpl,
                    .InternalBlob,
                    .Used,
                    .Empty,
                    .Blob,
                    .Null,
                    => {
                        break :brk request.body.value.use();
                    },
                    .Error => |*err_ref| {
                        destination_blob.detach();
                        _ = request.body.value.use();
                        return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err_ref.toJS(globalThis));
                    },
                    .Locked => |locked| {
                        if (destination_blob.isS3()) {
                            const s3 = &destination_blob.store.?.data.s3;
                            var aws_options = try s3.getCredentialsWithOptions(options.extra_options, globalThis);
                            defer aws_options.deinit();
                            _ = request.body.value.toReadableStream(globalThis);
                            if (locked.readable.get(globalThis)) |readable| {
                                if (readable.isDisturbed(globalThis)) {
                                    destination_blob.detach();
                                    return globalThis.throwInvalidArguments("ReadableStream has already been used", .{});
                                }
                                const proxy = globalThis.bunVM().transpiler.env.getHttpProxy(true, null);
                                const proxy_url = if (proxy) |p| p.href else null;
                                return S3.uploadStream(
                                    (if (options.extra_options != null) aws_options.credentials.dupe() else s3.getCredentials()),
                                    s3.path(),
                                    readable,
                                    globalThis,
                                    aws_options.options,
                                    aws_options.acl,
                                    aws_options.storage_class,
                                    destination_blob.contentTypeOrMimeType(),
                                    proxy_url,
                                    null,
                                    undefined,
                                );
                            }
                            destination_blob.detach();
                            return globalThis.throwInvalidArguments("ReadableStream has already been used", .{});
                        }
                        var task = bun.new(WriteFileWaitFromLockedValueTask, .{
                            .globalThis = globalThis,
                            .file_blob = destination_blob,
                            .promise = JSC.JSPromise.Strong.init(globalThis),
                            .mkdirp_if_not_exists = options.mkdirp_if_not_exists orelse true,
                        });

                        request.body.value.Locked.task = task;
                        request.body.value.Locked.onReceiveValue = WriteFileWaitFromLockedValueTask.thenWrap;

                        return task.promise.value();
                    },
                }
            }

            break :brk Blob.get(
                globalThis,
                data,
                false,
                false,
            ) catch |err| {
                if (err == error.InvalidArguments) {
                    return globalThis.throwInvalidArguments("Expected an Array", .{});
                }
                return globalThis.throwOutOfMemory();
            };
        };
        defer source_blob.detach();

        const destination_store = destination_blob.store;
        if (destination_store) |store| {
            store.ref();
        }

        defer {
            if (destination_store) |store| {
                store.deref();
            }
        }

        return writeFileWithSourceDestination(globalThis, &source_blob, &destination_blob, options);
    }

    /// `Bun.write(destination, input, options?)`
    pub fn writeFile(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        const arguments = callframe.arguments();
        var args = JSC.Node.ArgumentsSlice.init(globalThis.bunVM(), arguments);
        defer args.deinit();

        // accept a path or a blob
        var path_or_blob = try PathOrBlob.fromJSNoCopy(globalThis, &args);
        defer {
            if (path_or_blob == .path) {
                path_or_blob.path.deinit();
            }
        }
        // "Blob" must actually be a BunFile, not a webcore blob.
        if (path_or_blob == .blob) {
            const store = path_or_blob.blob.store orelse {
                return globalThis.throw("Cannot write to a detached Blob", .{});
            };
            if (store.data == .bytes) {
                return globalThis.throwInvalidArguments("Cannot write to a Blob backed by bytes, which are always read-only", .{});
            }
        }

        const data = args.nextEat() orelse {
            return globalThis.throwInvalidArguments("Bun.write(pathOrFdOrBlob, blob) expects a Blob-y thing to write", .{});
        };
        var mkdirp_if_not_exists: ?bool = null;
        const options = args.nextEat();
        if (options) |options_object| {
            if (options_object.isObject()) {
                if (try options_object.getTruthy(globalThis, "createPath")) |create_directory| {
                    if (!create_directory.isBoolean()) {
                        return globalThis.throwInvalidArgumentType("write", "options.createPath", "boolean");
                    }
                    mkdirp_if_not_exists = create_directory.toBoolean();
                }
            } else if (!options_object.isEmptyOrUndefinedOrNull()) {
                return globalThis.throwInvalidArgumentType("write", "options", "object");
            }
        }
        return writeFileInternal(globalThis, &path_or_blob, data, .{
            .mkdirp_if_not_exists = mkdirp_if_not_exists,
            .extra_options = options,
        });
    }

    const write_permissions = 0o664;

    fn writeStringToFileFast(
        globalThis: *JSC.JSGlobalObject,
        pathlike: JSC.Node.PathOrFileDescriptor,
        str: bun.String,
        needs_async: *bool,
        comptime needs_open: bool,
    ) JSC.JSValue {
        const fd: bun.FileDescriptor = if (comptime !needs_open) pathlike.fd else brk: {
            var file_path: bun.PathBuffer = undefined;
            switch (bun.sys.open(
                pathlike.path.sliceZ(&file_path),
                // we deliberately don't use O_TRUNC here
                // it's a perf optimization
                bun.O.WRONLY | bun.O.CREAT | bun.O.NONBLOCK,
                write_permissions,
            )) {
                .result => |result| {
                    break :brk result;
                },
                .err => |err| {
                    if (err.getErrno() == .NOENT) {
                        needs_async.* = true;
                        return .zero;
                    }

                    return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(
                        globalThis,
                        err.withPath(pathlike.path.slice()).toJSC(globalThis),
                    );
                },
            }
            unreachable;
        };

        var truncate = needs_open or str.isEmpty();
        const jsc_vm = globalThis.bunVM();
        var written: usize = 0;

        defer {
            // we only truncate if it's a path
            // if it's a file descriptor, we assume they want manual control over that behavior
            if (truncate) {
                _ = fd.truncate(@intCast(written));
            }
            if (needs_open) {
                fd.close();
            }
        }
        if (!str.isEmpty()) {
            var decoded = str.toUTF8(jsc_vm.allocator);
            defer decoded.deinit();

            var remain = decoded.slice();
            while (remain.len > 0) {
                const result = bun.sys.write(fd, remain);
                switch (result) {
                    .result => |res| {
                        written += res;
                        remain = remain[res..];
                        if (res == 0) break;
                    },
                    .err => |err| {
                        truncate = false;
                        if (err.getErrno() == .AGAIN) {
                            needs_async.* = true;
                            return .zero;
                        }
                        if (comptime !needs_open) {
                            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err.toJSC(globalThis));
                        }
                        return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(
                            globalThis,
                            err.withPath(pathlike.path.slice()).toJSC(globalThis),
                        );
                    },
                }
            }
        }

        return JSC.JSPromise.resolvedPromiseValue(globalThis, JSC.JSValue.jsNumber(written));
    }

    fn writeBytesToFileFast(
        globalThis: *JSC.JSGlobalObject,
        pathlike: JSC.Node.PathOrFileDescriptor,
        bytes: []const u8,
        needs_async: *bool,
        comptime needs_open: bool,
    ) JSC.JSValue {
        const fd: bun.FileDescriptor = if (comptime !needs_open) pathlike.fd else brk: {
            var file_path: bun.PathBuffer = undefined;
            switch (bun.sys.open(
                pathlike.path.sliceZ(&file_path),
                if (!Environment.isWindows)
                    // we deliberately don't use O_TRUNC here
                    // it's a perf optimization
                    bun.O.WRONLY | bun.O.CREAT | bun.O.NONBLOCK
                else
                    bun.O.WRONLY | bun.O.CREAT,
                write_permissions,
            )) {
                .result => |result| {
                    break :brk result;
                },
                .err => |err| {
                    if (!Environment.isWindows) {
                        if (err.getErrno() == .NOENT) {
                            needs_async.* = true;
                            return .zero;
                        }
                    }

                    return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(
                        globalThis,
                        err.withPath(pathlike.path.slice()).toJSC(globalThis),
                    );
                },
            }
        };

        // TODO: on windows this is always synchronous

        const truncate = needs_open or bytes.len == 0;
        var written: usize = 0;
        defer if (needs_open) fd.close();

        var remain = bytes;
        const end = remain.ptr + remain.len;

        while (remain.ptr != end) {
            const result = bun.sys.write(fd, remain);
            switch (result) {
                .result => |res| {
                    written += res;
                    remain = remain[res..];
                    if (res == 0) break;
                },
                .err => |err| {
                    if (!Environment.isWindows) {
                        if (err.getErrno() == .AGAIN) {
                            needs_async.* = true;
                            return .zero;
                        }
                    }
                    if (comptime !needs_open) {
                        return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(
                            globalThis,
                            err.toJSC(globalThis),
                        );
                    }
                    return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(
                        globalThis,
                        err.withPath(pathlike.path.slice()).toJSC(globalThis),
                    );
                },
            }
        }

        if (truncate) {
            if (Environment.isWindows) {
                _ = std.os.windows.kernel32.SetEndOfFile(fd.cast());
            } else {
                _ = bun.sys.ftruncate(fd, @as(i64, @intCast(written)));
            }
        }

        return JSC.JSPromise.resolvedPromiseValue(globalThis, JSC.JSValue.jsNumber(written));
    }
    export fn JSDOMFile__construct(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(JSC.conv) ?*Blob {
        return JSDOMFile__construct_(globalThis, callframe) catch |err| switch (err) {
            error.JSError => null,
            error.OutOfMemory => {
                globalThis.throwOutOfMemory() catch {};
                return null;
            },
        };
    }
    pub fn JSDOMFile__construct_(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!*Blob {
        JSC.markBinding(@src());
        const allocator = bun.default_allocator;
        var blob: Blob = undefined;
        var arguments = callframe.arguments_old(3);
        const args = arguments.slice();

        if (args.len < 2) {
            return globalThis.throwInvalidArguments("new File(bits, name) expects at least 2 arguments", .{});
        }
        {
            const name_value_str = try bun.String.fromJS(args[1], globalThis);
            defer name_value_str.deref();

            blob = get(globalThis, args[0], false, true) catch |err| switch (err) {
                error.JSError, error.OutOfMemory => |e| return e,
                error.InvalidArguments => {
                    return globalThis.throwInvalidArguments("new Blob() expects an Array", .{});
                },
            };
            if (blob.store) |store_| {
                switch (store_.data) {
                    .bytes => |*bytes| {
                        bytes.stored_name = bun.PathString.init(
                            (name_value_str.toUTF8WithoutRef(bun.default_allocator).clone(bun.default_allocator) catch bun.outOfMemory()).slice(),
                        );
                    },
                    .s3, .file => {
                        blob.name = name_value_str.dupeRef();
                    },
                }
            } else if (!name_value_str.isEmpty()) {
                // not store but we have a name so we need a store
                blob.store = Blob.Store.new(.{
                    .data = .{
                        .bytes = Blob.ByteStore.initEmptyWithName(
                            bun.PathString.init(
                                (name_value_str.toUTF8WithoutRef(bun.default_allocator).clone(bun.default_allocator) catch bun.outOfMemory()).slice(),
                            ),
                            allocator,
                        ),
                    },
                    .allocator = allocator,
                    .ref_count = .init(1),
                });
            }
        }

        var set_last_modified = false;

        if (args.len > 2) {
            const options = args[2];
            if (options.isObject()) {
                // type, the ASCII-encoded string in lower case
                // representing the media type of the Blob.
                // Normative conditions for this member are provided
                // in the § 3.1 Constructors.
                if (try options.get(globalThis, "type")) |content_type| {
                    inner: {
                        if (content_type.isString()) {
                            var content_type_str = try content_type.toSlice(globalThis, bun.default_allocator);
                            defer content_type_str.deinit();
                            const slice = content_type_str.slice();
                            if (!strings.isAllASCII(slice)) {
                                break :inner;
                            }
                            blob.content_type_was_set = true;

                            if (globalThis.bunVM().mimeType(slice)) |mime| {
                                blob.content_type = mime.value;
                                break :inner;
                            }
                            const content_type_buf = allocator.alloc(u8, slice.len) catch bun.outOfMemory();
                            blob.content_type = strings.copyLowercase(slice, content_type_buf);
                            blob.content_type_allocated = true;
                        }
                    }
                }

                if (try options.getTruthy(globalThis, "lastModified")) |last_modified| {
                    set_last_modified = true;
                    blob.last_modified = last_modified.coerce(f64, globalThis);
                }
            }
        }

        if (!set_last_modified) {
            // `lastModified` should be the current date in milliseconds if unspecified.
            // https://developer.mozilla.org/en-US/docs/Web/API/File/lastModified
            blob.last_modified = @floatFromInt(std.time.milliTimestamp());
        }

        if (blob.content_type.len == 0) {
            blob.content_type = "";
            blob.content_type_was_set = false;
        }

        var blob_ = Blob.new(blob);
        blob_.allocator = allocator;
        blob_.is_jsdom_file = true;
        return blob_;
    }

    fn calculateEstimatedByteSize(this: *Blob) void {
        // in-memory size. not the size on disk.
        var size: usize = @sizeOf(Blob);

        if (this.store) |store| {
            size += @sizeOf(Blob.Store);
            switch (store.data) {
                .bytes => {
                    size += store.data.bytes.stored_name.estimatedSize();
                    size += if (this.size != Blob.max_size)
                        this.size
                    else
                        store.data.bytes.len;
                },
                .file => size += store.data.file.pathlike.estimatedSize(),
                .s3 => size += store.data.s3.estimatedSize(),
            }
        }

        this.reported_estimated_size = size + (this.content_type.len * @intFromBool(this.content_type_allocated)) + this.name.byteSlice().len;
    }

    pub fn estimatedSize(this: *Blob) usize {
        return this.reported_estimated_size;
    }

    comptime {
        _ = JSDOMFile__hasInstance;
    }

    pub fn constructBunFile(
        globalObject: *JSC.JSGlobalObject,
        callframe: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        var vm = globalObject.bunVM();
        const arguments = callframe.arguments_old(2).slice();
        var args = JSC.Node.ArgumentsSlice.init(vm, arguments);
        defer args.deinit();

        var path = (try JSC.Node.PathOrFileDescriptor.fromJS(globalObject, &args, bun.default_allocator)) orelse {
            return globalObject.throwInvalidArguments("Expected file path string or file descriptor", .{});
        };
        const options = if (arguments.len >= 2) arguments[1] else null;

        if (path == .path) {
            if (strings.hasPrefixComptime(path.path.slice(), "s3://")) {
                return try S3File.constructInternalJS(globalObject, path.path, options);
            }
        }
        defer path.deinitAndUnprotect();

        var blob = Blob.findOrCreateFileFromPath(&path, globalObject, false);

        if (options) |opts| {
            if (opts.isObject()) {
                if (try opts.getTruthy(globalObject, "type")) |file_type| {
                    inner: {
                        if (file_type.isString()) {
                            var allocator = bun.default_allocator;
                            var str = try file_type.toSlice(globalObject, bun.default_allocator);
                            defer str.deinit();
                            const slice = str.slice();
                            if (!strings.isAllASCII(slice)) {
                                break :inner;
                            }
                            blob.content_type_was_set = true;
                            if (vm.mimeType(str.slice())) |entry| {
                                blob.content_type = entry.value;
                                break :inner;
                            }
                            const content_type_buf = allocator.alloc(u8, slice.len) catch bun.outOfMemory();
                            blob.content_type = strings.copyLowercase(slice, content_type_buf);
                            blob.content_type_allocated = true;
                        }
                    }
                }
                if (try opts.getTruthy(globalObject, "lastModified")) |last_modified| {
                    blob.last_modified = last_modified.coerce(f64, globalObject);
                }
            }
        }

        var ptr = Blob.new(blob);
        ptr.allocator = bun.default_allocator;
        return ptr.toJS(globalObject);
    }

    pub fn findOrCreateFileFromPath(path_or_fd: *JSC.Node.PathOrFileDescriptor, globalThis: *JSGlobalObject, comptime check_s3: bool) Blob {
        var vm = globalThis.bunVM();
        const allocator = bun.default_allocator;
        if (check_s3) {
            if (path_or_fd.* == .path) {
                if (strings.startsWith(path_or_fd.path.slice(), "s3://")) {
                    const credentials = globalThis.bunVM().transpiler.env.getS3Credentials();
                    const copy = path_or_fd.*;
                    path_or_fd.* = .{ .path = .{ .string = bun.PathString.empty } };
                    return Blob.initWithStore(Blob.Store.initS3(copy.path, null, credentials, allocator) catch bun.outOfMemory(), globalThis);
                }
            }
        }
        const path: JSC.Node.PathOrFileDescriptor = brk: {
            switch (path_or_fd.*) {
                .path => {
                    var slice = path_or_fd.path.slice();

                    if (Environment.isWindows and bun.strings.eqlComptime(slice, "/dev/null")) {
                        path_or_fd.deinit();
                        path_or_fd.* = .{
                            .path = .{
                                // this memory is freed with this allocator in `Blob.Store.deinit`
                                .string = bun.PathString.init(allocator.dupe(u8, "\\\\.\\NUL") catch bun.outOfMemory()),
                            },
                        };
                        slice = path_or_fd.path.slice();
                    }

                    if (vm.standalone_module_graph) |graph| {
                        if (graph.find(slice)) |file| {
                            defer {
                                if (path_or_fd.path != .string) {
                                    path_or_fd.deinit();
                                    path_or_fd.* = .{ .path = .{ .string = bun.PathString.empty } };
                                }
                            }

                            return file.blob(globalThis).dupe();
                        }
                    }

                    path_or_fd.toThreadSafe();
                    const copy = path_or_fd.*;
                    path_or_fd.* = .{ .path = .{ .string = bun.PathString.empty } };
                    break :brk copy;
                },
                .fd => {
                    if (path_or_fd.fd.stdioTag()) |tag| {
                        const store = switch (tag) {
                            .std_in => vm.rareData().stdin(),
                            .std_err => vm.rareData().stderr(),
                            .std_out => vm.rareData().stdout(),
                        };
                        store.ref();
                        return Blob.initWithStore(store, globalThis);
                    }
                    break :brk path_or_fd.*;
                },
            }
        };

        return Blob.initWithStore(Blob.Store.initFile(path, null, allocator) catch bun.outOfMemory(), globalThis);
    }

    pub const Store = struct {
        data: Data,

        mime_type: MimeType = MimeType.none,
        ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
        is_all_ascii: ?bool = null,
        allocator: std.mem.Allocator,

        pub const new = bun.TrivialNew(@This());

        pub fn memoryCost(this: *const Store) usize {
            return if (this.hasOneRef()) @sizeOf(@This()) + switch (this.data) {
                .bytes => this.data.bytes.len,
                .file => 0,
                .s3 => |s3| s3.estimatedSize(),
            } else 0;
        }

        pub fn getPath(this: *const Store) ?[]const u8 {
            return switch (this.data) {
                .bytes => |*bytes| if (bytes.stored_name.len > 0) bytes.stored_name.slice() else null,
                .file => |*file| if (file.pathlike == .path) file.pathlike.path.slice() else null,
                .s3 => |*s3| s3.pathlike.slice(),
            };
        }

        pub fn size(this: *const Store) SizeType {
            return switch (this.data) {
                .bytes => this.data.bytes.len,
                .s3, .file => Blob.max_size,
            };
        }

        pub const Map = std.HashMap(u64, *JSC.WebCore.Blob.Store, IdentityContext(u64), 80);

        pub const Data = union(enum) {
            bytes: ByteStore,
            file: FileStore,
            s3: S3Store,
        };

        pub fn ref(this: *Store) void {
            const old = this.ref_count.fetchAdd(1, .monotonic);
            assert(old > 0);
        }

        pub fn hasOneRef(this: *const Store) bool {
            return this.ref_count.load(.monotonic) == 1;
        }

        /// Caller is responsible for derefing the Store.
        pub fn toAnyBlob(this: *Store) ?AnyBlob {
            if (this.hasOneRef()) {
                if (this.data == .bytes) {
                    return .{ .InternalBlob = this.data.bytes.toInternalBlob() };
                }
            }

            return null;
        }

        pub fn external(ptr: ?*anyopaque, _: ?*anyopaque, _: usize) callconv(.C) void {
            if (ptr == null) return;
            var this = bun.cast(*Store, ptr);
            this.deref();
        }
        pub fn initS3WithReferencedCredentials(pathlike: JSC.Node.PathLike, mime_type: ?http.MimeType, credentials: *S3Credentials, allocator: std.mem.Allocator) !*Store {
            var path = pathlike;
            // this actually protects/refs the pathlike
            path.toThreadSafe();

            const store = Blob.Store.new(.{
                .data = .{
                    .s3 = S3Store.initWithReferencedCredentials(
                        path,
                        mime_type orelse brk: {
                            const sliced = path.slice();
                            if (sliced.len > 0) {
                                var extname = std.fs.path.extension(sliced);
                                extname = std.mem.trim(u8, extname, ".");
                                if (http.MimeType.byExtensionNoDefault(extname)) |mime| {
                                    break :brk mime;
                                }
                            }
                            break :brk null;
                        },
                        credentials,
                    ),
                },
                .allocator = allocator,
                .ref_count = std.atomic.Value(u32).init(1),
            });
            return store;
        }
        pub fn initS3(pathlike: JSC.Node.PathLike, mime_type: ?http.MimeType, credentials: S3Credentials, allocator: std.mem.Allocator) !*Store {
            var path = pathlike;
            // this actually protects/refs the pathlike
            path.toThreadSafe();

            const store = Blob.Store.new(.{
                .data = .{
                    .s3 = S3Store.init(
                        path,
                        mime_type orelse brk: {
                            const sliced = path.slice();
                            if (sliced.len > 0) {
                                var extname = std.fs.path.extension(sliced);
                                extname = std.mem.trim(u8, extname, ".");
                                if (http.MimeType.byExtensionNoDefault(extname)) |mime| {
                                    break :brk mime;
                                }
                            }
                            break :brk null;
                        },
                        credentials,
                    ),
                },
                .allocator = allocator,
                .ref_count = std.atomic.Value(u32).init(1),
            });
            return store;
        }
        pub fn initFile(pathlike: JSC.Node.PathOrFileDescriptor, mime_type: ?http.MimeType, allocator: std.mem.Allocator) !*Store {
            const store = Blob.Store.new(.{
                .data = .{
                    .file = FileStore.init(
                        pathlike,
                        mime_type orelse brk: {
                            if (pathlike == .path) {
                                const sliced = pathlike.path.slice();
                                if (sliced.len > 0) {
                                    var extname = std.fs.path.extension(sliced);
                                    extname = std.mem.trim(u8, extname, ".");
                                    if (http.MimeType.byExtensionNoDefault(extname)) |mime| {
                                        break :brk mime;
                                    }
                                }
                            }

                            break :brk null;
                        },
                    ),
                },
                .allocator = allocator,
                .ref_count = std.atomic.Value(u32).init(1),
            });
            return store;
        }

        /// Takes ownership of `bytes`, which must have been allocated with `allocator`.
        pub fn init(bytes: []u8, allocator: std.mem.Allocator) *Store {
            const store = Blob.Store.new(.{
                .data = .{
                    .bytes = ByteStore.init(bytes, allocator),
                },
                .allocator = allocator,
                .ref_count = .init(1),
            });
            return store;
        }

        pub fn sharedView(this: Store) []u8 {
            if (this.data == .bytes)
                return this.data.bytes.slice();

            return &[_]u8{};
        }

        pub fn deref(this: *Blob.Store) void {
            const old = this.ref_count.fetchSub(1, .monotonic);
            assert(old >= 1);
            if (old == 1) {
                this.deinit();
            }
        }

        pub fn deinit(this: *Blob.Store) void {
            const allocator = this.allocator;

            switch (this.data) {
                .bytes => |*bytes| {
                    bytes.deinit();
                },
                .file => |file| {
                    if (file.pathlike == .path) {
                        if (file.pathlike.path == .string) {
                            allocator.free(@constCast(file.pathlike.path.slice()));
                        } else {
                            file.pathlike.path.deinit();
                        }
                    }
                },
                .s3 => |*s3| {
                    s3.deinit(allocator);
                },
            }

            bun.destroy(this);
        }

        const SerializeTag = enum(u8) {
            file = 0,
            bytes = 1,
            empty = 2,
        };

        pub fn serialize(this: *Store, comptime Writer: type, writer: Writer) !void {
            switch (this.data) {
                .file => |file| {
                    const pathlike_tag: JSC.Node.PathOrFileDescriptor.SerializeTag = if (file.pathlike == .fd) .fd else .path;
                    try writer.writeInt(u8, @intFromEnum(pathlike_tag), .little);

                    switch (file.pathlike) {
                        .fd => |fd| {
                            try writer.writeStruct(fd);
                        },
                        .path => |path| {
                            const path_slice = path.slice();
                            try writer.writeInt(u32, @as(u32, @truncate(path_slice.len)), .little);
                            try writer.writeAll(path_slice);
                        },
                    }
                },
                .s3 => |s3| {
                    const pathlike_tag: JSC.Node.PathOrFileDescriptor.SerializeTag = .path;
                    try writer.writeInt(u8, @intFromEnum(pathlike_tag), .little);

                    const path_slice = s3.pathlike.slice();
                    try writer.writeInt(u32, @as(u32, @truncate(path_slice.len)), .little);
                    try writer.writeAll(path_slice);
                },
                .bytes => |bytes| {
                    const slice = bytes.slice();
                    try writer.writeInt(u32, @truncate(slice.len), .little);
                    try writer.writeAll(slice);

                    try writer.writeInt(u32, @truncate(bytes.stored_name.slice().len), .little);
                    try writer.writeAll(bytes.stored_name.slice());
                },
            }
        }

        pub fn fromArrayList(list: std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !*Blob.Store {
            return try Blob.Store.init(list.items, allocator);
        }

        pub fn FileOpenerMixin(comptime This: type) type {
            return struct {
                context: *This,

                const State = @This();

                const __opener_flags = bun.O.NONBLOCK | bun.O.CLOEXEC;

                const open_flags_ = if (@hasDecl(This, "open_flags"))
                    This.open_flags | __opener_flags
                else
                    bun.O.RDONLY | __opener_flags;

                pub inline fn getFdByOpening(this: *This, comptime Callback: OpenCallback) void {
                    var buf: bun.PathBuffer = undefined;
                    var path_string = if (@hasField(This, "file_store"))
                        this.file_store.pathlike.path
                    else
                        this.file_blob.store.?.data.file.pathlike.path;

                    const path = path_string.sliceZ(&buf);

                    if (Environment.isWindows) {
                        const WrappedCallback = struct {
                            pub fn callback(req: *libuv.fs_t) callconv(.C) void {
                                var self: *This = @alignCast(@ptrCast(req.data.?));
                                {
                                    defer req.deinit();
                                    if (req.result.errEnum()) |errEnum| {
                                        var path_string_2 = if (@hasField(This, "file_store"))
                                            self.file_store.pathlike.path
                                        else
                                            self.file_blob.store.?.data.file.pathlike.path;
                                        self.errno = bun.errnoToZigErr(errEnum);
                                        self.system_error = bun.sys.Error.fromCode(errEnum, .open)
                                            .withPath(path_string_2.slice())
                                            .toSystemError();
                                        self.opened_fd = invalid_fd;
                                    } else {
                                        self.opened_fd = req.result.toFD();
                                    }
                                }
                                Callback(self, self.opened_fd);
                            }
                        };

                        const rc = libuv.uv_fs_open(
                            this.loop,
                            &this.req,
                            path,
                            open_flags_,
                            JSC.Node.default_permission,
                            &WrappedCallback.callback,
                        );
                        if (rc.errEnum()) |errno| {
                            this.errno = bun.errnoToZigErr(errno);
                            this.system_error = bun.sys.Error.fromCode(errno, .open).withPath(path_string.slice()).toSystemError();
                            this.opened_fd = invalid_fd;
                            Callback(this, invalid_fd);
                        }
                        this.req.data = @ptrCast(this);
                        return;
                    }

                    while (true) {
                        this.opened_fd = switch (bun.sys.open(path, open_flags_, JSC.Node.default_permission)) {
                            .result => |fd| fd,
                            .err => |err| {
                                if (comptime @hasField(This, "mkdirp_if_not_exists")) {
                                    if (err.errno == @intFromEnum(bun.C.E.NOENT)) {
                                        switch (mkdirIfNotExists(this, err, path, path_string.slice())) {
                                            .@"continue" => continue,
                                            .fail => {
                                                this.opened_fd = invalid_fd;
                                                break;
                                            },
                                            .no => {},
                                        }
                                    }
                                }

                                this.errno = bun.errnoToZigErr(err.errno);
                                this.system_error = err.withPath(path_string.slice()).toSystemError();
                                this.opened_fd = invalid_fd;
                                break;
                            },
                        };
                        break;
                    }

                    Callback(this, this.opened_fd);
                }

                pub const OpenCallback = *const fn (*This, bun.FileDescriptor) void;

                pub fn getFd(this: *This, comptime Callback: OpenCallback) void {
                    if (this.opened_fd != invalid_fd) {
                        Callback(this, this.opened_fd);
                        return;
                    }

                    if (@hasField(This, "file_store")) {
                        const pathlike = this.file_store.pathlike;
                        if (pathlike == .fd) {
                            this.opened_fd = pathlike.fd;
                            Callback(this, this.opened_fd);
                            return;
                        }
                    } else {
                        const pathlike = this.file_blob.store.?.data.file.pathlike;
                        if (pathlike == .fd) {
                            this.opened_fd = pathlike.fd;
                            Callback(this, this.opened_fd);
                            return;
                        }
                    }

                    this.getFdByOpening(Callback);
                }
            };
        }

        pub fn FileCloserMixin(comptime This: type) type {
            return struct {
                const Closer = @This();

                fn scheduleClose(request: *io.Request) io.Action {
                    var this: *This = @alignCast(@fieldParentPtr("io_request", request));
                    return io.Action{
                        .close = .{
                            .ctx = this,
                            .fd = this.opened_fd,
                            .onDone = @ptrCast(&onIORequestClosed),
                            .poll = &this.io_poll,
                            .tag = This.io_tag,
                        },
                    };
                }

                fn onIORequestClosed(this: *This) void {
                    this.io_poll.flags.remove(.was_ever_registered);
                    this.task = .{ .callback = &onCloseIORequest };
                    bun.JSC.WorkPool.schedule(&this.task);
                }

                fn onCloseIORequest(task: *JSC.WorkPoolTask) void {
                    bloblog("onCloseIORequest()", .{});
                    var this: *This = @alignCast(@fieldParentPtr("task", task));
                    this.close_after_io = false;
                    this.update();
                }

                pub fn doClose(this: *This, is_allowed_to_close_fd: bool) bool {
                    if (@hasField(This, "io_request")) {
                        if (this.close_after_io) {
                            this.state.store(ClosingState.closing, .seq_cst);

                            @atomicStore(@TypeOf(this.io_request.callback), &this.io_request.callback, &scheduleClose, .seq_cst);
                            if (!this.io_request.scheduled)
                                io.Loop.get().schedule(&this.io_request);
                            return true;
                        }
                    }

                    if (is_allowed_to_close_fd and
                        this.opened_fd != invalid_fd and
                        this.opened_fd.stdioTag() == null)
                    {
                        if (comptime Environment.isWindows) {
                            bun.Async.Closer.close(this.opened_fd, this.loop);
                        } else {
                            _ = this.opened_fd.closeAllowingBadFileDescriptor(null);
                        }
                        this.opened_fd = invalid_fd;
                    }

                    return false;
                }
            };
        }

        pub const IOWhich = enum {
            source,
            destination,
            both,
        };

        pub const CopyFileWindows = struct {
            destination_file_store: *Store,
            source_file_store: *Store,

            io_request: libuv.fs_t = std.mem.zeroes(libuv.fs_t),
            promise: JSC.JSPromise.Strong = .{},
            mkdirp_if_not_exists: bool = false,
            event_loop: *JSC.EventLoop,

            size: Blob.SizeType = Blob.max_size,

            /// For mkdirp
            err: ?bun.sys.Error = null,

            /// When we are unable to get the original file path, we do a read-write loop that uses libuv.
            read_write_loop: ReadWriteLoop = .{},

            pub const ReadWriteLoop = struct {
                source_fd: bun.FileDescriptor = invalid_fd,
                must_close_source_fd: bool = false,
                destination_fd: bun.FileDescriptor = invalid_fd,
                must_close_destination_fd: bool = false,
                written: usize = 0,
                read_buf: std.ArrayList(u8) = std.ArrayList(u8).init(default_allocator),
                uv_buf: libuv.uv_buf_t = .{ .base = undefined, .len = 0 },

                pub fn start(read_write_loop: *ReadWriteLoop, this: *CopyFileWindows) JSC.Maybe(void) {
                    read_write_loop.read_buf.ensureTotalCapacityPrecise(64 * 1024) catch bun.outOfMemory();

                    return read(read_write_loop, this);
                }

                pub fn read(read_write_loop: *ReadWriteLoop, this: *CopyFileWindows) JSC.Maybe(void) {
                    read_write_loop.read_buf.items.len = 0;
                    read_write_loop.uv_buf = libuv.uv_buf_t.init(read_write_loop.read_buf.allocatedSlice());
                    const loop = this.event_loop.virtual_machine.event_loop_handle.?;

                    // This io_request is used for both reading and writing.
                    // For now, we don't start reading the next chunk until
                    // we've finished writing all the previous chunks.
                    this.io_request.data = @ptrCast(this);

                    const rc = libuv.uv_fs_read(
                        loop,
                        &this.io_request,
                        read_write_loop.source_fd.uv(),
                        @ptrCast(&read_write_loop.uv_buf),
                        1,
                        -1,
                        &onRead,
                    );

                    if (rc.toError(.read)) |err| {
                        return .{ .err = err };
                    }

                    return .{ .result = {} };
                }

                fn onRead(req: *libuv.fs_t) callconv(.C) void {
                    var this: *CopyFileWindows = @fieldParentPtr("io_request", req);
                    bun.assert(req.data == @as(?*anyopaque, @ptrCast(this)));

                    const source_fd = this.read_write_loop.source_fd;
                    const destination_fd = this.read_write_loop.destination_fd;
                    const read_buf = &this.read_write_loop.read_buf.items;

                    const event_loop = this.event_loop;

                    const rc = req.result;

                    bun.sys.syslog("uv_fs_read({}, {d}) = {d}", .{ source_fd, read_buf.len, rc.int() });
                    if (rc.toError(.read)) |err| {
                        this.err = err;
                        this.onReadWriteLoopComplete();
                        return;
                    }

                    read_buf.len = @intCast(rc.int());
                    this.read_write_loop.uv_buf = libuv.uv_buf_t.init(read_buf.*);

                    if (rc.int() == 0) {
                        // Handle EOF. We can't read any more.
                        this.onReadWriteLoopComplete();
                        return;
                    }

                    // Re-use the fs request.
                    req.deinit();
                    const rc2 = libuv.uv_fs_write(
                        event_loop.virtual_machine.event_loop_handle.?,
                        &this.io_request,
                        destination_fd.uv(),
                        @ptrCast(&this.read_write_loop.uv_buf),
                        1,
                        -1,
                        &onWrite,
                    );
                    req.data = @ptrCast(this);

                    if (rc2.toError(.write)) |err| {
                        this.err = err;
                        this.onReadWriteLoopComplete();
                        return;
                    }
                }

                fn onWrite(req: *libuv.fs_t) callconv(.C) void {
                    var this: *CopyFileWindows = @fieldParentPtr("io_request", req);
                    bun.assert(req.data == @as(?*anyopaque, @ptrCast(this)));
                    const buf = &this.read_write_loop.read_buf.items;

                    const destination_fd = this.read_write_loop.destination_fd;

                    const rc = req.result;

                    bun.sys.syslog("uv_fs_write({}, {d}) = {d}", .{ destination_fd, buf.len, rc.int() });

                    if (rc.toError(.write)) |err| {
                        this.err = err;
                        this.onReadWriteLoopComplete();
                        return;
                    }

                    const wrote: u32 = @intCast(rc.int());

                    this.read_write_loop.written += wrote;

                    if (wrote < buf.len) {
                        if (wrote == 0) {
                            // Handle EOF. We can't write any more.
                            this.onReadWriteLoopComplete();
                            return;
                        }

                        // Re-use the fs request.
                        req.deinit();
                        req.data = @ptrCast(this);

                        this.read_write_loop.uv_buf = libuv.uv_buf_t.init(this.read_write_loop.uv_buf.slice()[wrote..]);
                        const rc2 = libuv.uv_fs_write(
                            this.event_loop.virtual_machine.event_loop_handle.?,
                            &this.io_request,
                            destination_fd.uv(),
                            @ptrCast(&this.read_write_loop.uv_buf),
                            1,
                            -1,
                            &onWrite,
                        );

                        if (rc2.toError(.write)) |err| {
                            this.err = err;
                            this.onReadWriteLoopComplete();
                            return;
                        }

                        return;
                    }

                    req.deinit();
                    switch (this.read_write_loop.read(this)) {
                        .err => |err| {
                            this.err = err;
                            this.onReadWriteLoopComplete();
                        },
                        .result => {},
                    }
                }

                pub fn close(this: *ReadWriteLoop) void {
                    if (this.must_close_source_fd) {
                        if (this.source_fd.makeLibUVOwned()) |fd| {
                            bun.Async.Closer.close(
                                fd,
                                bun.Async.Loop.get(),
                            );
                        } else |_| {
                            this.source_fd.close();
                        }
                        this.must_close_source_fd = false;
                        this.source_fd = invalid_fd;
                    }

                    if (this.must_close_destination_fd) {
                        if (this.destination_fd.makeLibUVOwned()) |fd| {
                            bun.Async.Closer.close(
                                fd,
                                bun.Async.Loop.get(),
                            );
                        } else |_| {
                            this.destination_fd.close();
                        }
                        this.must_close_destination_fd = false;
                        this.destination_fd = invalid_fd;
                    }

                    this.read_buf.clearAndFree();
                }
            };

            pub fn onReadWriteLoopComplete(this: *CopyFileWindows) void {
                this.event_loop.unrefConcurrently();

                if (this.err) |err| {
                    this.err = null;
                    this.throw(err);
                    return;
                }

                this.onComplete(this.read_write_loop.written);
            }

            pub const new = bun.TrivialNew(@This());

            pub fn init(
                destination_file_store: *Store,
                source_file_store: *Store,
                event_loop: *JSC.EventLoop,
                mkdirp_if_not_exists: bool,
                size_: Blob.SizeType,
            ) JSC.JSValue {
                destination_file_store.ref();
                source_file_store.ref();
                const result = CopyFileWindows.new(.{
                    .destination_file_store = destination_file_store,
                    .source_file_store = source_file_store,
                    .promise = JSC.JSPromise.Strong.init(event_loop.global),
                    .io_request = std.mem.zeroes(libuv.fs_t),
                    .event_loop = event_loop,
                    .mkdirp_if_not_exists = mkdirp_if_not_exists,
                    .size = size_,
                });
                const promise = result.promise.value();

                // On error, this function might free the CopyFileWindows struct.
                // So we can no longer reference it beyond this point.
                result.copyfile();

                return promise;
            }

            fn preparePathlike(pathlike: *JSC.Node.PathOrFileDescriptor, must_close: *bool, is_reading: bool) JSC.Maybe(bun.FileDescriptor) {
                if (pathlike.* == .path) {
                    const fd = switch (bun.sys.openatWindowsT(
                        u8,
                        bun.invalid_fd,
                        pathlike.path.slice(),
                        if (is_reading)
                            bun.O.RDONLY
                        else
                            bun.O.WRONLY | bun.O.CREAT,
                        0,
                    )) {
                        .result => |result| result.makeLibUVOwned() catch {
                            result.close();
                            return .{
                                .err = .{
                                    .errno = @as(c_int, @intCast(@intFromEnum(bun.C.SystemErrno.EMFILE))),
                                    .syscall = .open,
                                    .path = pathlike.path.slice(),
                                },
                            };
                        },
                        .err => |err| {
                            return .{
                                .err = err,
                            };
                        },
                    };
                    must_close.* = true;
                    return .{ .result = fd };
                } else {
                    // We assume that this is already a uv-casted file descriptor.
                    return .{ .result = pathlike.fd };
                }
            }

            fn prepareReadWriteLoop(this: *CopyFileWindows) void {
                // Open the destination first, so that if we need to call
                // mkdirp(), we don't spend extra time opening the file handle for
                // the source.
                this.read_write_loop.destination_fd = switch (preparePathlike(&this.destination_file_store.data.file.pathlike, &this.read_write_loop.must_close_destination_fd, false)) {
                    .result => |fd| fd,
                    .err => |err| {
                        if (this.mkdirp_if_not_exists and err.getErrno() == .NOENT) {
                            this.mkdirp();
                            return;
                        }

                        this.throw(err);
                        return;
                    },
                };

                this.read_write_loop.source_fd = switch (preparePathlike(&this.source_file_store.data.file.pathlike, &this.read_write_loop.must_close_source_fd, true)) {
                    .result => |fd| fd,
                    .err => |err| {
                        this.throw(err);
                        return;
                    },
                };

                switch (this.read_write_loop.start(this)) {
                    .err => |err| {
                        this.throw(err);
                        return;
                    },
                    .result => {
                        this.event_loop.refConcurrently();
                    },
                }
            }

            fn copyfile(this: *CopyFileWindows) void {
                // This is for making it easier for us to test this code path
                if (bun.getRuntimeFeatureFlag("BUN_FEATURE_FLAG_DISABLE_UV_FS_COPYFILE")) {
                    this.prepareReadWriteLoop();
                    return;
                }

                var pathbuf1: bun.PathBuffer = undefined;
                var pathbuf2: bun.PathBuffer = undefined;
                var destination_file_store = &this.destination_file_store.data.file;
                var source_file_store = &this.source_file_store.data.file;

                const new_path: [:0]const u8 = brk: {
                    switch (destination_file_store.pathlike) {
                        .path => {
                            break :brk destination_file_store.pathlike.path.sliceZ(&pathbuf1);
                        },
                        .fd => |fd| {
                            switch (bun.sys.File.from(fd).kind()) {
                                .err => |err| {
                                    this.throw(err);
                                    return;
                                },
                                .result => |kind| {
                                    switch (kind) {
                                        .directory => {
                                            this.throw(bun.sys.Error.fromCode(.ISDIR, .open));
                                            return;
                                        },
                                        .character_device => {
                                            this.prepareReadWriteLoop();
                                            return;
                                        },
                                        else => {
                                            const out = bun.getFdPath(fd, &pathbuf1) catch {
                                                // This case can happen when either:
                                                // - NUL device
                                                // - Pipe. `cat foo.txt | bun bar.ts`
                                                this.prepareReadWriteLoop();
                                                return;
                                            };
                                            pathbuf1[out.len] = 0;
                                            break :brk pathbuf1[0..out.len :0];
                                        },
                                    }
                                },
                            }
                        },
                    }
                };
                const old_path: [:0]const u8 = brk: {
                    switch (source_file_store.pathlike) {
                        .path => {
                            break :brk source_file_store.pathlike.path.sliceZ(&pathbuf2);
                        },
                        .fd => |fd| {
                            switch (bun.sys.File.from(fd).kind()) {
                                .err => |err| {
                                    this.throw(err);
                                    return;
                                },
                                .result => |kind| {
                                    switch (kind) {
                                        .directory => {
                                            this.throw(bun.sys.Error.fromCode(.ISDIR, .open));
                                            return;
                                        },
                                        .character_device => {
                                            this.prepareReadWriteLoop();
                                            return;
                                        },
                                        else => {
                                            const out = bun.getFdPath(fd, &pathbuf2) catch {
                                                // This case can happen when either:
                                                // - NUL device
                                                // - Pipe. `cat foo.txt | bun bar.ts`
                                                this.prepareReadWriteLoop();
                                                return;
                                            };
                                            pathbuf2[out.len] = 0;
                                            break :brk pathbuf2[0..out.len :0];
                                        },
                                    }
                                },
                            }
                        },
                    }
                };
                const loop = this.event_loop.virtual_machine.event_loop_handle.?;
                this.io_request.data = @ptrCast(this);

                const rc = libuv.uv_fs_copyfile(
                    loop,
                    &this.io_request,
                    old_path,
                    new_path,
                    0,
                    &onCopyFile,
                );

                if (rc.errno()) |errno| {
                    this.throw(.{
                        // #6336
                        .errno = if (errno == @intFromEnum(bun.C.SystemErrno.EPERM))
                            @as(c_int, @intCast(@intFromEnum(bun.C.SystemErrno.ENOENT)))
                        else
                            errno,
                        .syscall = .copyfile,
                        .path = old_path,
                    });
                    return;
                }
                this.event_loop.refConcurrently();
            }

            pub fn throw(this: *CopyFileWindows, err: bun.sys.Error) void {
                const globalThis = this.event_loop.global;
                const promise = this.promise.swap();
                const err_instance = err.toJSC(globalThis);
                var event_loop = this.event_loop;
                event_loop.enter();
                defer event_loop.exit();
                this.deinit();
                promise.reject(globalThis, err_instance);
            }

            fn onCopyFile(req: *libuv.fs_t) callconv(.C) void {
                var this: *CopyFileWindows = @fieldParentPtr("io_request", req);
                bun.assert(req.data == @as(?*anyopaque, @ptrCast(this)));

                var event_loop = this.event_loop;
                event_loop.unrefConcurrently();
                const rc = req.result;

                bun.sys.syslog("uv_fs_copyfile() = {}", .{rc});
                if (rc.errEnum()) |errno| {
                    if (this.mkdirp_if_not_exists and errno == .NOENT) {
                        req.deinit();
                        this.mkdirp();
                        return;
                    } else {
                        var err = bun.sys.Error.fromCode(
                            // #6336
                            if (errno == .PERM) .NOENT else errno,

                            .copyfile,
                        );
                        const destination = &this.destination_file_store.data.file;

                        // we don't really know which one it is
                        if (destination.pathlike == .path) {
                            err = err.withPath(destination.pathlike.path.slice());
                        } else if (destination.pathlike == .fd) {
                            err = err.withFd(destination.pathlike.fd);
                        }

                        this.throw(err);
                    }
                    return;
                }

                this.onComplete(req.statbuf.size);
            }

            pub fn onComplete(this: *CopyFileWindows, written_actual: usize) void {
                var written = written_actual;
                if (written != @as(@TypeOf(written), @intCast(this.size)) and this.size != Blob.max_size) {
                    this.truncate();
                    written = @intCast(this.size);
                }
                const globalThis = this.event_loop.global;
                const promise = this.promise.swap();
                var event_loop = this.event_loop;
                event_loop.enter();
                defer event_loop.exit();

                this.deinit();
                promise.resolve(globalThis, JSC.JSValue.jsNumberFromUint64(written));
            }

            fn truncate(this: *CopyFileWindows) void {
                // TODO: optimize this
                @branchHint(.cold);

                var node_fs: JSC.Node.NodeFS = .{};
                _ = node_fs.truncate(
                    .{
                        .path = this.destination_file_store.data.file.pathlike,
                        .len = @intCast(this.size),
                    },
                    .sync,
                );
            }

            pub fn deinit(this: *CopyFileWindows) void {
                this.read_write_loop.close();
                this.destination_file_store.deref();
                this.source_file_store.deref();
                this.promise.deinit();
                this.io_request.deinit();
                bun.destroy(this);
            }

            fn mkdirp(
                this: *CopyFileWindows,
            ) void {
                bun.sys.syslog("mkdirp", .{});
                this.mkdirp_if_not_exists = false;
                var destination = &this.destination_file_store.data.file;
                if (destination.pathlike != .path) {
                    this.throw(.{
                        .errno = @as(c_int, @intCast(@intFromEnum(bun.C.SystemErrno.EINVAL))),
                        .syscall = .mkdir,
                    });
                    return;
                }

                this.event_loop.refConcurrently();
                JSC.Node.Async.AsyncMkdirp.new(.{
                    .completion = @ptrCast(&onMkdirpCompleteConcurrent),
                    .completion_ctx = this,
                    .path = bun.Dirname.dirname(u8, destination.pathlike.path.slice())
                    // this shouldn't happen
                    orelse destination.pathlike.path.slice(),
                }).schedule();
            }

            fn onMkdirpComplete(this: *CopyFileWindows) void {
                this.event_loop.unrefConcurrently();

                if (this.err) |err| {
                    this.throw(err);
                    bun.default_allocator.free(err.path);
                    return;
                }

                this.copyfile();
            }

            fn onMkdirpCompleteConcurrent(this: *CopyFileWindows, err_: JSC.Maybe(void)) void {
                bun.sys.syslog("mkdirp complete", .{});
                assert(this.err == null);
                this.err = if (err_ == .err) err_.err else null;
                this.event_loop.enqueueTaskConcurrent(JSC.ConcurrentTask.create(JSC.ManagedTask.New(CopyFileWindows, onMkdirpComplete).init(this)));
            }
        };

        const unsupported_directory_error = SystemError{
            .errno = @as(c_int, @intCast(@intFromEnum(bun.C.SystemErrno.EISDIR))),
            .message = bun.String.static("That doesn't work on folders"),
            .syscall = bun.String.static("fstat"),
        };
        const unsupported_non_regular_file_error = SystemError{
            .errno = @as(c_int, @intCast(@intFromEnum(bun.C.SystemErrno.ENOTSUP))),
            .message = bun.String.static("Non-regular files aren't supported yet"),
            .syscall = bun.String.static("fstat"),
        };

        pub const CopyFilePromiseTask = JSC.ConcurrentPromiseTask(CopyFile);
        pub const CopyFilePromiseTaskEventLoopTask = CopyFilePromiseTask.EventLoopTask;

        // blocking, but off the main thread
        pub const CopyFile = struct {
            destination_file_store: FileStore,
            source_file_store: FileStore,
            store: ?*Store = null,
            source_store: ?*Store = null,
            offset: SizeType = 0,
            size: SizeType = 0,
            max_length: SizeType = Blob.max_size,
            destination_fd: bun.FileDescriptor = invalid_fd,
            source_fd: bun.FileDescriptor = invalid_fd,

            system_error: ?SystemError = null,

            read_len: SizeType = 0,
            read_off: SizeType = 0,

            globalThis: *JSGlobalObject,

            mkdirp_if_not_exists: bool = false,

            pub const ResultType = anyerror!SizeType;

            pub const Callback = *const fn (ctx: *anyopaque, len: ResultType) void;

            pub fn create(
                allocator: std.mem.Allocator,
                store: *Store,
                source_store: *Store,
                off: SizeType,
                max_len: SizeType,
                globalThis: *JSC.JSGlobalObject,
                mkdirp_if_not_exists: bool,
            ) !*CopyFilePromiseTask {
                const read_file = bun.new(CopyFile, CopyFile{
                    .store = store,
                    .source_store = source_store,
                    .offset = off,
                    .max_length = max_len,
                    .globalThis = globalThis,
                    .destination_file_store = store.data.file,
                    .source_file_store = source_store.data.file,
                    .mkdirp_if_not_exists = mkdirp_if_not_exists,
                });
                store.ref();
                source_store.ref();
                return CopyFilePromiseTask.createOnJSThread(allocator, globalThis, read_file) catch bun.outOfMemory();
            }

            const linux = std.os.linux;
            const darwin = std.posix.system;

            pub fn deinit(this: *CopyFile) void {
                if (this.source_file_store.pathlike == .path) {
                    if (this.source_file_store.pathlike.path == .string and this.system_error == null) {
                        bun.default_allocator.free(@constCast(this.source_file_store.pathlike.path.slice()));
                    }
                }
                this.store.?.deref();

                bun.destroy(this);
            }

            pub fn reject(this: *CopyFile, promise: *JSC.JSPromise) void {
                const globalThis = this.globalThis;
                var system_error: SystemError = this.system_error orelse SystemError{};
                if (this.source_file_store.pathlike == .path and system_error.path.isEmpty()) {
                    system_error.path = bun.String.createUTF8(this.source_file_store.pathlike.path.slice());
                }

                if (system_error.message.isEmpty()) {
                    system_error.message = bun.String.static("Failed to copy file");
                }

                const instance = system_error.toErrorInstance(this.globalThis);
                if (this.store) |store| {
                    store.deref();
                }
                promise.reject(globalThis, instance);
            }

            pub fn then(this: *CopyFile, promise: *JSC.JSPromise) void {
                this.source_store.?.deref();

                if (this.system_error != null) {
                    this.reject(promise);
                    return;
                }

                promise.resolve(this.globalThis, JSC.JSValue.jsNumberFromUint64(this.read_len));
            }

            pub fn run(this: *CopyFile) void {
                this.runAsync();
            }

            pub fn doClose(this: *CopyFile) void {
                const close_input = this.destination_file_store.pathlike != .fd and this.destination_fd != invalid_fd;
                const close_output = this.source_file_store.pathlike != .fd and this.source_fd != invalid_fd;

                if (close_input and close_output) {
                    this.doCloseFile(.both);
                } else if (close_input) {
                    this.doCloseFile(.destination);
                } else if (close_output) {
                    this.doCloseFile(.source);
                }
            }

            const posix = std.posix;

            pub fn doCloseFile(this: *CopyFile, comptime which: IOWhich) void {
                switch (which) {
                    .both => {
                        this.destination_fd.close();
                        this.source_fd.close();
                    },
                    .destination => {
                        this.destination_fd.close();
                    },
                    .source => {
                        this.source_fd.close();
                    },
                }
            }

            const O = bun.O;
            const open_destination_flags = O.CLOEXEC | O.CREAT | O.WRONLY | O.TRUNC;
            const open_source_flags = O.CLOEXEC | O.RDONLY;

            pub fn doOpenFile(this: *CopyFile, comptime which: IOWhich) !void {
                var path_buf1: bun.PathBuffer = undefined;
                // open source file first
                // if it fails, we don't want the extra destination file hanging out
                if (which == .both or which == .source) {
                    this.source_fd = switch (bun.sys.open(
                        this.source_file_store.pathlike.path.sliceZ(&path_buf1),
                        open_source_flags,
                        0,
                    )) {
                        .result => |result| switch (result.makeLibUVOwnedForSyscall(.open, .close_on_fail)) {
                            .result => |result_fd| result_fd,
                            .err => |errno| {
                                this.system_error = errno.toSystemError();
                                return bun.errnoToZigErr(errno.errno);
                            },
                        },
                        .err => |errno| {
                            this.system_error = errno.toSystemError();
                            return bun.errnoToZigErr(errno.errno);
                        },
                    };
                }

                if (which == .both or which == .destination) {
                    while (true) {
                        const dest = this.destination_file_store.pathlike.path.sliceZ(&path_buf1);
                        this.destination_fd = switch (bun.sys.open(
                            dest,
                            open_destination_flags,
                            JSC.Node.default_permission,
                        )) {
                            .result => |result| switch (result.makeLibUVOwnedForSyscall(.open, .close_on_fail)) {
                                .result => |result_fd| result_fd,
                                .err => |errno| {
                                    this.system_error = errno.toSystemError();
                                    return bun.errnoToZigErr(errno.errno);
                                },
                            },
                            .err => |errno| {
                                switch (mkdirIfNotExists(this, errno, dest, dest)) {
                                    .@"continue" => continue,
                                    .fail => {
                                        if (which == .both) {
                                            this.source_fd.close();
                                            this.source_fd = .invalid;
                                        }
                                        return bun.errnoToZigErr(errno.errno);
                                    },
                                    .no => {},
                                }

                                if (which == .both) {
                                    this.source_fd.close();
                                    this.source_fd = .invalid;
                                }

                                this.system_error = errno.withPath(this.destination_file_store.pathlike.path.slice()).toSystemError();
                                return bun.errnoToZigErr(errno.errno);
                            },
                        };
                        break;
                    }
                }
            }

            const TryWith = enum {
                sendfile,
                copy_file_range,
                splice,

                pub const tag = std.EnumMap(TryWith, bun.sys.Tag).init(.{
                    .sendfile = .sendfile,
                    .copy_file_range = .copy_file_range,
                    .splice = .splice,
                });
            };

            pub fn doCopyFileRange(
                this: *CopyFile,
                comptime use: TryWith,
                comptime clear_append_if_invalid: bool,
            ) anyerror!void {
                this.read_off += this.offset;

                var remain = @as(usize, this.max_length);
                const unknown_size = remain == max_size or remain == 0;
                if (unknown_size) {
                    // sometimes stat lies
                    // let's give it 4096 and see how it goes
                    remain = 4096;
                }

                var total_written: usize = 0;
                const src_fd = this.source_fd;
                const dest_fd = this.destination_fd;

                defer {
                    this.read_len = @as(SizeType, @truncate(total_written));
                }

                var has_unset_append = false;

                // If they can't use copy_file_range, they probably also can't
                // use sendfile() or splice()
                if (!bun.canUseCopyFileRangeSyscall()) {
                    switch (JSC.Node.NodeFS.copyFileUsingReadWriteLoop("", "", src_fd, dest_fd, if (unknown_size) 0 else remain, &total_written)) {
                        .err => |err| {
                            this.system_error = err.toSystemError();
                            return bun.errnoToZigErr(err.errno);
                        },
                        .result => {
                            _ = linux.ftruncate(dest_fd.cast(), @as(std.posix.off_t, @intCast(total_written)));
                            return;
                        },
                    }
                }

                while (true) {
                    // TODO: this should use non-blocking I/O.
                    const written = switch (comptime use) {
                        .copy_file_range => linux.copy_file_range(src_fd.cast(), null, dest_fd.cast(), null, remain, 0),
                        .sendfile => linux.sendfile(dest_fd.cast(), src_fd.cast(), null, remain),
                        .splice => bun.C.splice(src_fd.cast(), null, dest_fd.cast(), null, remain, 0),
                    };

                    switch (bun.C.getErrno(written)) {
                        .SUCCESS => {},

                        .NOSYS, .XDEV => {
                            // TODO: this should use non-blocking I/O.
                            switch (JSC.Node.NodeFS.copyFileUsingReadWriteLoop("", "", src_fd, dest_fd, if (unknown_size) 0 else remain, &total_written)) {
                                .err => |err| {
                                    this.system_error = err.toSystemError();
                                    return bun.errnoToZigErr(err.errno);
                                },
                                .result => {
                                    _ = linux.ftruncate(dest_fd.cast(), @as(std.posix.off_t, @intCast(total_written)));
                                    return;
                                },
                            }
                        },

                        .INVAL => {
                            if (comptime clear_append_if_invalid) {
                                if (!has_unset_append) {
                                    // https://kylelaker.com/2018/08/31/stdout-oappend.html
                                    // make() can set STDOUT / STDERR to O_APPEND
                                    // this messes up sendfile()
                                    has_unset_append = true;
                                    const flags = linux.fcntl(dest_fd.cast(), linux.F.GETFL, @as(c_int, 0));
                                    if ((flags & O.APPEND) != 0) {
                                        _ = linux.fcntl(dest_fd.cast(), linux.F.SETFL, flags ^ O.APPEND);
                                        continue;
                                    }
                                }
                            }

                            // If the Linux machine doesn't support
                            // copy_file_range or the file descrpitor is
                            // incompatible with the chosen syscall, fall back
                            // to a read/write loop
                            if (total_written == 0) {
                                // TODO: this should use non-blocking I/O.
                                switch (JSC.Node.NodeFS.copyFileUsingReadWriteLoop("", "", src_fd, dest_fd, if (unknown_size) 0 else remain, &total_written)) {
                                    .err => |err| {
                                        this.system_error = err.toSystemError();
                                        return bun.errnoToZigErr(err.errno);
                                    },
                                    .result => {
                                        _ = linux.ftruncate(dest_fd.cast(), @as(std.posix.off_t, @intCast(total_written)));
                                        return;
                                    },
                                }
                            }

                            this.system_error = (bun.sys.Error{
                                .errno = @as(bun.sys.Error.Int, @intCast(@intFromEnum(linux.E.INVAL))),
                                .syscall = TryWith.tag.get(use).?,
                            }).toSystemError();
                            return bun.errnoToZigErr(linux.E.INVAL);
                        },
                        else => |errno| {
                            this.system_error = (bun.sys.Error{
                                .errno = @as(bun.sys.Error.Int, @intCast(@intFromEnum(errno))),
                                .syscall = TryWith.tag.get(use).?,
                            }).toSystemError();
                            return bun.errnoToZigErr(errno);
                        },
                    }

                    // wrote zero bytes means EOF
                    remain -|= @intCast(written);
                    total_written += @intCast(written);
                    if (written == 0 or remain == 0) break;
                }
            }

            pub fn doFCopyFileWithReadWriteLoopFallback(this: *CopyFile) anyerror!void {
                switch (bun.sys.fcopyfile(this.source_fd, this.destination_fd, posix.system.COPYFILE{ .DATA = true })) {
                    .err => |errno| {
                        switch (errno.getErrno()) {
                            // If the file type doesn't support seeking, it may return EBADF
                            // Example case:
                            //
                            // bun test bun-write.test | xargs echo
                            //
                            .BADF => {
                                var total_written: u64 = 0;

                                // TODO: this should use non-blocking I/O.
                                switch (JSC.Node.NodeFS.copyFileUsingReadWriteLoop("", "", this.source_fd, this.destination_fd, 0, &total_written)) {
                                    .err => |err| {
                                        this.system_error = err.toSystemError();
                                        return bun.errnoToZigErr(err.errno);
                                    },
                                    .result => {},
                                }
                            },
                            else => {
                                this.system_error = errno.toSystemError();

                                return bun.errnoToZigErr(errno.errno);
                            },
                        }
                    },
                    .result => {},
                }
            }

            pub fn doClonefile(this: *CopyFile) anyerror!void {
                var source_buf: bun.PathBuffer = undefined;
                var dest_buf: bun.PathBuffer = undefined;

                while (true) {
                    const dest = this.destination_file_store.pathlike.path.sliceZ(
                        &dest_buf,
                    );
                    switch (bun.sys.clonefile(
                        this.source_file_store.pathlike.path.sliceZ(&source_buf),
                        dest,
                    )) {
                        .err => |errno| {
                            switch (mkdirIfNotExists(this, errno, dest, this.destination_file_store.pathlike.path.slice())) {
                                .@"continue" => continue,
                                .fail => {},
                                .no => {},
                            }
                            this.system_error = errno.toSystemError();
                            return bun.errnoToZigErr(errno.errno);
                        },
                        .result => {},
                    }
                    break;
                }
            }

            pub fn runAsync(this: *CopyFile) void {
                if (Environment.isWindows) return; //why
                // defer task.onFinish();

                var stat_: ?bun.Stat = null;

                if (this.destination_file_store.pathlike == .fd) {
                    this.destination_fd = this.destination_file_store.pathlike.fd;
                }

                if (this.source_file_store.pathlike == .fd) {
                    this.source_fd = this.source_file_store.pathlike.fd;
                }

                // Do we need to open both files?
                if (this.destination_fd == invalid_fd and this.source_fd == invalid_fd) {

                    // First, we attempt to clonefile() on macOS
                    // This is the fastest way to copy a file.
                    if (comptime Environment.isMac) {
                        if (this.offset == 0 and this.source_file_store.pathlike == .path and this.destination_file_store.pathlike == .path) {
                            do_clonefile: {
                                var path_buf: bun.PathBuffer = undefined;

                                // stat the output file, make sure it:
                                // 1. Exists
                                switch (bun.sys.stat(this.source_file_store.pathlike.path.sliceZ(&path_buf))) {
                                    .result => |result| {
                                        stat_ = result;

                                        if (posix.S.ISDIR(result.mode)) {
                                            this.system_error = unsupported_directory_error;
                                            return;
                                        }

                                        if (!posix.S.ISREG(result.mode))
                                            break :do_clonefile;
                                    },
                                    .err => |err| {
                                        // If we can't stat it, we also can't copy it.
                                        this.system_error = err.toSystemError();
                                        return;
                                    },
                                }

                                if (this.doClonefile()) {
                                    if (this.max_length != Blob.max_size and this.max_length < @as(SizeType, @intCast(stat_.?.size))) {
                                        // If this fails...well, there's not much we can do about it.
                                        _ = bun.C.truncate(
                                            this.destination_file_store.pathlike.path.sliceZ(&path_buf),
                                            @as(std.posix.off_t, @intCast(this.max_length)),
                                        );
                                        this.read_len = @as(SizeType, @intCast(this.max_length));
                                    } else {
                                        this.read_len = @as(SizeType, @intCast(stat_.?.size));
                                    }
                                    return;
                                } else |_| {

                                    // this may still fail, in which case we just continue trying with fcopyfile
                                    // it can fail when the input file already exists
                                    // or if the output is not a directory
                                    // or if it's a network volume
                                    this.system_error = null;
                                }
                            }
                        }
                    }

                    this.doOpenFile(.both) catch return;
                    // Do we need to open only one file?
                } else if (this.destination_fd == invalid_fd) {
                    this.source_fd = this.source_file_store.pathlike.fd;

                    this.doOpenFile(.destination) catch return;
                    // Do we need to open only one file?
                } else if (this.source_fd == invalid_fd) {
                    this.destination_fd = this.destination_file_store.pathlike.fd;

                    this.doOpenFile(.source) catch return;
                }

                if (this.system_error != null) {
                    return;
                }

                assert(this.destination_fd != invalid_fd);
                assert(this.source_fd != invalid_fd);

                if (this.destination_file_store.pathlike == .fd) {}

                const stat: bun.Stat = stat_ orelse switch (bun.sys.fstat(this.source_fd)) {
                    .result => |result| result,
                    .err => |err| {
                        this.doClose();
                        this.system_error = err.toSystemError();
                        return;
                    },
                };

                if (posix.S.ISDIR(stat.mode)) {
                    this.system_error = unsupported_directory_error;
                    this.doClose();
                    return;
                }

                if (stat.size != 0) {
                    this.max_length = @max(@min(@as(SizeType, @intCast(stat.size)), this.max_length), this.offset) - this.offset;
                    if (this.max_length == 0) {
                        this.doClose();
                        return;
                    }

                    if (posix.S.ISREG(stat.mode) and
                        this.max_length > bun.C.preallocate_length and
                        this.max_length != Blob.max_size)
                    {
                        bun.C.preallocate_file(this.destination_fd.cast(), 0, this.max_length) catch {};
                    }
                }

                if (comptime Environment.isLinux) {

                    // Bun.write(Bun.file("a"), Bun.file("b"))
                    if (posix.S.ISREG(stat.mode) and (posix.S.ISREG(this.destination_file_store.mode) or this.destination_file_store.mode == 0)) {
                        if (this.destination_file_store.is_atty orelse false) {
                            this.doCopyFileRange(.copy_file_range, true) catch {};
                        } else {
                            this.doCopyFileRange(.copy_file_range, false) catch {};
                        }

                        this.doClose();
                        return;
                    }

                    // $ bun run foo.js | bun run bar.js
                    if (posix.S.ISFIFO(stat.mode) and posix.S.ISFIFO(this.destination_file_store.mode)) {
                        if (this.destination_file_store.is_atty orelse false) {
                            this.doCopyFileRange(.splice, true) catch {};
                        } else {
                            this.doCopyFileRange(.splice, false) catch {};
                        }

                        this.doClose();
                        return;
                    }

                    if (posix.S.ISREG(stat.mode) or posix.S.ISCHR(stat.mode) or posix.S.ISSOCK(stat.mode)) {
                        if (this.destination_file_store.is_atty orelse false) {
                            this.doCopyFileRange(.sendfile, true) catch {};
                        } else {
                            this.doCopyFileRange(.sendfile, false) catch {};
                        }

                        this.doClose();
                        return;
                    }

                    this.system_error = unsupported_non_regular_file_error;
                    this.doClose();
                    return;
                }

                if (comptime Environment.isMac) {
                    this.doFCopyFileWithReadWriteLoopFallback() catch {
                        this.doClose();

                        return;
                    };
                    if (stat.size != 0 and @as(SizeType, @intCast(stat.size)) > this.max_length) {
                        _ = darwin.ftruncate(this.destination_fd.cast(), @as(std.posix.off_t, @intCast(this.max_length)));
                    }

                    this.doClose();
                } else {
                    @compileError("TODO: implement copyfile");
                }
            }
        };
    };

    pub const FileStore = struct {
        pathlike: JSC.Node.PathOrFileDescriptor,
        mime_type: http.MimeType = http.MimeType.other,
        is_atty: ?bool = null,
        mode: bun.Mode = 0,
        seekable: ?bool = null,
        max_size: SizeType = Blob.max_size,
        // milliseconds since ECMAScript epoch
        last_modified: JSC.JSTimeType = JSC.init_timestamp,

        pub fn unlink(this: *const FileStore, globalThis: *JSC.JSGlobalObject) bun.JSError!JSValue {
            return switch (this.pathlike) {
                .path => |path_like| JSC.Node.Async.unlink.create(globalThis, undefined, .{
                    .path = .{
                        .encoded_slice = switch (path_like) {
                            .encoded_slice => |slice| try slice.toOwned(bun.default_allocator),
                            else => try ZigString.init(path_like.slice()).toSliceClone(bun.default_allocator),
                        },
                    },
                }, globalThis.bunVM()),
                .fd => JSC.JSPromise.resolvedPromiseValue(globalThis, globalThis.createInvalidArgs("Is not possible to unlink a file descriptor", .{})),
            };
        }
        pub fn isSeekable(this: *const FileStore) ?bool {
            if (this.seekable) |seekable| {
                return seekable;
            }

            if (this.mode != 0) {
                return bun.isRegularFile(this.mode);
            }

            return null;
        }

        pub fn init(pathlike: JSC.Node.PathOrFileDescriptor, mime_type: ?http.MimeType) FileStore {
            return .{ .pathlike = pathlike, .mime_type = mime_type orelse http.MimeType.other };
        }
    };

    pub const S3Store = struct {
        pathlike: JSC.Node.PathLike,
        mime_type: http.MimeType = http.MimeType.other,
        credentials: ?*S3Credentials,
        options: bun.S3.MultiPartUploadOptions = .{},
        acl: ?S3.ACL = null,
        storage_class: ?S3.StorageClass = null,

        pub fn isSeekable(_: *const @This()) ?bool {
            return true;
        }

        pub fn getCredentials(this: *const @This()) *S3Credentials {
            bun.assert(this.credentials != null);
            return this.credentials.?;
        }

        pub fn getCredentialsWithOptions(this: *const @This(), options: ?JSValue, globalObject: *JSC.JSGlobalObject) bun.JSError!S3.S3CredentialsWithOptions {
            return S3Credentials.getCredentialsWithOptions(this.getCredentials().*, this.options, options, this.acl, this.storage_class, globalObject);
        }

        pub fn path(this: *@This()) []const u8 {
            var path_name = bun.URL.parse(this.pathlike.slice()).s3Path();
            // normalize start and ending
            if (strings.endsWith(path_name, "/")) {
                path_name = path_name[0..path_name.len];
            } else if (strings.endsWith(path_name, "\\")) {
                path_name = path_name[0 .. path_name.len - 1];
            }
            if (strings.startsWith(path_name, "/")) {
                path_name = path_name[1..];
            } else if (strings.startsWith(path_name, "\\")) {
                path_name = path_name[1..];
            }
            return path_name;
        }

        pub fn unlink(this: *@This(), store: *Store, globalThis: *JSC.JSGlobalObject, extra_options: ?JSValue) bun.JSError!JSValue {
            const Wrapper = struct {
                promise: JSC.JSPromise.Strong,
                store: *Store,
                global: *JSC.JSGlobalObject,

                pub const new = bun.TrivialNew(@This());

                pub fn resolve(result: S3.S3DeleteResult, opaque_self: *anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(opaque_self));
                    defer self.deinit();
                    const globalObject = self.global;
                    switch (result) {
                        .success => {
                            self.promise.resolve(globalObject, .true);
                        },
                        .not_found, .failure => |err| {
                            self.promise.reject(globalObject, err.toJS(globalObject, self.store.getPath()));
                        },
                    }
                }

                fn deinit(wrap: *@This()) void {
                    wrap.store.deref();
                    wrap.promise.deinit();
                    bun.destroy(wrap);
                }
            };
            const promise = JSC.JSPromise.Strong.init(globalThis);
            const value = promise.value();
            const proxy_url = globalThis.bunVM().transpiler.env.getHttpProxy(true, null);
            const proxy = if (proxy_url) |url| url.href else null;
            var aws_options = try this.getCredentialsWithOptions(extra_options, globalThis);
            defer aws_options.deinit();
            S3.delete(&aws_options.credentials, this.path(), @ptrCast(&Wrapper.resolve), Wrapper.new(.{
                .promise = promise,
                .store = store, // store is needed in case of not found error
                .global = globalThis,
            }), proxy);
            store.ref();

            return value;
        }

        pub fn listObjects(this: *@This(), store: *Store, globalThis: *JSC.JSGlobalObject, listOptions: JSValue, extra_options: ?JSValue) bun.JSError!JSValue {
            if (!listOptions.isEmptyOrUndefinedOrNull() and !listOptions.isObject()) {
                return globalThis.throwInvalidArguments("S3Client.listObjects() needs a S3ListObjectsOption as it's first argument", .{});
            }

            const Wrapper = struct {
                promise: JSC.JSPromise.Strong,
                store: *Store,
                resolvedlistOptions: S3.S3ListObjectsOptions,
                global: *JSC.JSGlobalObject,

                pub fn resolve(result: S3.S3ListObjectsResult, opaque_self: *anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(opaque_self));
                    defer self.deinit();
                    const globalObject = self.global;

                    switch (result) {
                        .success => |list_result| {
                            defer list_result.deinit();
                            self.promise.resolve(globalObject, list_result.toJS(globalObject));
                        },

                        inline .not_found, .failure => |err| {
                            self.promise.reject(globalObject, err.toJS(globalObject, self.store.getPath()));
                        },
                    }
                }

                fn deinit(self: *@This()) void {
                    self.store.deref();
                    self.promise.deinit();
                    self.resolvedlistOptions.deinit();
                    self.destroy();
                }

                pub inline fn destroy(self: *@This()) void {
                    bun.destroy(self);
                }
            };

            const promise = JSC.JSPromise.Strong.init(globalThis);
            const value = promise.value();
            const proxy_url = globalThis.bunVM().transpiler.env.getHttpProxy(true, null);
            const proxy = if (proxy_url) |url| url.href else null;
            var aws_options = try this.getCredentialsWithOptions(extra_options, globalThis);
            defer aws_options.deinit();

            const options = S3.getListObjectsOptionsFromJS(globalThis, listOptions) catch bun.outOfMemory();
            store.ref();

            S3.listObjects(&aws_options.credentials, options, @ptrCast(&Wrapper.resolve), bun.new(Wrapper, .{
                .promise = promise,
                .store = store, // store is needed in case of not found error
                .resolvedlistOptions = options,
                .global = globalThis,
            }), proxy);

            return value;
        }

        pub fn initWithReferencedCredentials(pathlike: JSC.Node.PathLike, mime_type: ?http.MimeType, credentials: *S3Credentials) S3Store {
            credentials.ref();
            return .{
                .credentials = credentials,
                .pathlike = pathlike,
                .mime_type = mime_type orelse http.MimeType.other,
            };
        }
        pub fn init(pathlike: JSC.Node.PathLike, mime_type: ?http.MimeType, credentials: S3Credentials) S3Store {
            return .{
                .credentials = credentials.dupe(),
                .pathlike = pathlike,
                .mime_type = mime_type orelse http.MimeType.other,
            };
        }
        pub fn estimatedSize(this: *const @This()) usize {
            return this.pathlike.estimatedSize() + if (this.credentials) |credentials| credentials.estimatedSize() else 0;
        }

        pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
            if (this.pathlike == .string) {
                allocator.free(@constCast(this.pathlike.slice()));
            } else {
                this.pathlike.deinit();
            }
            this.pathlike = .{
                .string = bun.PathString.empty,
            };
            if (this.credentials) |credentials| {
                credentials.deref();
                this.credentials = null;
            }
        }
    };

    pub const ByteStore = struct {
        ptr: ?[*]u8 = undefined,
        len: SizeType = 0,
        cap: SizeType = 0,
        allocator: std.mem.Allocator,

        /// Used by standalone module graph and the File constructor
        stored_name: bun.PathString = bun.PathString.empty,

        /// Takes ownership of `bytes`, which must have been allocated with
        /// `allocator`.
        pub fn init(bytes: []u8, allocator: std.mem.Allocator) ByteStore {
            return .{
                .ptr = bytes.ptr,
                .len = @as(SizeType, @truncate(bytes.len)),
                .cap = @as(SizeType, @truncate(bytes.len)),
                .allocator = allocator,
            };
        }
        pub fn initEmptyWithName(name: bun.PathString, allocator: std.mem.Allocator) ByteStore {
            return .{
                .ptr = null,
                .len = 0,
                .cap = 0,
                .allocator = allocator,
                .stored_name = name,
            };
        }

        pub fn fromArrayList(list: std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !*ByteStore {
            return ByteStore.init(list.items, allocator);
        }

        pub fn toInternalBlob(this: *ByteStore) InternalBlob {
            const ptr = this.ptr orelse return InternalBlob{
                .bytes = std.ArrayList(u8){
                    .items = &.{},
                    .capacity = 0,
                    .allocator = this.allocator,
                },
            };

            const result = InternalBlob{
                .bytes = std.ArrayList(u8){
                    .items = ptr[0..this.len],
                    .capacity = this.cap,
                    .allocator = this.allocator,
                },
            };

            this.allocator = bun.default_allocator;
            this.len = 0;
            this.cap = 0;
            return result;
        }
        pub fn slice(this: ByteStore) []u8 {
            if (this.ptr) |ptr| {
                return ptr[0..this.len];
            }
            return "";
        }

        pub fn allocatedSlice(this: ByteStore) []u8 {
            if (this.ptr) |ptr| {
                return ptr[0..this.cap];
            }
            return "";
        }

        pub fn deinit(this: *ByteStore) void {
            bun.default_allocator.free(this.stored_name.slice());
            if (this.ptr) |ptr| {
                this.allocator.free(ptr[0..this.cap]);
            }
            this.ptr = null;
            this.len = 0;
            this.cap = 0;
        }

        pub fn asArrayList(this: ByteStore) std.ArrayListUnmanaged(u8) {
            return this.asArrayListLeak();
        }

        pub fn asArrayListLeak(this: ByteStore) std.ArrayListUnmanaged(u8) {
            return .{
                .items = this.ptr[0..this.len],
                .capacity = this.cap,
            };
        }
    };

    pub fn getStream(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        callframe: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        const thisValue = callframe.this();
        if (js.streamGetCached(thisValue)) |cached| {
            return cached;
        }
        var recommended_chunk_size: SizeType = 0;
        var arguments_ = callframe.arguments_old(2);
        var arguments = arguments_.ptr[0..arguments_.len];
        if (arguments.len > 0) {
            if (!arguments[0].isNumber() and !arguments[0].isUndefinedOrNull()) {
                return globalThis.throwInvalidArguments("chunkSize must be a number", .{});
            }

            recommended_chunk_size = @as(SizeType, @intCast(@max(0, @as(i52, @truncate(arguments[0].toInt64())))));
        }
        const stream = JSC.WebCore.ReadableStream.fromBlob(
            globalThis,
            this,
            recommended_chunk_size,
        );

        if (this.store) |store| {
            switch (store.data) {
                .file => |f| switch (f.pathlike) {
                    .fd => {
                        // in the case we have a file descriptor store, we want to de-duplicate
                        // readable streams. in every other case we want `.stream()` to be it's
                        // own stream.
                        js.streamSetCached(thisValue, globalThis, stream);
                    },
                    else => {},
                },
                else => {},
            }
        }

        return stream;
    }

    pub fn toStreamWithOffset(
        globalThis: *JSC.JSGlobalObject,
        callframe: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        const this = callframe.this().as(Blob) orelse @panic("this is not a Blob");
        const args = callframe.arguments_old(1).slice();

        return JSC.WebCore.ReadableStream.fromFileBlobWithOffset(
            globalThis,
            this,
            @intCast(args[0].toInt64()),
        );
    }

    // Zig doesn't let you pass a function with a comptime argument to a runtime-knwon function.
    fn lifetimeWrap(comptime Fn: anytype, comptime lifetime: JSC.WebCore.Lifetime) fn (*Blob, *JSC.JSGlobalObject) JSC.JSValue {
        return struct {
            fn wrap(this: *Blob, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
                return JSC.toJSHostValue(globalObject, Fn(this, globalObject, lifetime));
            }
        }.wrap;
    }

    pub fn getText(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        return this.getTextClone(globalThis);
    }

    pub fn getTextClone(
        this: *Blob,
        globalObject: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();
        return JSC.JSPromise.wrap(globalObject, lifetimeWrap(toString, .clone), .{ this, globalObject });
    }

    pub fn getTextTransfer(
        this: *Blob,
        globalObject: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();
        return JSC.JSPromise.wrap(globalObject, lifetimeWrap(toString, .transfer), .{ this, globalObject });
    }

    pub fn getJSON(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        return this.getJSONShare(globalThis);
    }

    pub fn getJSONShare(
        this: *Blob,
        globalObject: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();
        return JSC.JSPromise.wrap(globalObject, lifetimeWrap(toJSON, .share), .{ this, globalObject });
    }
    pub fn getArrayBufferTransfer(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();

        return JSC.JSPromise.wrap(globalThis, lifetimeWrap(toArrayBuffer, .transfer), .{ this, globalThis });
    }

    pub fn getArrayBufferClone(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
    ) JSC.JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();
        return JSC.JSPromise.wrap(globalThis, lifetimeWrap(toArrayBuffer, .clone), .{ this, globalThis });
    }

    pub fn getArrayBuffer(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSValue {
        return this.getArrayBufferClone(globalThis);
    }

    pub fn getBytesClone(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
    ) JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();
        return JSC.JSPromise.wrap(globalThis, lifetimeWrap(toUint8Array, .clone), .{ this, globalThis });
    }

    pub fn getBytes(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSValue {
        return this.getBytesClone(globalThis);
    }

    pub fn getBytesTransfer(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
    ) JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();
        return JSC.JSPromise.wrap(globalThis, lifetimeWrap(toUint8Array, .transfer), .{ this, globalThis });
    }

    pub fn getFormData(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSValue {
        const store = this.store;
        if (store) |st| st.ref();
        defer if (store) |st| st.deref();

        return JSC.JSPromise.wrap(globalThis, lifetimeWrap(toFormData, .temporary), .{ this, globalThis });
    }

    fn getExistsSync(this: *Blob) JSC.JSValue {
        if (this.size == Blob.max_size) {
            this.resolveSize();
        }

        // If there's no store that means it's empty and we just return true
        // it will not error to return an empty Blob
        const store = this.store orelse return JSValue.jsBoolean(true);

        if (store.data == .bytes) {
            // Bytes will never error
            return JSValue.jsBoolean(true);
        }

        // We say regular files and pipes exist.
        // This is mostly meant for "Can we use this in new Response(file)?"
        return JSValue.jsBoolean(bun.isRegularFile(store.data.file.mode) or bun.C.S.ISFIFO(store.data.file.mode));
    }

    pub fn isS3(this: *const Blob) bool {
        if (this.store) |store| {
            return store.data == .s3;
        }
        return false;
    }

    const S3BlobDownloadTask = struct {
        blob: Blob,
        globalThis: *JSC.JSGlobalObject,
        promise: JSC.JSPromise.Strong,
        poll_ref: bun.Async.KeepAlive = .{},

        handler: S3ReadHandler,
        pub const new = bun.TrivialNew(S3BlobDownloadTask);
        pub const S3ReadHandler = *const fn (this: *Blob, globalthis: *JSGlobalObject, raw_bytes: []u8) JSValue;

        pub fn callHandler(this: *S3BlobDownloadTask, raw_bytes: []u8) JSValue {
            return this.handler(&this.blob, this.globalThis, raw_bytes);
        }
        pub fn onS3DownloadResolved(result: S3.S3DownloadResult, this: *S3BlobDownloadTask) void {
            defer this.deinit();
            switch (result) {
                .success => |response| {
                    const bytes = response.body.list.items;
                    if (this.blob.size == Blob.max_size) {
                        this.blob.size = @truncate(bytes.len);
                    }
                    JSC.AnyPromise.wrap(.{ .normal = this.promise.get() }, this.globalThis, S3BlobDownloadTask.callHandler, .{ this, bytes });
                },
                inline .not_found, .failure => |err| {
                    this.promise.reject(this.globalThis, err.toJS(this.globalThis, this.blob.store.?.getPath()));
                },
            }
        }

        pub fn init(globalThis: *JSC.JSGlobalObject, blob: *Blob, handler: S3BlobDownloadTask.S3ReadHandler) JSValue {
            blob.store.?.ref();

            const this = S3BlobDownloadTask.new(.{
                .globalThis = globalThis,
                .blob = blob.*,
                .promise = JSC.JSPromise.Strong.init(globalThis),
                .handler = handler,
            });
            const promise = this.promise.value();
            const env = this.globalThis.bunVM().transpiler.env;
            const credentials = this.blob.store.?.data.s3.getCredentials();
            const path = this.blob.store.?.data.s3.path();

            this.poll_ref.ref(globalThis.bunVM());
            if (blob.offset > 0) {
                const len: ?usize = if (blob.size != Blob.max_size) @intCast(blob.size) else null;
                const offset: usize = @intCast(blob.offset);
                S3.downloadSlice(credentials, path, offset, len, @ptrCast(&S3BlobDownloadTask.onS3DownloadResolved), this, if (env.getHttpProxy(true, null)) |proxy| proxy.href else null);
            } else if (blob.size == Blob.max_size) {
                S3.download(credentials, path, @ptrCast(&S3BlobDownloadTask.onS3DownloadResolved), this, if (env.getHttpProxy(true, null)) |proxy| proxy.href else null);
            } else {
                const len: usize = @intCast(blob.size);
                const offset: usize = @intCast(blob.offset);
                S3.downloadSlice(credentials, path, offset, len, @ptrCast(&S3BlobDownloadTask.onS3DownloadResolved), this, if (env.getHttpProxy(true, null)) |proxy| proxy.href else null);
            }
            return promise;
        }

        pub fn deinit(this: *S3BlobDownloadTask) void {
            this.blob.store.?.deref();
            this.poll_ref.unref(this.globalThis.bunVM());
            this.promise.deinit();
            bun.destroy(this);
        }
    };

    pub fn doWrite(this: *Blob, globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const arguments = callframe.arguments_old(3).slice();
        var args = JSC.Node.ArgumentsSlice.init(globalThis.bunVM(), arguments);
        defer args.deinit();

        const data = args.nextEat() orelse {
            return globalThis.throwInvalidArguments("blob.write(pathOrFdOrBlob, blob) expects a Blob-y thing to write", .{});
        };
        if (data.isEmptyOrUndefinedOrNull()) {
            return globalThis.throwInvalidArguments("blob.write(pathOrFdOrBlob, blob) expects a Blob-y thing to write", .{});
        }
        var mkdirp_if_not_exists: ?bool = null;
        const options = args.nextEat();
        if (options) |options_object| {
            if (options_object.isObject()) {
                if (try options_object.getTruthy(globalThis, "createPath")) |create_directory| {
                    if (!create_directory.isBoolean()) {
                        return globalThis.throwInvalidArgumentType("write", "options.createPath", "boolean");
                    }
                    mkdirp_if_not_exists = create_directory.toBoolean();
                }
                if (try options_object.getTruthy(globalThis, "type")) |content_type| {
                    //override the content type
                    if (!content_type.isString()) {
                        return globalThis.throwInvalidArgumentType("write", "options.type", "string");
                    }
                    var content_type_str = try content_type.toSlice(globalThis, bun.default_allocator);
                    defer content_type_str.deinit();
                    const slice = content_type_str.slice();
                    if (strings.isAllASCII(slice)) {
                        if (this.content_type_allocated) {
                            bun.default_allocator.free(this.content_type);
                        }
                        this.content_type_was_set = true;

                        if (globalThis.bunVM().mimeType(slice)) |mime| {
                            this.content_type = mime.value;
                        } else {
                            const content_type_buf = bun.default_allocator.alloc(u8, slice.len) catch bun.outOfMemory();
                            this.content_type = strings.copyLowercase(slice, content_type_buf);
                            this.content_type_allocated = true;
                        }
                    }
                }
            } else if (!options_object.isEmptyOrUndefinedOrNull()) {
                return globalThis.throwInvalidArgumentType("write", "options", "object");
            }
        }
        var blob_internal: PathOrBlob = .{ .blob = this.* };
        return writeFileInternal(globalThis, &blob_internal, data, .{ .mkdirp_if_not_exists = mkdirp_if_not_exists, .extra_options = options });
    }

    pub fn doUnlink(this: *Blob, globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const arguments = callframe.arguments_old(1).slice();
        var args = JSC.Node.ArgumentsSlice.init(globalThis.bunVM(), arguments);
        defer args.deinit();
        const store = this.store orelse {
            return JSC.JSPromise.resolvedPromiseValue(globalThis, globalThis.createInvalidArgs("Blob is detached", .{}));
        };
        return switch (store.data) {
            .s3 => |*s3| try s3.unlink(store, globalThis, args.nextEat()),
            .file => |file| file.unlink(globalThis),
            else => JSC.JSPromise.resolvedPromiseValue(globalThis, globalThis.createInvalidArgs("Blob is read-only", .{})),
        };
    }

    // This mostly means 'can it be read?'
    pub fn getExists(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        _: *JSC.CallFrame,
    ) bun.JSError!JSValue {
        if (this.isS3()) {
            return S3File.S3BlobStatTask.exists(globalThis, this);
        }
        return JSC.JSPromise.resolvedPromiseValue(globalThis, this.getExistsSync());
    }

    pub const FileStreamWrapper = struct {
        promise: JSC.JSPromise.Strong,
        readable_stream_ref: JSC.WebCore.ReadableStream.Strong,
        sink: *JSC.WebCore.FileSink,

        pub const new = bun.TrivialNew(@This());

        pub fn deinit(this: *@This()) void {
            this.promise.deinit();
            this.readable_stream_ref.deinit();
            this.sink.deref();
            bun.destroy(this);
        }
    };

    pub fn onFileStreamResolveRequestStream(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        var args = callframe.arguments_old(2);
        var this = args.ptr[args.len - 1].asPromisePtr(FileStreamWrapper);
        defer this.deinit();
        var strong = this.readable_stream_ref;
        defer strong.deinit();
        this.readable_stream_ref = .{};
        if (strong.get(globalThis)) |stream| {
            stream.done(globalThis);
        }
        this.promise.resolve(globalThis, JSC.JSValue.jsNumber(0));
        return .undefined;
    }

    pub fn onFileStreamRejectRequestStream(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        const args = callframe.arguments_old(2);
        var this = args.ptr[args.len - 1].asPromisePtr(FileStreamWrapper);
        defer this.sink.deref();
        const err = args.ptr[0];

        var strong = this.readable_stream_ref;
        defer strong.deinit();
        this.readable_stream_ref = .{};

        this.promise.reject(globalThis, err);

        if (strong.get(globalThis)) |stream| {
            stream.cancel(globalThis);
        }
        return .undefined;
    }
    comptime {
        const jsonResolveRequestStream = JSC.toJSHostFunction(onFileStreamResolveRequestStream);
        @export(&jsonResolveRequestStream, .{ .name = "Bun__FileStreamWrapper__onResolveRequestStream" });
        const jsonRejectRequestStream = JSC.toJSHostFunction(onFileStreamRejectRequestStream);
        @export(&jsonRejectRequestStream, .{ .name = "Bun__FileStreamWrapper__onRejectRequestStream" });
    }

    pub fn pipeReadableStreamToBlob(this: *Blob, globalThis: *JSC.JSGlobalObject, readable_stream: JSC.WebCore.ReadableStream, extra_options: ?JSValue) JSC.JSValue {
        var store = this.store orelse {
            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, globalThis.createErrorInstance("Blob is detached", .{}));
        };

        if (this.isS3()) {
            const s3 = &this.store.?.data.s3;
            var aws_options = s3.getCredentialsWithOptions(extra_options, globalThis) catch |err| {
                return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, globalThis.takeException(err));
            };
            defer aws_options.deinit();

            const path = s3.path();
            const proxy = globalThis.bunVM().transpiler.env.getHttpProxy(true, null);
            const proxy_url = if (proxy) |p| p.href else null;

            return S3.uploadStream(
                (if (extra_options != null) aws_options.credentials.dupe() else s3.getCredentials()),
                path,
                readable_stream,
                globalThis,
                aws_options.options,
                aws_options.acl,
                aws_options.storage_class,
                this.contentTypeOrMimeType(),
                proxy_url,
                null,
                undefined,
            );
        }

        if (store.data != .file) {
            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, globalThis.createErrorInstance("Blob is read-only", .{}));
        }

        const file_sink = brk_sink: {
            if (Environment.isWindows) {
                const pathlike = store.data.file.pathlike;
                const fd: bun.FileDescriptor = if (pathlike == .fd) pathlike.fd else brk: {
                    var file_path: bun.PathBuffer = undefined;
                    const path = pathlike.path.sliceZ(&file_path);
                    switch (bun.sys.open(
                        path,
                        bun.O.WRONLY | bun.O.CREAT | bun.O.NONBLOCK,
                        write_permissions,
                    )) {
                        .result => |result| {
                            break :brk result;
                        },
                        .err => |err| {
                            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err.withPath(path).toJSC(globalThis));
                        },
                    }
                    unreachable;
                };

                const is_stdout_or_stderr = brk: {
                    if (pathlike != .fd) {
                        break :brk false;
                    }

                    if (globalThis.bunVM().rare_data) |rare| {
                        if (store == rare.stdout_store) {
                            break :brk true;
                        }

                        if (store == rare.stderr_store) {
                            break :brk true;
                        }
                    }

                    break :brk if (fd.stdioTag()) |tag| switch (tag) {
                        .std_out, .std_err => true,
                        else => false,
                    } else false;
                };
                var sink = JSC.WebCore.FileSink.init(fd, this.globalThis.bunVM().eventLoop());
                sink.writer.owns_fd = pathlike != .fd;

                if (is_stdout_or_stderr) {
                    switch (sink.writer.startSync(fd, false)) {
                        .err => |err| {
                            sink.deref();
                            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err.toJSC(globalThis));
                        },
                        else => {},
                    }
                } else {
                    switch (sink.writer.start(fd, true)) {
                        .err => |err| {
                            sink.deref();
                            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err.toJSC(globalThis));
                        },
                        else => {},
                    }
                }

                break :brk_sink sink;
            }

            var sink = JSC.WebCore.FileSink.init(bun.invalid_fd, this.globalThis.bunVM().eventLoop());

            const input_path: JSC.WebCore.PathOrFileDescriptor = brk: {
                if (store.data.file.pathlike == .fd) {
                    break :brk .{ .fd = store.data.file.pathlike.fd };
                } else {
                    break :brk .{
                        .path = ZigString.Slice.fromUTF8NeverFree(
                            store.data.file.pathlike.path.slice(),
                        ).clone(
                            bun.default_allocator,
                        ) catch bun.outOfMemory(),
                    };
                }
            };
            defer input_path.deinit();

            const stream_start: JSC.WebCore.StreamStart = .{
                .FileSink = .{
                    .input_path = input_path,
                },
            };

            switch (sink.start(stream_start)) {
                .err => |err| {
                    sink.deref();
                    return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err.toJSC(globalThis));
                },
                else => {},
            }
            break :brk_sink sink;
        };
        var signal = &file_sink.signal;

        signal.* = JSC.WebCore.FileSink.JSSink.SinkSignal.init(.zero);

        // explicitly set it to a dead pointer
        // we use this memory address to disable signals being sent
        signal.clear();
        bun.assert(signal.isDead());

        const assignment_result: JSC.JSValue = JSC.WebCore.FileSink.JSSink.assignToStream(
            globalThis,
            readable_stream.value,
            file_sink,
            @as(**anyopaque, @ptrCast(&signal.ptr)),
        );

        assignment_result.ensureStillAlive();

        // assert that it was updated
        bun.assert(!signal.isDead());

        if (assignment_result.toError()) |err| {
            file_sink.deref();
            return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, err);
        }

        if (!assignment_result.isEmptyOrUndefinedOrNull()) {
            globalThis.bunVM().drainMicrotasks();

            assignment_result.ensureStillAlive();
            // it returns a Promise when it goes through ReadableStreamDefaultReader
            if (assignment_result.asAnyPromise()) |promise| {
                switch (promise.status(globalThis.vm())) {
                    .pending => {
                        const wrapper = FileStreamWrapper.new(.{
                            .promise = JSC.JSPromise.Strong.init(globalThis),
                            .readable_stream_ref = JSC.WebCore.ReadableStream.Strong.init(readable_stream, globalThis),
                            .sink = file_sink,
                        });
                        const promise_value = wrapper.promise.value();

                        assignment_result.then(
                            globalThis,
                            wrapper,
                            onFileStreamResolveRequestStream,
                            onFileStreamRejectRequestStream,
                        );
                        return promise_value;
                    },
                    .fulfilled => {
                        file_sink.deref();
                        readable_stream.done(globalThis);
                        return JSC.JSPromise.resolvedPromiseValue(globalThis, JSC.JSValue.jsNumber(0));
                    },
                    .rejected => {
                        file_sink.deref();

                        readable_stream.cancel(globalThis);

                        return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, promise.result(globalThis.vm()));
                    },
                }
            } else {
                file_sink.deref();

                readable_stream.cancel(globalThis);

                return JSC.JSPromise.dangerouslyCreateRejectedPromiseValueWithoutNotifyingVM(globalThis, assignment_result);
            }
        }
        file_sink.deref();

        return JSC.JSPromise.resolvedPromiseValue(globalThis, JSC.JSValue.jsNumber(0));
    }

    pub fn getWriter(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        callframe: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        var arguments_ = callframe.arguments_old(1);
        var arguments = arguments_.ptr[0..arguments_.len];

        if (!arguments.ptr[0].isEmptyOrUndefinedOrNull() and !arguments.ptr[0].isObject()) {
            return globalThis.throwInvalidArguments("options must be an object or undefined", .{});
        }

        var store = this.store orelse {
            return globalThis.throwInvalidArguments("Blob is detached", .{});
        };
        if (this.isS3()) {
            const s3 = &this.store.?.data.s3;
            const path = s3.path();
            const proxy = globalThis.bunVM().transpiler.env.getHttpProxy(true, null);
            const proxy_url = if (proxy) |p| p.href else null;
            if (arguments.len > 0) {
                const options = arguments.ptr[0];
                if (options.isObject()) {
                    if (try options.getTruthy(globalThis, "type")) |content_type| {
                        //override the content type
                        if (!content_type.isString()) {
                            return globalThis.throwInvalidArgumentType("write", "options.type", "string");
                        }
                        var content_type_str = try content_type.toSlice(globalThis, bun.default_allocator);
                        defer content_type_str.deinit();
                        const slice = content_type_str.slice();
                        if (strings.isAllASCII(slice)) {
                            if (this.content_type_allocated) {
                                bun.default_allocator.free(this.content_type);
                            }
                            this.content_type_was_set = true;

                            if (globalThis.bunVM().mimeType(slice)) |mime| {
                                this.content_type = mime.value;
                            } else {
                                const content_type_buf = bun.default_allocator.alloc(u8, slice.len) catch bun.outOfMemory();
                                this.content_type = strings.copyLowercase(slice, content_type_buf);
                                this.content_type_allocated = true;
                            }
                        }
                    }
                    const credentialsWithOptions = try s3.getCredentialsWithOptions(options, globalThis);
                    return try S3.writableStream(
                        credentialsWithOptions.credentials.dupe(),
                        path,
                        globalThis,
                        credentialsWithOptions.options,
                        this.contentTypeOrMimeType(),
                        proxy_url,
                        credentialsWithOptions.storage_class,
                    );
                }
            }
            return try S3.writableStream(
                s3.getCredentials(),
                path,
                globalThis,
                .{},
                this.contentTypeOrMimeType(),
                proxy_url,
                null,
            );
        }
        if (store.data != .file) {
            return globalThis.throwInvalidArguments("Blob is read-only", .{});
        }

        if (Environment.isWindows) {
            const pathlike = store.data.file.pathlike;
            const vm = globalThis.bunVM();
            const fd: bun.FileDescriptor = if (pathlike == .fd) pathlike.fd else brk: {
                var file_path: bun.PathBuffer = undefined;
                switch (bun.sys.open(
                    pathlike.path.sliceZ(&file_path),
                    bun.O.WRONLY | bun.O.CREAT | bun.O.NONBLOCK,
                    write_permissions,
                )) {
                    .result => |result| {
                        break :brk result;
                    },
                    .err => |err| {
                        return globalThis.throwValue(err.withPath(pathlike.path.slice()).toJSC(globalThis));
                    },
                }
                @compileError(unreachable);
            };

            const is_stdout_or_stderr = brk: {
                if (pathlike != .fd) {
                    break :brk false;
                }

                if (vm.rare_data) |rare| {
                    if (store == rare.stdout_store) {
                        break :brk true;
                    }

                    if (store == rare.stderr_store) {
                        break :brk true;
                    }
                }

                break :brk if (fd.stdioTag()) |tag| switch (tag) {
                    .std_out, .std_err => true,
                    else => false,
                } else false;
            };
            var sink = JSC.WebCore.FileSink.init(fd, this.globalThis.bunVM().eventLoop());
            sink.writer.owns_fd = pathlike != .fd;

            if (is_stdout_or_stderr) {
                switch (sink.writer.startSync(fd, false)) {
                    .err => |err| {
                        sink.deref();
                        return globalThis.throwValue(err.toJSC(globalThis));
                    },
                    else => {},
                }
            } else {
                switch (sink.writer.start(fd, true)) {
                    .err => |err| {
                        sink.deref();
                        return globalThis.throwValue(err.toJSC(globalThis));
                    },
                    else => {},
                }
            }

            return sink.toJS(globalThis);
        }

        var sink = JSC.WebCore.FileSink.init(bun.invalid_fd, this.globalThis.bunVM().eventLoop());

        const input_path: JSC.WebCore.PathOrFileDescriptor = brk: {
            if (store.data.file.pathlike == .fd) {
                break :brk .{ .fd = store.data.file.pathlike.fd };
            } else {
                break :brk .{
                    .path = ZigString.Slice.fromUTF8NeverFree(
                        store.data.file.pathlike.path.slice(),
                    ).clone(
                        globalThis.allocator(),
                    ) catch bun.outOfMemory(),
                };
            }
        };
        defer input_path.deinit();

        var stream_start: JSC.WebCore.StreamStart = .{
            .FileSink = .{
                .input_path = input_path,
            },
        };

        if (arguments.len > 0 and arguments.ptr[0].isObject()) {
            stream_start = try JSC.WebCore.StreamStart.fromJSWithTag(globalThis, arguments[0], .FileSink);
            stream_start.FileSink.input_path = input_path;
        }

        switch (sink.start(stream_start)) {
            .err => |err| {
                sink.deref();
                return globalThis.throwValue(err.toJSC(globalThis));
            },
            else => {},
        }

        return sink.toJS(globalThis);
    }

    pub fn getSliceFrom(this: *Blob, globalThis: *JSC.JSGlobalObject, relativeStart: i64, relativeEnd: i64, content_type: []const u8, content_type_was_allocated: bool) JSValue {
        const offset = this.offset +| @as(SizeType, @intCast(relativeStart));
        const len = @as(SizeType, @intCast(@max(relativeEnd -| relativeStart, 0)));

        // This copies over the is_all_ascii flag
        // which is okay because this will only be a <= slice
        var blob = this.dupe();
        blob.offset = offset;
        blob.size = len;

        // infer the content type if it was not specified
        if (content_type.len == 0 and this.content_type.len > 0 and !this.content_type_allocated) {
            blob.content_type = this.content_type;
        } else {
            blob.content_type = content_type;
        }
        blob.content_type_allocated = content_type_was_allocated;
        blob.content_type_was_set = this.content_type_was_set or content_type_was_allocated;

        var blob_ = Blob.new(blob);
        blob_.allocator = bun.default_allocator;
        return blob_.toJS(globalThis);
    }

    /// https://w3c.github.io/FileAPI/#slice-method-algo
    /// The slice() method returns a new Blob object with bytes ranging from the
    /// optional start parameter up to but not including the optional end
    /// parameter, and with a type attribute that is the value of the optional
    /// contentType parameter. It must act as follows:
    pub fn getSlice(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
        callframe: *JSC.CallFrame,
    ) bun.JSError!JSC.JSValue {
        const allocator = bun.default_allocator;
        var arguments_ = callframe.arguments_old(3);
        var args = arguments_.ptr[0..arguments_.len];

        if (this.size == 0) {
            const empty = Blob.initEmpty(globalThis);
            var ptr = Blob.new(empty);
            ptr.allocator = allocator;
            return ptr.toJS(globalThis);
        }

        // If the optional start parameter is not used as a parameter when making this call, let relativeStart be 0.
        var relativeStart: i64 = 0;

        // If the optional end parameter is not used as a parameter when making this call, let relativeEnd be size.
        var relativeEnd: i64 = @as(i64, @intCast(this.size));

        if (args.ptr[0].isString()) {
            args.ptr[2] = args.ptr[0];
            args.ptr[1] = .zero;
            args.ptr[0] = .zero;
            args.len = 3;
        } else if (args.ptr[1].isString()) {
            args.ptr[2] = args.ptr[1];
            args.ptr[1] = .zero;
            args.len = 3;
        }

        var args_iter = JSC.Node.ArgumentsSlice.init(globalThis.bunVM(), args);
        if (args_iter.nextEat()) |start_| {
            if (start_.isNumber()) {
                const start = start_.toInt64();
                if (start < 0) {
                    // If the optional start parameter is negative, let relativeStart be start + size.
                    relativeStart = @as(i64, @intCast(@max(start +% @as(i64, @intCast(this.size)), 0)));
                } else {
                    // Otherwise, let relativeStart be start.
                    relativeStart = @min(@as(i64, @intCast(start)), @as(i64, @intCast(this.size)));
                }
            }
        }

        if (args_iter.nextEat()) |end_| {
            if (end_.isNumber()) {
                const end = end_.toInt64();
                // If end is negative, let relativeEnd be max((size + end), 0).
                if (end < 0) {
                    // If the optional start parameter is negative, let relativeStart be start + size.
                    relativeEnd = @as(i64, @intCast(@max(end +% @as(i64, @intCast(this.size)), 0)));
                } else {
                    // Otherwise, let relativeStart be start.
                    relativeEnd = @min(@as(i64, @intCast(end)), @as(i64, @intCast(this.size)));
                }
            }
        }

        var content_type: string = "";
        var content_type_was_allocated = false;
        if (args_iter.nextEat()) |content_type_| {
            inner: {
                if (content_type_.isString()) {
                    var zig_str = try content_type_.getZigString(globalThis);
                    var slicer = zig_str.toSlice(bun.default_allocator);
                    defer slicer.deinit();
                    const slice = slicer.slice();
                    if (!strings.isAllASCII(slice)) {
                        break :inner;
                    }

                    if (globalThis.bunVM().mimeType(slice)) |mime| {
                        content_type = mime.value;
                        break :inner;
                    }

                    content_type_was_allocated = slice.len > 0;
                    const content_type_buf = allocator.alloc(u8, slice.len) catch bun.outOfMemory();
                    content_type = strings.copyLowercase(slice, content_type_buf);
                }
            }
        }

        return this.getSliceFrom(globalThis, relativeStart, relativeEnd, content_type, content_type_was_allocated);
    }

    pub fn getMimeType(this: *const Blob) ?bun.http.MimeType {
        if (this.store) |store| {
            return store.mime_type;
        }

        return null;
    }

    pub fn getMimeTypeOrContentType(this: *const Blob) ?bun.http.MimeType {
        if (this.content_type_was_set) {
            return bun.http.MimeType.init(this.content_type, null, null);
        }

        if (this.store) |store| {
            return store.mime_type;
        }

        return null;
    }

    pub fn getType(
        this: *Blob,
        globalThis: *JSC.JSGlobalObject,
    ) JSValue {
        if (this.content_type.len > 0) {
            if (this.content_type_allocated) {
                return ZigString.init(this.content_type).toJS(globalThis);
            }
            return ZigString.init(this.content_type).toJS(globalThis);
        }

        if (this.store) |store| {
            return ZigString.init(store.mime_type.value).toJS(globalThis);
        }

        return ZigString.Empty.toJS(globalThis);
    }

    pub fn getNameString(this: *Blob) ?bun.String {
        if (this.name.tag != .Dead) return this.name;

        if (this.getFileName()) |path| {
            this.name = bun.String.createUTF8(path);
            return this.name;
        }

        return null;
    }

    // TODO: Move this to a separate `File` object or BunFile
    pub fn getName(
        this: *Blob,
        _: JSC.JSValue,
        globalThis: *JSC.JSGlobalObject,
    ) JSValue {
        return if (this.getNameString()) |name| name.toJS(globalThis) else .undefined;
    }

    pub fn setName(
        this: *Blob,
        jsThis: JSC.JSValue,
        globalThis: *JSC.JSGlobalObject,
        value: JSValue,

        // TODO: support JSError for getters/setters
    ) bool {
        // by default we don't have a name so lets allow it to be set undefined
        if (value.isEmptyOrUndefinedOrNull()) {
            this.name.deref();
            this.name = bun.String.dead;
            js.nameSetCached(jsThis, globalThis, value);
            return true;
        }
        if (value.isString()) {
            const old_name = this.name;

            this.name = bun.String.fromJS(value, globalThis) catch |err| {
                switch (err) {
                    error.JSError => {},
                    error.OutOfMemory => {
                        globalThis.throwOutOfMemory() catch {};
                    },
                }
                this.name = bun.String.empty;
                return false;
            };
            // We don't need to increment the reference count since tryFromJS already did it.
            js.nameSetCached(jsThis, globalThis, value);
            old_name.deref();
            return true;
        }
        return false;
    }

    pub fn getFileName(
        this: *const Blob,
    ) ?[]const u8 {
        if (this.store) |store| {
            if (store.data == .file) {
                if (store.data.file.pathlike == .path) {
                    return store.data.file.pathlike.path.slice();
                }

                // we shouldn't return Number here.
            } else if (store.data == .bytes) {
                if (store.data.bytes.stored_name.slice().len > 0)
                    return store.data.bytes.stored_name.slice();
            } else if (store.data == .s3) {
                return store.data.s3.path();
            }
        }

        return null;
    }

    pub fn getLoader(blob: *const Blob, jsc_vm: *VirtualMachine) ?bun.options.Loader {
        if (blob.getFileName()) |filename| {
            const current_path = bun.fs.Path.init(filename);
            return current_path.loader(&jsc_vm.transpiler.options.loaders) orelse .tsx;
        } else if (blob.getMimeTypeOrContentType()) |mime_type| {
            return .fromMimeType(mime_type);
        } else {
            // Be maximally permissive.
            return .tsx;
        }
    }

    // TODO: Move this to a separate `File` object or BunFile
    pub fn getLastModified(
        this: *Blob,
        _: *JSC.JSGlobalObject,
    ) JSValue {
        if (this.store) |store| {
            if (store.data == .file) {
                // last_modified can be already set during read.
                if (store.data.file.last_modified == JSC.init_timestamp and !this.isS3()) {
                    resolveFileStat(store);
                }
                return JSValue.jsNumber(store.data.file.last_modified);
            }
        }

        if (this.is_jsdom_file) {
            return JSValue.jsNumber(this.last_modified);
        }

        return JSValue.jsNumber(JSC.init_timestamp);
    }

    pub fn getSizeForBindings(this: *Blob) u64 {
        if (this.size == Blob.max_size) {
            this.resolveSize();
        }

        // If the file doesn't exist or is not seekable
        // signal that the size is unknown.
        if (this.store != null and this.store.?.data == .file and
            !(this.store.?.data.file.seekable orelse false))
        {
            return std.math.maxInt(u64);
        }

        if (this.size == Blob.max_size)
            return std.math.maxInt(u64);

        return this.size;
    }

    export fn Bun__Blob__getSizeForBindings(this: *Blob) callconv(.C) u64 {
        return this.getSizeForBindings();
    }

    comptime {
        _ = Bun__Blob__getSizeForBindings;
    }
    pub fn getStat(this: *Blob, globalThis: *JSC.JSGlobalObject, callback: *JSC.CallFrame) bun.JSError!JSC.JSValue {
        const store = this.store orelse return JSC.JSValue.jsUndefined();
        // TODO: make this async for files
        return switch (store.data) {
            .file => |*file| {
                return switch (file.pathlike) {
                    .path => |path_like| {
                        return JSC.Node.Async.stat.create(globalThis, undefined, .{
                            .path = .{
                                .encoded_slice = switch (path_like) {
                                    // it's already converted to utf8
                                    .encoded_slice => |slice| try slice.toOwned(bun.default_allocator),
                                    else => try ZigString.init(path_like.slice()).toSliceClone(bun.default_allocator),
                                },
                            },
                        }, globalThis.bunVM());
                    },
                    .fd => |fd| JSC.Node.Async.fstat.create(globalThis, undefined, .{ .fd = fd }, globalThis.bunVM()),
                };
            },
            .s3 => S3File.getStat(this, globalThis, callback),
            else => JSC.JSValue.jsUndefined(),
        };
    }
    pub fn getSize(this: *Blob, _: *JSC.JSGlobalObject) JSValue {
        if (this.size == Blob.max_size) {
            if (this.isS3()) {
                return JSC.JSValue.jsNumber(std.math.nan(f64));
            }
            this.resolveSize();
            if (this.size == Blob.max_size and this.store != null) {
                return JSC.jsNumber(std.math.inf(f64));
            } else if (this.size == 0 and this.store != null) {
                if (this.store.?.data == .file and
                    (this.store.?.data.file.seekable orelse true) == false and
                    this.store.?.data.file.max_size == Blob.max_size)
                {
                    return JSC.jsNumber(std.math.inf(f64));
                }
            }
        }

        return JSValue.jsNumber(this.size);
    }

    pub fn resolveSize(this: *Blob) void {
        if (this.store) |store| {
            if (store.data == .bytes) {
                const offset = this.offset;
                const store_size = store.size();
                if (store_size != Blob.max_size) {
                    this.offset = @min(store_size, offset);
                    this.size = store_size - offset;
                }

                return;
            } else if (store.data == .file) {
                if (store.data.file.seekable == null) {
                    resolveFileStat(store);
                }

                if (store.data.file.seekable != null and store.data.file.max_size != Blob.max_size) {
                    const store_size = store.data.file.max_size;
                    const offset = this.offset;

                    this.offset = @min(store_size, offset);
                    this.size = store_size -| offset;
                    return;
                }
            }

            this.size = 0;
        } else {
            this.size = 0;
        }
    }

    /// resolve file stat like size, last_modified
    fn resolveFileStat(store: *Store) void {
        if (store.data.file.pathlike == .path) {
            var buffer: bun.PathBuffer = undefined;
            switch (bun.sys.stat(store.data.file.pathlike.path.sliceZ(&buffer))) {
                .result => |stat| {
                    store.data.file.max_size = if (bun.isRegularFile(stat.mode) or stat.size > 0)
                        @truncate(@as(u64, @intCast(@max(stat.size, 0))))
                    else
                        Blob.max_size;
                    store.data.file.mode = @intCast(stat.mode);
                    store.data.file.seekable = bun.isRegularFile(stat.mode);
                    store.data.file.last_modified = JSC.toJSTime(stat.mtime().sec, stat.mtime().nsec);
                },
                // the file may not exist yet. Thats's okay.
                else => {},
            }
        } else if (store.data.file.pathlike == .fd) {
            switch (bun.sys.fstat(store.data.file.pathlike.fd)) {
                .result => |stat| {
                    store.data.file.max_size = if (bun.isRegularFile(stat.mode) or stat.size > 0)
                        @as(SizeType, @truncate(@as(u64, @intCast(@max(stat.size, 0)))))
                    else
                        Blob.max_size;
                    store.data.file.mode = @intCast(stat.mode);
                    store.data.file.seekable = bun.isRegularFile(stat.mode);
                    store.data.file.last_modified = JSC.toJSTime(stat.mtime().sec, stat.mtime().nsec);
                },
                // the file may not exist yet. Thats's okay.
                else => {},
            }
        }
    }

    pub fn constructor(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!*Blob {
        const allocator = bun.default_allocator;
        var blob: Blob = undefined;
        var arguments = callframe.arguments_old(2);
        const args = arguments.slice();

        switch (args.len) {
            0 => {
                const empty: []u8 = &[_]u8{};
                blob = Blob.init(empty, allocator, globalThis);
            },
            else => {
                blob = get(globalThis, args[0], false, true) catch |err| switch (err) {
                    error.OutOfMemory, error.JSError => |e| return e,
                    error.InvalidArguments => return globalThis.throwInvalidArguments("new Blob() expects an Array", .{}),
                };

                if (args.len > 1) {
                    const options = args[1];
                    if (options.isObject()) {
                        // type, the ASCII-encoded string in lower case
                        // representing the media type of the Blob.
                        // Normative conditions for this member are provided
                        // in the § 3.1 Constructors.
                        if (try options.get(globalThis, "type")) |content_type| {
                            inner: {
                                if (content_type.isString()) {
                                    var content_type_str = try content_type.toSlice(globalThis, bun.default_allocator);
                                    defer content_type_str.deinit();
                                    const slice = content_type_str.slice();
                                    if (!strings.isAllASCII(slice)) {
                                        break :inner;
                                    }
                                    blob.content_type_was_set = true;

                                    if (globalThis.bunVM().mimeType(slice)) |mime| {
                                        blob.content_type = mime.value;
                                        break :inner;
                                    }
                                    const content_type_buf = allocator.alloc(u8, slice.len) catch bun.outOfMemory();
                                    blob.content_type = strings.copyLowercase(slice, content_type_buf);
                                    blob.content_type_allocated = true;
                                }
                            }
                        }
                    }
                }

                if (blob.content_type.len == 0) {
                    blob.content_type = "";
                    blob.content_type_was_set = false;
                }
            },
        }

        blob.calculateEstimatedByteSize();

        var blob_ = Blob.new(blob);
        blob_.allocator = allocator;
        return blob_;
    }

    pub fn finalize(this: *Blob) void {
        this.deinit();
    }

    pub fn initWithAllASCII(bytes: []u8, allocator: std.mem.Allocator, globalThis: *JSGlobalObject, is_all_ascii: bool) Blob {
        // avoid allocating a Blob.Store if the buffer is actually empty
        var store: ?*Blob.Store = null;
        if (bytes.len > 0) {
            store = Blob.Store.init(bytes, allocator);
            store.?.is_all_ascii = is_all_ascii;
        }
        return Blob{
            .size = @as(SizeType, @truncate(bytes.len)),
            .store = store,
            .allocator = null,
            .content_type = "",
            .globalThis = globalThis,
            .is_all_ascii = is_all_ascii,
        };
    }

    /// Takes ownership of `bytes`, which must have been allocated with `allocator`.
    pub fn init(bytes: []u8, allocator: std.mem.Allocator, globalThis: *JSGlobalObject) Blob {
        return Blob{
            .size = @as(SizeType, @truncate(bytes.len)),
            .store = if (bytes.len > 0)
                Blob.Store.init(bytes, allocator)
            else
                null,
            .allocator = null,
            .content_type = "",
            .globalThis = globalThis,
        };
    }

    pub fn createWithBytesAndAllocator(
        bytes: []u8,
        allocator: std.mem.Allocator,
        globalThis: *JSGlobalObject,
        was_string: bool,
    ) Blob {
        return Blob{
            .size = @as(SizeType, @truncate(bytes.len)),
            .store = if (bytes.len > 0)
                Blob.Store.init(bytes, allocator)
            else
                null,
            .allocator = null,
            .content_type = if (was_string) MimeType.text.value else "",
            .globalThis = globalThis,
        };
    }

    pub fn tryCreate(
        bytes_: []const u8,
        allocator_: std.mem.Allocator,
        globalThis: *JSGlobalObject,
        was_string: bool,
    ) !Blob {
        if (comptime Environment.isLinux) {
            if (bun.linux.memfd_allocator.shouldUse(bytes_)) {
                switch (bun.linux.memfd_allocator.create(bytes_)) {
                    .err => {},
                    .result => |result| {
                        const store = Store.new(
                            .{
                                .data = .{
                                    .bytes = result,
                                },
                                .allocator = bun.default_allocator,
                                .ref_count = std.atomic.Value(u32).init(1),
                            },
                        );
                        var blob = initWithStore(store, globalThis);
                        if (was_string and blob.content_type.len == 0) {
                            blob.content_type = MimeType.text.value;
                        }

                        return blob;
                    },
                }
            }
        }

        return createWithBytesAndAllocator(try allocator_.dupe(u8, bytes_), allocator_, globalThis, was_string);
    }

    pub fn create(
        bytes_: []const u8,
        allocator_: std.mem.Allocator,
        globalThis: *JSGlobalObject,
        was_string: bool,
    ) Blob {
        return tryCreate(bytes_, allocator_, globalThis, was_string) catch bun.outOfMemory();
    }

    pub fn initWithStore(store: *Blob.Store, globalThis: *JSGlobalObject) Blob {
        return Blob{
            .size = store.size(),
            .store = store,
            .allocator = null,
            .content_type = if (store.data == .file)
                store.data.file.mime_type.value
            else
                "",
            .globalThis = globalThis,
        };
    }

    pub fn initEmpty(globalThis: *JSGlobalObject) Blob {
        return Blob{
            .size = 0,
            .store = null,
            .allocator = null,
            .content_type = "",
            .globalThis = globalThis,
        };
    }

    // Transferring doesn't change the reference count
    // It is a move
    inline fn transfer(this: *Blob) void {
        this.store = null;
    }

    pub fn detach(this: *Blob) void {
        if (this.store != null) this.store.?.deref();
        this.store = null;
    }

    /// This does not duplicate
    /// This creates a new view
    /// and increment the reference count
    pub fn dupe(this: *const Blob) Blob {
        return this.dupeWithContentType(false);
    }

    pub fn dupeWithContentType(this: *const Blob, include_content_type: bool) Blob {
        if (this.store != null) this.store.?.ref();
        var duped = this.*;
        if (duped.content_type_allocated and duped.allocator != null and !include_content_type) {

            // for now, we just want to avoid a use-after-free here
            if (JSC.VirtualMachine.get().mimeType(duped.content_type)) |mime| {
                duped.content_type = mime.value;
            } else {
                // TODO: fix this
                // this is a bug.
                // it means whenever
                duped.content_type = "";
            }

            duped.content_type_allocated = false;
            duped.content_type_was_set = false;
            if (this.content_type_was_set) {
                duped.content_type_was_set = duped.content_type.len > 0;
            }
        } else if (duped.content_type_allocated and duped.allocator != null and include_content_type) {
            duped.content_type = bun.default_allocator.dupe(u8, this.content_type) catch bun.outOfMemory();
        }
        duped.name = duped.name.dupeRef();

        duped.allocator = null;
        return duped;
    }

    pub fn toJS(this: *Blob, globalObject: *JSC.JSGlobalObject) JSC.JSValue {
        // if (comptime Environment.allow_assert) {
        //     assert(this.allocator != null);
        // }
        this.calculateEstimatedByteSize();

        if (this.isS3()) {
            return S3File.toJSUnchecked(globalObject, this);
        }

        return js.toJSUnchecked(globalObject, this);
    }

    pub fn deinit(this: *Blob) void {
        this.detach();
        this.name.deref();
        this.name = .dead;

        // TODO: remove this field, make it a boolean.
        if (this.allocator) |alloc| {
            this.allocator = null;
            bun.debugAssert(alloc.vtable == bun.default_allocator.vtable);
            bun.destroy(this);
        }
    }

    pub fn sharedView(this: *const Blob) []const u8 {
        if (this.size == 0 or this.store == null) return "";
        var slice_ = this.store.?.sharedView();
        if (slice_.len == 0) return "";
        slice_ = slice_[this.offset..];

        return slice_[0..@min(slice_.len, @as(usize, this.size))];
    }

    pub const Lifetime = JSC.WebCore.Lifetime;
    pub fn setIsASCIIFlag(this: *Blob, is_all_ascii: bool) void {
        this.is_all_ascii = is_all_ascii;
        // if this Blob represents the entire binary data
        // which will be pretty common
        // we can update the store's is_all_ascii flag
        // and any other Blob that points to the same store
        // can skip checking the encoding
        if (this.size > 0 and this.offset == 0 and this.store.?.data == .bytes) {
            this.store.?.is_all_ascii = is_all_ascii;
        }
    }

    pub fn needsToReadFile(this: *const Blob) bool {
        return this.store != null and (this.store.?.data == .file);
    }

    pub fn toStringWithBytes(this: *Blob, global: *JSGlobalObject, raw_bytes: []const u8, comptime lifetime: Lifetime) bun.JSError!JSValue {
        const bom, const buf = strings.BOM.detectAndSplit(raw_bytes);

        if (buf.len == 0) {
            // If all it contained was the bom, we need to free the bytes
            if (lifetime == .temporary) bun.default_allocator.free(raw_bytes);
            return ZigString.Empty.toJS(global);
        }

        if (bom == .utf16_le) {
            defer if (lifetime == .temporary) bun.default_allocator.free(raw_bytes);
            var out = bun.String.createUTF16(bun.reinterpretSlice(u16, buf));
            defer out.deref();
            return out.toJS(global);
        }

        // null == unknown
        // false == can't be
        const could_be_all_ascii = this.is_all_ascii orelse this.store.?.is_all_ascii;

        if (could_be_all_ascii == null or !could_be_all_ascii.?) {
            // if toUTF16Alloc returns null, it means there are no non-ASCII characters
            // instead of erroring, invalid characters will become a U+FFFD replacement character
            if (strings.toUTF16Alloc(bun.default_allocator, buf, false, false) catch return global.throwOutOfMemory()) |external| {
                if (lifetime != .temporary)
                    this.setIsASCIIFlag(false);

                if (lifetime == .transfer) {
                    this.detach();
                }

                if (lifetime == .temporary) {
                    bun.default_allocator.free(raw_bytes);
                }

                return ZigString.toExternalU16(external.ptr, external.len, global);
            }

            if (lifetime != .temporary) this.setIsASCIIFlag(true);
        }

        switch (comptime lifetime) {
            // strings are immutable
            // we don't need to clone
            .clone => {
                this.store.?.ref();
                // we don't need to worry about UTF-8 BOM in this case because the store owns the memory.
                return ZigString.init(buf).external(global, this.store.?, Store.external);
            },
            .transfer => {
                const store = this.store.?;
                assert(store.data == .bytes);
                this.transfer();
                // we don't need to worry about UTF-8 BOM in this case because the store owns the memory.
                return ZigString.init(buf).external(global, store, Store.external);
            },
            // strings are immutable
            // sharing isn't really a thing
            .share => {
                this.store.?.ref();
                // we don't need to worry about UTF-8 BOM in this case because the store owns the memory.s
                return ZigString.init(buf).external(global, this.store.?, Store.external);
            },
            .temporary => {
                // if there was a UTF-8 BOM, we need to clone the buffer because
                // external doesn't support this case here yet.
                if (buf.len != raw_bytes.len) {
                    var out = bun.String.createLatin1(buf);
                    defer {
                        bun.default_allocator.free(raw_bytes);
                        out.deref();
                    }

                    return out.toJS(global);
                }

                return ZigString.init(buf).toExternalValue(global);
            },
        }
    }

    pub fn toStringTransfer(this: *Blob, global: *JSGlobalObject) bun.JSError!JSValue {
        return this.toString(global, .transfer);
    }

    pub fn toString(this: *Blob, global: *JSGlobalObject, comptime lifetime: Lifetime) bun.JSError!JSValue {
        if (this.needsToReadFile()) {
            return this.doReadFile(toStringWithBytes, global);
        }
        if (this.isS3()) {
            return this.doReadFromS3(toStringWithBytes, global);
        }

        const view_: []u8 =
            @constCast(this.sharedView());

        if (view_.len == 0)
            return ZigString.Empty.toJS(global);

        return toStringWithBytes(this, global, view_, lifetime);
    }

    pub fn toJSON(this: *Blob, global: *JSGlobalObject, comptime lifetime: Lifetime) bun.JSError!JSValue {
        if (this.needsToReadFile()) {
            return this.doReadFile(toJSONWithBytes, global);
        }
        if (this.isS3()) {
            return this.doReadFromS3(toJSONWithBytes, global);
        }

        const view_ = this.sharedView();

        return toJSONWithBytes(this, global, view_, lifetime);
    }

    pub fn toJSONWithBytes(this: *Blob, global: *JSGlobalObject, raw_bytes: []const u8, comptime lifetime: Lifetime) bun.JSError!JSValue {
        const bom, const buf = strings.BOM.detectAndSplit(raw_bytes);
        if (buf.len == 0) return global.createSyntaxErrorInstance("Unexpected end of JSON input", .{});

        if (bom == .utf16_le) {
            var out = bun.String.createUTF16(bun.reinterpretSlice(u16, buf));
            defer if (lifetime == .temporary) bun.default_allocator.free(raw_bytes);
            defer if (lifetime == .transfer) this.detach();
            defer out.deref();
            return out.toJSByParseJSON(global);
        }
        // null == unknown
        // false == can't be
        const could_be_all_ascii = this.is_all_ascii orelse this.store.?.is_all_ascii;
        defer if (comptime lifetime == .temporary) bun.default_allocator.free(@constCast(buf));

        if (could_be_all_ascii == null or !could_be_all_ascii.?) {
            var stack_fallback = std.heap.stackFallback(4096, bun.default_allocator);
            const allocator = stack_fallback.get();
            // if toUTF16Alloc returns null, it means there are no non-ASCII characters
            if (strings.toUTF16Alloc(allocator, buf, false, false) catch null) |external| {
                if (comptime lifetime != .temporary) this.setIsASCIIFlag(false);
                const result = ZigString.initUTF16(external).toJSONObject(global);
                allocator.free(external);
                return result;
            }

            if (comptime lifetime != .temporary) this.setIsASCIIFlag(true);
        }

        return ZigString.init(buf).toJSONObject(global);
    }

    pub fn toFormDataWithBytes(this: *Blob, global: *JSGlobalObject, buf: []u8, comptime _: Lifetime) JSValue {
        var encoder = this.getFormDataEncoding() orelse return {
            return ZigString.init("Invalid encoding").toErrorInstance(global);
        };
        defer encoder.deinit();

        return bun.FormData.toJS(global, buf, encoder.encoding) catch |err|
            global.createErrorInstance("FormData encoding failed: {s}", .{@errorName(err)});
    }

    pub fn toArrayBufferWithBytes(this: *Blob, global: *JSGlobalObject, buf: []u8, comptime lifetime: Lifetime) bun.JSError!JSValue {
        return toArrayBufferViewWithBytes(this, global, buf, lifetime, .ArrayBuffer);
    }

    pub fn toUint8ArrayWithBytes(this: *Blob, global: *JSGlobalObject, buf: []u8, comptime lifetime: Lifetime) bun.JSError!JSValue {
        return toArrayBufferViewWithBytes(this, global, buf, lifetime, .Uint8Array);
    }

    pub fn toArrayBufferViewWithBytes(this: *Blob, global: *JSGlobalObject, buf: []u8, comptime lifetime: Lifetime, comptime TypedArrayView: JSC.JSValue.JSType) bun.JSError!JSValue {
        switch (comptime lifetime) {
            .clone => {
                if (TypedArrayView != .ArrayBuffer) {
                    // ArrayBuffer doesn't have this limit.
                    if (buf.len > JSC.synthetic_allocation_limit) {
                        this.detach();
                        return global.throwOutOfMemory();
                    }
                }

                if (comptime Environment.isLinux) {
                    // If we can use a copy-on-write clone of the buffer, do so.
                    if (this.store) |store| {
                        if (store.data == .bytes) {
                            const allocated_slice = store.data.bytes.allocatedSlice();
                            if (bun.isSliceInBuffer(buf, allocated_slice)) {
                                if (bun.linux.memfd_allocator.from(store.data.bytes.allocator)) |allocator| {
                                    allocator.ref();
                                    defer allocator.deref();

                                    const byteOffset = @as(usize, @intFromPtr(buf.ptr)) -| @as(usize, @intFromPtr(allocated_slice.ptr));
                                    const byteLength = buf.len;

                                    const result = JSC.ArrayBuffer.toArrayBufferFromSharedMemfd(
                                        allocator.fd.cast(),
                                        global,
                                        byteOffset,
                                        byteLength,
                                        allocated_slice.len,
                                        TypedArrayView,
                                    );
                                    bloblog("toArrayBuffer COW clone({d}, {d}) = {d}", .{ byteOffset, byteLength, @intFromBool(result != .zero) });

                                    if (result != .zero) {
                                        return result;
                                    }
                                }
                            }
                        }
                    }
                }
                return JSC.ArrayBuffer.create(global, buf, TypedArrayView);
            },
            .share => {
                if (buf.len > JSC.synthetic_allocation_limit and TypedArrayView != .ArrayBuffer) {
                    return global.throwOutOfMemory();
                }

                this.store.?.ref();
                return JSC.ArrayBuffer.fromBytes(buf, TypedArrayView).toJSWithContext(
                    global,
                    this.store.?,
                    JSC.BlobArrayBuffer_deallocator,
                    null,
                );
            },
            .transfer => {
                if (buf.len > JSC.synthetic_allocation_limit and TypedArrayView != .ArrayBuffer) {
                    this.detach();
                    return global.throwOutOfMemory();
                }

                const store = this.store.?;
                this.transfer();
                return JSC.ArrayBuffer.fromBytes(buf, TypedArrayView).toJSWithContext(
                    global,
                    store,
                    JSC.BlobArrayBuffer_deallocator,
                    null,
                );
            },
            .temporary => {
                if (buf.len > JSC.synthetic_allocation_limit and TypedArrayView != .ArrayBuffer) {
                    bun.default_allocator.free(buf);
                    return global.throwOutOfMemory();
                }

                return JSC.ArrayBuffer.fromBytes(buf, TypedArrayView).toJS(
                    global,
                    null,
                );
            },
        }
    }

    pub fn toArrayBuffer(this: *Blob, global: *JSGlobalObject, comptime lifetime: Lifetime) bun.JSError!JSValue {
        bloblog("toArrayBuffer", .{});
        return toArrayBufferView(this, global, lifetime, .ArrayBuffer);
    }

    pub fn toUint8Array(this: *Blob, global: *JSGlobalObject, comptime lifetime: Lifetime) bun.JSError!JSValue {
        bloblog("toUin8Array", .{});
        return toArrayBufferView(this, global, lifetime, .Uint8Array);
    }

    pub fn toArrayBufferView(this: *Blob, global: *JSGlobalObject, comptime lifetime: Lifetime, comptime TypedArrayView: JSC.JSValue.JSType) bun.JSError!JSValue {
        const WithBytesFn = comptime if (TypedArrayView == .Uint8Array)
            toUint8ArrayWithBytes
        else
            toArrayBufferWithBytes;
        if (this.needsToReadFile()) {
            return this.doReadFile(WithBytesFn, global);
        }

        if (this.isS3()) {
            return this.doReadFromS3(WithBytesFn, global);
        }

        const view_ = this.sharedView();
        if (view_.len == 0)
            return JSC.ArrayBuffer.create(global, "", TypedArrayView);

        return WithBytesFn(this, global, @constCast(view_), lifetime);
    }

    pub fn toFormData(this: *Blob, global: *JSGlobalObject, comptime lifetime: Lifetime) JSValue {
        if (this.needsToReadFile()) {
            return this.doReadFile(toFormDataWithBytes, global);
        }
        if (this.isS3()) {
            return this.doReadFromS3(toFormDataWithBytes, global);
        }

        const view_ = this.sharedView();

        if (view_.len == 0)
            return JSC.DOMFormData.create(global);

        return toFormDataWithBytes(this, global, @constCast(view_), lifetime);
    }

    const FromJsError = bun.JSError || error{InvalidArguments};

    pub inline fn get(
        global: *JSGlobalObject,
        arg: JSValue,
        comptime move: bool,
        comptime require_array: bool,
    ) FromJsError!Blob {
        return fromJSMovable(global, arg, move, require_array);
    }

    pub inline fn fromJSMove(global: *JSGlobalObject, arg: JSValue) FromJsError!Blob {
        return fromJSWithoutDeferGC(global, arg, true, false);
    }

    pub inline fn fromJSClone(global: *JSGlobalObject, arg: JSValue) FromJsError!Blob {
        return fromJSWithoutDeferGC(global, arg, false, true);
    }

    pub inline fn fromJSCloneOptionalArray(global: *JSGlobalObject, arg: JSValue) FromJsError!Blob {
        return fromJSWithoutDeferGC(global, arg, false, false);
    }

    fn fromJSMovable(
        global: *JSGlobalObject,
        arg: JSValue,
        comptime move: bool,
        comptime require_array: bool,
    ) FromJsError!Blob {
        const FromJSFunction = if (comptime move and !require_array)
            fromJSMove
        else if (!require_array)
            fromJSCloneOptionalArray
        else
            fromJSClone;

        return FromJSFunction(global, arg);
    }

    fn fromJSWithoutDeferGC(
        global: *JSGlobalObject,
        arg: JSValue,
        comptime move: bool,
        comptime require_array: bool,
    ) FromJsError!Blob {
        var current = arg;
        if (current.isUndefinedOrNull()) {
            return Blob{ .globalThis = global };
        }

        var top_value = current;
        var might_only_be_one_thing = false;
        arg.ensureStillAlive();
        defer arg.ensureStillAlive();
        var fail_if_top_value_is_not_typed_array_like = false;
        switch (current.jsTypeLoose()) {
            .Array, .DerivedArray => {
                var top_iter = JSC.JSArrayIterator.init(current, global);
                might_only_be_one_thing = top_iter.len == 1;
                if (top_iter.len == 0) {
                    return Blob{ .globalThis = global };
                }
                if (might_only_be_one_thing) {
                    top_value = top_iter.next().?;
                }
            },
            else => {
                might_only_be_one_thing = true;
                if (require_array) {
                    fail_if_top_value_is_not_typed_array_like = true;
                }
            },
        }

        if (might_only_be_one_thing or !move) {

            // Fast path: one item, we don't need to join
            switch (top_value.jsTypeLoose()) {
                .Cell,
                .NumberObject,
                JSC.JSValue.JSType.String,
                JSC.JSValue.JSType.StringObject,
                JSC.JSValue.JSType.DerivedStringObject,
                => {
                    if (!fail_if_top_value_is_not_typed_array_like) {
                        var str = try top_value.toBunString(global);
                        defer str.deref();
                        const bytes, const ascii = try str.toOwnedSliceReturningAllASCII(bun.default_allocator);
                        return Blob.initWithAllASCII(bytes, bun.default_allocator, global, ascii);
                    }
                },

                JSC.JSValue.JSType.ArrayBuffer,
                JSC.JSValue.JSType.Int8Array,
                JSC.JSValue.JSType.Uint8Array,
                JSC.JSValue.JSType.Uint8ClampedArray,
                JSC.JSValue.JSType.Int16Array,
                JSC.JSValue.JSType.Uint16Array,
                JSC.JSValue.JSType.Int32Array,
                JSC.JSValue.JSType.Uint32Array,
                JSC.JSValue.JSType.Float16Array,
                JSC.JSValue.JSType.Float32Array,
                JSC.JSValue.JSType.Float64Array,
                JSC.JSValue.JSType.BigInt64Array,
                JSC.JSValue.JSType.BigUint64Array,
                JSC.JSValue.JSType.DataView,
                => {
                    return try Blob.tryCreate(top_value.asArrayBuffer(global).?.byteSlice(), bun.default_allocator, global, false);
                },

                .DOMWrapper => {
                    if (!fail_if_top_value_is_not_typed_array_like) {
                        if (top_value.as(Blob)) |blob| {
                            if (comptime move) {
                                var _blob = blob.*;
                                _blob.allocator = null;
                                blob.transfer();
                                return _blob;
                            } else {
                                return blob.dupe();
                            }
                        } else if (top_value.as(JSC.API.BuildArtifact)) |build| {
                            if (comptime move) {
                                // I don't think this case should happen?
                                var blob = build.blob;
                                blob.transfer();
                                return blob;
                            } else {
                                return build.blob.dupe();
                            }
                        } else if (current.toSliceClone(global)) |sliced| {
                            if (sliced.allocator.get()) |allocator| {
                                return Blob.initWithAllASCII(@constCast(sliced.slice()), allocator, global, false);
                            }
                        }
                    }
                },

                else => {},
            }

            // new Blob("ok")
            // new File("ok", "file.txt")
            if (fail_if_top_value_is_not_typed_array_like) {
                return error.InvalidArguments;
            }
        }

        var stack_allocator = std.heap.stackFallback(1024, bun.default_allocator);
        const stack_mem_all = stack_allocator.get();
        var stack: std.ArrayList(JSValue) = std.ArrayList(JSValue).init(stack_mem_all);
        var joiner = StringJoiner{ .allocator = stack_mem_all };
        var could_have_non_ascii = false;

        defer if (stack_allocator.fixed_buffer_allocator.end_index >= 1024) stack.deinit();

        while (true) {
            switch (current.jsTypeLoose()) {
                .NumberObject,
                JSC.JSValue.JSType.String,
                JSC.JSValue.JSType.StringObject,
                JSC.JSValue.JSType.DerivedStringObject,
                => {
                    var sliced = try current.toSlice(global, bun.default_allocator);
                    const allocator = sliced.allocator.get();
                    could_have_non_ascii = could_have_non_ascii or !sliced.allocator.isWTFAllocator();
                    joiner.push(sliced.slice(), allocator);
                },

                .Array, .DerivedArray => {
                    var iter = JSC.JSArrayIterator.init(current, global);
                    try stack.ensureUnusedCapacity(iter.len);
                    var any_arrays = false;
                    while (iter.next()) |item| {
                        if (item.isUndefinedOrNull()) continue;

                        // When it's a string or ArrayBuffer inside an array, we can avoid the extra push/pop
                        // we only really want this for nested arrays
                        // However, we must preserve the order
                        // That means if there are any arrays
                        // we have to restart the loop
                        if (!any_arrays) {
                            switch (item.jsTypeLoose()) {
                                .NumberObject,
                                .Cell,
                                .String,
                                .StringObject,
                                .DerivedStringObject,
                                => {
                                    var sliced = try item.toSlice(global, bun.default_allocator);
                                    const allocator = sliced.allocator.get();
                                    could_have_non_ascii = could_have_non_ascii or !sliced.allocator.isWTFAllocator();
                                    joiner.push(sliced.slice(), allocator);
                                    continue;
                                },
                                .ArrayBuffer,
                                .Int8Array,
                                .Uint8Array,
                                .Uint8ClampedArray,
                                .Int16Array,
                                .Uint16Array,
                                .Int32Array,
                                .Uint32Array,
                                .Float16Array,
                                .Float32Array,
                                .Float64Array,
                                .BigInt64Array,
                                .BigUint64Array,
                                .DataView,
                                => {
                                    could_have_non_ascii = true;
                                    var buf = item.asArrayBuffer(global).?;
                                    joiner.pushStatic(buf.byteSlice());
                                    continue;
                                },
                                .Array, .DerivedArray => {
                                    any_arrays = true;
                                    could_have_non_ascii = true;
                                    break;
                                },

                                .DOMWrapper => {
                                    if (item.as(Blob)) |blob| {
                                        could_have_non_ascii = could_have_non_ascii or !(blob.is_all_ascii orelse false);
                                        joiner.pushStatic(blob.sharedView());
                                        continue;
                                    } else if (current.toSliceClone(global)) |sliced| {
                                        const allocator = sliced.allocator.get();
                                        could_have_non_ascii = could_have_non_ascii or allocator != null;
                                        joiner.push(sliced.slice(), allocator);
                                    }
                                },
                                else => {},
                            }
                        }

                        stack.appendAssumeCapacity(item);
                    }
                },

                .DOMWrapper => {
                    if (current.as(Blob)) |blob| {
                        could_have_non_ascii = could_have_non_ascii or !(blob.is_all_ascii orelse false);
                        joiner.pushStatic(blob.sharedView());
                    } else if (current.toSliceClone(global)) |sliced| {
                        const allocator = sliced.allocator.get();
                        could_have_non_ascii = could_have_non_ascii or allocator != null;
                        joiner.push(sliced.slice(), allocator);
                    }
                },

                .ArrayBuffer,
                .Int8Array,
                .Uint8Array,
                .Uint8ClampedArray,
                .Int16Array,
                .Uint16Array,
                .Int32Array,
                .Uint32Array,
                .Float16Array,
                .Float32Array,
                .Float64Array,
                .BigInt64Array,
                .BigUint64Array,
                .DataView,
                => {
                    var buf = current.asArrayBuffer(global).?;
                    joiner.pushStatic(buf.slice());
                    could_have_non_ascii = true;
                },

                else => {
                    var sliced = try current.toSlice(global, bun.default_allocator);
                    if (global.hasException()) {
                        const end_result = try joiner.done(bun.default_allocator);
                        bun.default_allocator.free(end_result);
                        return error.JSError;
                    }
                    could_have_non_ascii = could_have_non_ascii or !sliced.allocator.isWTFAllocator();
                    joiner.push(sliced.slice(), sliced.allocator.get());
                },
            }
            current = stack.pop() orelse break;
        }

        const joined = try joiner.done(bun.default_allocator);

        if (!could_have_non_ascii) {
            return Blob.initWithAllASCII(joined, bun.default_allocator, global, true);
        }
        return Blob.init(joined, bun.default_allocator, global);
    }
};

pub const AnyBlob = union(enum) {
    Blob: Blob,
    InternalBlob: InternalBlob,
    WTFStringImpl: bun.WTF.StringImpl,

    pub fn fromOwnedSlice(allocator: std.mem.Allocator, bytes: []u8) AnyBlob {
        return .{ .InternalBlob = .{ .bytes = .fromOwnedSlice(allocator, bytes) } };
    }

    pub fn fromArrayList(list: std.ArrayList(u8)) AnyBlob {
        return .{ .InternalBlob = .{ .bytes = list } };
    }

    /// Assumed that AnyBlob itself is covered by the caller.
    pub fn memoryCost(this: *const AnyBlob) usize {
        return switch (this.*) {
            .Blob => |*blob| if (blob.store) |blob_store| blob_store.memoryCost() else 0,
            .WTFStringImpl => |str| if (str.refCount() == 1) str.memoryCost() else 0,
            .InternalBlob => |*internal_blob| internal_blob.memoryCost(),
        };
    }

    pub fn hasOneRef(this: *const AnyBlob) bool {
        if (this.store()) |s| {
            return s.hasOneRef();
        }

        return false;
    }

    pub fn getFileName(this: *const AnyBlob) ?[]const u8 {
        return switch (this.*) {
            .Blob => this.Blob.getFileName(),
            .WTFStringImpl => null,
            .InternalBlob => null,
        };
    }

    pub inline fn fastSize(this: *const AnyBlob) Blob.SizeType {
        return switch (this.*) {
            .Blob => this.Blob.size,
            .WTFStringImpl => @truncate(this.WTFStringImpl.byteLength()),
            .InternalBlob => @truncate(this.slice().len),
        };
    }

    pub inline fn size(this: *const AnyBlob) Blob.SizeType {
        return switch (this.*) {
            .Blob => this.Blob.size,
            .WTFStringImpl => @truncate(this.WTFStringImpl.utf8ByteLength()),
            else => @truncate(this.slice().len),
        };
    }

    pub fn hasContentTypeFromUser(this: AnyBlob) bool {
        return switch (this) {
            .Blob => this.Blob.hasContentTypeFromUser(),
            .WTFStringImpl => false,
            .InternalBlob => false,
        };
    }

    fn toInternalBlobIfPossible(this: *AnyBlob) void {
        if (this.* == .Blob) {
            if (this.Blob.store) |s| {
                if (s.data == .bytes and s.hasOneRef()) {
                    this.* = .{ .InternalBlob = s.data.bytes.toInternalBlob() };
                    s.deref();
                    return;
                }
            }
        }
    }

    pub fn toActionValue(this: *AnyBlob, globalThis: *JSGlobalObject, action: JSC.WebCore.BufferedReadableStreamAction) bun.JSError!JSC.JSValue {
        if (action != .blob) {
            this.toInternalBlobIfPossible();
        }

        switch (action) {
            .text => {
                if (this.* == .Blob) {
                    return this.toString(globalThis, .clone);
                }

                return this.toStringTransfer(globalThis);
            },
            .bytes => {
                if (this.* == .Blob) {
                    return this.toArrayBufferView(globalThis, .clone, .Uint8Array);
                }

                return this.toUint8ArrayTransfer(globalThis);
            },
            .blob => {
                const result = Blob.new(this.toBlob(globalThis));
                result.allocator = bun.default_allocator;
                result.globalThis = globalThis;
                return result.toJS(globalThis);
            },
            .arrayBuffer => {
                if (this.* == .Blob) {
                    return this.toArrayBufferView(globalThis, .clone, .ArrayBuffer);
                }

                return this.toArrayBufferTransfer(globalThis);
            },
            .json => {
                return this.toJSON(globalThis, .share);
            },
        }
    }

    pub fn toPromise(this: *AnyBlob, globalThis: *JSGlobalObject, action: JSC.WebCore.BufferedReadableStreamAction) JSC.JSValue {
        return JSC.JSPromise.wrap(globalThis, toActionValue, .{ this, globalThis, action });
    }

    pub fn wrap(this: *AnyBlob, promise: JSC.AnyPromise, globalThis: *JSGlobalObject, action: JSC.WebCore.BufferedReadableStreamAction) void {
        promise.wrap(globalThis, toActionValue, .{ this, globalThis, action });
    }

    pub fn toJSON(this: *AnyBlob, global: *JSGlobalObject, comptime lifetime: JSC.WebCore.Lifetime) bun.JSError!JSValue {
        switch (this.*) {
            .Blob => return this.Blob.toJSON(global, lifetime),
            // .InlineBlob => {
            //     if (this.InlineBlob.len == 0) {
            //         return JSValue.jsNull();
            //     }
            //     var str = this.InlineBlob.toStringOwned(global);
            //     return str.parseJSON(global);
            // },
            .InternalBlob => {
                if (this.InternalBlob.bytes.items.len == 0) {
                    return JSValue.jsNull();
                }

                const str = this.InternalBlob.toJSON(global);

                // the GC will collect the string
                this.* = .{
                    .Blob = .{},
                };

                return str;
            },
            .WTFStringImpl => {
                var str = bun.String.init(this.WTFStringImpl);
                defer str.deref();
                this.* = .{
                    .Blob = .{},
                };

                if (str.length() == 0) {
                    return JSValue.jsNull();
                }

                return str.toJSByParseJSON(global);
            },
        }
    }

    pub fn toJSONShare(this: *AnyBlob, global: *JSGlobalObject) bun.JSError!JSValue {
        return this.toJSON(global, .share);
    }

    pub fn toStringTransfer(this: *AnyBlob, global: *JSGlobalObject) bun.JSError!JSValue {
        return this.toString(global, .transfer);
    }

    pub fn toUint8ArrayTransfer(this: *AnyBlob, global: *JSGlobalObject) bun.JSError!JSValue {
        return this.toUint8Array(global, .transfer);
    }

    pub fn toArrayBufferTransfer(this: *AnyBlob, global: *JSGlobalObject) bun.JSError!JSValue {
        return this.toArrayBuffer(global, .transfer);
    }

    pub fn toBlob(this: *AnyBlob, global: *JSGlobalObject) Blob {
        if (this.size() == 0) {
            return Blob.initEmpty(global);
        }

        if (this.* == .Blob) {
            return this.Blob.dupe();
        }

        if (this.* == .WTFStringImpl) {
            const blob = Blob.create(this.slice(), bun.default_allocator, global, true);
            this.* = .{ .Blob = .{} };
            return blob;
        }

        const blob = Blob.init(this.InternalBlob.slice(), this.InternalBlob.bytes.allocator, global);
        this.* = .{ .Blob = .{} };
        return blob;
    }

    pub fn toString(this: *AnyBlob, global: *JSGlobalObject, comptime lifetime: JSC.WebCore.Lifetime) bun.JSError!JSValue {
        switch (this.*) {
            .Blob => return this.Blob.toString(global, lifetime),
            // .InlineBlob => {
            //     if (this.InlineBlob.len == 0) {
            //         return ZigString.Empty.toValue(global);
            //     }
            //     const owned = this.InlineBlob.toStringOwned(global);
            //     this.* = .{ .InlineBlob = .{ .len = 0 } };
            //     return owned;
            // },
            .InternalBlob => {
                if (this.InternalBlob.bytes.items.len == 0) {
                    return ZigString.Empty.toJS(global);
                }

                const owned = this.InternalBlob.toStringOwned(global);
                this.* = .{ .Blob = .{} };
                return owned;
            },
            .WTFStringImpl => {
                var str = bun.String.init(this.WTFStringImpl);
                defer str.deref();
                this.* = .{ .Blob = .{} };

                return str.toJS(global);
            },
        }
    }

    pub fn toArrayBuffer(this: *AnyBlob, global: *JSGlobalObject, comptime lifetime: JSC.WebCore.Lifetime) bun.JSError!JSValue {
        return this.toArrayBufferView(global, lifetime, .ArrayBuffer);
    }

    pub fn toUint8Array(this: *AnyBlob, global: *JSGlobalObject, comptime lifetime: JSC.WebCore.Lifetime) bun.JSError!JSValue {
        return this.toArrayBufferView(global, lifetime, .Uint8Array);
    }

    pub fn toArrayBufferView(this: *AnyBlob, global: *JSGlobalObject, comptime lifetime: JSC.WebCore.Lifetime, comptime TypedArrayView: JSC.JSValue.JSType) bun.JSError!JSValue {
        switch (this.*) {
            .Blob => return this.Blob.toArrayBufferView(global, lifetime, TypedArrayView),
            // .InlineBlob => {
            //     if (this.InlineBlob.len == 0) {
            //         return JSC.ArrayBuffer.create(global, "", .ArrayBuffer);
            //     }
            //     var bytes = this.InlineBlob.sliceConst();
            //     this.InlineBlob.len = 0;
            //     const value = JSC.ArrayBuffer.create(
            //         global,
            //         bytes,
            //         .ArrayBuffer,
            //     );
            //     return value;
            // },
            .InternalBlob => {
                if (this.InternalBlob.bytes.items.len == 0) {
                    return JSC.ArrayBuffer.create(global, "", TypedArrayView);
                }

                const bytes = this.InternalBlob.toOwnedSlice();
                this.* = .{ .Blob = .{} };

                return JSC.ArrayBuffer.fromDefaultAllocator(
                    global,
                    bytes,
                    TypedArrayView,
                );
            },
            .WTFStringImpl => {
                const str = bun.String.init(this.WTFStringImpl);
                this.* = .{ .Blob = .{} };
                defer str.deref();

                const out_bytes = str.toUTF8WithoutRef(bun.default_allocator);
                if (out_bytes.isAllocated()) {
                    return JSC.ArrayBuffer.fromDefaultAllocator(
                        global,
                        @constCast(out_bytes.slice()),
                        TypedArrayView,
                    );
                }

                return JSC.ArrayBuffer.create(global, out_bytes.slice(), TypedArrayView);
            },
        }
    }

    pub fn isDetached(this: *const AnyBlob) bool {
        return switch (this.*) {
            .Blob => |blob| blob.isDetached(),
            .InternalBlob => this.InternalBlob.bytes.items.len == 0,
            .WTFStringImpl => this.WTFStringImpl.length() == 0,
        };
    }

    pub fn store(this: *const @This()) ?*Blob.Store {
        if (this.* == .Blob) {
            return this.Blob.store;
        }

        return null;
    }

    pub fn contentType(self: *const @This()) []const u8 {
        return switch (self.*) {
            .Blob => self.Blob.content_type,
            .WTFStringImpl => MimeType.text.value,
            // .InlineBlob => self.InlineBlob.contentType(),
            .InternalBlob => self.InternalBlob.contentType(),
        };
    }

    pub fn wasString(self: *const @This()) bool {
        return switch (self.*) {
            .Blob => self.Blob.is_all_ascii orelse false,
            .WTFStringImpl => true,
            // .InlineBlob => self.InlineBlob.was_string,
            .InternalBlob => self.InternalBlob.was_string,
        };
    }

    pub inline fn slice(self: *const @This()) []const u8 {
        return switch (self.*) {
            .Blob => self.Blob.sharedView(),
            .WTFStringImpl => self.WTFStringImpl.utf8Slice(),
            // .InlineBlob => self.InlineBlob.sliceConst(),
            .InternalBlob => self.InternalBlob.sliceConst(),
        };
    }

    pub fn needsToReadFile(self: *const @This()) bool {
        return switch (self.*) {
            .Blob => self.Blob.needsToReadFile(),
            .WTFStringImpl, .InternalBlob => false,
        };
    }

    pub fn isS3(self: *const @This()) bool {
        return switch (self.*) {
            .Blob => self.Blob.isS3(),
            .WTFStringImpl, .InternalBlob => false,
        };
    }

    pub fn detach(self: *@This()) void {
        return switch (self.*) {
            .Blob => {
                self.Blob.detach();
                self.* = .{
                    .Blob = .{},
                };
            },
            // .InlineBlob => {
            //     self.InlineBlob.len = 0;
            // },
            .InternalBlob => {
                self.InternalBlob.bytes.clearAndFree();
                self.* = .{ .Blob = .{} };
            },
            .WTFStringImpl => {
                self.WTFStringImpl.deref();
                self.* = .{ .Blob = .{} };
            },
        };
    }
};

/// A single-use Blob
pub const InternalBlob = struct {
    bytes: std.ArrayList(u8),
    was_string: bool = false,

    pub fn memoryCost(this: *const @This()) usize {
        return this.bytes.capacity;
    }

    pub fn toStringOwned(this: *@This(), globalThis: *JSC.JSGlobalObject) JSValue {
        const bytes_without_bom = strings.withoutUTF8BOM(this.bytes.items);
        if (strings.toUTF16Alloc(globalThis.allocator(), bytes_without_bom, false, false) catch &[_]u16{}) |out| {
            const return_value = ZigString.toExternalU16(out.ptr, out.len, globalThis);
            return_value.ensureStillAlive();
            this.deinit();
            return return_value;
        } else if
        // If there was a UTF8 BOM, we clone it
        (bytes_without_bom.len != this.bytes.items.len) {
            defer this.deinit();
            var out = bun.String.createLatin1(this.bytes.items[3..]);
            defer out.deref();
            return out.toJS(globalThis);
        } else {
            var str = ZigString.init(this.toOwnedSlice());
            str.mark();
            return str.toExternalValue(globalThis);
        }
    }

    pub fn toJSON(this: *@This(), globalThis: *JSC.JSGlobalObject) JSValue {
        const str_bytes = ZigString.init(strings.withoutUTF8BOM(this.bytes.items)).withEncoding();
        const json = str_bytes.toJSONObject(globalThis);
        this.deinit();
        return json;
    }

    pub inline fn sliceConst(this: *const @This()) []const u8 {
        return this.bytes.items;
    }

    pub fn deinit(this: *@This()) void {
        this.bytes.clearAndFree();
    }

    pub inline fn slice(this: @This()) []u8 {
        return this.bytes.items;
    }

    pub fn toOwnedSlice(this: *@This()) []u8 {
        const bytes = this.bytes.items;
        this.bytes.items = &.{};
        this.bytes.capacity = 0;
        return bytes;
    }

    pub fn clearAndFree(this: *@This()) void {
        this.bytes.clearAndFree();
    }

    pub fn contentType(self: *const @This()) []const u8 {
        if (self.was_string) {
            return MimeType.text.value;
        }

        return MimeType.other.value;
    }
};

/// A blob which stores all the data in the same space as a real Blob
/// This is an optimization for small Response and Request bodies
/// It means that we can avoid an additional heap allocation for a small response
pub const InlineBlob = extern struct {
    const real_blob_size = @sizeOf(Blob);
    pub const IntSize = u8;
    pub const available_bytes = real_blob_size - @sizeOf(IntSize) - 1 - 1;
    bytes: [available_bytes]u8 align(1) = undefined,
    len: IntSize align(1) = 0,
    was_string: bool align(1) = false,

    pub fn concat(first: []const u8, second: []const u8) InlineBlob {
        const total = first.len + second.len;
        assert(total <= available_bytes);

        var inline_blob: JSC.WebCore.InlineBlob = .{};
        var bytes_slice = inline_blob.bytes[0..total];

        if (first.len > 0)
            @memcpy(bytes_slice[0..first.len], first);

        if (second.len > 0)
            @memcpy(bytes_slice[first.len..][0..second.len], second);

        inline_blob.len = @as(@TypeOf(inline_blob.len), @truncate(total));
        return inline_blob;
    }

    fn internalInit(data: []const u8, was_string: bool) InlineBlob {
        assert(data.len <= available_bytes);

        var blob = InlineBlob{
            .len = @as(IntSize, @intCast(data.len)),
            .was_string = was_string,
        };

        if (data.len > 0)
            @memcpy(blob.bytes[0..data.len], data);
        return blob;
    }

    pub fn init(data: []const u8) InlineBlob {
        return internalInit(data, false);
    }

    pub fn initString(data: []const u8) InlineBlob {
        return internalInit(data, true);
    }

    pub fn toStringOwned(this: *@This(), globalThis: *JSC.JSGlobalObject) JSValue {
        if (this.len == 0)
            return ZigString.Empty.toJS(globalThis);

        var str = ZigString.init(this.sliceConst());

        if (!strings.isAllASCII(this.sliceConst())) {
            str.markUTF8();
        }

        const out = str.toJS(globalThis);
        out.ensureStillAlive();
        this.len = 0;
        return out;
    }

    pub fn contentType(self: *const @This()) []const u8 {
        if (self.was_string) {
            return MimeType.text.value;
        }

        return MimeType.other.value;
    }

    pub fn deinit(_: *@This()) void {}

    pub inline fn slice(this: *@This()) []u8 {
        return this.bytes[0..this.len];
    }

    pub inline fn sliceConst(this: *const @This()) []const u8 {
        return this.bytes[0..this.len];
    }

    pub fn toOwnedSlice(this: *@This()) []u8 {
        return this.slice();
    }

    pub fn clearAndFree(_: *@This()) void {}
};

const assert = bun.assert;

pub export fn JSDOMFile__hasInstance(_: JSC.JSValue, _: *JSC.JSGlobalObject, value: JSC.JSValue) callconv(JSC.conv) bool {
    JSC.markBinding(@src());
    const blob = value.as(Blob) orelse return false;
    return blob.is_jsdom_file;
}
