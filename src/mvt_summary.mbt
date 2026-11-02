///|
/// A small consumer of stored MVT tile bytes. It checks the protobuf
/// envelope and reports layer names/counts; it does not decode geometry.
pub(all) struct LayerSummary {
  name : String
  features : Int
  extent : Int
  version : Int
}

///|
fn protobuf_blob(c : Cursor) -> Bytes raise PMError {
  let length64 = c.varint()
  if length64 > 16777216L || length64 > (c.bytes.length() - c.pos).to_int64() {
    raise Invalid("truncated or oversized protobuf field")
  }
  let length = length64.to_int()
  let start = c.pos
  c.pos = c.pos + length
  c.bytes[start:c.pos].to_owned()
}

///|
fn protobuf_skip(c : Cursor, wire : Int) -> Unit raise PMError {
  match wire {
    0 => c.varint() |> ignore
    1 => {
      if c.pos > c.bytes.length() - 8 {
        raise Invalid("truncated 64-bit protobuf field")
      }
      c.pos = c.pos + 8
    }
    2 => protobuf_blob(c) |> ignore
    5 => {
      if c.pos > c.bytes.length() - 4 {
        raise Invalid("truncated 32-bit protobuf field")
      }
      c.pos = c.pos + 4
    }
    _ => raise Invalid("unsupported protobuf wire type")
  }
}

///|
fn parse_layer_summary(data : Bytes) -> LayerSummary raise PMError {
  let c : Cursor = { bytes: data, pos: 0 }
  let mut name = ""
  let mut feature_count = 0
  let mut extent = 4096
  let mut version = 0
  let mut fields = 0
  while c.pos < data.length() {
    fields = fields + 1
    if fields > 1000000 {
      raise Invalid("too many MVT fields")
    }
    let key = c.varint()
    let field = key >> 3
    let wire = (key & 7L).to_int()
    if field == 0L {
      raise Invalid("invalid protobuf field number")
    }
    if field == 1L && wire == 2 {
      let raw = protobuf_blob(c)
      name = @utf8.decode(raw) catch {
        _ => raise Invalid("MVT layer name is not UTF-8")
      }
    } else if field == 2L && wire == 2 {
      protobuf_blob(c) |> ignore
      feature_count = feature_count + 1
    } else if field == 5L && wire == 0 {
      let n = c.varint()
      if n < 1L || n > 2147483647L {
        raise Invalid("invalid MVT extent")
      }
      extent = n.to_int()
    } else if field == 15L && wire == 0 {
      let n = c.varint()
      if n > 2147483647L {
        raise Invalid("invalid MVT version")
      }
      version = n.to_int()
    } else {
      protobuf_skip(c, wire)
    }
  }
  if name == "" || version < 1 {
    raise Invalid("MVT layer has no name or version")
  }
  { name, features: feature_count, extent, version }
}

///|
pub fn mvt_summary(data : Bytes) -> Array[LayerSummary] raise PMError {
  if data.length() < 1 || data.length() > 16777216 {
    raise Invalid("MVT tile size outside limit")
  }
  let c : Cursor = { bytes: data, pos: 0 }
  let layers : Array[LayerSummary] = []
  let mut fields = 0
  while c.pos < data.length() {
    fields = fields + 1
    if fields > 1000000 {
      raise Invalid("too many MVT fields")
    }
    let key = c.varint()
    let field = key >> 3
    let wire = (key & 7L).to_int()
    if field == 0L {
      raise Invalid("invalid protobuf field number")
    }
    if field == 3L && wire == 2 {
      if layers.length() >= 10000 {
        raise Invalid("too many MVT layers")
      }
      layers.push(parse_layer_summary(protobuf_blob(c)))
    } else {
      protobuf_skip(c, wire)
    }
  }
  if layers.length() == 0 {
    raise Invalid("MVT tile has no layers")
  }
  layers
}
