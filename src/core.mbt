///|
/// Bounded PMTiles v3 archive parsing and directory lookup.
pub(all) suberror PMError {
  Invalid(String)
}

///|
pub(all) struct Header {
  root_offset : Int64
  root_length : Int64
  metadata_offset : Int64
  metadata_length : Int64
  leaf_offset : Int64
  leaf_length : Int64
  tile_offset : Int64
  tile_length : Int64
  addressed_tiles : Int64
  tile_entries : Int64
  tile_contents : Int64
  clustered : Bool
  internal_compression : Int
  tile_compression : Int
  tile_type : Int
  min_zoom : Int
  max_zoom : Int
  min_lon_e7 : Int
  min_lat_e7 : Int
  max_lon_e7 : Int
  max_lat_e7 : Int
  center_zoom : Int
  center_lon_e7 : Int
  center_lat_e7 : Int
}

///|
pub(all) struct Entry {
  tile_id : Int64
  run_length : Int64
  length : Int64
  offset : Int64
}

///|
pub(all) struct TileRef {
  offset : Int64
  length : Int64
  compression : Int
  tile_type : Int
}

///|
pub(all) enum LookupStep {
  Missing
  Leaf(Int64, Int64)
  Tile(TileRef)
}

///|
pub(all) struct TileData {
  reference : TileRef
  bytes : Bytes
}

///|
pub(all) struct ZXY {
  z : Int
  x : Int
  y : Int
}

///|
fn u8(data : Bytes, i : Int) -> Int raise PMError {
  if i < 0 || i >= data.length() {
    raise Invalid("truncated input")
  }
  data[i].to_int()
}

///|
/// Values above signed Int64 are rejected to avoid wrapped file offsets.
fn u64le(data : Bytes, start : Int) -> Int64 raise PMError {
  let mut result = 0L
  for i in 0..<8 {
    let b = u8(data, start + i)
    if i == 7 && b >= 128 {
      raise Invalid("unsigned integer exceeds signed 64-bit limit")
    }
    result = result | (b.to_int64() << (i * 8))
  }
  result
}

///|
fn i32le(data : Bytes, start : Int) -> Int raise PMError {
  let mut n = 0
  for i in 0..<4 {
    n = n | (u8(data, start + i) << (i * 8))
  }
  n
}

///|
pub fn parse_header(data : Bytes) -> Header raise PMError {
  if data.length() < 127 {
    raise Invalid("header must contain 127 bytes")
  }
  let magic = [80, 77, 84, 105, 108, 101, 115]
  for i in 0..<7 {
    if u8(data, i) != magic[i] {
      raise Invalid("bad PMTiles magic")
    }
  }
  if u8(data, 7) != 3 {
    raise Invalid("only PMTiles version 3 is supported")
  }
  let root_offset = u64le(data, 8)
  let root_length = u64le(data, 16)
  if root_offset < 127L ||
    root_length < 1L ||
    root_offset > 16384L - root_length {
    raise Invalid("root directory must fit in first 16384 bytes")
  }
  let clustered = u8(data, 96)
  if clustered > 1 {
    raise Invalid("invalid clustered flag")
  }
  let min_zoom = u8(data, 100)
  let max_zoom = u8(data, 101)
  if min_zoom > max_zoom || max_zoom > 31 {
    raise Invalid("invalid zoom range")
  }
  let metadata_offset = u64le(data, 24)
  let metadata_length = u64le(data, 32)
  let leaf_offset = u64le(data, 40)
  let leaf_length = u64le(data, 48)
  let tile_offset = u64le(data, 56)
  let tile_length = u64le(data, 64)
  if metadata_offset > 9223372036854775807L - metadata_length ||
    leaf_offset > 9223372036854775807L - leaf_length ||
    tile_offset > 9223372036854775807L - tile_length {
    raise Invalid("section range overflow")
  }
  {
    root_offset,
    root_length,
    metadata_offset,
    metadata_length,
    leaf_offset,
    leaf_length,
    tile_offset,
    tile_length,
    addressed_tiles: u64le(data, 72),
    tile_entries: u64le(data, 80),
    tile_contents: u64le(data, 88),
    clustered: clustered == 1,
    internal_compression: u8(data, 97),
    tile_compression: u8(data, 98),
    tile_type: u8(data, 99),
    min_zoom,
    max_zoom,
    min_lon_e7: i32le(data, 102),
    min_lat_e7: i32le(data, 106),
    max_lon_e7: i32le(data, 110),
    max_lat_e7: i32le(data, 114),
    center_zoom: u8(data, 118),
    center_lon_e7: i32le(data, 119),
    center_lat_e7: i32le(data, 123),
  }
}

