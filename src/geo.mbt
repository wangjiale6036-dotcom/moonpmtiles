///|
/// Return the XYZ Web Mercator tile containing a longitude/latitude point.
/// The accepted latitude is the finite Web Mercator extent.
pub fn lon_lat_to_tile(
  longitude : Double,
  latitude : Double,
  z : Int,
) -> ZXY raise PMError {
  if z < 0 ||
    z > 31 ||
    longitude.is_nan() ||
    latitude.is_nan() ||
    longitude < -180.0 ||
    longitude > 180.0 ||
    latitude < -85.05112878 ||
    latitude > 85.05112878 {
    raise Invalid("invalid Web Mercator position or zoom")
  }
  let side = (1L << z).to_double()
  let radians = latitude * @math.PI / 180.0
  let raw_x = @math.floor((longitude + 180.0) / 360.0 * side)
  let raw_y = @math.floor(
    (1.0 - @math.asinh(@math.tan(radians)) / @math.PI) / 2.0 * side,
  )
  let max = side - 1.0
  let x = if raw_x < 0.0 {
    0
  } else if raw_x > max {
    max.to_int()
  } else {
    raw_x.to_int()
  }
  let y = if raw_y < 0.0 {
    0
  } else if raw_y > max {
    max.to_int()
  } else {
    raw_y.to_int()
  }
  { z, x, y }
}

///|
/// Enumerate the XYZ tiles touching a non-wrapping geographic rectangle.
/// A 4096-tile bound prevents accidental whole-world expansion.
pub fn tiles_for_bounds(
  min_lon : Double,
  min_lat : Double,
  max_lon : Double,
  max_lat : Double,
  z : Int,
) -> Array[ZXY] raise PMError {
  if min_lon > max_lon || min_lat > max_lat {
    raise Invalid("bounds must be ordered and not cross the antimeridian")
  }
  let northwest = lon_lat_to_tile(min_lon, max_lat, z)
  let southeast = lon_lat_to_tile(max_lon, min_lat, z)
  let columns = southeast.x.to_int64() - northwest.x.to_int64() + 1L
  let rows = southeast.y.to_int64() - northwest.y.to_int64() + 1L
  if columns < 1L ||
    rows < 1L ||
    columns > 4096L ||
    rows > 4096L ||
    columns * rows > 4096L {
    raise Invalid("tile cover exceeds 4096 tiles")
  }
  let result : Array[ZXY] = []
  let mut y = northwest.y
  while y <= southeast.y {
    let mut x = northwest.x
    while x <= southeast.x {
      result.push({ z, x, y })
      if x == southeast.x {
        break
      }
      x = x + 1
    }
    if y == southeast.y {
      break
    }
    y = y + 1
  }
  result
}
