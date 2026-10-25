const std = @import("std");

pub const Nd2Error = error{
    // File errors
    IoError,
    InvalidFormat,
    InvalidMagic,
    CorruptChunkHeader,
    ChunkNotFound,
    InvalidChunkmapSignature,
    ChunkmapParse,
    ClxParse,
    Decompression,
    Utf16Decode,
    MetadataParse,
    // Input errors
    MissingDimension,
    OutOfRange,
    InvalidArgument,
    IncompatibleParams,
    // Internal errors
    Overflow,
    InvariantViolation,
    OutOfMemory,
    // Unsupported errors
    UnsupportedVersion,
    UnsupportedClxType,
};

pub const ErrorSource = enum {
    /// Errors arising from invalid, corrupt, or truncated file content.
    file,
    /// Errors caused by out-of-range indices or invalid caller arguments.
    input,
    /// Errors caused by internal invariants or arithmetic overflow.
    internal,
    /// Errors caused by unsupported format features or ND2 versions.
    unsupported,

    pub fn asStr(self: ErrorSource) []const u8 {
        return switch (self) {
            .file => "File",
            .input => "Input",
            .internal => "Internal",
            .unsupported => "Unsupported",
        };
    }

    pub fn format(self: ErrorSource, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.asStr());
    }
};

pub fn classifyError(err: Nd2Error) ErrorSource {
    return switch (err) {
        error.IoError,
        error.InvalidFormat,
        error.InvalidMagic,
        error.CorruptChunkHeader,
        error.ChunkNotFound,
        error.InvalidChunkmapSignature,
        error.ChunkmapParse,
        error.ClxParse,
        error.Decompression,
        error.Utf16Decode,
        error.MetadataParse,
        => .file,

        error.MissingDimension,
        error.OutOfRange,
        error.InvalidArgument,
        error.IncompatibleParams,
        => .input,

        error.Overflow,
        error.InvariantViolation,
        error.OutOfMemory,
        => .internal,

        error.UnsupportedVersion,
        error.UnsupportedClxType,
        => .unsupported,
    };
}

pub fn isFileError(err: Nd2Error) bool {
    return classifyError(err) == .file;
}

pub fn isInputError(err: Nd2Error) bool {
    return classifyError(err) == .input;
}

pub fn isInternalError(err: Nd2Error) bool {
    return classifyError(err) == .internal;
}

pub fn isUnsupportedError(err: Nd2Error) bool {
    return classifyError(err) == .unsupported;
}