///|
/// TileID follows the sequence of Hilbert curves specified by PMTiles v3.
pub fn tile_id(z : Int, x : Int, y : Int) -> Int64 raise PMError {
  if z < 0 || z > 31 || x < 0 || y < 0 {
    raise Invalid("invalid tile coordinates")
  }
  let size = 1L << z
  if x.to_int64() >= size || y.to_int64() >= size {
    raise Invalid("tile coordinates outside zoom")
  }
  let mut xx = x.to_int64()
  let mut yy = y.to_int64()
  let mut s = size / 2L
  let mut d = 0L
  while s > 0L {
    let rx = if (xx & s) != 0L { 1L } else { 0L }
    let ry = if (yy & s) != 0L { 1L } else { 0L }
    d = d + s * s * ((3L * rx) ^ ry)
    if ry == 0L {
      if rx == 1L {
        xx = s - 1L - xx
        yy = s - 1L - yy
      }
      let t = xx
      xx = yy
      yy = t
    }
    s = s / 2L
  }
  let mut base = 0L
  let mut level = 1L
  for i in 0..<z {
    base = base + level
    if i + 1 < z {
      level = level * 4L
    }
  }
  base + d
}

///|
/// Convert a PMTiles TileID back to z/x/y. Useful for directory inspection.
pub fn tile_coords(id : Int64) -> ZXY raise PMError {
  if id < 0L {
    raise Invalid("negative tile ID")
  }
  let mut base = 0L
  let mut width = 1L
  for z in 0..<=31 {
    if id < base + width {
      let mut d = id - base
      let mut x = 0L
      let mut y = 0L
      let mut s = 1L
      let size = 1L << z
      while s < size {
        let rx = (d / 2L) & 1L
        let ry = (d ^ rx) & 1L
        if ry == 0L {
          if rx == 1L {
            x = s - 1L - x
            y = s - 1L - y
          }
          let t = x
          x = y
          y = t
        }
        x = x + s * rx
        y = y + s * ry
        d = d / 4L
        s = s * 2L
      }
      return { z, x: x.to_int(), y: y.to_int() }
    }
    if z < 31 {
      base = base + width
      width = width * 4L
    }
  }
  raise Invalid("tile ID exceeds supported zoom 31")
}

///|
priv struct Cursor {
  bytes : Bytes
  mut pos : Int
}

///|
fn Cursor::varint(self : Cursor) -> Int64 raise PMError {
  let mut n = 0L
  for i in 0..<9 {
    let b = u8(self.bytes, self.pos)
    self.pos = self.pos + 1
    n = n | ((b & 127).to_int64() << (7 * i))
    if b < 128 {
      return n
    }
  }
  raise Invalid("varint exceeds supported 63-bit range")
}

///|
/// Directory bytes must already be decompressed. 8 MiB / 1 million entry bounds.
pub fn parse_directory(data : Bytes) -> Array[Entry] raise PMError {
  if data.length() > 8388608 {
    raise Invalid("directory exceeds 8 MiB limit")
  }
  let c : Cursor = { bytes: data, pos: 0 }
  let count64 = c.varint()
  if count64 < 1L || count64 > 1000000L {
    raise Invalid("invalid directory entry count")
  }
  let count = count64.to_int()
  let ids : Array[Int64] = []
  let runs : Array[Int64] = []
  let lengths : Array[Int64] = []
  let mut last = 0L
  for i in 0..<count {
    let delta = c.varint()
    if i > 0 && delta == 0L {
      raise Invalid("directory tile IDs must increase")
    }
    if delta > 9223372036854775807L - last {
      raise Invalid("tile ID overflow")
    }
    last = last + delta
    ids.push(last)
  }
  for _ in 0..<count {
    runs.push(c.varint())
  }
  for i in 0..<count {
    let run = runs[i]
    if run > 0L {
      if run - 1L > 9223372036854775807L - ids[i] {
        raise Invalid("tile run exceeds supported ID range")
      }
      if i + 1 < count && run > ids[i + 1] - ids[i] {
        raise Invalid("tile runs overlap subsequent directory entry")
      }
    }
  }
  for _ in 0..<count {
    let len = c.varint()
    if len == 0L {
      raise Invalid("zero-length entry")
    }
    lengths.push(len)
  }
  let entries : Array[Entry] = []
  for i in 0..<count {
    let encoded = c.varint()
    let offset = if encoded == 0L {
      if i == 0 {
        raise Invalid("first offset cannot use contiguous encoding")
      }
      let previous = entries[i - 1]
      if previous.offset > 9223372036854775807L - previous.length {
        raise Invalid("offset overflow")
      }
      previous.offset + previous.length
    } else {
      encoded - 1L
    }
    entries.push({
      tile_id: ids[i],
      run_length: runs[i],
      length: lengths[i],
      offset,
    })
  }
  if c.pos != data.length() {
    raise Invalid("trailing directory bytes")
  }
  entries
}

