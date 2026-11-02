import {open} from 'node:fs/promises';
import {gunzipSync, brotliDecompressSync, zstdDecompressSync} from 'node:zlib';
import {header_hex, step_hex, mvt_summary_hex, cover_bounds_json, audit_directory_hex} from './dist/engine.mjs';

const MAX_DIRECTORY = 8 * 1024 * 1024;
const MAX_TILE = 32 * 1024 * 1024;
const MAX_DECODED_TILE = 64 * 1024 * 1024;
const MAX_MVT_SUMMARY = 16 * 1024 * 1024;
const MAX_METADATA = 8 * 1024 * 1024;
const MAX_SAFE = BigInt(Number.MAX_SAFE_INTEGER);

function assertRange(offset, length, limit = MAX_TILE) {
  if (typeof offset !== 'bigint' || offset < 0n || offset > MAX_SAFE ||
      !Number.isSafeInteger(length) || length < 1 || length > limit ||
      offset + BigInt(length) > MAX_SAFE) {
    throw new Error('range exceeds supported address or read limit');
  }
}

function parseResult(json) {
  const result = JSON.parse(json);
  if (result.status === 'invalid') throw new Error(`PMTiles: ${result.message}`);
  return result;
}

async function readLimited(response, expected) {
  const reader = response.body?.getReader();
  if (!reader) throw new Error('range response has no body');
  const chunks = [];
  let size = 0;
  try {
    for (;;) {
      const {value, done} = await reader.read();
      if (done) break;
      size += value.length;
      if (size > expected) throw new Error('range response exceeds requested length');
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel();
    throw error;
  } finally {
    reader.releaseLock();
  }
  if (size !== expected) throw new Error(`short range read: ${size} of ${expected}`);
  return Buffer.concat(chunks, size);
}

export class FileRangeSource {
  static async open(path) {
    const handle = await open(path, 'r');
    try { return new FileRangeSource(handle, await handle.stat()); }
    catch (error) { await handle.close(); throw error; }
  }

  constructor(handle, initial) {
    this.handle = handle;
    this.initial = initial;
    this.requests = [];
  }

  async read(offset, length) {
    assertRange(offset, length);
    const current = await this.handle.stat();
    if (current.size !== this.initial.size ||
        current.mtimeMs !== this.initial.mtimeMs ||
        current.ctimeMs !== this.initial.ctimeMs) {
      throw new Error('file changed during range reads');
    }
    if (offset + BigInt(length) > BigInt(current.size)) {
      throw new Error('range outside file');
    }
    const result = Buffer.alloc(length);
    let received = 0;
    while (received < length) {
      const {bytesRead} = await this.handle.read(result, received, length - received, Number(offset) + received);
      if (bytesRead === 0) throw new Error('short file range read');
      received += bytesRead;
    }
    this.requests.push({offset: offset.toString(), length});
    return result;
  }

  async close() { await this.handle.close(); }
}

export class HttpRangeSource {
  constructor(url, fetchImpl = fetch, {requireValidator = true} = {}) {
    this.url = url;
    this.fetchImpl = fetchImpl;
    this.requireValidator = requireValidator;
    this.etag = undefined;
    this.lastModified = undefined;
    this.total = undefined;
    this.requests = [];
  }

  async read(offset, length) {
    assertRange(offset, length);
    const end = offset + BigInt(length) - 1n;
    const headers = {'Range': `bytes=${offset}-${end}`, 'Accept-Encoding': 'identity'};
    if (this.etag) headers['If-Range'] = this.etag;
    else if (this.lastModified) headers['If-Range'] = this.lastModified;
    let response;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        response = await this.fetchImpl(this.url, {
          headers,
          signal: AbortSignal.timeout(30000),
        });
        break;
      } catch (error) {
        if (attempt === 2) throw error;
      }
    }
    if (response.status !== 206) {
      await response.body?.cancel();
      throw new Error(`server did not honor byte range (HTTP ${response.status})`);
    }
    const contentRange = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range') || '');
    if (!contentRange || BigInt(contentRange[1]) !== offset ||
        BigInt(contentRange[2]) !== end || BigInt(contentRange[3]) <= end) {
      await response.body?.cancel();
      throw new Error('invalid Content-Range');
    }
    const total = BigInt(contentRange[3]);
    if (this.total !== undefined && total !== this.total) {
      await response.body?.cancel();
      throw new Error('archive size changed during range reads');
    }
    this.total = total;
    const encoding = response.headers.get('content-encoding');
    if (encoding && encoding.toLowerCase() !== 'identity') {
      await response.body?.cancel();
      throw new Error('range response applied HTTP content encoding');
    }
    const etag = response.headers.get('etag') || undefined;
    const strongEtag = etag && !/^W\//i.test(etag) ? etag : undefined;
    const lastModified = response.headers.get('last-modified') || undefined;
    if (this.etag && strongEtag !== this.etag ||
        !this.etag && this.lastModified && lastModified !== this.lastModified) {
      await response.body?.cancel();
      throw new Error('archive version changed during range reads');
    }
    if (!this.etag && !this.lastModified && this.requireValidator &&
        !strongEtag && !lastModified) {
      await response.body?.cancel();
      throw new Error('HTTP archive has no strong ETag or Last-Modified validator');
    }
    if (this.etag === undefined && strongEtag) this.etag = strongEtag;
    if (this.lastModified === undefined && lastModified) this.lastModified = lastModified;
    const declared = response.headers.get('content-length');
    if (declared !== null && BigInt(declared) !== BigInt(length)) {
      await response.body?.cancel();
      throw new Error('incorrect Content-Length');
    }
    const data = await readLimited(response, length);
    this.requests.push({offset: offset.toString(), length});
    return data;
  }

  async close() {}
}

