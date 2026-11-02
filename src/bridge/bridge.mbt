///|
fn hex_digit(c : Char) -> Int raise @moonpmtiles.PMError {
  let n = c.to_int()
  if n >= 48 && n <= 57 {
    n - 48
  } else if n >= 65 && n <= 70 {
    n - 65 + 10
  } else if n >= 97 && n <= 102 {
    n - 97 + 10
  } else {
    raise @moonpmtiles.Invalid("non-hexadecimal input")
  }
}

///|
fn from_hex(hex : String, max_bytes : Int) -> Bytes raise @moonpmtiles.PMError {
  let chars = hex.iter().to_array()
  if chars.length() % 2 != 0 || chars.length() / 2 > max_bytes {
    raise @moonpmtiles.Invalid("hex input length outside limit")
  }
  let data : Array[Byte] = []
  for i in 0..<(chars.length() / 2) {
    data.push(
      (hex_digit(chars[i * 2]) * 16 + hex_digit(chars[i * 2 + 1])).to_byte(),
    )
  }
  Bytes::from_array(data)
}

///|
fn invalid(message : String) -> String {
  let output : Json = { "status": "invalid", "message": message }
  output.stringify()
}

///|
/// JS uses decimal strings for byte positions so no 53-bit precision is lost.
pub fn header_hex(header : String) -> String {
  header_hex_checked(header) catch {
    @moonpmtiles.Invalid(message) => invalid(message)
  }
}

///|
fn header_hex_checked(input : String) -> String raise @moonpmtiles.PMError {
  let h = @moonpmtiles.parse_header(from_hex(input, 127))
  let output : Json = {
    "status": "ok",
    "rootOffset": h.root_offset.to_string(),
    "rootLength": h.root_length.to_string(),
    "metadataOffset": h.metadata_offset.to_string(),
    "metadataLength": h.metadata_length.to_string(),
    "minZoom": h.min_zoom,
    "maxZoom": h.max_zoom,
    "tileType": h.tile_type,
    "tileCompression": h.tile_compression,
    "internalCompression": h.internal_compression,
    "addressedTiles": h.addressed_tiles.to_string(),
    "tileEntries": h.tile_entries.to_string(),
    "tileContents": h.tile_contents.to_string(),
  }
  output.stringify()
}

///|
/// One directory transition. Range fetching and decompression happen in the
/// host; all TileID, directory and section decisions happen in MoonBit.
pub fn step_hex(
  header : String,
  z : Int,
  x : Int,
  y : Int,
  directory : String,
) -> String {
  step_hex_checked(header, z, x, y, directory) catch {
    @moonpmtiles.Invalid(message) => invalid(message)
  }
}

///|
fn step_hex_checked(
  header : String,
  z : Int,
  x : Int,
  y : Int,
  directory : String,
) -> String raise @moonpmtiles.PMError {
  let h = @moonpmtiles.parse_header(from_hex(header, 127))
  let id = @moonpmtiles.tile_id(z, x, y)
  if z < h.min_zoom || z > h.max_zoom {
    let result : Json = { "status": "missing" }
    return result.stringify()
  }
  let decoded = from_hex(directory, 8388608)
  match @moonpmtiles.resolve_directory(h, id, decoded) {
    @moonpmtiles.Missing => {
      let result : Json = { "status": "missing" }
      result.stringify()
    }
    @moonpmtiles.Leaf(offset, length) => {
      let result : Json = {
        "status": "leaf",
        "offset": offset.to_string(),
        "length": length.to_string(),
      }
      result.stringify()
    }
    @moonpmtiles.Tile(tile) => {
      let result : Json = {
        "status": "tile",
        "offset": tile.offset.to_string(),
        "length": tile.length.to_string(),
        "compression": tile.compression,
        "tileType": tile.tile_type,
      }
      result.stringify()
    }
  }
}

///|
pub fn mvt_summary_hex(data : String) -> String {
  mvt_summary_hex_checked(data) catch {
    @moonpmtiles.Invalid(message) => invalid(message)
  }
}

///|
fn mvt_summary_hex_checked(data : String) -> String raise @moonpmtiles.PMError {
  let layers = @moonpmtiles.mvt_summary(from_hex(data, 16777216))
  let items : Array[Json] = layers.map(layer => {
    let item : Json = {
      "name": layer.name,
      "features": layer.features,
      "extent": layer.extent,
      "version": layer.version,
    }
    item
  })
  let output : Json = { "status": "ok", "layers": Json::array(items) }
  output.stringify()
}

///|
pub fn cover_bounds_json(
  min_lon : Double,
  min_lat : Double,
  max_lon : Double,
  max_lat : Double,
  z : Int,
) -> String {
  cover_bounds_json_checked(min_lon, min_lat, max_lon, max_lat, z) catch {
    @moonpmtiles.Invalid(message) => invalid(message)
  }
}

///|
fn cover_bounds_json_checked(
  min_lon : Double,
  min_lat : Double,
  max_lon : Double,
  max_lat : Double,
  z : Int,
) -> String raise @moonpmtiles.PMError {
  let cover = @moonpmtiles.tiles_for_bounds(
    min_lon, min_lat, max_lon, max_lat, z,
  )
  let tiles : Array[Json] = cover.map(position => {
    let tile : Json = { "z": position.z, "x": position.x, "y": position.y }
    tile
  })
  let response : Json = {
    "status": "ok",
    "count": cover.length(),
    "tiles": Json::array(tiles),
  }
  response.stringify()
}

///|
pub fn audit_directory_hex(header : String, directory : String) -> String {
  audit_directory_hex_checked(header, directory) catch {
    @moonpmtiles.Invalid(message) => invalid(message)
  }
}

///|
fn audit_directory_hex_checked(
  header : String,
  directory : String,
) -> String raise @moonpmtiles.PMError {
  let h = @moonpmtiles.parse_header(from_hex(header, 127))
  let result = @moonpmtiles.audit_directory(h, from_hex(directory, 8388608))
  let leaves : Array[Json] = result.leaves.map(leaf => {
    let item : Json = {
      "offset": leaf.offset.to_string(),
      "length": leaf.length.to_string(),
      "firstTileId": leaf.first_tile_id.to_string(),
    }
    item
  })
  let response : Json = {
    "status": "ok",
    "leaves": Json::array(leaves),
    "tileEntries": result.tile_entries.to_string(),
    "addressedTiles": result.addressed_tiles.to_string(),
    "referencedTileBytes": result.referenced_tile_bytes.to_string(),
  }
  response.stringify()
}
