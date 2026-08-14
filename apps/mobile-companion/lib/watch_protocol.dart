import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

typedef AppMessageDictionary = Map<String, Object?>;

abstract final class WatchKeys {
  static const cmd = 'cmd';
  static const width = 'width';
  static const height = 'height';
  static const bytesPerRow = 'bytes_per_row';
  static const isColor = 'is_color';
  static const compressionFormat = 'compression_format';
  static const totalBytes = 'total_bytes';
  static const chunkIndex = 'chunk_index';
  static const chunkOffset = 'chunk_offset';
  static const chunkData = 'chunk_data';
  static const buttonId = 'button_id';
  static const instruction = 'instruction';
  static const destination = 'destination';
  static const worldX = 'world_x';
  static const worldY = 'world_y';
  static const tileZoom = 'tile_zoom';
  static const gpsSequence = 'gps_sequence';
  static const gpsElapsedMs = 'gps_elapsed_ms';
  static const gpsAccuracyCm = 'gps_accuracy_cm';
  static const gpsProvider = 'gps_provider';
  static const requestId = 'request_id';
  static const protocolVersion = 'protocol_version';
}

abstract final class WatchCommands {
  static const init = 101;
  static const errorState = 102;
  static const logEvent = 103;
  static const phoneReady = 104;
  static const gps = 201;
  static const tileRequest = 202;
  static const tile = 203;
  static const mapSettings = 204;
  static const mapOrientation = 205;
  static const tileAnimation = 206;
  static const button = 207;
  static const destinations = 301;
  static const routeRequest = 302;
  static const routePoints = 303;
  static const routeClear = 304;
  static const navSteps = 305;
  static const routeWindowRequest = 306;
  static const routeWindowPoints = 307;
  static const routeApplied = 308;
  static const routeComplete = 309;
  static const theme = 401;
  static const travelMode = 402;
  static const units = 403;
  static const backlight = 404;
  static const declination = 405;
  static const hapticMode = 406;
  static const glanceMode = 407;
  static const debugCompass = 901;
  static const debugTile = 902;
  static const debugRouteProgress = 903;
}

const watchProtocolVersion = 3;

const watchTileWidth = 54;
const watchTileHeight = 63;
const watchTilePixels = watchTileWidth * watchTileHeight;
const watchDecodedTileBytes = watchTilePixels ~/ 2;
const watchTileGridCols = 5;
const watchTileGridRows = 5;
const watchRotatedTileGridCols = 7;
const watchRotatedTileGridRows = 6;
const emeryViewportWidth = 200;
const emeryViewportHeight = 228;
const routeWorldZoom = 16;
const sourceTileSize = 256;
const maxRoutePoints = 128;
const maxWatchTextBytes = 47;
const maxDestinationRecords = 0x7f;
const maxSavedLocationId = 253;
const maxDestinationLabelBytes = 30;

bool isSavedLocationId(int value) => value >= 0 && value <= maxSavedLocationId;

enum WatchThemeMode {
  auto(0, 'Auto'),
  day(1, 'Day'),
  night(2, 'Night');

  const WatchThemeMode(this.protocolValue, this.label);

  final int protocolValue;
  final String label;

  static WatchThemeMode fromProtocol(int? value) {
    return switch (value) {
      1 => WatchThemeMode.day,
      2 => WatchThemeMode.night,
      _ => WatchThemeMode.auto,
    };
  }
}

enum WatchTravelMode {
  walk(0, 'Walk'),
  bike(1, 'Bike'),
  drive(2, 'Drive');

  const WatchTravelMode(this.protocolValue, this.label);

  final int protocolValue;
  final String label;

  static WatchTravelMode fromProtocol(int? value) {
    return switch (value) {
      0 => WatchTravelMode.walk,
      1 => WatchTravelMode.bike,
      _ => WatchTravelMode.drive,
    };
  }
}

enum WatchUnitsMode {
  imperial(0, 'Imperial'),
  metric(1, 'Metric');

  const WatchUnitsMode(this.protocolValue, this.label);

  final int protocolValue;
  final String label;

