import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile, stat} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {createServer} from 'node:http';
import {PMTiles} from 'pmtiles';
import {Archive, FileRangeSource, HttpRangeSource} from '../reader.mjs';

const fixturePath = new URL('../test-fixtures/generated/gzip.pmtiles', import.meta.url);
const plainPath = new URL('../test-fixtures/generated/plain.pmtiles', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('../test-fixtures/generated/manifest.json', import.meta.url)));
const sha256 = data => createHash('sha256').update(data).digest('hex');
const upstream = [
  ['test_fixture_1.pmtiles', 'f3f65093582c81625cdfab11b3d1a27c2fb6aadcf8bd9802b2ad694d4d7cdca5'],
  ['test_fixture_2.pmtiles', '7ee80a53000bfb15a5d54162bc3161094239e775fef180fffb2d3ff607e46c1a'],
];

function referenceArchive(data, key) {
  return new PMTiles({
    getKey: () => key,
    async getBytes(offset, length) {
      const chunk = data.subarray(offset, offset + length);
      return {data: chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + chunk.byteLength)};
    },
  });
}

async function withArchive(path, run) {
  const source = await FileRangeSource.open(path);
  try { return await run(await Archive.open(source), source); }
  finally { await source.close(); }
}

test('plain and gzip archives resolve direct, leaf, deduplicated and absent tiles', async () => {
  for (const path of [plainPath, fixturePath]) {
    await withArchive(path, async archive => {
      for (const [zxy, expected] of Object.entries(manifest.expected)) {
        const [z, x, y] = zxy.split('/').map(Number);
        const tile = await archive.tile(z, x, y);
        assert.equal(tile ? sha256(tile.bytes) : null, expected, zxy);
      }
      assert.deepEqual((await archive.mvtSummary(1, 1, 0)), [
        {name: 'roads', features: 1, extent: 4096, version: 2},
      ]);
      assert.equal((await archive.metadata()).vector_layers.length, 3);
    });
  }
});

test('two genuine Protomaps fixtures match the official JS reader byte for byte', async () => {
  for (const [name, expectedHash] of upstream) {
    const url = new URL(`../test-fixtures/upstream/${name}`, import.meta.url);
    const data = await readFile(url);
    assert.equal(sha256(data), expectedHash, `${name} provenance hash`);
    const reference = referenceArchive(data, name);
    await withArchive(url, async archive => {
      const officialHeader = await reference.getHeader();
      assert.equal(archive.header.rootOffset, String(officialHeader.rootDirectoryOffset));
      assert.equal(archive.header.rootLength, String(officialHeader.rootDirectoryLength));
      assert.deepEqual(await archive.metadata(), await reference.getMetadata());
      for (const [z, x, y] of [[0, 0, 0], [1, 0, 0]]) {
        const ours = await archive.tile(z, x, y, {decode: true});
        const official = await reference.getZxy(z, x, y);
        assert.equal(ours ? sha256(ours.bytes) : null,
          official ? sha256(Buffer.from(official.data)) : null,
          `${name} ${z}/${x}/${y}`);
      }
    });
  }
});

test('synthetic root/leaf cases also agree with official JS reader', async () => {
  for (const url of [plainPath, fixturePath]) {
    const data = await readFile(url);
    const reference = referenceArchive(data, url.pathname);
    await withArchive(url, async archive => {
      for (const zxy of Object.keys(manifest.expected)) {
        const [z, x, y] = zxy.split('/').map(Number);
        const ours = await archive.tile(z, x, y, {decode: true});
        const official = await reference.getZxy(z, x, y);
        assert.equal(ours ? sha256(ours.bytes) : null,
          official ? sha256(Buffer.from(official.data)) : null,
          zxy);
      }
    });
  }
});

test('one leaf tile needs only header, root, leaf and tile ranges', async () => {
  await withArchive(fixturePath, async (archive, source) => {
    const tile = await archive.tile(1, 1, 0);
    assert.ok(tile);
    assert.equal(source.requests.length, 4);
    assert.deepEqual(source.requests.map(r => r.length), [127, 29, 29, 25]);
    const size = (await stat(fixturePath)).size;
    assert.ok(source.requests.reduce((sum, r) => sum + r.length, 0) < size);
  });
});

test('directory cache avoids repeated root and leaf reads', async () => {
  await withArchive(fixturePath, async (archive, source) => {
    await archive.tile(1, 0, 0);
    assert.equal(source.requests.length, 4);
    await archive.tile(1, 1, 0);
    assert.equal(source.requests.length, 5); // Only the second tile bytes are new.
    assert.equal(archive.directoryCache.size, 2);
  });
});

test('MoonBit geographic cover locates visible tiles without reading contents', async () => {
  await withArchive(fixturePath, async (archive, source) => {
    const tiles = await archive.cover(-1, -1, 1, 1, 1, {maxTiles: 4});
    assert.equal(tiles.length, 4);
    assert.deepEqual(tiles.map(tile => tile.present), [true, true, true, false]);
    assert.equal(source.requests.length, 3); // Header, root, leaf only.
  });
});

