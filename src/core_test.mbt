///|
fn set64(a : Array[Byte], at : Int, n : Int64) -> Unit {
  for i in 0..<8 {
    a[at + i] = ((n >> (i * 8)) & 255L).to_int().to_byte()
  }
}

///|
fn fixture(leaf : Bool, compression : Int) -> Bytes {
  let size = if leaf { 140 } else { 135 }
  let data : Array[Byte] = Array::make(size, (0).to_byte())
  let magic = [80, 77, 84, 105, 108, 101, 115, 3]
  for i in 0..<magic.length() {
    data[i] = magic[i].to_byte()
  }
  set64(data, 8, 127L)
  set64(data, 16, 5L)
  set64(data, 40, 132L)
  set64(data, 48, if leaf { 5L } else { 0L })
  set64(data, 56, if leaf { 137L } else { 132L })
  set64(data, 64, 3L)
  data[97] = compression.to_byte()
  data[98] = (1).to_byte()
  data[99] = (2).to_byte()
  let root = [1, 0, if leaf { 0 } else { 1 }, if leaf { 5 } else { 3 }, 1]
  for i in 0..<5 {
    data[127 + i] = root[i].to_byte()
  }
  if leaf {
    let child = [1, 0, 1, 3, 1]
    for i in 0..<5 {
      data[132 + i] = child[i].to_byte()
    }
  }
  Bytes::from_array(data)
}

///|
fn reader(data : Bytes) -> (Int64, Int) -> Bytes raise @moonpmtiles.PMError {
  (offset, length) => {
    let start = offset.to_int()
    if start < 0 || length < 0 || start > data.length() - length {
      b""
    } else {
      data[start:start + length].to_owned()
    }
  }
}