export async function openSource(pathOrUrl) {
  if (/^https?:\/\//i.test(pathOrUrl)) return new HttpRangeSource(pathOrUrl);
  return FileRangeSource.open(pathOrUrl);
}

function decompress(kind, data, maxOutput) {
  if (kind === 1) {
    if (data.length > maxOutput) throw new Error('uncompressed section exceeds limit');
    return data;
  }
  try {
    const options = {maxOutputLength: maxOutput};
    if (kind === 2) return gunzipSync(data, options);
    if (kind === 3) return brotliDecompressSync(data, options);
    if (kind === 4 && typeof zstdDecompressSync === 'function') {
      return zstdDecompressSync(data, options);
    }
  } catch (error) {
    throw new Error(`invalid or oversized compressed data: ${error.message}`);
  }
  throw new Error(`unsupported compression kind ${kind}`);
}

function exactInteger(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`invalid ${name}`);
  return value;
}

export class Archive {
  static async open(source) {
    const headerBytes = await source.read(0n, 127);
    const header = parseResult(header_hex(headerBytes.toString('hex')));
    return new Archive(source, headerBytes.toString('hex'), header);
  }

  constructor(source, headerHex, header) {
    this.source = source;
    this.headerHex = headerHex;
    this.header = header;
    this.directoryCache = new Map();
    this.directoryCacheBytes = 0;
  }

