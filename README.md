# nd2-zig

Fast, memory-efficient, pure Zig reader for Nikon ND2 (`.nd2`) microscopy files.

Ported from `nd2-rs` to Zig with zero external C/C++ dependencies (uses `std.compress.flate` for zlib-compressed CLX metadata and `ImageDataSeq` chunks).

## Features

- **Pure Zig**: 100% safe, portable Zig with zero external C/C++ libraries.
- **Multi-Dimensional Navigation**: Read frames by linear sequence index (`readFrame(index)`) or by multidimensional coordinates `(Position, Time, Channel, Z-stack)` via `readFrame2d(p, t, c, z)`.
- **Compression Support**: Handles uncompressed chunks and zlib-compressed `ImageDataSeq` and CLX Lite payloads.
- **Broad Format Compatibility**: Supports ND2 v2.0, v2.1, and v3.0 chunk maps, CLX Lite binary TLV metadata, experiment loops (`TimeLoop`, `NETimeLoop`, `XYPosLoop`, `ZStackLoop`), padded row strides (`uiWidthBytes`), and unaligned chunkmap offsets.

## Build & Test

```sh
zig build
zig build test
```
