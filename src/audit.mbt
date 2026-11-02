///|
/// A referenced leaf directory, using an absolute archive byte position.
pub(all) struct LeafRef {
  offset : Int64
  length : Int64
  first_tile_id : Int64
}

///|
pub(all) struct DirectoryAudit {
  leaves : Array[LeafRef]
  tile_entries : Int64
  addressed_tiles : Int64
  referenced_tile_bytes : Int64
}

///|
pub(all) struct ArchiveAudit {
  directories : Int
  compressed_directory_bytes : Int64
  tile_entries : Int64
  addressed_tiles : Int64
  referenced_tile_bytes : Int64
}

///|
priv struct PendingDir {
  offset : Int64
  length : Int64
  depth : Int
}

///|
fn checked_add(a : Int64, b : Int64) -> Int64 raise PMError {
  if a < 0L || b < 0L || b > 9223372036854775807L - a {
    raise Invalid("archive audit counter overflow")
  }
  a + b
}

///|
/// Validate every range referenced by one decompressed directory. Tile
/// contents are not fetched; referenced bytes count deduplicated blobs again.
pub fn audit_directory(
  header : Header,
  data : Bytes,
) -> DirectoryAudit raise PMError {
  let entries = parse_directory(data)
  let leaves : Array[LeafRef] = []
  let mut tile_entries = 0L
  let mut addressed_tiles = 0L
  let mut referenced_tile_bytes = 0L
  for entry in entries {
    if entry.run_length == 0L {
      let offset = checked_range(
        header.leaf_offset,
        header.leaf_length,
        entry.offset,
        entry.length,
      )
      leaves.push({ offset, length: entry.length, first_tile_id: entry.tile_id })
    } else {
      checked_range(
        header.tile_offset,
        header.tile_length,
        entry.offset,
        entry.length,
      )
      |> ignore
      tile_entries = checked_add(tile_entries, 1L)
      addressed_tiles = checked_add(addressed_tiles, entry.run_length)
      referenced_tile_bytes = checked_add(referenced_tile_bytes, entry.length)
    }
  }
  { leaves, tile_entries, addressed_tiles, referenced_tile_bytes }
}

///|
/// Walk all root/leaf directories, checking their ranges and the header's
/// declared tile-entry/addressed-tile counts when those counts are known.
/// The read and decode callbacks must be exact and bounded.
pub fn audit_archive_with_decoder(
  read : (Int64, Int) -> Bytes raise PMError,
  decode : (Int, Bytes) -> Bytes raise PMError,
) -> ArchiveAudit raise PMError {
  let header_bytes = read(0L, 127)
  if header_bytes.length() != 127 {
    raise Invalid("short header range read")
  }
  let header = parse_header(header_bytes)
  if header.internal_compression < 1 || header.internal_compression > 4 {
    raise Invalid("unknown internal compression")
  }
  let pending : Array[PendingDir] = [
    { offset: header.root_offset, length: header.root_length, depth: 0 },
  ]
  let visited : Map[String, Bool] = Map([])
  let mut directories = 0
  let mut compressed_directory_bytes = 0L
  let mut tile_entries = 0L
  let mut addressed_tiles = 0L
  let mut referenced_tile_bytes = 0L
  while pending.length() > 0 {
    if directories >= 20000 {
      raise Invalid("archive contains too many directories")
    }
    let current = pending.pop().unwrap()
    if current.depth > 3 || current.length < 1L || current.length > 8388608L {
      raise Invalid("directory depth or range exceeds limit")
    }
    let key = "\{current.offset}:\{current.length}"
    if visited.contains(key) {
      raise Invalid("directory cycle or duplicate leaf reference")
    }
    visited.set(key, true)
    compressed_directory_bytes = checked_add(
      compressed_directory_bytes,
      current.length,
    )
    if compressed_directory_bytes > 268435456L {
      raise Invalid("archive audit exceeds 256 MiB directory budget")
    }
    let stored = read(current.offset, current.length.to_int())
    if stored.length() != current.length.to_int() {
      raise Invalid("short directory range read")
    }
    let decoded = if header.internal_compression == 1 {
      stored
    } else {
      decode(header.internal_compression, stored)
    }
    let result = audit_directory(header, decoded)
    directories = directories + 1
    tile_entries = checked_add(tile_entries, result.tile_entries)
    addressed_tiles = checked_add(addressed_tiles, result.addressed_tiles)
    referenced_tile_bytes = checked_add(
      referenced_tile_bytes,
      result.referenced_tile_bytes,
    )
    for leaf in result.leaves {
      pending.push({
        offset: leaf.offset,
        length: leaf.length,
        depth: current.depth + 1,
      })
    }
  }
  if header.tile_entries != 0L && header.tile_entries != tile_entries {
    raise Invalid("declared tile-entry count differs from directory tree")
  }
  if header.addressed_tiles != 0L && header.addressed_tiles != addressed_tiles {
    raise Invalid("declared addressed-tile count differs from directory tree")
  }
  {
    directories,
    compressed_directory_bytes,
    tile_entries,
    addressed_tiles,
    referenced_tile_bytes,
  }
}

///|
pub fn audit_archive(
  read : (Int64, Int) -> Bytes raise PMError,
) -> ArchiveAudit raise PMError {
  audit_archive_with_decoder(read, (kind, _) => {
    raise Invalid("unsupported internal compression \{kind}")
  })
}