///|
fn push_varint(out : Array[Byte], n : Int64) -> Unit raise PMError {
  if n < 0L {
    raise Invalid("negative directory varint")
  }
  let mut value = n
  while value > 127L {
    out.push(((value & 127L).to_int() | 128).to_byte())
    value = value >> 7
  }
  out.push(value.to_int().to_byte())
}

///|
/// Serialize a pre-sorted directory. This is also useful to build small
/// fixtures without depending on a JavaScript PMTiles writer.
pub fn encode_directory(entries : Array[Entry]) -> Bytes raise PMError {
  if entries.length() < 1 || entries.length() > 1000000 {
    raise Invalid("invalid directory entry count")
  }
  let mut last = 0L
  for i in 0..<entries.length() {
    let entry = entries[i]
    if entry.tile_id < last ||
      (i > 0 && entry.tile_id == last) ||
      entry.run_length < 0L ||
      (
        entry.run_length > 0L &&
        entry.run_length - 1L > 9223372036854775807L - entry.tile_id
      ) ||
      entry.length < 1L ||
      entry.offset < 0L ||
      entry.offset > 9223372036854775807L - entry.length {
      raise Invalid("invalid directory entry")
    }
    if i + 1 < entries.length() &&
      entry.run_length > 0L &&
      entry.run_length > entries[i + 1].tile_id - entry.tile_id {
      raise Invalid("overlapping directory runs")
    }
    last = entry.tile_id
  }
  let out : Array[Byte] = []
  push_varint(out, entries.length().to_int64())
  last = 0L
  for entry in entries {
    push_varint(out, entry.tile_id - last)
    last = entry.tile_id
  }
  for entry in entries {
    push_varint(out, entry.run_length)
  }
  for entry in entries {
    push_varint(out, entry.length)
  }
  for i in 0..<entries.length() {
    let entry = entries[i]
    if i > 0 && entry.offset == entries[i - 1].offset + entries[i - 1].length {
      push_varint(out, 0L)
    } else {
      if entry.offset == 9223372036854775807L {
        raise Invalid("directory offset overflow")
      }
      push_varint(out, entry.offset + 1L)
    }
  }
  if out.length() > 8388608 {
    raise Invalid("directory exceeds 8 MiB limit")
  }
  Bytes::from_array(out)
}