  static WatchUnitsMode fromProtocol(int? value) {
    return switch (value) {
      0 => WatchUnitsMode.imperial,
      _ => WatchUnitsMode.metric,
    };
  }
}

enum WatchBacklightMode {
  system(0, 'System'),
  keepOn(1, 'Keep on');

  const WatchBacklightMode(this.protocolValue, this.label);

  final int protocolValue;
  final String label;

  static WatchBacklightMode fromProtocol(int? value) {
    return switch (value) {
      1 => WatchBacklightMode.keepOn,
      _ => WatchBacklightMode.system,
    };
  }
}

enum WatchNavigationFeedbackMode {
  all(3, 'All'),
  turns(1, 'Turns'),
  arrival(2, 'Arrival'),
  off(0, 'Off');

  const WatchNavigationFeedbackMode(this.protocolValue, this.label);

  final int protocolValue;
  final String label;

  static WatchNavigationFeedbackMode fromProtocol(int? value) {
    return switch (value) {
      0 => WatchNavigationFeedbackMode.off,
      1 => WatchNavigationFeedbackMode.turns,
      2 => WatchNavigationFeedbackMode.arrival,
      _ => WatchNavigationFeedbackMode.all,
    };
  }
}

enum WatchMapOrientation {
  northUp(0, 'North up'),
  forwardUp(1, 'Face forward');

  const WatchMapOrientation(this.protocolValue, this.label);

  final int protocolValue;
  final String label;

  static WatchMapOrientation fromProtocol(int? value) {
    return switch (value) {
      1 => WatchMapOrientation.forwardUp,
      _ => WatchMapOrientation.northUp,
    };
  }
}

enum WatchTileAnimationMode {
  none(0, 'No Animation'),
  fadeIn(1, 'Fade In'),
  fadeZoom(2, 'Fade + Zoom');

  const WatchTileAnimationMode(this.protocolValue, this.label);

  final int protocolValue;
  final String label;

  static WatchTileAnimationMode fromProtocol(int? value) {
    return switch (value) {
      1 => WatchTileAnimationMode.fadeIn,
      2 => WatchTileAnimationMode.fadeZoom,
      _ => WatchTileAnimationMode.none,
    };
  }
}

enum TouchPlatformMode {
  enabled('PBL_TOUCH enabled'),
  disabled('PBL_TOUCH disabled'),
  unavailable('No touch support');

  const TouchPlatformMode(this.label);

  final String label;

  bool get productionTouchEnabled => this == TouchPlatformMode.enabled;
}

enum PinchCapabilityMode {
  reliable('Pinch reliable'),
  coarse('Pinch discrete'),
  unavailable('No pinch data');

  const PinchCapabilityMode(this.label);

  final String label;

  bool get productionPinchEnabled => this != PinchCapabilityMode.unavailable;

  bool get smoothTransientZoom => this == PinchCapabilityMode.reliable;
}

class WatchMessage {
  WatchMessage(AppMessageDictionary fields)
    : fields = Map<String, Object?>.unmodifiable(fields);

  WatchMessage.command(int command, [AppMessageDictionary fields = const {}])
    : fields = Map<String, Object?>.unmodifiable({
        ...fields,
        WatchKeys.cmd: command,
      });

  final AppMessageDictionary fields;

  int? get command => asInt(fields[WatchKeys.cmd]);

  Uint8List? get chunkData => bytesFromValue(fields[WatchKeys.chunkData]);

  String get commandName => watchCommandName(command);

  String get summary {
    final command = this.command;
    if (command == WatchCommands.tile || command == WatchCommands.tileRequest) {
      return '$commandName ${asInt(fields[WatchKeys.worldX])},'
          '${asInt(fields[WatchKeys.worldY])} z${asInt(fields[WatchKeys.tileZoom])}';
    }
    if (command == WatchCommands.errorState) {
      return '$commandName category ${asInt(fields[WatchKeys.buttonId])}';
    }
    if (command == WatchCommands.routeRequest) {
      return '$commandName slot ${asInt(fields[WatchKeys.buttonId])}';
    }
    final bytes = chunkData;
    if (bytes != null) {
      return '$commandName ${bytes.length} bytes';
    }
    return commandName;
  }
}

