const std = @import("../std.zig");
const builtin = @import("builtin");
const os = std.os;
const io = std.io;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const windows = os.windows;
const Os = builtin.Os;
const maxInt = std.math.maxInt;

pub const File = struct {
    /// The OS-specific file descriptor or file handle.
    handle: os.fd_t,

    pub const Mode = switch (builtin.os) {
        Os.windows => void,
        else => u32,
    };

    pub const default_mode = switch (builtin.os) {
        Os.windows => {},
        else => 0o666,
    };

    pub const OpenError = windows.CreateFileError || os.OpenError;


    pub const READ = 1;
    pub const WRITE = 2;
    pub const CLOBBER = 4;

    pub fn openW(path: [*]const u16, flags: u32) OpenError!File{
        assert(windows.is_the_target);

        if((flags & CLOBBER) > 0 and !((flags & WRITE) > 0)) {
            assert(false);//Cannot clobber a read only file! Did you forget to add '| WRITE'?
        }
        

        var desiredAccess: u32 = 0;
        if(flags & READ > 0) {
            desiredAccess |= windows.GENERIC_READ;
        }
        if(flags & WRITE > 0) {
            desiredAccess |= windows.GENERIC_WRITE;
        }

        var creationDisposition: u32 = windows.OPEN_EXISTING;
        if(flags & CLOBBER > 0) {
            creationDisposition = windows.CREATE_ALWAYS;
        }

        if(flags & WRITE > 0) {
            creationDisposition = windows.OPEN_ALWAYS;
        }

        const handle = try windows.CreateFileW(
            path,
            desiredAccess,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
            null,
            creationDisposition,
            windows.FILE_ATTRIBUTE_NORMAL,
            null
        );

        return openHandle(handle);
    }

    pub fn openC(path: []const u8, comptime flags: u32) OpenError!File {
        if((flags & CLOBBER) > 0 and !((flags & WRITE) > 0)) {
            assert(false);//Cannot clobber a read only file! Did you forget to add '| WRITE'?
        }
    
        if (windows.is_the_target) {
            const path_w = try windows.cStrToPrefixedFileW(path);
            return openW(&path_w, flags);
        }

        var posixFlags: u32 = O_LARGEFILE;

        if(flags & READ > 0) {
            if(flags & WRITE > 0) {
                posixFlags |= O_RDWR;
            }
            else {
                posixFlags |= O_RDONLY;
            }
        }
        else if (flags & WRITE > 0) {
            posixFlags |= O_WRONLY;
        }
        else {
            assert(true);
        }

        if(flags & WRITE > 0) {
            posixFlags |= O_CREAT;
        }

        if(flags & CLOBBER > 0) {
            posixFlags |= O_TRUNC;
        }

        const fd = try os.openC(path, posixFlags, 0);
        return openHandle(fd);
    }

    pub fn open(path: []const u8, flags: u32) OpenError!File {
        if (windows.is_the_target) {
            const path_w = try windows.sliceToPrefixedFileW(path);
            return openW(&path_w, flags);
        }
        const path_c = try os.toPosixPath(path);
        return openC(&path_c, flags);
    }

    pub fn openHandle(handle: os.fd_t) File {
        return File{ .handle = handle };
    }

    /// Test for the existence of `path`.
    /// `path` is UTF8-encoded.
    /// In general it is recommended to avoid this function. For example,
    /// instead of testing if a file exists and then opening it, just
    /// open it and handle the error for file not found.
    pub fn access(path: []const u8) !void {
        return os.access(path, os.F_OK);
    }

    /// Same as `access` except the parameter is null-terminated.
    pub fn accessC(path: [*]const u8) !void {
        return os.accessC(path, os.F_OK);
    }

    /// Same as `access` except the parameter is null-terminated UTF16LE-encoded.
    pub fn accessW(path: [*]const u16) !void {
        return os.accessW(path, os.F_OK);
    }

    /// Upon success, the stream is in an uninitialized state. To continue using it,
    /// you must use the open() function.
    pub fn close(self: File) void {
        return os.close(self.handle);
    }

    /// Test whether the file refers to a terminal.
    /// See also `supportsAnsiEscapeCodes`.
    pub fn isTty(self: File) bool {
        return os.isatty(self.handle);
    }

    /// Test whether ANSI escape codes will be treated as such.
    pub fn supportsAnsiEscapeCodes(self: File) bool {
        if (windows.is_the_target) {
            return os.isCygwinPty(self.handle);
        }
        return self.isTty();
    }

    pub const SeekError = os.SeekError;

    /// Repositions read/write file offset relative to the current offset.
    pub fn seekBy(self: File, offset: i64) SeekError!void {
        return os.lseek_CUR(self.handle, offset);
    }

    /// Repositions read/write file offset relative to the end.
    pub fn seekFromEnd(self: File, offset: i64) SeekError!void {
        return os.lseek_END(self.handle, offset);
    }

    /// Repositions read/write file offset relative to the beginning.
    pub fn seekTo(self: File, offset: u64) SeekError!void {
        return os.lseek_SET(self.handle, offset);
    }

    pub const GetPosError = os.SeekError || os.FStatError;

    pub fn getPos(self: File) GetPosError!u64 {
        return os.lseek_CUR_get(self.handle);
    }

    pub fn getEndPos(self: File) GetPosError!u64 {
        if (windows.is_the_target) {
            return windows.GetFileSizeEx(self.handle);
        }
        return (try self.stat()).size;
    }

    pub const ModeError = os.FStatError;

    pub fn mode(self: File) ModeError!Mode {
        if (windows.is_the_target) {
            return {};
        }
        return (try self.stat()).mode;
    }

    pub const Stat = struct {
        size: u64,
        mode: Mode,

        /// access time in nanoseconds
        atime: i64,

        /// last modification time in nanoseconds
        mtime: i64,

        /// creation time in nanoseconds
        ctime: i64,
    };

    pub const StatError = os.FStatError;

    pub fn stat(self: File) StatError!Stat {
        if (windows.is_the_target) {
            var io_status_block: windows.IO_STATUS_BLOCK = undefined;
            var info: windows.FILE_ALL_INFORMATION = undefined;
            const rc = windows.ntdll.NtQueryInformationFile(self.handle, &io_status_block, &info, @sizeOf(windows.FILE_ALL_INFORMATION), .FileAllInformation);
            switch (rc) {
                windows.STATUS.SUCCESS => {},
                windows.STATUS.BUFFER_OVERFLOW => {},
                else => return windows.unexpectedStatus(rc),
            }
            return Stat{
                .size = @bitCast(u64, info.StandardInformation.EndOfFile),
                .mode = {},
                .atime = windows.fromSysTime(info.BasicInformation.LastAccessTime),
                .mtime = windows.fromSysTime(info.BasicInformation.LastWriteTime),
                .ctime = windows.fromSysTime(info.BasicInformation.CreationTime),
            };
        }

        const st = try os.fstat(self.handle);
        const atime = st.atime();
        const mtime = st.mtime();
        const ctime = st.ctime();
        return Stat{
            .size = @bitCast(u64, st.size),
            .mode = st.mode,
            .atime = atime.tv_sec * std.time.ns_per_s + atime.tv_nsec,
            .mtime = mtime.tv_sec * std.time.ns_per_s + mtime.tv_nsec,
            .ctime = ctime.tv_sec * std.time.ns_per_s + ctime.tv_nsec,
        };
    }

    pub const UpdateTimesError = os.FutimensError || windows.SetFileTimeError;

    /// `atime`: access timestamp in nanoseconds
    /// `mtime`: last modification timestamp in nanoseconds
    pub fn updateTimes(self: File, atime: i64, mtime: i64) UpdateTimesError!void {
        if (windows.is_the_target) {
            const atime_ft = windows.nanoSecondsToFileTime(atime);
            const mtime_ft = windows.nanoSecondsToFileTime(mtime);
            return windows.SetFileTime(self.handle, null, &atime_ft, &mtime_ft);
        }
        const times = [2]os.timespec{
            os.timespec{
                .tv_sec = @divFloor(atime, std.time.ns_per_s),
                .tv_nsec = @mod(atime, std.time.ns_per_s),
            },
            os.timespec{
                .tv_sec = @divFloor(mtime, std.time.ns_per_s),
                .tv_nsec = @mod(mtime, std.time.ns_per_s),
            },
        };
        try os.futimens(self.handle, &times);
    }

    pub const ReadError = os.ReadError;

    pub fn read(self: File, buffer: []u8) ReadError!usize {
        return os.read(self.handle, buffer);
    }

    pub const WriteError = os.WriteError;

    pub fn write(self: File, bytes: []const u8) WriteError!void {
        return os.write(self.handle, bytes);
    }

    pub fn writev_iovec(self: File, iovecs: []const os.iovec_const) WriteError!void {
        if (std.event.Loop.instance) |loop| {
            return std.event.fs.writevPosix(loop, self.handle, iovecs);
        } else {
            return os.writev(self.handle, iovecs);
        }
    }

    pub fn inStream(file: File) InStream {
        return InStream{
            .file = file,
            .stream = InStream.Stream{ .readFn = InStream.readFn },
        };
    }

    pub fn outStream(file: File) OutStream {
        return OutStream{
            .file = file,
            .stream = OutStream.Stream{ .writeFn = OutStream.writeFn },
        };
    }

    pub fn seekableStream(file: File) SeekableStream {
        return SeekableStream{
            .file = file,
            .stream = SeekableStream.Stream{
                .seekToFn = SeekableStream.seekToFn,
                .seekByFn = SeekableStream.seekByFn,
                .getPosFn = SeekableStream.getPosFn,
                .getEndPosFn = SeekableStream.getEndPosFn,
            },
        };
    }

    /// Implementation of io.InStream trait for File
    pub const InStream = struct {
        file: File,
        stream: Stream,

        pub const Error = ReadError;
        pub const Stream = io.InStream(Error);

        fn readFn(in_stream: *Stream, buffer: []u8) Error!usize {
            const self = @fieldParentPtr(InStream, "stream", in_stream);
            return self.file.read(buffer);
        }
    };

    /// Implementation of io.OutStream trait for File
    pub const OutStream = struct {
        file: File,
        stream: Stream,

        pub const Error = WriteError;
        pub const Stream = io.OutStream(Error);

        fn writeFn(out_stream: *Stream, bytes: []const u8) Error!void {
            const self = @fieldParentPtr(OutStream, "stream", out_stream);
            return self.file.write(bytes);
        }
    };

    /// Implementation of io.SeekableStream trait for File
    pub const SeekableStream = struct {
        file: File,
        stream: Stream,

        pub const Stream = io.SeekableStream(SeekError, GetPosError);

        pub fn seekToFn(seekable_stream: *Stream, pos: u64) SeekError!void {
            const self = @fieldParentPtr(SeekableStream, "stream", seekable_stream);
            return self.file.seekTo(pos);
        }

        pub fn seekByFn(seekable_stream: *Stream, amt: i64) SeekError!void {
            const self = @fieldParentPtr(SeekableStream, "stream", seekable_stream);
            return self.file.seekBy(amt);
        }

        pub fn getEndPosFn(seekable_stream: *Stream) GetPosError!u64 {
            const self = @fieldParentPtr(SeekableStream, "stream", seekable_stream);
            return self.file.getEndPos();
        }

        pub fn getPosFn(seekable_stream: *Stream) GetPosError!u64 {
            const self = @fieldParentPtr(SeekableStream, "stream", seekable_stream);
            return self.file.getPos();
        }
    };
};
