(function() {
  'use strict';

  var KEY_CMD = 50;
  var KEY_IS_COLOR = 54;
  var KEY_BUTTON_ID = 60;
  var KEY_WORLD_X = 63;
  var KEY_WORLD_Y = 64;
  var KEY_TILE_ZOOM = 65;
  var KEY_REQUEST_ID = 70;
  var CMD_INIT = 101;
  var CMD_ERROR_STATE = 102;
  var CMD_PHONE_READY = 104;
  var CMD_GPS = 201;
  var CMD_TILE_REQUEST = 202;
  var CMD_TILE = 203;
  var CMD_TILE_ANIMATION = 206;
  var CMD_BUTTON = 207;
  var CMD_DESTINATIONS = 301;
  var CMD_ROUTE_REQUEST = 302;
  var CMD_ROUTE_POINTS = 303;
  var CMD_ROUTE_CLEAR = 304;
  var CMD_NAV_STEPS = 305;
  var CMD_ROUTE_APPLIED = 308;
  var CMD_ROUTE_COMPLETE = 309;
  var CMD_THEME = 401;
  var CMD_TRAVEL_MODE = 402;
  var CMD_UNITS = 403;
  var CMD_BACKLIGHT = 404;

  var TILE_W = 54;
  var TILE_H = 63;
  var ROUTE_ZOOM = 16;
  var gpsWorldX = 8388608;
  var gpsWorldY = 8388608;
  var txQueue = [];
  var txBusy = false;
  var didSendStartupState = false;
  var fixtureOptions = Pebble.__mappyFixtureOptions || {};
  var txSuccessDelayMs = numberOption('txSuccessDelayMs', 5, 0, 5000);
  var txFailureDelayMs = numberOption('txFailureDelayMs', 25, 0, 5000);
  var tileDelayMs = numberOption('tileDelayMs', 0, 0, 60000);
  var tileStaggerMs = numberOption('tileStaggerMs', 0, 0, 60000);
  var tileAnimationMode = numberOption('tileAnimationMode', -1, -1, 2);
  var routePointCount = numberOption('routePointCount', 3, 3, 128);
  var phoneReadyDelayMs = numberOption('phoneReadyDelayMs', 0, 0, 60000);
  var ignoreStartupReady = fixtureOptions.ignoreStartupReady === true;
  var ignoreFirstInit = fixtureOptions.ignoreFirstInit === true;
  var injectStaleTileFirst = fixtureOptions.injectStaleTileFirst === true;
  var tileSequence = 0;
  var initCount = 0;

  function numberOption(name, fallback, minValue, maxValue) {
    var value = Number(fixtureOptions[name]);
    if (!isFinite(value)) return fallback;
    value = Math.round(value);
    return Math.max(minValue, Math.min(maxValue, value));
  }

  function pick(payload, name, id) {
    if (payload[name] !== undefined) return payload[name];
    if (payload[String(id)] !== undefined) return payload[String(id)];
    return undefined;
  }

  function enqueue(label, dict) {
    txQueue.push({ label: label, dict: dict });
    pumpQueue();
  }

  function enqueueDelayed(label, dict, delayMs) {
    if (delayMs <= 0) {
      enqueue(label, dict);
      return;
    }
    setTimeout(function() {
      enqueue(label, dict);
    }, delayMs);
  }

  function summarize(dict) {
    var clone = {};
    for (var key in dict) {
      if (!Object.prototype.hasOwnProperty.call(dict, key)) continue;
      if (key === 'chunk_data' && dict[key] && dict[key].length !== undefined) {
        clone[key] = '<' + dict[key].length + ' bytes>';
      } else {
        clone[key] = dict[key];
      }
    }
    return clone;
  }

  function pumpQueue() {
    if (txBusy || txQueue.length === 0) return;
    var next = txQueue.shift();
    txBusy = true;
    console.log('[mappy-map-mock] tx ' + next.label + ' ' + JSON.stringify(summarize(next.dict)));
    Pebble.sendAppMessage(next.dict, function() {
      txBusy = false;
      setTimeout(pumpQueue, txSuccessDelayMs);
    }, function(e) {
      txBusy = false;
      console.log('[mappy-map-mock] tx-fail ' + next.label + ' ' + JSON.stringify(e));
      setTimeout(pumpQueue, txFailureDelayMs);
    });
  }

  function i32le(bytes, value) {
    var unsigned = value >>> 0;
    bytes.push(unsigned & 0xff);
    bytes.push((unsigned >>> 8) & 0xff);
    bytes.push((unsigned >>> 16) & 0xff);
    bytes.push((unsigned >>> 24) & 0xff);
  }

  function utf8ish(text, maxBytes) {
    var bytes = [];
    for (var i = 0; i < text.length && bytes.length < maxBytes; i++) {
      var code = text.charCodeAt(i);
      bytes.push(code < 128 ? code : 0x3f);
    }
    return bytes;
  }

  function encodeDestinations() {
    var bytes = [0x82];
    var label0 = utf8ish('North Gate', 30);
    bytes.push(0, 2, 2);
    i32le(bytes, 0);
    i32le(bytes, 0);
    bytes.push(label0.length);
    Array.prototype.push.apply(bytes, label0);

    var label1 = utf8ish('Central Station', 30);
    bytes.push(1, 2, 0);
    i32le(bytes, 100000);
    i32le(bytes, 100000);
    bytes.push(label1.length);
    Array.prototype.push.apply(bytes, label1);
    return bytes;
  }

  function tilePaletteIndex(wx, wy, px, py) {
    var roadX = Math.abs((wx + px) % 61);
    var roadY = Math.abs((wy + py) % 83);
    if (roadX < 4 || roadY < 4) return 6;
    if (((wx + px + wy + py) % 137) < 8) return 8;
    if (((wx >> 4) + (wy >> 4) + Math.floor(px / 18) + Math.floor(py / 21)) % 5 === 0) return 4;
    return 1 + ((Math.floor((wx + px) / 27) + Math.floor((wy + py) / 31)) % 3);
  }

  function encodeTile(wx, wy) {
    var encoded = [];
    var runValue = -1;
    var runLength = 0;

    function flush() {
      if (runLength > 0) {
        encoded.push(((runLength - 1) << 4) | (runValue & 0x0f));
      }
    }

    for (var py = 0; py < TILE_H; py++) {
      for (var px = 0; px < TILE_W; px++) {
        var value = tilePaletteIndex(wx, wy, px, py) & 0x0f;
        if (value === runValue && runLength < 16) {
          runLength++;
        } else {
          flush();
          runValue = value;
          runLength = 1;
        }
      }
    }
    flush();
    return encoded;
  }

  function encodeRoute() {
    var points;
    if (routePointCount === 3) {
      points = [
        { x: gpsWorldX - 78, y: gpsWorldY + 76 },
        { x: gpsWorldX - 22, y: gpsWorldY + 18 },
        { x: gpsWorldX + 64, y: gpsWorldY - 68 }
      ];
    } else {
      points = [];
      var midpoint = Math.floor((routePointCount - 1) / 2);
      for (var pointIndex = 0; pointIndex < routePointCount; pointIndex++) {
        var x = gpsWorldX - 900 +
            Math.round(1800 * pointIndex / (routePointCount - 1));
        var y = gpsWorldY + ((pointIndex * 37) % 41 - 20) * 3;
        if (pointIndex === midpoint) {
          x = gpsWorldX;
          y = gpsWorldY;
        }
        points.push({ x: x, y: y });
      }
    }
    var bytes = [points.length & 0xff, (points.length >> 8) & 0xff, ROUTE_ZOOM];
    for (var i = 0; i < points.length; i++) {
      i32le(bytes, points[i].x);
      i32le(bytes, points[i].y);
    }
    return bytes;
  }

  function encodeNavSteps(firstIndex) {
    var steps = [
      {
        index: 0,
        x: gpsWorldX - 78,
        y: gpsWorldY + 76,
        meters: 1200,
        seconds: 420,
        instruction: 'Head north, then turn right'
      },
      {
        index: 1,
        x: gpsWorldX - 16,
        y: gpsWorldY + 12,
        meters: 480,
        seconds: 180,
        instruction: 'Continue to destination'
      }
    ];
    var selected = [];
    for (var i = 0; i < steps.length && selected.length < 3; i++) {
      if (steps[i].index >= firstIndex) selected.push(steps[i]);
    }
    if (selected.length === 0) selected.push(steps[steps.length - 1]);
    var bytes = [steps.length, firstIndex & 0xff, selected.length];
    for (var s = 0; s < selected.length; s++) {
      var step = selected[s];
      var instruction = utf8ish(step.instruction, 47);
      bytes.push(step.index & 0xff);
      i32le(bytes, step.x);
      i32le(bytes, step.y);
      bytes.push(step.meters & 0xff, (step.meters >> 8) & 0xff);
      bytes.push(step.seconds & 0xff, (step.seconds >> 8) & 0xff);
      bytes.push(instruction.length);
      Array.prototype.push.apply(bytes, instruction);
    }
    return bytes;
  }

  function sendReadyState() {
    if (didSendStartupState) {
      return;
    }
    didSendStartupState = true;
    enqueue('phone-ready', {
      cmd: CMD_PHONE_READY,
      protocol_version: 2
    });
    enqueue('theme', { cmd: CMD_THEME, button_id: 1 });
    enqueue('units', { cmd: CMD_UNITS, button_id: 1 });
    enqueue('backlight', { cmd: CMD_BACKLIGHT, button_id: 0 });
    if (tileAnimationMode >= 0) {
      enqueue('tile-animation', {
        cmd: CMD_TILE_ANIMATION,
        button_id: tileAnimationMode
      });
    }
    enqueue('destinations', {
      cmd: CMD_DESTINATIONS,
      total_bytes: encodeDestinations().length,
      chunk_data: encodeDestinations()
    });
    enqueue('gps', {
      cmd: CMD_GPS,
      world_x: gpsWorldX,
      world_y: gpsWorldY,
      tile_zoom: ROUTE_ZOOM,
      button_id: 35
    });
    if (routePointCount > 3) {
      enqueue('stress-route', {
        cmd: CMD_ROUTE_POINTS,
        button_id: 1,
        is_color: 2,
        request_id: 1,
        total_bytes: 1,
        chunk_index: 1,
        chunk_data: encodeRoute()
      });
      enqueue('stress-nav', {
        cmd: CMD_NAV_STEPS,
        request_id: 1,
        total_bytes: 1,
        chunk_data: encodeNavSteps(0)
      });
    }
  }

  Pebble.addEventListener('ready', function() {
    console.log('[mappy-map-mock] ready');
    if (!ignoreStartupReady) sendReadyState();
  });

  Pebble.addEventListener('appmessage', function(e) {
    var payload = e.payload || {};
    var cmd = Number(pick(payload, 'cmd', KEY_CMD));
    console.log('[mappy-map-mock] rx cmd=' + cmd + ' ' + JSON.stringify(payload));

    if (cmd === CMD_INIT) {
      initCount++;
      if (ignoreFirstInit && initCount === 1) {
        console.log('[mappy-map-mock] intentionally dropped first init');
        return;
      }
      setTimeout(sendReadyState, phoneReadyDelayMs);
      return;
    }

    if (cmd === CMD_TILE_REQUEST) {
      var wx = Number(pick(payload, 'world_x', KEY_WORLD_X) || 0);
      var wy = Number(pick(payload, 'world_y', KEY_WORLD_Y) || 0);
      var zoom = Number(pick(payload, 'tile_zoom', KEY_TILE_ZOOM) || ROUTE_ZOOM);
      var requestId = Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 0);
      var tile = encodeTile(wx, wy);
      var tileMessage = {
        cmd: CMD_TILE,
        world_x: wx,
        world_y: wy,
        tile_zoom: zoom,
        total_bytes: tile.length,
        request_id: requestId,
        chunk_data: tile
      };
      var delayMs = tileDelayMs + tileSequence * tileStaggerMs;
      tileSequence++;
      if (injectStaleTileFirst) {
        var staleTileMessage = {};
        for (var tileKey in tileMessage) {
          if (Object.prototype.hasOwnProperty.call(tileMessage, tileKey)) {
            staleTileMessage[tileKey] = tileMessage[tileKey];
          }
        }
        staleTileMessage.request_id = Math.max(0, requestId - 1);
        enqueueDelayed('stale-tile', staleTileMessage, delayMs);
        delayMs += 25;
      }
      enqueueDelayed('tile', tileMessage, delayMs);
      return;
    }

    if (cmd === CMD_ROUTE_REQUEST) {
      var slot = Number(pick(payload, 'button_id', KEY_BUTTON_ID) || 0);
      if (slot > 1) {
        enqueue('empty-slot', {
          cmd: CMD_ERROR_STATE,
          button_id: 8,
          chunk_index: CMD_ROUTE_REQUEST,
          chunk_offset: slot,
          instruction: 'Destination not configured'
        });
        return;
      }
      enqueue('route', {
        cmd: CMD_ROUTE_POINTS,
        button_id: 1,
        request_id: Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 1),
        total_bytes: 1,
        chunk_index: 1,
        chunk_data: encodeRoute()
      });
      enqueue('nav', {
        cmd: CMD_NAV_STEPS,
        request_id: Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 1),
        total_bytes: 1,
        chunk_data: encodeNavSteps(0)
      });
      return;
    }

    if (cmd === CMD_NAV_STEPS) {
      enqueue('nav-request', {
        cmd: CMD_NAV_STEPS,
        request_id: Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 1),
        total_bytes: Number(pick(payload, 'total_bytes', 56) || 1),
        chunk_data: encodeNavSteps(Number(pick(payload, 'button_id', KEY_BUTTON_ID) || 0))
      });
      return;
    }

    if (cmd === CMD_ROUTE_CLEAR) {
      enqueue('route-clear', { cmd: CMD_ROUTE_CLEAR });
      return;
    }

    if (cmd === CMD_ROUTE_APPLIED) {
      console.log('[mappy-map-mock] route applied request=' +
          Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 0));
      return;
    }

    if (cmd === CMD_ROUTE_COMPLETE) {
      console.log('[mappy-map-mock] route complete request=' +
          Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 0));
      return;
    }

    if (cmd === CMD_TRAVEL_MODE) {
      var travelMode = pick(payload, 'button_id', KEY_BUTTON_ID);
      enqueue('travel-mode', {
        cmd: CMD_TRAVEL_MODE,
        button_id: Number(travelMode === undefined ? 2 : travelMode)
      });
      return;
    }

    if (cmd === CMD_BUTTON) {
      console.log('[mappy-map-mock] zoom notice ' + JSON.stringify(payload));
    }
  });
})();
