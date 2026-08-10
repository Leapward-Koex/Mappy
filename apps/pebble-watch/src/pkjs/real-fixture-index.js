// Development-only entrypoint for locally generated provider-map fixtures.
// Bundled only when MAPPY_WATCH_PHONE_MODE=real-fixture.
try {
  Pebble.__mappyFixtureOptions = require('./fixture-options.js') || {};
} catch (e) {
  Pebble.__mappyFixtureOptions = {};
}

require('../../../../tooling/real-map-fixtures/generated/pebble-map-real-fixture-pkjs.js');