class WatchProtocolException implements Exception {
  const WatchProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WorldPoint {
  const WorldPoint({required this.worldX, required this.worldY});

  final int worldX;
  final int worldY;
}

class DecodedWatchTile {
  const DecodedWatchTile({
    required this.worldX,
    required this.worldY,
    required this.zoom,
    required this.width,
    required this.height,
    required this.encodedBytes,
    required this.decodedNibbles,
    required this.paletteIndexes,
  });

  final int worldX;
  final int worldY;
  final int zoom;
  final int width;
  final int height;
  final int encodedBytes;
  final Uint8List decodedNibbles;
  final Uint8List paletteIndexes;

  String get cacheKey => '$worldX:$worldY:$zoom:$width:$height';
}

class WatchDestinationRecord {
  const WatchDestinationRecord({
    required this.slotIndex,
    required this.kind,
    required this.defaultTravelMode,
    required this.latitude,
    required this.longitude,
    required this.label,
  });

  final int slotIndex;
  final int kind;
  final WatchTravelMode defaultTravelMode;
  final double latitude;
  final double longitude;
  final String label;
}

class DecodedRoutePayload {
  const DecodedRoutePayload({
    required this.zoom,
    required this.points,
    required this.clearsRoute,
  });

  final int zoom;
  final List<WorldPoint> points;
  final bool clearsRoute;
}

class WatchNavStep {
  const WatchNavStep({
    required this.globalIndex,
    required this.startWorldX,
    required this.startWorldY,
    required this.remainingMeters,
    required this.remainingSeconds,
    required this.instruction,
  });

  final int globalIndex;
  final int startWorldX;
  final int startWorldY;
  final int remainingMeters;
  final int remainingSeconds;
  final String instruction;
}

class DecodedNavStepsPayload {
  const DecodedNavStepsPayload({
    required this.totalSteps,
    required this.firstGlobalIndex,
    required this.steps,
  });

  final int totalSteps;
  final int firstGlobalIndex;
  final List<WatchNavStep> steps;
}

int? asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double && value.isFinite) {
    return value.round();
  }
  return null;
}

Uint8List? bytesFromValue(Object? value) {
  if (value is Uint8List) {
    return value;
  }
  if (value is ByteData) {
    return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
  }
  if (value is List<int>) {
    return Uint8List.fromList(value);
  }
  if (value is String) {
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }
  return null;
}

String watchCommandName(int? command) {
  return switch (command) {
    WatchCommands.init => 'CMD_INIT',
    WatchCommands.phoneReady => 'CMD_PHONE_READY',
    WatchCommands.tile => 'CMD_TILE',
    WatchCommands.button => 'CMD_BUTTON',
    WatchCommands.gps => 'CMD_GPS',
    WatchCommands.theme => 'CMD_THEME',
    WatchCommands.tileRequest => 'CMD_TILE_REQUEST',
    WatchCommands.destinations => 'CMD_DESTINATIONS',
    WatchCommands.routeRequest => 'CMD_ROUTE_REQUEST',
    WatchCommands.routePoints => 'CMD_ROUTE_POINTS',
    WatchCommands.routeClear => 'CMD_ROUTE_CLEAR',
    WatchCommands.travelMode => 'CMD_TRAVEL_MODE',
    WatchCommands.navSteps => 'CMD_NAV_STEPS',
    WatchCommands.units => 'CMD_UNITS',
    WatchCommands.logEvent => 'CMD_LOG_EVENT',
    WatchCommands.mapSettings => 'CMD_MAP_SETTINGS',
    WatchCommands.backlight => 'CMD_BACKLIGHT',
    WatchCommands.declination => 'CMD_DECLINATION',
    WatchCommands.hapticMode => 'CMD_HAPTIC_MODE',
    WatchCommands.glanceMode => 'CMD_GLANCE_MODE',
    WatchCommands.errorState => 'CMD_ERROR_STATE',
    WatchCommands.mapOrientation => 'CMD_MAP_ORIENTATION',
    WatchCommands.tileAnimation => 'CMD_TILE_ANIMATION',
    WatchCommands.routeWindowRequest => 'CMD_ROUTE_WINDOW_REQUEST',
    WatchCommands.routeWindowPoints => 'CMD_ROUTE_WINDOW_POINTS',
    WatchCommands.routeApplied => 'CMD_ROUTE_APPLIED',
    WatchCommands.routeComplete => 'CMD_ROUTE_COMPLETE',
    WatchCommands.debugCompass => 'CMD_DEBUG_COMPASS',
    WatchCommands.debugTile => 'CMD_DEBUG_TILE',
    WatchCommands.debugRouteProgress => 'CMD_DEBUG_ROUTE_PROGRESS',
    null => 'UNKNOWN',
    _ => 'CMD_$command',
  };
}

