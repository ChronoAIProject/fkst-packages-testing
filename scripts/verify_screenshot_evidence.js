#!/usr/bin/env node
'use strict';

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const workspace = process.argv[2];
const artifactRoot = process.argv[3];
if (!workspace || !artifactRoot) throw new Error('usage: verify_screenshot_evidence.js <workspace> <artifact-root>');

function readArtifact(relativePath) {
  return fs.readFileSync(path.join(workspace, relativePath));
}

function readJson(relativePath) {
  return JSON.parse(readArtifact(relativePath).toString('utf8'));
}

function paeth(left, up, upperLeft) {
  const prediction = left + up - upperLeft;
  const leftDistance = Math.abs(prediction - left);
  const upDistance = Math.abs(prediction - up);
  const upperLeftDistance = Math.abs(prediction - upperLeft);
  if (leftDistance <= upDistance && leftDistance <= upperLeftDistance) return left;
  return upDistance <= upperLeftDistance ? up : upperLeft;
}

function decodePng(buffer) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert(buffer.subarray(0, 8).equals(signature), 'screenshot must have a PNG signature');
  let offset = 8;
  let width;
  let height;
  let colorType;
  let bitDepth;
  const compressed = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('ascii', offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    offset += 12 + length;
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
    } else if (type === 'IDAT') {
      compressed.push(data);
    } else if (type === 'IEND') {
      break;
    }
  }
  assert.strictEqual(bitDepth, 8, 'screenshot PNG must use 8-bit channels');
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : 0;
  assert(channels > 0, `unsupported screenshot PNG color type ${colorType}`);
  const raw = zlib.inflateSync(Buffer.concat(compressed));
  const stride = width * channels;
  const pixels = Buffer.alloc(stride * height);
  let inputOffset = 0;
  for (let y = 0; y < height; y += 1) {
    const filter = raw[inputOffset++];
    const rowOffset = y * stride;
    for (let x = 0; x < stride; x += 1) {
      const value = raw[inputOffset++];
      const left = x >= channels ? pixels[rowOffset + x - channels] : 0;
      const up = y > 0 ? pixels[rowOffset - stride + x] : 0;
      const upperLeft = y > 0 && x >= channels ? pixels[rowOffset - stride + x - channels] : 0;
      let predictor = 0;
      if (filter === 1) predictor = left;
      else if (filter === 2) predictor = up;
      else if (filter === 3) predictor = Math.floor((left + up) / 2);
      else if (filter === 4) predictor = paeth(left, up, upperLeft);
      else assert.strictEqual(filter, 0, `unsupported PNG filter ${filter}`);
      pixels[rowOffset + x] = (value + predictor) & 0xff;
    }
  }
  return {
    width,
    height,
    pixel(x, y) {
      assert(x >= 0 && x < width && y >= 0 && y < height, 'mask probe must be inside the screenshot');
      const index = y * stride + x * channels;
      return [pixels[index], pixels[index + 1], pixels[index + 2]];
    },
  };
}

const event = readJson(`${artifactRoot}/event.json`);
const pointer = event.native_summary.failure_screenshot;
const screenshot = readArtifact(pointer.path);
assert(screenshot.length > 8, 'screenshot must be non-empty');
assert.strictEqual(pointer.size_bytes, screenshot.length, 'pointer size must match the PNG');
assert.strictEqual(pointer.media_type, 'image/png', 'pointer media type must be image/png');
assert.strictEqual(pointer.sha256, crypto.createHash('sha256').update(screenshot).digest('hex'), 'pointer digest must match the PNG');

const index = readJson(`${artifactRoot}/evidence/screenshot-index.json`);
const failures = readJson(`${artifactRoot}/evidence/failures.json`);
const receipt = readJson(`${artifactRoot}/browser-execution-receipt.json`);
assert.deepStrictEqual(index.refs, [pointer], 'screenshot index must contain the event pointer exactly once');
assert.deepStrictEqual(failures.failed_assertions[0].screenshot_artifact, pointer, 'failure attribution must reuse the event pointer');
const failedAssertions = receipt.actions.flatMap((action) => action.assertion_results).filter((item) => item.status === 'failed');
assert.strictEqual(failedAssertions.length, 1, 'fixture must produce exactly one failed assertion');
assert.deepStrictEqual(failedAssertions[0].screenshot_artifact, pointer, 'runtime receipt must reuse the event pointer');

const png = decodePng(screenshot);
for (const [x, y] of [[60, 60], [120, 90], [180, 120]]) {
  assert.deepStrictEqual(png.pixel(x, y), [217, 48, 37], `configured sensitive region must be masked at ${x},${y}`);
}

for (const relativePath of [
  `${artifactRoot}/event.json`,
  `${artifactRoot}/metadata.json`,
  `${artifactRoot}/browser-execution-receipt.json`,
  `${artifactRoot}/cdp-execution.json`,
  `${artifactRoot}/evidence/screenshot-index.json`,
  `${artifactRoot}/evidence/failures.json`,
  `${artifactRoot}/stage-report.md`,
]) {
  const body = readArtifact(relativePath).toString('utf8');
  assert(!body.includes('fixture-secret-71'), `${relativePath} must not contain the fixture secret`);
  assert(!body.includes('data:image'), `${relativePath} must not contain an inline image`);
}

process.stdout.write(`screenshot evidence verified: ${pointer.path} ${png.width}x${png.height}\n`);