///|
test "specification Hilbert vectors and invalid coordinate" {
  assert_eq(@moonpmtiles.tile_id(0, 0, 0), 0L)
  assert_eq(@moonpmtiles.tile_id(1, 0, 0), 1L)
  assert_eq(@moonpmtiles.tile_id(1, 0, 1), 2L)
  assert_eq(@moonpmtiles.tile_id(1, 1, 1), 3L)
  assert_eq(@moonpmtiles.tile_id(1, 1, 0), 4L)
  assert_eq(@moonpmtiles.tile_id(2, 0, 0), 5L)
  assert_eq(@moonpmtiles.tile_id(12, 3423, 1763), 19078479L)
  assert_eq(@moonpmtiles.tile_id(31, 0, 0), 1537228672809129301L)
  assert_eq(@moonpmtiles.tile_id(31, 2147483647, 0), 6148914691236517204L)
  let failed = try {
    @moonpmtiles.tile_id(1, 2, 0) |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(failed)
}

///|
test "zoom 3 tile IDs match upstream reference across the whole grid" {
  // Captured from the PMTiles JavaScript reference zxyToTileId, y-major.
  let expected = [
    21L, 24L, 25L, 26L, 79L, 80L, 81L, 84L, 22L, 23L, 28L, 27L, 78L, 77L, 82L, 83L,
    35L, 34L, 29L, 30L, 75L, 76L, 71L, 70L, 36L, 33L, 32L, 31L, 74L, 73L, 72L, 69L,
    37L, 38L, 51L, 52L, 53L, 54L, 67L, 68L, 40L, 39L, 50L, 49L, 56L, 55L, 66L, 65L,
    41L, 44L, 45L, 48L, 57L, 60L, 61L, 64L, 42L, 43L, 46L, 47L, 58L, 59L, 62L, 63L,
  ]
  for y in 0..<8 {
    for x in 0..<8 {
      assert_eq(@moonpmtiles.tile_id(3, x, y), expected[y * 8 + x])
    }
  }
}

///|
test "range lookup follows root and leaf directories" {
  let direct = @moonpmtiles.locate(reader(fixture(false, 1)), 0, 0, 0).unwrap()
  assert_eq(direct.offset, 132L)
  assert_eq(direct.length, 3L)
  let via_leaf = @moonpmtiles.locate(reader(fixture(true, 1)), 0, 0, 0).unwrap()
  assert_eq(via_leaf.offset, 137L)
  assert_eq(via_leaf.tile_type, 2)
}

///|
test "directory deltas contiguous offsets and run lengths" {
  // Entries: ID 5, run 2, len 3, offset 0; ID 10, run 1, len 4, offset 3.
  let d = @moonpmtiles.parse_directory(b"\x02\x05\x05\x02\x01\x03\x04\x01\x00")
  assert_eq(d.length(), 2)
  assert_eq(d[0].tile_id, 5L)
  assert_eq(d[1].tile_id, 10L)
  assert_eq(d[1].offset, 3L)
  assert_eq(d[0].run_length, 2L)
}

///|
test "overlapping tile runs are rejected" {
  // IDs 5 and 7: a run of 3 at 5 would also cover the second entry.
  let overlap = try {
    @moonpmtiles.parse_directory(b"\x02\x05\x02\x03\x01\x01\x01\x01\x00")
    |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(overlap)
  // A run ending immediately before the next entry is valid.
  let adjacent = @moonpmtiles.parse_directory(
    b"\x02\x05\x02\x02\x01\x01\x01\x01\x00",
  )
  assert_eq(adjacent.length(), 2)
  let overflow = try {
    @moonpmtiles.parse_directory(
      b"\x01\xff\xff\xff\xff\xff\xff\xff\xff\x7f\x02\x01\x01",
    )
    |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(overflow)
}

///|
test "compressed directory requires explicit decoder" {
  let data = fixture(false, 2)
  let rejected = try {
    @moonpmtiles.locate(reader(data), 0, 0, 0) |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(rejected)
  let calls = [0]
  let result = @moonpmtiles.locate_with_decoder(
    reader(data),
    (kind, bytes) => {
      if kind != 2 {
        raise @moonpmtiles.Invalid("wrong decoder kind")
      }
      calls[0] = calls[0] + 1
      bytes
    },
    0,
    0,
    0,
  ).unwrap()
  assert_eq(calls[0], 1)
  assert_eq(result.offset, 132L)
}

///|
test "truncated headers and invalid directories fail" {
  let short = try {
    @moonpmtiles.parse_header(b"PMTiles\x03") |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  let bad = try {
    @moonpmtiles.parse_directory(b"\x01\x00\x01\x00\x01") |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(short)
  assert_true(bad)
}

///|
test "TileID inverse covers grids and signed 64-bit boundary" {
  for z in 0..<6 {
    let side = 1 << z
    for x in 0..<side {
      for y in 0..<side {
        let coords = @moonpmtiles.tile_coords(@moonpmtiles.tile_id(z, x, y))
        assert_eq(coords.z, z)
        assert_eq(coords.x, x)
        assert_eq(coords.y, y)
      }
    }
  }
  let edge = @moonpmtiles.tile_coords(@moonpmtiles.tile_id(31, 2147483647, 0))
  assert_eq(edge.x, 2147483647)
  assert_eq(edge.y, 0)
  let too_large = try {
    @moonpmtiles.tile_coords(6148914691236517205L) |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(too_large)
}

///|
test "directory encoder round trips runs and contiguous offsets" {
  let entries : Array[@moonpmtiles.Entry] = [
    { tile_id: 5L, run_length: 2L, length: 7L, offset: 0L },
    { tile_id: 8L, run_length: 1L, length: 3L, offset: 7L },
  ]
  let decoded = @moonpmtiles.parse_directory(
    @moonpmtiles.encode_directory(entries),
  )
  assert_eq(decoded.length(), 2)
  assert_eq(decoded[0].tile_id, 5L)
  assert_eq(decoded[0].run_length, 2L)
  assert_eq(decoded[1].offset, 7L)
  let invalid = try {
    @moonpmtiles.encode_directory([
      { tile_id: 5L, run_length: 4L, length: 7L, offset: 0L },
      { tile_id: 8L, run_length: 1L, length: 3L, offset: 7L },
    ])
    |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(invalid)
}

///|
test "MoonBit MVT consumer reports a real layer envelope" {
  let layers = @moonpmtiles.mvt_summary(
    b"\x1a\x17\x78\x02\x0a\x05world\x12\x09\x08\x0a\x18\x01\x22\x03\x09\x00\x00\x28\x80\x20",
  )
  assert_eq(layers.length(), 1)
  assert_eq(layers[0].name, "world")
  assert_eq(layers[0].features, 1)
  assert_eq(layers[0].version, 2)
  let malformed = try {
    @moonpmtiles.mvt_summary(b"\x1a\x05bad") |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(malformed)
}

///|
test "tile read separates missing from truncated and source errors" {
  let data = fixture(false, 1)
  let found = @moonpmtiles.read_tile(reader(data), 0, 0, 0).unwrap()
  assert_eq(found.bytes.length(), 3)
  assert_true(@moonpmtiles.read_tile(reader(data), 1, 0, 0) is None)
  let failed = try {
    @moonpmtiles.read_tile(
      (offset, length) => {
        if offset == 132L {
          b""
        } else {
          reader(data)(offset, length)
        }
      },
      0,
      0,
      0,
    )
    |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(failed)
}

///|
test "Web Mercator point conversion and bounded rectangle cover" {
  let center = @moonpmtiles.lon_lat_to_tile(0.0, 0.0, 1)
  assert_eq(center.x, 1)
  assert_eq(center.y, 1)
  let sf = @moonpmtiles.lon_lat_to_tile(-122.4194, 37.7749, 10)
  assert_eq(sf.x, 163)
  assert_eq(sf.y, 395)
  let east = @moonpmtiles.lon_lat_to_tile(180.0, 0.0, 31)
  assert_eq(east.x, 2147483647)
  let cover = @moonpmtiles.tiles_for_bounds(-1.0, -1.0, 1.0, 1.0, 1)
  assert_eq(cover.length(), 4)
  let edge = @moonpmtiles.tiles_for_bounds(180.0, 0.0, 180.0, 0.0, 31)
  assert_eq(edge.length(), 1)
  assert_eq(edge[0].x, 2147483647)
  let huge = try {
    @moonpmtiles.tiles_for_bounds(-180.0, -85.0, 180.0, 85.0, 7) |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(huge)
}

///|
test "archive audit checks every directory and declared counts" {
  let direct = @moonpmtiles.audit_archive(reader(fixture(false, 1)))
  assert_eq(direct.directories, 1)
  assert_eq(direct.tile_entries, 1L)
  assert_eq(direct.addressed_tiles, 1L)
  let leaf = @moonpmtiles.audit_archive(reader(fixture(true, 1)))
  assert_eq(leaf.directories, 2)
  assert_eq(leaf.compressed_directory_bytes, 10L)
  assert_eq(leaf.referenced_tile_bytes, 3L)

  let wrong_count = fixture(true, 1).to_array()
  set64(wrong_count, 72, 2L)
  let mismatched = try {
    @moonpmtiles.audit_archive(reader(Bytes::from_array(wrong_count))) |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(mismatched)

  let cycle = fixture(true, 1).to_array()
  cycle[134] = (0).to_byte()
  cycle[135] = (5).to_byte()
  let rejected = try {
    @moonpmtiles.audit_archive(reader(Bytes::from_array(cycle))) |> ignore
    false
  } catch {
    @moonpmtiles.Invalid(_) => true
  }
  assert_true(rejected)
}