WorldPoint latLngToWorldPixels(
  double latitude,
  double longitude, {
  int zoom = routeWorldZoom,
}) {
  final scale = 1 << zoom;
  final clampedLat = latitude.clamp(-85.05112878, 85.05112878).toDouble();
  final wrappedLng = ((longitude + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;
  final latRad = clampedLat * math.pi / 180.0;
  final worldX = ((wrappedLng + 180.0) / 360.0) * scale * sourceTileSize;
  final mercator =
      (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
      2.0;
  final worldY = mercator * scale * sourceTileSize;
  return WorldPoint(worldX: worldX.round(), worldY: worldY.round());
}

DecodedWatchTile decodeWatchTile(WatchMessage message) {
  final bytes = message.chunkData;
  final worldX = asInt(message.fields[WatchKeys.worldX]);
  final worldY = asInt(message.fields[WatchKeys.worldY]);
  final zoom = asInt(message.fields[WatchKeys.tileZoom]);
  final width = asInt(message.fields[WatchKeys.width]) ?? watchTileWidth;
  final height = asInt(message.fields[WatchKeys.height]) ?? watchTileHeight;
  final totalBytes = asInt(message.fields[WatchKeys.totalBytes]);
  if (bytes == null) {
    throw const WatchProtocolException('Tile message has no chunk_data.');
  }
  if (worldX == null || worldY == null || zoom == null) {
    throw const WatchProtocolException(
      'Tile message is missing x, y, or zoom.',
    );
  }
  if (totalBytes != bytes.length) {
    throw WatchProtocolException(
      'Tile total_bytes $totalBytes does not match ${bytes.length}.',
    );
  }
  final paletteIndexes = decodeRlePaletteIndexes(
    bytes,
    width: width,
    height: height,
  );
  return DecodedWatchTile(
    worldX: worldX,
    worldY: worldY,
    zoom: zoom,
    width: width,
    height: height,
    encodedBytes: bytes.length,
    decodedNibbles: packPaletteNibbles(
      paletteIndexes,
      width: width,
      height: height,
    ),
    paletteIndexes: paletteIndexes,
  );
}

Uint8List decodeRlePaletteIndexes(
  Uint8List bytes, {
  int width = watchTileWidth,
  int height = watchTileHeight,
}) {
  final tilePixels = width * height;
  if (bytes.length > tilePixels) {
    throw const WatchProtocolException('Tile RLE payload is oversized.');
  }
  final output = Uint8List(tilePixels);
  var outputIndex = 0;
  for (final byte in bytes) {
    final runLength = (byte >> 4) + 1;
    final paletteIndex = byte & 0x0f;
    if (outputIndex + runLength > tilePixels) {
      throw const WatchProtocolException('Tile RLE payload overfills tile.');
    }
    output.fillRange(outputIndex, outputIndex + runLength, paletteIndex);
    outputIndex += runLength;
  }
  if (outputIndex != tilePixels) {
    throw const WatchProtocolException('Tile RLE payload underfills tile.');
  }
  return output;
}

Uint8List encodeRlePaletteIndexes(
  List<int> paletteIndexes, {
  int width = watchTileWidth,
  int height = watchTileHeight,
}) {
  final tilePixels = width * height;
  if (paletteIndexes.length != tilePixels) {
    throw WatchProtocolException(
      'Tile source has ${paletteIndexes.length} pixels, expected $tilePixels.',
    );
  }
  final output = BytesBuilder(copy: false);
  var index = 0;
  while (index < paletteIndexes.length) {
    final paletteIndex = paletteIndexes[index] & 0x0f;
    var runLength = 1;
    while (index + runLength < paletteIndexes.length &&
        runLength < 16 &&
        (paletteIndexes[index + runLength] & 0x0f) == paletteIndex) {
      runLength++;
    }
    output.addByte(((runLength - 1) << 4) | paletteIndex);
    index += runLength;
  }
  return output.takeBytes();
}

Uint8List packPaletteNibbles(
  Uint8List paletteIndexes, {
  int width = watchTileWidth,
  int height = watchTileHeight,
}) {
  final tilePixels = width * height;
  if (paletteIndexes.length != tilePixels) {
    throw const WatchProtocolException('Decoded tile pixel count is invalid.');
  }
  final output = Uint8List((tilePixels + 1) ~/ 2);
  for (var index = 0; index < paletteIndexes.length; index += 2) {
    output[index ~/ 2] =
        (paletteIndexes[index] & 0x0f) |
        ((paletteIndexes[index + 1] & 0x0f) << 4);
  }
  return output;
}

List<WatchDestinationRecord> decodeDestinations(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const WatchProtocolException('Destination payload is empty.');
  }
  final header = bytes[0];
  if ((header & 0x80) == 0) {
    throw const WatchProtocolException(
      'Destination payload discriminator missing.',
    );
  }
  final count = header & 0x7f;
  if (count > maxDestinationRecords) {
    throw const WatchProtocolException('Destination count exceeds 127.');
  }
  final destinations = <WatchDestinationRecord>[];
  final seenSlots = <int>{};
  var offset = 1;
  for (var index = 0; index < count; index++) {
    if (offset + 12 > bytes.length) {
      throw const WatchProtocolException('Destination record is truncated.');
    }
    final slot = bytes[offset++];
    if (!isSavedLocationId(slot)) {
      throw const WatchProtocolException('Destination slot is out of range.');
    }
    if (!seenSlots.add(slot)) {
      throw const WatchProtocolException('Destination slot is duplicated.');
    }
    final kind = bytes[offset++];
    final mode = WatchTravelMode.fromProtocol(bytes[offset++]);
    final latitudeE7 = _readInt32(bytes, offset);
    offset += 4;
    final longitudeE7 = _readInt32(bytes, offset);
    offset += 4;
    final labelLength = bytes[offset++];
    if (labelLength > maxDestinationLabelBytes ||
        offset + labelLength > bytes.length) {
      throw const WatchProtocolException(
        'Destination label length is invalid.',
      );
    }
    final label = _decodeUtf8(bytes.sublist(offset, offset + labelLength));
    offset += labelLength;
    destinations.add(
      WatchDestinationRecord(
        slotIndex: slot,
        kind: kind,
        defaultTravelMode: mode,
        latitude: latitudeE7 / 1e7,
        longitude: longitudeE7 / 1e7,
        label: label,
      ),
    );
  }
  if (offset != bytes.length) {
    throw const WatchProtocolException(
      'Destination payload has trailing bytes.',
    );
  }
  return destinations;
}

Uint8List encodeDestinations(List<WatchDestinationRecord> destinations) {
  if (destinations.length > maxDestinationRecords) {
    throw const WatchProtocolException('Destination count exceeds 127.');
  }
  final output = BytesBuilder(copy: false)..addByte(0x80 | destinations.length);
  final seenSlots = <int>{};
  for (final destination in destinations) {
    if (!isSavedLocationId(destination.slotIndex)) {
      throw const WatchProtocolException('Destination slot is out of range.');
    }
    if (!seenSlots.add(destination.slotIndex)) {
      throw const WatchProtocolException('Destination slot is duplicated.');
    }
    final labelBytes = truncateUtf8Bytes(
      destination.label,
      maxDestinationLabelBytes,
    );
    output
      ..addByte(destination.slotIndex)
      ..addByte(destination.kind.clamp(0, 2))
      ..addByte(destination.defaultTravelMode.protocolValue)
      ..add(_int32Bytes((destination.latitude * 1e7).round()))
      ..add(_int32Bytes((destination.longitude * 1e7).round()))
      ..addByte(labelBytes.length)
      ..add(labelBytes);
  }
  return output.takeBytes();
}

DecodedRoutePayload decodeRoutePoints(Uint8List bytes) {
  if (bytes.length < 3) {
    throw const WatchProtocolException('Route payload is too short.');
  }
  final count = _readUint16(bytes, 0);
  final header = bytes[2];
  if ((header & 0x80) != 0) {
    throw const WatchProtocolException('Route header has reserved bit set.');
  }
  final zoom = header & 0x7f;
  if (zoom != routeWorldZoom) {
    throw const WatchProtocolException('Route zoom is unsupported.');
  }
  if (count > maxRoutePoints) {
    throw const WatchProtocolException('Route point count exceeds 128.');
  }
  if (count == 0) {
    if (bytes.length != 3) {
      throw const WatchProtocolException(
        'Zero-route payload has trailing bytes.',
      );
    }
    return DecodedRoutePayload(zoom: zoom, points: const [], clearsRoute: true);
  }
  if (count == 1) {
    throw const WatchProtocolException('Successful route contains one point.');
  }
  final expectedLength = 3 + count * 8;
  if (bytes.length != expectedLength) {
    throw WatchProtocolException(
      'Route payload length ${bytes.length} expected $expectedLength.',
    );
  }
  final points = <WorldPoint>[];
  var offset = 3;
  for (var index = 0; index < count; index++) {
    points.add(
      WorldPoint(
        worldX: _readInt32(bytes, offset),
        worldY: _readInt32(bytes, offset + 4),
      ),
    );
    offset += 8;
  }
  return DecodedRoutePayload(zoom: zoom, points: points, clearsRoute: false);
}

Uint8List encodeRoutePoints(
  List<WorldPoint> points, {
  int zoom = routeWorldZoom,
}) {
  if (points.length > maxRoutePoints) {
    throw const WatchProtocolException('Route point count exceeds 128.');
  }
  if (points.length == 1) {
    throw const WatchProtocolException('Successful route contains one point.');
  }
  final output = BytesBuilder(copy: false)
    ..add(_uint16Bytes(points.length))
    ..addByte(zoom & 0x7f);
  for (final point in points) {
    output
      ..add(_int32Bytes(point.worldX))
      ..add(_int32Bytes(point.worldY));
  }
  return output.takeBytes();
}

DecodedNavStepsPayload decodeNavSteps(Uint8List bytes) {
  if (bytes.length < 3) {
    throw const WatchProtocolException('Nav-step payload is too short.');
  }
  final totalSteps = bytes[0];
  final firstGlobalIndex = bytes[1];
  final chunkCount = bytes[2];
  if (chunkCount < 1 || chunkCount > 3) {
    throw const WatchProtocolException('Nav-step chunk count must be 1..3.');
  }
  final steps = <WatchNavStep>[];
  var offset = 3;
  for (var index = 0; index < chunkCount; index++) {
    if (offset + 14 > bytes.length) {
      throw const WatchProtocolException('Nav-step record is truncated.');
    }
    final globalIndex = bytes[offset++];
    final worldX = _readInt32(bytes, offset);
    offset += 4;
    final worldY = _readInt32(bytes, offset);
    offset += 4;
    final remainingMeters = _readUint16(bytes, offset);
    offset += 2;
    final remainingSeconds = _readUint16(bytes, offset);
    offset += 2;
    final instructionLength = bytes[offset++];
    if (instructionLength > maxWatchTextBytes ||
        offset + instructionLength > bytes.length) {
      throw const WatchProtocolException(
        'Nav-step instruction length is invalid.',
      );
    }
    final instruction = _decodeUtf8(
      bytes.sublist(offset, offset + instructionLength),
    );
    offset += instructionLength;
    steps.add(
      WatchNavStep(
        globalIndex: globalIndex,
        startWorldX: worldX,
        startWorldY: worldY,
        remainingMeters: remainingMeters,
        remainingSeconds: remainingSeconds,
        instruction: instruction,
      ),
    );
  }
  if (offset != bytes.length) {
    throw const WatchProtocolException('Nav-step payload has trailing bytes.');
  }
  return DecodedNavStepsPayload(
    totalSteps: totalSteps,
    firstGlobalIndex: firstGlobalIndex,
    steps: steps,
  );
}

Uint8List encodeNavSteps(List<WatchNavStep> allSteps, int firstGlobalIndex) {
  final chunk = allSteps
      .where((step) => step.globalIndex >= firstGlobalIndex)
      .take(3)
      .toList(growable: false);
  if (chunk.isEmpty) {
    throw const WatchProtocolException('Nav-step chunk is empty.');
  }
  final output = BytesBuilder(copy: false)
    ..addByte(allSteps.length.clamp(0, 255))
    ..addByte(firstGlobalIndex.clamp(0, 255))
    ..addByte(chunk.length);
  for (final step in chunk) {
    final instruction = truncateUtf8Bytes(step.instruction, maxWatchTextBytes);
    output
      ..addByte(step.globalIndex.clamp(0, 255))
      ..add(_int32Bytes(step.startWorldX))
      ..add(_int32Bytes(step.startWorldY))
      ..add(_uint16Bytes(step.remainingMeters.clamp(0, 65535)))
      ..add(_uint16Bytes(step.remainingSeconds.clamp(0, 65535)))
      ..addByte(instruction.length)
      ..add(instruction);
  }
  return output.takeBytes();
}

Uint8List truncateUtf8Bytes(String value, int maxBytes) {
  final builder = BytesBuilder(copy: false);
  for (final rune in value.runes) {
    final bytes = utf8.encode(String.fromCharCode(rune));
    if (builder.length + bytes.length > maxBytes) {
      break;
    }
    builder.add(bytes);
  }
  return builder.takeBytes();
}

String redactedProtocolValue(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is Uint8List) {
    return '<${value.length} bytes>';
  }
  if (value is ByteData) {
    return '<${value.lengthInBytes} bytes>';
  }
  if (value is List<int>) {
    return '<${value.length} bytes>';
  }
  if (value is Map) {
    return '{${value.entries.map((entry) => '${entry.key}: ${redactedProtocolValue(entry.value)}').join(', ')}}';
  }
  if (value is Iterable) {
    return '[${value.map(redactedProtocolValue).join(', ')}]';
  }
  final text = value.toString();
  return text
      .replaceAll(RegExp(r'AIza[0-9A-Za-z_-]{10,}'), '[redacted-google-key]')
      .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._-]+'), 'Bearer [redacted]')
      .replaceAllMapped(
        RegExp(r'(session=)[A-Za-z0-9._-]+'),
        (match) => '${match.group(1)}[redacted]',
      );
}

String redactedDictionary(AppMessageDictionary fields) {
  final entries = fields.entries.map(
    (entry) => '${entry.key}: ${redactedProtocolValue(entry.value)}',
  );
  return '{${entries.join(', ')}}';
}

int _readUint16(Uint8List bytes, int offset) {
  if (offset + 2 > bytes.length) {
    throw const WatchProtocolException('uint16 read exceeds payload.');
  }
  return ByteData.sublistView(
    bytes,
    offset,
    offset + 2,
  ).getUint16(0, Endian.little);
}

int _readInt32(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) {
    throw const WatchProtocolException('int32 read exceeds payload.');
  }
  return ByteData.sublistView(
    bytes,
    offset,
    offset + 4,
  ).getInt32(0, Endian.little);
}

Uint8List _uint16Bytes(int value) {
  final data = ByteData(2)..setUint16(0, value, Endian.little);
  return data.buffer.asUint8List();
}

Uint8List _int32Bytes(int value) {
  final data = ByteData(4)..setInt32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

String _decodeUtf8(Uint8List bytes) {
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes);
  } on FormatException {
    throw const WatchProtocolException('Payload contains invalid UTF-8.');
  }
}
