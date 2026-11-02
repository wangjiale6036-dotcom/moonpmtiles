import {writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {Archive, openSource} from './reader.mjs';

function usage() {
  console.error('Usage: node cli.mjs info <file-or-URL>');
  console.error('       node cli.mjs metadata <file-or-URL>');
  console.error('       node cli.mjs audit <file-or-URL>');
  console.error('       node cli.mjs tile <file-or-URL> <z> <x> <y> [--decode] [--output <path>]');
  console.error('       node cli.mjs mvt <file-or-URL> <z> <x> <y>');
  console.error('       node cli.mjs cover <file-or-URL> <minLon> <minLat> <maxLon> <maxLat> <z>');
  process.exitCode = 2;
}

const [command, location, ...args] = process.argv.slice(2);
if (!location || !['info', 'metadata', 'audit', 'tile', 'mvt', 'cover'].includes(command)) {
  usage();
} else {
  let source;
  try {
    source = await openSource(location);
    const archive = await Archive.open(source);
    let report;
    if (command === 'info') {
      report = {header: archive.header};
    } else if (command === 'metadata') {
      report = {metadata: await archive.metadata()};
    } else if (command === 'audit') {
      report = {audit: await archive.audit()};
    } else if (command === 'cover') {
      if (args.length !== 5 || args.some(value => !Number.isFinite(Number(value)))) {
        throw new Error('cover requires minLon minLat maxLon maxLat z');
      }
      const [minLon, minLat, maxLon, maxLat, z] = args.map(Number);
      report = {
        bounds: {minLon, minLat, maxLon, maxLat, z},
        tiles: await archive.cover(minLon, minLat, maxLon, maxLat, z, {maxTiles: 16}),
      };
    } else {
      const [zText, xText, yText, ...flags] = args;
      if ([zText, xText, yText].some(x => !/^\d+$/.test(x ?? ''))) {
        throw new Error('tile requires integer z x y');
      }
      const [z, x, y] = [zText, xText, yText].map(Number);
      const decode = flags.includes('--decode');
      if (command === 'mvt') {
        const layers = await archive.mvtSummary(z, x, y);
        report = {z, x, y, layers};
      } else {
        const outputIndex = flags.indexOf('--output');
        const output = outputIndex >= 0 ? flags[outputIndex + 1] : undefined;
        if (outputIndex >= 0 && !output) throw new Error('--output requires a path');
        const tile = await archive.tile(z, x, y, {decode});
        if (!tile) {
          report = {tile: null, z, x, y};
        } else {
          if (output) await writeFile(output, tile.bytes);
          report = {
            z, x, y, offset: tile.offset.toString(),
            storedLength: tile.length, outputLength: tile.bytes.length,
            compression: tile.compression, tileType: tile.tileType,
            decoded: tile.decoded,
            sha256: createHash('sha256').update(tile.bytes).digest('hex'),
            output: output ?? null,
          };
        }
      }
    }
    report.requests = source.requests;
    report.bytesRead = source.requests.reduce((n, r) => n + r.length, 0);
    console.log(JSON.stringify(report, null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  } finally {
    await source?.close();
  }
}
