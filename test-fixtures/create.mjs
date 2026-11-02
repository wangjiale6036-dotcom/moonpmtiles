// Independent, small PMTiles v3 writer for repeatable reader tests.
// It follows the public format specification and is not part of the library.
import {mkdir, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const directory = path.join(path.dirname(fileURLToPath(import.meta.url)), 'generated');
await mkdir(directory, {recursive: true});

function varint(n) {
  n = BigInt(n);
  if (n < 0n) throw new Error('negative varint');
  const out = [];
  while (n > 127n) {
    out.push(Number(n & 127n) | 128);
    n >>= 7n;
  }
  out.push(Number(n));
  return Buffer.from(out);
}

function field(number, wire, payload) {
  const key = varint(number * 8 + wire);
  return wire === 2
    ? Buffer.concat([key, varint(payload.length), payload])
    : Buffer.concat([key, varint(payload)]);
}

function mvt(name, id) {
  const feature = Buffer.concat([
    field(1, 0, id), field(3, 0, 1),
    field(4, 2, Buffer.from([9, 0, 0])),
  ]);
  const layer = Buffer.concat([
    field(15, 0, 2), field(1, 2, Buffer.from(name)),
    field(2, 2, feature), field(5, 0, 4096),
  ]);
  return field(3, 2, layer);
}

function encodeDirectory(entries) {
  const parts = [varint(entries.length)];
  let lastId = 0;
  for (const e of entries) {
    parts.push(varint(e.id - lastId));
    lastId = e.id;
  }
  for (const e of entries) parts.push(varint(e.run));
  for (const e of entries) parts.push(varint(e.length));
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    const prev = entries[i - 1];
    const contiguous = i > 0 && e.offset === prev.offset + prev.length;
    parts.push(varint(contiguous ? 0 : e.offset + 1));
  }
  return Buffer.concat(parts);
}

const tile0 = mvt('world', 10);
const tile1 = mvt('places', 21);
const tile4 = mvt('roads', 34);
const tileData = Buffer.concat([tile0, tile1, tile4]);
const metadata = Buffer.from(JSON.stringify({
  name: 'MoonPMTiles synthetic vector fixture',
  vector_layers: [{id: 'world'}, {id: 'places'}, {id: 'roads'}],
}));

function makeArchive(internalCompression) {
  const pack = internalCompression === 2 ? data => gzipSync(data, {mtime: 0}) : data => data;
  const leaf = pack(encodeDirectory([
    {id: 1, run: 2, offset: tile0.length, length: tile1.length},
    {id: 4, run: 1, offset: tile0.length + tile1.length, length: tile4.length},
  ]));
  const root = pack(encodeDirectory([
    {id: 0, run: 1, offset: 0, length: tile0.length},
    {id: 1, run: 0, offset: 0, length: leaf.length},
  ]));
  const meta = pack(metadata);
  const header = Buffer.alloc(127);
  header.write('PMTiles', 0, 'ascii');
  header[7] = 3;
  const set64 = (at, n) => header.writeBigUInt64LE(BigInt(n), at);
  set64(8, 127);
  set64(16, root.length);
  set64(24, 127 + root.length);
  set64(32, meta.length);
  set64(40, 127 + root.length + meta.length);
  set64(48, leaf.length);
  set64(56, 127 + root.length + meta.length + leaf.length);
  set64(64, tileData.length);
  set64(72, 4); // addressed tile IDs: 0, 1, 2, 4
  set64(80, 3); // tile entries
  set64(88, 3); // stored tile contents
  header[96] = 1; // clustered
  header[97] = internalCompression;
  header[98] = 1; // tile data uncompressed
  header[99] = 1; // MVT
  header[100] = 0;
  header[101] = 1;
  return Buffer.concat([header, root, meta, leaf, tileData]);
}

const files = {};
for (const [name, compression] of [['plain', 1], ['gzip', 2]]) {
  const archive = makeArchive(compression);
  await writeFile(path.join(directory, `${name}.pmtiles`), archive);
  files[name] = {
    bytes: archive.length,
    sha256: createHash('sha256').update(archive).digest('hex'),
  };
}
await writeFile(path.join(directory, 'manifest.json'), JSON.stringify({
  provenance: 'Generated locally from test-fixtures/create.mjs; synthetic test data',
  files,
  expected: {
    '0/0/0': createHash('sha256').update(tile0).digest('hex'),
    '1/0/0': createHash('sha256').update(tile1).digest('hex'),
    '1/0/1': createHash('sha256').update(tile1).digest('hex'),
    '1/1/0': createHash('sha256').update(tile4).digest('hex'),
    '1/1/1': null,
  },
}, null, 2));
console.log('Generated plain and gzip PMTiles v3 fixtures.');
