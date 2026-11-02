// Optional live verification against an Overture Maps release.
// It fetches only byte ranges and stores no tiles on disk.
import {createHash} from 'node:crypto';
import {mkdir, writeFile} from 'node:fs/promises';
import {PMTiles} from 'pmtiles';
import {Archive, HttpRangeSource} from '../reader.mjs';
import {mvt_summary_hex} from '../dist/engine.mjs';

const url = 'https://overturemaps-extras-us-west-2.s3.us-west-2.amazonaws.com/tiles/2026-10-21.0/base.pmtiles';
const remote = new HttpRangeSource(url);
const cached = [];
const source = {
  async read(offset, length) {
    const hit = cached.find(chunk => offset >= chunk.offset &&
      offset + BigInt(length) <= chunk.offset + BigInt(chunk.data.length));
    if (hit) {
      const start = Number(offset - hit.offset);
      return hit.data.subarray(start, start + length);
    }
    const data = await remote.read(offset, length);
    cached.push({offset, data});
    return data;
  },
};

function hash(bytes) { return createHash('sha256').update(bytes).digest('hex'); }

try {
  await source.read(0n, 16384);
  const archive = await Archive.open(source);
  const reference = new PMTiles({
    getKey: () => url,
    async getBytes(offset, length) {
      const data = await source.read(BigInt(offset), length);
      return {data: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)};
    },
  });
  const metadata = await archive.metadata();
  const referenceMetadata = await reference.getMetadata();
  if (JSON.stringify(metadata) !== JSON.stringify(referenceMetadata)) {
    throw new Error('metadata differs from official JS reader');
  }
  const zxy = [1, 0, 0];
  const ours = await archive.tile(...zxy, {decode: true});
  const official = await reference.getZxy(...zxy);
  if (!ours || !official || hash(ours.bytes) !== hash(Buffer.from(official.data))) {
    throw new Error('tile differs from official JS reader');
  }
  const summary = JSON.parse(mvt_summary_hex(ours.bytes.toString('hex')));
  if (summary.status !== 'ok') {
    throw new Error(`MoonBit MVT summary failed: ${summary.message}`);
  }
  const report = {
    checkedAt: new Date().toISOString(),
    source: url,
    sourceETag: remote.etag,
    archiveBytes: remote.total?.toString(),
    coordinate: zxy.join('/'),
    tileOffset: ours.offset.toString(),
    storedTileBytes: ours.length,
    decodedTileBytes: ours.bytes.length,
    decodedTileSHA256: hash(ours.bytes),
    mvtLayers: summary.layers,
    metadataName: metadata.name ?? null,
    matchOfficialPMTilesJS: true,
    fetchedRanges: remote.requests,
    fetchedBytes: remote.requests.reduce((n, r) => n + r.length, 0),
  };
  if (process.argv.includes('--write-evidence')) {
    await mkdir(new URL('../docs/evidence/', import.meta.url), {recursive: true});
    await writeFile(new URL('../docs/evidence/overture-2026-10-21-base.json', import.meta.url),
      JSON.stringify(report, null, 2) + '\n');
  }
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
