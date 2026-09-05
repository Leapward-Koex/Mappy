'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const source = fs.readFileSync(path.join(__dirname, 'pebble-map-mock-pkjs.js'), 'utf8');
const fixture = require('./tile-codec-vectors.json');
const vectors = fixture.vectors || fixture;
let cases = 0;
for (const dimensions of [[54, 63], [72, 84], [108, 126]]) {
  for (let format = 0; format <= 4; format++) {
    const events = {}, timers = [], messages = [];
    vm.runInNewContext(source, {
      require: name => require(path.join(__dirname, name)),
      console: {log: () => {}},
      setTimeout: callback => timers.push(callback),
      Pebble: {
        __mappyFixtureOptions: {
          tileWidth: dimensions[0], tileHeight: dimensions[1], tileCodec: format,
          tileChunkBytes: 128,
        },
        addEventListener: (name, callback) => { events[name] = callback; },
        sendAppMessage: (message, success) => { messages.push(message); success(); },
      },
    });
    events.appmessage({payload: {cmd: 202, world_x: 0, world_y: 0,
                                  tile_zoom: 16, request_id: 17}});
    for (let steps = 0; timers.length && steps < 1000; steps++) timers.shift()();
    assert.strictEqual(timers.length, 0);
    assert(messages.length > 0);
    const bytes = [];
    for (let index = 0; index < messages.length; index++) {
      const message = messages[index];
      assert.strictEqual(message.cmd, 203);
      assert.strictEqual(message.compression_format, format || 1);
      assert.strictEqual(message.request_id, 17);
      assert.strictEqual(message.chunk_index, index);
      assert.strictEqual(message.chunk_offset, bytes.length);
      bytes.push(...message.chunk_data);
    }
    assert.strictEqual(bytes.length, messages[0].total_bytes);
    if (format) {
      const vector = vectors.find(v => v.width === dimensions[0] &&
          v.height === dimensions[1] && v.format === format);
      assert.deepStrictEqual(bytes, vector.payload);
    } else {
      assert.strictEqual(bytes.reduce((count, b) => count + (b >> 4) + 1, 0),
                         dimensions[0] * dimensions[1]);
    }
    cases++;
  }
}
console.log('fixture codec dispatch: ' + cases + ' cases passed');
