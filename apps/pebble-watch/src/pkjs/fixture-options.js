// Development-only fixture options.
// wscript rewrites fixture-options.generated.js from MAPPY_FIXTURE_* env vars.
var options = {};

try {
  options = require('./fixture-options.generated.js') || {};
} catch (e) {
  options = {};
}

module.exports = options;
