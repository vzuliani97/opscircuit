#!/usr/bin/env node
// Published images must carry no metadata: EXIF (GPS position, camera, capture time), XMP or IPTC.
//   node scripts/image-metadata.mjs check <dir...>   exits 1 if any JPEG or PNG still has a metadata block
//   node scripts/image-metadata.mjs strip <dir...>   removes those blocks without re-encoding the pixels
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const [mode, ...dirs] = process.argv.slice(2);
if (!['check', 'strip'].includes(mode) || dirs.length === 0) {
  console.error('usage: image-metadata.mjs check|strip <dir...>');
  process.exit(2);
}

function* images(dir) {
  for (const name of readdirSync(dir)) {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) {
      if (name !== 'node_modules') yield* images(file);
    } else if (/\.(jpe?g|png)$/i.test(name)) {
      yield file;
    }
  }
}

// EXIF orientation (tag 0x0112 in IFD0). Dropping a value other than 1 would show the photo rotated.
function orientation(tiff) {
  const le = tiff.subarray(0, 2).toString('latin1') === 'II';
  const u16 = (at) => (le ? tiff.readUInt16LE(at) : tiff.readUInt16BE(at));
  const u32 = (at) => (le ? tiff.readUInt32LE(at) : tiff.readUInt32BE(at));
  const ifd = u32(4);
  for (let n = 0, count = u16(ifd); n < count; n += 1) {
    const entry = ifd + 2 + n * 12;
    if (u16(entry) === 0x0112) return u16(entry + 8);
  }
  return 1;
}

// JPEG: APP1 holds EXIF or XMP, APP13 holds IPTC. Everything up to the start of scan has a length.
function jpeg(buf) {
  const keep = [buf.subarray(0, 2)];
  const found = [];
  let rotated = false;
  let i = 2;
  while (i + 4 <= buf.length && buf[i] === 0xff && buf[i + 1] !== 0xda) {
    const marker = buf[i + 1];
    const segment = buf.subarray(i, i + 2 + buf.readUInt16BE(i + 2));
    const body = segment.subarray(4);
    let label = null;
    if (marker === 0xe1 && body.subarray(0, 6).toString('latin1') === 'Exif\0\0') {
      label = 'EXIF';
      rotated = orientation(body.subarray(6)) !== 1;
    } else if (marker === 0xe1 && body.includes('http://ns.adobe.com/xap')) {
      label = 'XMP';
    } else if (marker === 0xed) {
      label = 'IPTC';
    }
    if (label) found.push(label);
    else keep.push(segment);
    i += segment.length;
  }
  keep.push(buf.subarray(i));
  return { found, rotated, clean: Buffer.concat(keep) };
}

// PNG: eXIf holds EXIF; text chunks can hold XMP, authors or locations.
function png(buf) {
  const keep = [buf.subarray(0, 8)];
  const found = [];
  for (let i = 8; i < buf.length; ) {
    const length = buf.readUInt32BE(i);
    const type = buf.subarray(i + 4, i + 8).toString('latin1');
    const chunk = buf.subarray(i, i + 12 + length);
    if (['eXIf', 'tEXt', 'zTXt', 'iTXt'].includes(type)) found.push(type);
    else keep.push(chunk);
    i += chunk.length;
  }
  return { found, rotated: false, clean: Buffer.concat(keep) };
}

let dirty = 0;
for (const dir of dirs) {
  for (const file of images(dir)) {
    const buf = readFileSync(file);
    const result = /\.png$/i.test(file) ? png(buf) : jpeg(buf);
    if (result.found.length === 0) continue;
    if (mode === 'check') {
      dirty += 1;
      console.error(`${file}: ${result.found.join(', ')}`);
    } else if (result.rotated) {
      dirty += 1;
      console.error(`${file}: EXIF orientation is not 1; rotate the pixels first, then strip`);
    } else {
      writeFileSync(file, result.clean);
      console.log(`stripped ${file}: ${result.found.join(', ')}`);
    }
  }
}
if (dirty > 0) {
  console.error(mode === 'check' ? `${dirty} image(s) carry metadata; run: node scripts/image-metadata.mjs strip <dir>` : `${dirty} image(s) left untouched`);
  process.exit(1);
}
if (mode === 'check') console.log('no image metadata found');
