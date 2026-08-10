// Development-only emulator entrypoint.
// Bundled only when MAPPY_WATCH_PHONE_MODE=fixture.
try {
  Pebble.__mappyFixtureOptions = require('./fixture-options.js') || {};
} catch (e) {
  Pebble.__mappyFixtureOptions = {};
}

require('../../../../tooling/pebble-map-mock-pkjs.js');
