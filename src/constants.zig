/// ND2 chunk header magic number
pub const ND2_CHUNK_MAGIC: u32 = 0x0ABECEDA;

/// Legacy JP2 magic number
pub const JP2_MAGIC: u32 = 0x0C00_0000;

/// File signature at the beginning
pub const ND2_FILE_SIGNATURE = "ND2 FILE SIGNATURE CHUNK NAME01!";

/// Signature at the end of file marking chunkmap location
pub const ND2_CHUNKMAP_SIGNATURE = "ND2 CHUNK MAP SIGNATURE 0000001!";

/// Signature at the start of the chunkmap section
pub const ND2_FILEMAP_SIGNATURE = "ND2 FILEMAP SIGNATURE NAME 0001!";

/// CLX Lite data types
pub const clx_types = struct {
    pub const UNKNOWN: u8 = 0;
    pub const BOOL: u8 = 1;
    pub const INT32: u8 = 2;
    pub const UINT32: u8 = 3;
    pub const INT64: u8 = 4;
    pub const UINT64: u8 = 5;
    pub const DOUBLE: u8 = 6;
    pub const VOID_POINTER: u8 = 7;
    pub const STRING: u8 = 8;
    pub const BYTE_ARRAY: u8 = 9;
    pub const DEPRECATED: u8 = 10;
    pub const LEVEL: u8 = 11;
    pub const COMPRESS: u8 = 76; // 'L'
};