  async metadata() {
    const length = Number(this.header.metadataLength);
    if (!Number.isSafeInteger(length) || length < 1 || length > MAX_METADATA) {
      throw new Error('metadata length outside limit');
    }
    const stored = await this.source.read(BigInt(this.header.metadataOffset), length);
    const bytes = decompress(this.header.internalCompression, stored, MAX_METADATA);
    let object;
    try { object = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes)); }
    catch (error) { throw new Error(`invalid metadata JSON: ${error.message}`); }
    if (object === null || typeof object !== 'object' || Array.isArray(object)) {
      throw new Error('PMTiles metadata must be a JSON object');
    }
    return object;
  }

  async directory(offset, length) {
    if (!Number.isSafeInteger(length) || length < 1 || length > MAX_DIRECTORY) {
      throw new Error('directory range outside limit');
    }
    const key = `${offset}:${length}`;
    let decoded = this.directoryCache.get(key);
    if (decoded) {
      this.directoryCache.delete(key);
      this.directoryCache.set(key, decoded);
      return decoded;
    }
    const stored = await this.source.read(offset, length);
    decoded = decompress(this.header.internalCompression, stored, MAX_DIRECTORY);
    if (decoded.length <= MAX_DIRECTORY) {
      while (this.directoryCacheBytes + decoded.length > MAX_DIRECTORY) {
        const oldest = this.directoryCache.keys().next().value;
        if (oldest === undefined) break;
        this.directoryCacheBytes -= this.directoryCache.get(oldest).length;
        this.directoryCache.delete(oldest);
      }
      this.directoryCache.set(key, decoded);
      this.directoryCacheBytes += decoded.length;
    }
    return decoded;
  }

  async locate(z, x, y) {
    exactInteger(z, 'zoom'); exactInteger(x, 'x'); exactInteger(y, 'y');
    if (z > 31 || BigInt(x) >= (1n << BigInt(z)) || BigInt(y) >= (1n << BigInt(z))) {
      throw new Error('tile coordinates outside supported zoom');
    }
    if (z < this.header.minZoom || z > this.header.maxZoom) return null;
    let offset = BigInt(this.header.rootOffset);
    let length = Number(this.header.rootLength);
    for (let depth = 0; depth < 4; depth++) {
      const decoded = await this.directory(offset, length);
      const step = parseResult(step_hex(this.headerHex, z, x, y, decoded.toString('hex')));
      if (step.status === 'missing') return null;
      if (step.status === 'tile') return {
        offset: BigInt(step.offset), length: Number(step.length),
        compression: step.compression, tileType: step.tileType,
      };
      if (step.status !== 'leaf') throw new Error('invalid MoonBit lookup step');
      offset = BigInt(step.offset);
      length = Number(step.length);
    }
    throw new Error('directory depth exceeds limit');
  }

  async tile(z, x, y, {decode = false} = {}) {
    const reference = await this.locate(z, x, y);
    if (!reference) return null;
    if (reference.length < 1 || reference.length > MAX_TILE) {
      throw new Error('tile length outside limit');
    }
    const stored = await this.source.read(reference.offset, reference.length);
    return {
      ...reference,
      bytes: decode ? decompress(reference.compression, stored, MAX_DECODED_TILE) : stored,
      decoded: decode,
    };
  }

  async mvtSummary(z, x, y) {
    const tile = await this.tile(z, x, y, {decode: true});
    if (!tile) return null;
    if (tile.tileType !== 1 && tile.tileType !== 6) {
      throw new Error('tile type is not MVT');
    }
    if (tile.bytes.length > MAX_MVT_SUMMARY) {
      throw new Error('MVT summary exceeds 16 MiB bridge limit');
    }
    return parseResult(mvt_summary_hex(tile.bytes.toString('hex'))).layers;
  }

  async cover(minLon, minLat, maxLon, maxLat, z, {maxTiles = 4096} = {}) {
    exactInteger(z, 'zoom');
    for (const value of [minLon, minLat, maxLon, maxLat]) {
      if (!Number.isFinite(value)) throw new Error('bounds must be finite numbers');
    }
    const {tiles} = parseResult(cover_bounds_json(minLon, minLat, maxLon, maxLat, z));
    if (tiles.length > maxTiles) throw new Error(`cover exceeds ${maxTiles} tile query limit`);
    const result = [];
    for (const position of tiles) {
      const tile = await this.locate(position.z, position.x, position.y);
      result.push({
        ...position,
        present: tile !== null,
        offset: tile?.offset.toString() ?? null,
        length: tile?.length ?? null,
      });
    }
    return result;
  }

  async audit() {
    const pending = [{
      offset: BigInt(this.header.rootOffset),
      length: Number(this.header.rootLength),
      depth: 0,
    }];
    const visited = new Set();
    let directories = 0;
    let compressedDirectoryBytes = 0n;
    let tileEntries = 0n;
    let addressedTiles = 0n;
    let referencedTileBytes = 0n;
    while (pending.length) {
      if (directories >= 20000) throw new Error('archive contains too many directories');
      const current = pending.pop();
      if (current.depth > 3 || !Number.isSafeInteger(current.length) ||
          current.length < 1 || current.length > MAX_DIRECTORY) {
        throw new Error('directory depth or range exceeds limit');
      }
      const key = `${current.offset}:${current.length}`;
      if (visited.has(key)) throw new Error('directory cycle or duplicate leaf reference');
      visited.add(key);
      compressedDirectoryBytes += BigInt(current.length);
      if (compressedDirectoryBytes > 268435456n) {
        throw new Error('archive audit exceeds 256 MiB directory budget');
      }
      const decoded = await this.directory(current.offset, current.length);
      const result = parseResult(audit_directory_hex(this.headerHex, decoded.toString('hex')));
      directories++;
      tileEntries += BigInt(result.tileEntries);
      addressedTiles += BigInt(result.addressedTiles);
      referencedTileBytes += BigInt(result.referencedTileBytes);
      for (const leaf of result.leaves) {
        pending.push({offset: BigInt(leaf.offset), length: Number(leaf.length),
          depth: current.depth + 1});
      }
    }
    if (this.header.tileEntries !== '0' &&
        tileEntries !== BigInt(this.header.tileEntries)) {
      throw new Error('declared tile-entry count differs from directory tree');
    }
    if (this.header.addressedTiles !== '0' &&
        addressedTiles !== BigInt(this.header.addressedTiles)) {
      throw new Error('declared addressed-tile count differs from directory tree');
    }
    return {
      directories,
      compressedDirectoryBytes: compressedDirectoryBytes.toString(),
      tileEntries: tileEntries.toString(),
      addressedTiles: addressedTiles.toString(),
      referencedTileBytes: referencedTileBytes.toString(),
    };
  }
}