///|
fn entry_for(entries : Array[Entry], id : Int64) -> Entry? {
  let mut lo = 0
  let mut hi = entries.length()
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    if entries[mid].tile_id <= id {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  if lo == 0 {
    return None
  }
  let entry = entries[lo - 1]
  if entry.run_length == 0L || id - entry.tile_id < entry.run_length {
    Some(entry)
  } else {
    None
  }
}

///|
fn checked_range(
  base : Int64,
  section_length : Int64,
  offset : Int64,
  length : Int64,
) -> Int64 raise PMError {
  if offset < 0L ||
    length < 1L ||
    offset > section_length ||
    length > section_length - offset ||
    base > 9223372036854775807L - offset {
    raise Invalid("entry outside declared section")
  }
  let absolute = base + offset
  if absolute > 9223372036854775807L - length {
    raise Invalid("absolute range overflow")
  }
  absolute
}

///|
/// Resolve one *decompressed* root or leaf directory. The caller performs
/// the indicated range read and repeats this operation for a Leaf result.
pub fn resolve_directory(
  header : Header,
  id : Int64,
  directory : Bytes,
) -> LookupStep raise PMError {
  if id < 0L {
    raise Invalid("negative tile ID")
  }
  match entry_for(parse_directory(directory), id) {
    None => Missing
    Some(entry) =>
      if entry.run_length == 0L {
        Leaf(
          checked_range(
            header.leaf_offset,
            header.leaf_length,
            entry.offset,
            entry.length,
          ),
          entry.length,
        )
      } else {
        Tile({
          offset: checked_range(
            header.tile_offset,
            header.tile_length,
            entry.offset,
            entry.length,
          ),
          length: entry.length,
          compression: header.tile_compression,
          tile_type: header.tile_type,
        })
      }
  }
}

///|
/// Read exact byte ranges, and supply a decoder for gzip/brotli/zstd directories.
/// The decoder must enforce its own decompression memory limit. Tile bytes are not decoded.
pub fn locate_with_decoder(
  read : (Int64, Int) -> Bytes raise PMError,
  decode : (Int, Bytes) -> Bytes raise PMError,
  z : Int,
  x : Int,
  y : Int,
) -> TileRef? raise PMError {
  let header_bytes = read(0L, 127)
  if header_bytes.length() != 127 {
    raise Invalid("short header range read")
  }
  let h = parse_header(header_bytes)
  if h.internal_compression < 1 || h.internal_compression > 4 {
    raise Invalid("unknown internal compression")
  }
  let id = tile_id(z, x, y)
  if z < h.min_zoom || z > h.max_zoom {
    return None
  }
  let mut offset = h.root_offset
  let mut len = h.root_length
  for _ in 0..<4 {
    if len < 1L || len > 8388608L {
      raise Invalid("directory range exceeds limit")
    }
    let bytes = read(offset, len.to_int())
    if bytes.length() != len.to_int() {
      raise Invalid("short directory range read")
    }
    let decoded = if h.internal_compression == 1 {
      bytes
    } else {
      decode(h.internal_compression, bytes)
    }
    match resolve_directory(h, id, decoded) {
      Missing => return None
      Tile(tile) => return Some(tile)
      Leaf(next_offset, next_len) => {
        offset = next_offset
        len = next_len
      }
    }
  }
  raise Invalid("directory depth exceeds limit")
}

///|
/// Convenience entry point for archives with uncompressed directories.
pub fn locate(
  read : (Int64, Int) -> Bytes raise PMError,
  z : Int,
  x : Int,
  y : Int,
) -> TileRef? raise PMError {
  locate_with_decoder(
    read,
    (kind, _) => raise Invalid("unsupported internal compression \{kind}"),
    z,
    x,
    y,
  )
}

///|
/// Read a tile's stored bytes, preserving the header's compression tag.
/// The caller can decode MVT or image content using the returned tile type.
pub fn read_tile_with_decoder(
  read : (Int64, Int) -> Bytes raise PMError,
  decode : (Int, Bytes) -> Bytes raise PMError,
  z : Int,
  x : Int,
  y : Int,
) -> TileData? raise PMError {
  match locate_with_decoder(read, decode, z, x, y) {
    None => None
    Some(reference) => {
      if reference.length > 33554432L {
        raise Invalid("tile exceeds 32 MiB read limit")
      }
      let bytes = read(reference.offset, reference.length.to_int())
      if bytes.length() != reference.length.to_int() {
        raise Invalid("short tile range read")
      }
      Some({ reference, bytes })
    }
  }
}

///|
pub fn read_tile(
  read : (Int64, Int) -> Bytes raise PMError,
  z : Int,
  x : Int,
  y : Int,
) -> TileData? raise PMError {
  read_tile_with_decoder(
    read,
    (kind, _) => raise Invalid("unsupported internal compression \{kind}"),
    z,
    x,
    y,
  )
}

///|
/// Read metadata's stored bytes. Decode them using internal_compression
/// before parsing the UTF-8 JSON object.
pub fn read_metadata(
  read : (Int64, Int) -> Bytes raise PMError,
) -> (Header, Bytes) raise PMError {
  let header = parse_header(read(0L, 127))
  if header.metadata_length > 8388608L {
    raise Invalid("metadata exceeds 8 MiB read limit")
  }
  let raw = read(header.metadata_offset, header.metadata_length.to_int())
  if raw.length() != header.metadata_length.to_int() {
    raise Invalid("short metadata range read")
  }
  (header, raw)
}
