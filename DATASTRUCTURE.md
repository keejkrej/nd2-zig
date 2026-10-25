# ND2-RS Data Structure & File Format Documentation

This document provides detailed technical information about the ND2 file format and how nd2-rs parses it.

## Table of Contents

1. [ND2 File Format Overview](#nd2-file-format-overview)
2. [File Structure](#file-structure)
3. [Chunk-Based Architecture](#chunk-based-architecture)
4. [CLX Lite Binary Format](#clx-lite-binary-format)
5. [Parsing Pipeline](#parsing-pipeline)
6. [Module Architecture](#module-architecture)
7. [Error Handling](#error-handling)
8. [Performance Considerations](#performance-considerations)
9. [Experiment Parsing: Findings & Compatibility](#experiment-parsing-findings--compatibility)

---

## ND2 File Format Overview

ND2 (Nikon Data) files are proprietary binary files created by Nikon NIS Elements microscopy software. The modern format (v2.0+) uses a chunk-based structure similar to TIFF or PNG.

### Format Versions

| Version | Description | Metadata Format | Image Encoding |
|---------|-------------|-----------------|----------------|
| 1.0 | Legacy | XML | JPEG2000 |
| 2.0, 2.1 | Modern | CLX XML | Raw/Zlib |
| 3.0 | Current | CLX Lite (binary) | Raw/Zlib |

**nd2-rs currently supports versions 2.0, 2.1, and 3.0.**

---

## File Structure

### Overall Layout

```
┌─────────────────────────────────────────┐
│  File Header (112 bytes)                │  Offset: 0
│  - Chunk magic: 0x0ABECEDA              │
│  - Name length: 32                      │
│  - Data length: 64                      │
│  - Name: "ND2 FILE SIGNATURE..."        │
│  - Data: "Ver3.0\x00..."                │
├─────────────────────────────────────────┤
│  Chunk 1: ImageAttributesLV!            │
│  - 16-byte header                       │
│  - Chunk name                           │
│  - Chunk data (CLX Lite encoded)        │
├─────────────────────────────────────────┤
│  Chunk 2: ImageMetadataLV!              │
│  - Experiment loop definitions          │
├─────────────────────────────────────────┤
│  Chunk 3: ImageTextInfoLV!              │
│  - Text metadata (author, description)  │
├─────────────────────────────────────────┤
│  Chunk 4: ImageDataSeq|0!               │
│  - First frame image data               │
├─────────────────────────────────────────┤
│  ...more chunks...                      │
├─────────────────────────────────────────┤
│  ChunkMap Section                       │
│  - CHUNK_HEADER                         │
│  - "ND2 FILEMAP SIGNATURE..."           │
│  - Entries: name + offset + size        │
│  - Terminator: "ND2 CHUNK MAP..."       │
├─────────────────────────────────────────┤
│  Last 40 bytes                          │  Offset: -40
│  - Signature (32 bytes)                 │
│  - ChunkMap offset (8 bytes)            │
└─────────────────────────────────────────┘
```

### File Header Details

**Offset 0-15: Chunk Header (16 bytes)**
```
Bytes 0-3:   magic (u32 LE)      = 0x0ABECEDA
Bytes 4-7:   name_length (u32)   = 32
Bytes 8-15:  data_length (u64)   = 64
```

**Offset 16-47: Chunk Name (32 bytes)**
```
"ND2 FILE SIGNATURE CHUNK NAME01!"
```

**Offset 48-111: Version Data (64 bytes)**
```
"Ver3.0\x00\x00..." (null-padded)
```

**Version Extraction:**
- Byte 51 (index 3): Major version digit (e.g., '3')
- Byte 53 (index 5): Minor version digit (e.g., '0')

---

## Chunk-Based Architecture

### Chunk Header Structure

Every chunk in the file starts with a 16-byte header:

```rust
struct ChunkHeader {
    magic: u32,        // Always 0x0ABECEDA (little-endian)
    name_length: u32,  // Length of chunk name in bytes
    data_length: u64,  // Length of chunk data in bytes
}
```

**Layout in binary:**
```
┌────────────┬──────────────┬──────────────┐
│  Magic     │ Name Length  │ Data Length  │
│  4 bytes   │  4 bytes     │  8 bytes     │
└────────────┴──────────────┴──────────────┘
```

### Chunk Structure

```
┌─────────────────────────────────┐
│  ChunkHeader (16 bytes)         │
├─────────────────────────────────┤
│  Name (name_length bytes)       │
│  e.g., "ImageAttributesLV!"     │
├─────────────────────────────────┤
│  Data (data_length bytes)       │
│  - May be CLX Lite encoded      │
│  - May be zlib compressed       │
└─────────────────────────────────┘
```

### ChunkMap

The ChunkMap is a directory at the end of the file that maps chunk names to their locations.

**ChunkMap Entry Format:**
```
┌──────────────────────┬─────────────┬─────────────┐
│  Chunk Name + "!"    │  Offset     │  Size       │
│  Variable length     │  8 bytes    │  8 bytes    │
└──────────────────────┴─────────────┴─────────────┘
```

**Example ChunkMap in memory:**
```rust
HashMap {
    b"ImageAttributesLV!" => (1024, 512),   // offset=1024, size=512
    b"ImageMetadataLV!"   => (2048, 1024),  // offset=2048, size=1024
    b"ImageTextInfoLV!"   => (4096, 256),   // offset=4096, size=256
    b"ImageDataSeq|0!"    => (8192, 65536), // offset=8192, size=65536
}
```

**Reading the ChunkMap:**
1. Seek to `-40` bytes from end of file
2. Read 32-byte signature (should be `"ND2 CHUNK MAP SIGNATURE 0000001!"`)
3. Read 8-byte offset to ChunkMap section
4. Seek to that offset
5. Read ChunkMap header
6. Parse entries until terminator signature

---

## CLX Lite Binary Format

CLX Lite is a binary Type-Length-Value (TLV) encoding format used for metadata in v3.0 files.

### Data Types

| Type Code | Name | Size | Description |
|-----------|------|------|-------------|
| 1 | BOOL | 1 byte | Boolean (0 or non-zero) |
| 2 | INT32 | 4 bytes | Signed 32-bit integer |
| 3 | UINT32 | 4 bytes | Unsigned 32-bit integer |
| 4 | INT64 | 8 bytes | Signed 64-bit integer |
| 5 | UINT64 | 8 bytes | Unsigned 64-bit integer |
| 6 | DOUBLE | 8 bytes | 64-bit floating point |
| 7 | VOIDPOINTER | 8 bytes | Pointer (treated as u64) |
| 8 | STRING | Variable | UTF-16 LE null-terminated |
| 9 | BYTEARRAY | Variable | Length-prefixed byte array |
| 11 | LEVEL | Variable | Nested structure |
| 76 ('L') | COMPRESS | Variable | Zlib-compressed data |

### TLV Entry Format

**Basic Entry:**
```
┌─────────┬─────────────┬────────────┬─────────┐
│ Type    │ Name Length │ Name       │ Value   │
│ 1 byte  │ 1 byte      │ N*2 bytes  │ varies  │
└─────────┴─────────────┴────────────┴─────────┘
```

**Field Details:**

1. **Type (1 byte)**: Data type code from table above
2. **Name Length (1 byte)**: Number of UTF-16 characters in name
3. **Name (N*2 bytes)**: UTF-16 LE encoded name, null-terminated
4. **Value**: Type-specific data

### Examples

**UINT32 Entry:**
```
Type:        0x03        (UINT32)
Name Length: 0x07        (7 characters)
Name:        0x75 0x00 0x69 0x00 0x57 0x00 0x69 0x00
             0x64 0x00 0x74 0x00 0x68 0x00 0x00 0x00
             ("uiWidth\0" in UTF-16 LE)
Value:       0x00 0x04 0x00 0x00  (1024 in little-endian)
```

**STRING Entry:**
```
Type:        0x08        (STRING)
Name Length: 0x06        (6 characters)
Name:        0x41 0x00 0x75 0x00 0x74 0x00 0x68 0x00
             0x6F 0x00 0x72 0x00 0x00 0x00
             ("Author\0" in UTF-16 LE)
Value:       0x4A 0x00 0x6F 0x00 0x68 0x00 0x6E 0x00
             0x00 0x00
             ("John\0" in UTF-16 LE)
```

### LEVEL Type (Nested Structures)

The LEVEL type (11) represents nested objects:

```
┌─────────┬─────────────┬────────────┬────────────┬────────────┬─────────┐
│ Type=11 │ Name Length │ Name       │ Item Count │ Length     │ Items   │
│ 1 byte  │ 1 byte      │ N*2 bytes  │ 4 bytes    │ 8 bytes    │ ...     │
└─────────┴─────────────┴────────────┴────────────┴────────────┴─────────┘
```

**Parsing Algorithm:**
```rust
fn read_level() {
    let item_count = read_u32();  // Number of nested items
    let length = read_u64();       // Total length of nested data

    // Recursively parse item_count items
    for i in 0..item_count {
        parse_clx_entry();
    }

    // Skip offset table (item_count * 8 bytes)
    skip(item_count * 8);
}
```

### COMPRESS Type (Zlib Compression)

The COMPRESS type (76) contains zlib-compressed CLX Lite data:

```
┌─────────┬─────────────┬────────────┬────────────┬──────────────┐
│ Type=76 │ Name Len=0  │ Reserved   │ Compressed │              │
│ 1 byte  │ 1 byte      │ 10 bytes   │ Data       │              │
└─────────┴─────────────┴────────────┴────────────┴──────────────┘
```

**Decompression Steps:**
1. Read type (should be 76)
2. Read name length (always 0 for COMPRESS)
3. Skip 10 bytes (reserved/header)
4. Read remaining bytes as compressed data
5. Decompress with zlib
6. Recursively parse decompressed data as CLX Lite

---

## Parsing Pipeline

### High-Level Flow

```
┌──────────────┐
│  Open File   │
└──────┬───────┘
       │
       ▼
┌──────────────────────┐
│  Read File Header    │
│  Extract Version     │
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐
│  Read ChunkMap       │
│  (from end of file)  │
└──────┬───────────────┘
       │
       ▼
┌──────────────────────────────────────────┐
│  Read Metadata Chunks On-Demand          │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │  1. Seek to chunk offset          │ │
│  │  2. Read chunk data               │ │
│  │  3. Parse CLX Lite format         │ │
│  │  4. Map to Rust structs           │ │
│  │  5. Cache result                  │ │
│  └────────────────────────────────────┘ │
└───────────────────────────────────────────┘
```

### Detailed Parsing Sequence

#### 1. File Opening

```rust
// src/reader.rs: Nd2File::open()

let file = File::open(path)?;
let mut reader = BufReader::new(file);

// Read and validate header
let version = read_version(&mut reader)?;

// Version must be 2.x or 3.x
if version.0 < 2 || version.0 > 3 {
    return Err(UnsupportedVersion);
}

// Read ChunkMap from end of file
let chunkmap = read_chunkmap(&mut reader)?;
```

#### 2. ChunkMap Reading

```rust
// src/chunk/map.rs: read_chunkmap()

// Seek to last 40 bytes
reader.seek(SeekFrom::End(-40))?;

// Read signature (32 bytes)
let mut signature = [0u8; 32];
reader.read_exact(&mut signature)?;
assert_eq!(signature, b"ND2 CHUNK MAP SIGNATURE 0000001!");

// Read offset to ChunkMap section
let chunkmap_offset = read_u64_le()?;

// Seek to ChunkMap
reader.seek(SeekFrom::Start(chunkmap_offset))?;

// Read ChunkMap header
let header = ChunkHeader::read()?;

// Parse entries
while bytes_read < header.data_length {
    let chunk_name = read_until(b'!')?;
    let offset = read_u64_le()?;
    let size = read_u64_le()?;

    chunkmap.insert(chunk_name, (offset, size));
}
```

#### 3. Chunk Data Reading

```rust
// src/chunk/map.rs: read_chunk()

let (offset, size) = chunkmap.get(name)?;

// Seek to chunk
reader.seek(SeekFrom::Start(offset))?;

// Read and validate header
let header = ChunkHeader::read()?;
assert_eq!(header.magic, 0x0ABECEDA);

// Skip chunk name
reader.seek(SeekFrom::Current(header.name_length as i64))?;

// Read chunk data
let mut data = vec![0u8; size];
reader.read_exact(&mut data)?;
```

#### 4. CLX Lite Parsing

```rust
// src/parse/clx_lite.rs: ClxLiteParser::parse()

let mut cursor = Cursor::new(data);
let mut output = HashMap::new();

loop {
    // Read header
    let data_type = cursor.read_u8()?;
    let name_length = cursor.read_u8()?;

    // Read name (UTF-16 LE)
    let mut name_bytes = vec![0u8; name_length * 2];
    cursor.read_exact(&mut name_bytes)?;
    let name = decode_utf16_le(&name_bytes)?;

    // Read value based on type
    let value = match data_type {
        1 => ClxValue::Bool(cursor.read_u8()? != 0),
        2 => ClxValue::Int(cursor.read_i32::<LE>()? as i64),
        3 => ClxValue::UInt(cursor.read_u32::<LE>()? as u64),
        6 => ClxValue::Float(cursor.read_f64::<LE>()?),
        8 => read_utf16_string(&mut cursor)?,
        11 => read_level(&mut cursor)?,      // Nested
        76 => decompress_and_parse(&mut cursor)?,  // Compressed
        _ => continue,
    };

    output.insert(name, value);
}
```

#### 5. Struct Mapping

```rust
// src/metadata/attributes.rs: parse_attributes()

let obj = clx.as_object()?;

let attributes = Attributes {
    bits_per_component_in_memory: get_u32(obj, "uiBpcInMemory")?,
    bits_per_component_significant: get_u32(obj, "uiBpcSignificant")?,
    component_count: get_u32(obj, "uiComp")?,
    height_px: get_u32(obj, "uiHeight")?,
    width_px: get_opt_u32(obj, "uiWidth"),
    sequence_count: get_u32(obj, "uiSequenceCount")?,
    // ... more fields
};
```

---

## Module Architecture

### Dependency Graph

```
┌─────────────┐
│   lib.rs    │  Public API
└──────┬──────┘
       │
       ├──────────────┐
       │              │
       ▼              ▼
┌──────────┐   ┌───────────┐
│ reader.rs│   │  types/*  │
└────┬─────┘   └───────────┘
     │
     ├────────────┬──────────────┬─────────────┐
     │            │              │             │
     ▼            ▼              ▼             ▼
┌────────┐  ┌─────────┐  ┌──────────┐  ┌──────────┐
│chunk/* │  │ parse/* │  │metadata/*│  │constants │
└────────┘  └─────────┘  └──────────┘  └──────────┘
     │            │              │
     ▼            ▼              ▼
┌──────────────────────────────────┐
│           error.rs               │
└──────────────────────────────────┘
```

### Module Responsibilities

**`chunk/`** - Binary chunk I/O
- `header.rs`: ChunkHeader parsing and validation
- `map.rs`: ChunkMap reading and chunk data retrieval

**`parse/`** - Format parsing
- `clx_lite.rs`: CLX Lite binary TLV parser

**`types/`** - Data structures
- `attributes.rs`: Image attributes
- `experiment.rs`: Experiment loop types
- `metadata.rs`: Channel and volume metadata
- `text_info.rs`: Text metadata

**`metadata/`** - Type conversion
- `attributes.rs`: ClxValue → Attributes
- `experiment.rs`: ClxValue → Vec<ExpLoop>
- `text_info.rs`: ClxValue → TextInfo

**`reader.rs`** - Main API
- File opening and version detection
- Lazy metadata loading with caching
- Public interface

**`error.rs`** - Error handling
- All error types using `thiserror`

**`constants.rs`** - Constants
- Magic numbers
- Signatures
- CLX type codes

---

## Error Handling

### Error Types

```rust
pub enum Nd2Error {
    Io(std::io::Error),                    // File I/O errors
    InvalidFormat(String),                 // Malformed file
    InvalidMagic { expected: u32, actual: u32 },
    CorruptChunkHeader { position: u64 },
    ChunkNotFound { name: String },
    InvalidChunkmapSignature,
    ClxParse(String),                      // CLX parsing errors
    UnsupportedClxType(u8),
    Decompression(String),                 // Zlib errors
    Utf16Decode(String),                   // Text encoding errors
    UnsupportedVersion { major: u32, minor: u32 },
    MetadataParse(String),                 // Type conversion errors
}
```

### Error Propagation

All functions return `Result<T>` where `Result<T> = std::result::Result<T, Nd2Error>`.

**Example:**
```rust
pub fn attributes(&mut self) -> Result<&Attributes> {
    if self.attributes.is_none() {
        let chunk_name: &[u8] = if self.version.0 >= 3 {
            b"ImageAttributesLV!"
        } else {
            b"ImageAttributes!"
        };

        // Each ? propagates errors up the call stack
        let data = read_chunk(&mut self.reader, &self.chunkmap, chunk_name)?;
        let parser = ClxLiteParser::new(false);
        let clx = parser.parse(&data)?;
        self.attributes = Some(parse_attributes(clx)?);
    }
    Ok(self.attributes.as_ref().unwrap())
}
```

---

## Performance Considerations

### Lazy Loading

Metadata is loaded on-demand and cached:

```rust
pub struct Nd2File {
    reader: BufReader<File>,
    version: (u32, u32),
    chunkmap: ChunkMap,

    // Cached metadata (loaded on first access)
    attributes: Option<Attributes>,
    experiment: Option<Vec<ExpLoop>>,
    text_info: Option<TextInfo>,
}
```

**Benefits:**
- Faster startup (only reads file header and ChunkMap)
- Lower memory usage (only loads requested metadata)
- No wasted I/O for unused metadata

### Buffered I/O

Uses `BufReader` for efficient file access:

```rust
let file = File::open(path)?;
let mut reader = BufReader::new(file);  // 8KB buffer by default
```

**Benefits:**
- Reduces syscalls
- Better performance for sequential reads
- Automatic read-ahead

### Future Optimizations

**Memory-mapped I/O:**
```rust
// Not yet implemented
use memmap2::Mmap;

let file = File::open(path)?;
let mmap = unsafe { Mmap::map(&file)? };

// Direct memory access, zero-copy
let chunk_data = &mmap[offset..offset+size];
```

**Parallel Chunk Loading:**
```rust
// Not yet implemented
use rayon::prelude::*;

let chunks: Vec<&[u8]> = chunk_names
    .par_iter()
    .map(|name| read_chunk(reader, chunkmap, name))
    .collect()?;
```

---

## Version-Specific Differences

### Chunk Names

| Metadata | v2.0, v2.1 | v3.0 |
|----------|------------|------|
| Attributes | `ImageAttributes!` | `ImageAttributesLV!` |
| Experiment | `ImageMetadata!` | `ImageMetadataLV!` |
| Text Info | `ImageTextInfo!` | `ImageTextInfoLV!` |

The `LV` suffix indicates "Lite Variant" (binary format vs XML).

### Encoding

| Version | Metadata Encoding | Decompression |
|---------|-------------------|---------------|
| 2.0, 2.1 | CLX XML | Optional |
| 3.0 | CLX Lite (binary) | COMPRESS type |

### Detection

```rust
let chunk_name: &[u8] = if self.version.0 >= 3 {
    b"ImageAttributesLV!"
} else {
    b"ImageAttributes!"
};
```

---

## Debugging Tips

### Inspect ChunkMap

```rust
let chunks = nd2.chunk_names();
for chunk in chunks {
    println!("{}", chunk);
}
```

### Read Raw Chunk Data

```rust
let data = nd2.read_raw_chunk(b"ImageAttributesLV!")?;
std::fs::write("chunk_dump.bin", data)?;
```

### Parse CLX Manually

```rust
use nd2::parse::ClxLiteParser;

let parser = ClxLiteParser::new(false);
let clx = parser.parse(&data)?;
println!("{:#?}", clx);
```

### Validate Magic Numbers

```rust
use byteorder::{LittleEndian, ReadBytesExt};

let mut file = File::open("image.nd2")?;
let magic = file.read_u32::<LittleEndian>()?;
assert_eq!(magic, 0x0ABECEDA);
```

---

## Experiment Parsing: Findings & Compatibility

This section documents compatibility fixes made to align nd2-rs experiment parsing with nd2-py. Reference: [nd2-py](https://github.com/tlambert03/nd2) `load_experiment`, `_parse_xy_pos_loop`, `json_from_clx_lite_variant`.

### CLX Lite: ByteArray nested-parsing guard

**Problem:** `looks_like_clx_lite` was too permissive when `name_length <= 1`. Byte arrays like `pItemValid` (144 bytes of 1/0 flags) could be misdetected as nested CLX Lite: byte 0 resembled a type code, byte 1 resembled `name_length`, bytes 2–3 resembled a null terminator. The parser would then try to recursively parse binary data, yielding garbage (e.g. a single `false`) instead of the full validity mask.

**Fix:** Require `name_length > 1` for standalone CLX Lite detection (`clx_lite.rs`). This matches nd2-py’s guard. Small binary fields like `pItemValid` stay as `ByteArray` and are interpreted correctly.

### Experiment structure unwrapping

**Problem:** v3 `ImageMetadataLV!` and `ppNextLevelEx` use nested wrappers: single-key objects (`{"i0000000000": ...}`, `{"SLxExperiment": ...}`), single-element arrays, or objects keyed by `""`. Without unwrapping, `parse_single_loop` receives the wrapper instead of the loop object, and no loop is parsed.

**Fix:** Introduce `unwrap_single_item()` that recurses through:
- Single-element arrays: `[x]` → `x`
- Single-key objects with `i0000000000`, `SLxExperiment`, or `""` → inner value

Apply this when passing `SLxExperiment`, when iterating `ppNextLevelEx` children, and when reading position entries from `Points`.

### ppNextLevelEx: direct loop vs indexed children

**Problem:** In some v3 files, `ppNextLevelEx` is the *loop object itself* (with `eType`, `uLoopPars`, etc.) instead of an indexed container. Iterating `.values()` yields non-object primitives; the actual loop is the parent.

**Fix:** If `ppNextLevelEx` is an object with `eType` or `uiLoopType`, treat it as a single loop child. Otherwise, iterate over sorted keys (for `i0000000000`, `i0000000001`, …) as before.

### XYPosLoop: uLoopPars and count source

**Problem:** Count and points were taken from the wrong place. nd2-py uses `uLoopPars` (with optional `i0000000000` unwrap) and prefers `uiCount` from loop params; positions come from `uLoopPars.Points`.

**Fix:**
- Resolve `params` from `uLoopPars`, unwrapping `i0000000000` when it is the only key.
- Use `params["uiCount"]` (or `obj["uiCount"]`) for loop count.
- Read positions from `params["Points"]` or `params["pPeriod"]`, with keys sorted when `Points` is an object.

### XYPosLoop: pItemValid filtering

**Problem:** `Points` can list many positions (e.g. 144) while only some are valid. nd2-py filters with `pItemValid`: `[p for p, is_valid in zip(out_points, valid) if is_valid]`.

**Fix:**
- Parse `pItemValid` from:
  - `Object`: sort keys, collect bool/u64 values.
  - `Array`: collect bool/u64 values.
  - `ByteArray`: treat each byte as `!= 0`.
- When iterating `Points`, skip index `i` if `valid[i]` is false.

### TimeLoop: parameter keys

**Problem:** nd2-py expects `dStart`, `dPeriod`, `dDuration` in `uLoopPars`; nd2-rs used different names and multipliers.

**Fix:** Use `params` (from `uLoopPars` with unwrap), and read `dStart`, `dPeriod`, `dDuration` directly. Drop incorrect `* 1000.0` where values are already in milliseconds.

### Sequence index and axis order

**Problem:** nd2-rs assumed a fixed order (P,T,C,Z). Actual ND2 layout follows the experiment’s loop order; channel may be in-pixel (not in the sequence).

**Fix:**
- Build `coord_axis_order` from the experiment: axis order = experiment loops (outer to inner) then C.
- When experiment is empty, fall back to P,T,C,Z.
- **In-pixel channels:** When `sequence_count` equals the product of experiment loops, do NOT add C to axis order. Each chunk stores one (P,T) frame with all channels. Add C only when `exp_product * n_chan <= sequence_count`.
- Compute `seq_index` via a row-major ravel in that axis order.
- In `read_frame_2d`, extract the requested channel from the planar (C,Y,X) frame: `frame[c*len..(c+1)*len]`.

---

## References

1. **Python nd2 library**: https://github.com/tlambert03/nd2
2. **Nikon ND2 SDK**: (Proprietary, not publicly documented)
3. **CLX Format**: Custom Nikon format (reverse-engineered)

---

## Contributing

When adding new features, follow this architecture:

1. **New types** → Add to `types/`
2. **Parsing logic** → Add to `metadata/` or `parse/`
3. **Public API** → Expose via `reader.rs`
4. **Error cases** → Add to `Nd2Error` enum
5. **Tests** → Add integration tests

**Example: Adding ROI support**
```
1. types/roi.rs        → ROI, RoiInfo structs
2. metadata/roi.rs     → parse_roi(clx: ClxValue) -> Result<Vec<ROI>>
3. reader.rs           → pub fn rois(&mut self) -> Result<&Vec<ROI>>
4. error.rs            → (Add ROI-specific errors if needed)
```