test('archive audit traverses leaves and checks declared tile counts', async () => {
  await withArchive(fixturePath, async (archive, source) => {
    const report = await archive.audit();
    assert.equal(report.directories, 2);
    assert.equal(report.tileEntries, '3');
    assert.equal(report.addressedTiles, '4');
    assert.equal(source.requests.length, 3); // Header and two directories.
  });
  await withArchive(new URL('../test-fixtures/upstream/test_fixture_1.pmtiles', import.meta.url),
    async archive => {
      const report = await archive.audit();
      assert.equal(report.tileEntries, '1');
      assert.equal(report.directories, 1);
    });
});

test('HTTP source enforces byte ranges and stable ETag', async () => {
  const data = await readFile(fixturePath);
  const seen = [];
  const fakeFetch = async (_url, options) => {
    const range = /^bytes=(\d+)-(\d+)$/.exec(options.headers.Range);
    assert.ok(range);
    const start = Number(range[1]);
    const end = Number(range[2]);
    seen.push({start, end, ifRange: options.headers['If-Range']});
    return new Response(data.subarray(start, end + 1), {
      status: 206,
      headers: {
        'Content-Range': `bytes ${start}-${end}/${data.length}`,
        'Content-Length': String(end - start + 1),
        ETag: '"fixture-v1"',
      },
    });
  };
  const source = new HttpRangeSource('https://example.test/map.pmtiles', fakeFetch);
  const archive = await Archive.open(source);
  const tile = await archive.tile(1, 1, 0);
  assert.equal(sha256(tile.bytes), manifest.expected['1/1/0']);
  assert.equal(seen.length, 4);
  assert.equal(seen[0].ifRange, undefined);
  assert.ok(seen.slice(1).every(r => r.ifRange === '"fixture-v1"'));
});

test('real local HTTP server serves one tile through four GET Range requests', async () => {
  const data = await readFile(fixturePath);
  const ranges = [];
  const server = createServer((request, response) => {
    const match = /^bytes=(\d+)-(\d+)$/.exec(request.headers.range ?? '');
    if (!match) { response.writeHead(400).end(); return; }
    const start = Number(match[1]);
    const end = Number(match[2]);
    ranges.push([start, end]);
    response.writeHead(206, {
      'Content-Range': `bytes ${start}-${end}/${data.length}`,
      'Content-Length': end - start + 1,
      'Accept-Ranges': 'bytes',
      ETag: '"fixture-v1"',
    });
    response.end(data.subarray(start, end + 1));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const source = new HttpRangeSource(`http://127.0.0.1:${server.address().port}/fixture.pmtiles`);
    const archive = await Archive.open(source);
    const tile = await archive.tile(1, 1, 0);
    assert.equal(sha256(tile.bytes), manifest.expected['1/1/0']);
    assert.equal(ranges.length, 4);
    assert.equal(source.requests.reduce((n, r) => n + r.length, 0), 210);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test('HTTP source refuses ignored ranges, wrong Content-Range and archive changes', async () => {
  const ignored = new HttpRangeSource('https://example.test/a', async () =>
    new Response(Buffer.alloc(127), {status: 200}));
  await assert.rejects(ignored.read(0n, 127), /did not honor byte range/);

  const wrong = new HttpRangeSource('https://example.test/a', async () =>
    new Response(Buffer.alloc(127), {
      status: 206, headers: {'Content-Range': 'bytes 1-127/200'},
    }));
  await assert.rejects(wrong.read(0n, 127), /invalid Content-Range/);

  let version = 0;
  const changed = new HttpRangeSource('https://example.test/a', async () => {
    version += 1;
    return new Response(Buffer.alloc(1), {
      status: 206,
      headers: {'Content-Range': 'bytes 0-0/200', ETag: `"v${version}"`},
    });
  });
  await changed.read(0n, 1);
  await assert.rejects(changed.read(0n, 1), /version changed/);

  const noValidator = new HttpRangeSource('https://example.test/a', async () =>
    new Response(Buffer.alloc(1), {
      status: 206, headers: {'Content-Range': 'bytes 0-0/200'},
    }));
  await assert.rejects(noValidator.read(0n, 1), /no strong ETag or Last-Modified/);

  const weak = new HttpRangeSource('https://example.test/a', async () =>
    new Response(Buffer.alloc(1), {
      status: 206,
      headers: {'Content-Range': 'bytes 0-0/200', ETag: 'W/"weak"'},
    }));
  await assert.rejects(weak.read(0n, 1), /no strong ETag or Last-Modified/);
});

test('corrupt directory and decompression expansion are explicit errors', async () => {
  const data = Buffer.from(await readFile(plainPath));
  data[127] = 0; // An empty PMTiles directory is forbidden.
  const source = {
    requests: [],
    async read(offset, length) {
      return data.subarray(Number(offset), Number(offset) + length);
    },
  };
  const archive = await Archive.open(source);
  await assert.rejects(archive.tile(0, 0, 0), /invalid directory entry count/);

  const bomb = gzipSync(Buffer.alloc(9 * 1024 * 1024));
  const compressedSource = {
    requests: [],
    async read(offset) {
      return offset === 0n ? Buffer.from(await readFile(fixturePath)).subarray(0, 127) : bomb;
    },
  };
  const compressedArchive = await Archive.open(compressedSource);
  compressedArchive.header.rootLength = String(bomb.length);
  await assert.rejects(compressedArchive.tile(0, 0, 0), /invalid or oversized compressed data/);
});
