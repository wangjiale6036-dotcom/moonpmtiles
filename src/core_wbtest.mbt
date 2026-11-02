///|
test "lookup uses runs and gaps and leaf ranges" {
  let entries : Array[Entry] = [
    { tile_id: 5L, run_length: 3L, length: 4L, offset: 0L },
    { tile_id: 10L, run_length: 1L, length: 5L, offset: 4L },
    { tile_id: 20L, run_length: 0L, length: 5L, offset: 0L },
  ]
  assert_true(entry_for(entries, 4L) is None)
  assert_eq(entry_for(entries, 7L).unwrap().tile_id, 5L)
  assert_true(entry_for(entries, 8L) is None)
  assert_true(entry_for(entries, 11L) is None)
  assert_eq(entry_for(entries, 22L).unwrap().run_length, 0L)
}

///|
test "first implicit offset and overflowing varint are rejected" {
  let implicit = try {
    parse_directory(b"\x01\x00\x01\x01\x00") |> ignore
    false
  } catch {
    Invalid(_) => true
  }
  let overflowing = try {
    parse_directory(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01") |> ignore
    false
  } catch {
    Invalid(_) => true
  }
  assert_true(implicit)
  assert_true(overflowing)
}

///|
test "encoder rejects a tile run outside the supported ID range" {
  let invalid : Array[Entry] = [
    { tile_id: 9223372036854775807L, run_length: 2L, length: 1L, offset: 0L },
  ]
  let rejected = try {
    encode_directory(invalid) |> ignore
    false
  } catch {
    Invalid(_) => true
  }
  assert_true(rejected)
}
