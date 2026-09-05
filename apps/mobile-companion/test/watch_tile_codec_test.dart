import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mappy/watch_protocol.dart';

void main() {
  final vectors =
      jsonDecode(
            File('../../tooling/tile-codec-vectors.json').readAsStringSync(),
          )
          as List;

  group('shared Android/watch tile codec vectors', () {
    for (final raw in vectors) {
      final vector = Map<String, Object?>.from(raw as Map);
      test(vector['name'] as String, () {
        final payload = Uint8List.fromList(
          (vector['payload'] as List).cast<int>(),
        );
        final tile = decodeWatchTile(
          WatchMessage.command(WatchCommands.tile, {
            WatchKeys.worldX: 100,
            WatchKeys.worldY: 200,
            WatchKeys.tileZoom: 16,
            WatchKeys.width: vector['width'],
            WatchKeys.height: vector['height'],
            WatchKeys.compressionFormat: vector['format'],
            WatchKeys.totalBytes: payload.length,
            WatchKeys.chunkData: payload,
          }),
        );
        expect(tile.decodedNibbles, (vector['packed'] as List).cast<int>());
        expect(tile.compressionFormat, vector['format']);
      });
    }
  });

  test('LZ4 copies overlapping matches and the final literals', () {
    final payload = Uint8List.fromList([
      0x18,
      65,
      1,
      0,
      0x50,
      66,
      67,
      68,
      69,
      70,
    ]);
    expect(decodeLz4Block(payload, maxOutputBytes: 18), [
      ...List<int>.filled(13, 65),
      66,
      67,
      68,
      69,
      70,
    ]);
  });

  test('LZ4 accepts extended literal lengths at the exact output bound', () {
    final literals = List<int>.generate(300, (index) => index & 255);
    final payload = Uint8List.fromList([0xf0, 255, 30, ...literals]);
    expect(decodeLz4Block(payload, maxOutputBytes: 300), literals);
    expect(
      () => decodeLz4Block(payload, maxOutputBytes: 299),
      throwsA(isA<WatchProtocolException>()),
    );
  });

  test('LZ4 rejects malformed lengths offsets and output overflow', () {
    final malformed = <List<int>>[
      [],
      [0xf0],
      [0xf0, 255],
      [0x20, 65],
      [0x10, 65, 1],
      [0x10, 65, 0, 0, 0],
      [0x10, 65, 2, 0, 0],
      [0x1f, 65, 1, 0],
      [0x1f, 65, 1, 0, 255, 255, 255, 0, 0],
      [0x10, 65, 1, 0],
      [0x10, 65, 1, 0, 0],
      [0x10, 65, 1, 0, 0x50, 66, 67, 68, 69, 70],
      [0x18, 65, 1, 0, 0x40, 66, 67, 68, 69],
    ];
    for (final payload in malformed) {
      expect(
        () => decodeLz4Block(Uint8List.fromList(payload), maxOutputBytes: 32),
        throwsA(isA<WatchProtocolException>()),
        reason: '$payload',
      );
    }
  });

  test('v4 requires codec geometry and a complete payload', () {
    final payload = Uint8List(watchDecodedTileBytes);
    final fields = <String, Object?>{
      WatchKeys.worldX: 100,
      WatchKeys.worldY: 200,
      WatchKeys.tileZoom: 16,
      WatchKeys.width: watchTileWidth,
      WatchKeys.height: watchTileHeight,
      WatchKeys.compressionFormat: WatchTileCompression.packed,
      WatchKeys.totalBytes: payload.length,
      WatchKeys.chunkData: payload,
    };
    expect(
      decodeWatchTile(
        WatchMessage.command(WatchCommands.tile, fields),
      ).paletteIndexes,
      everyElement(0),
    );
    for (final key in [
      WatchKeys.compressionFormat,
      WatchKeys.width,
      WatchKeys.height,
      WatchKeys.totalBytes,
      WatchKeys.worldX,
    ]) {
      expect(
        () => decodeWatchTile(
          WatchMessage.command(WatchCommands.tile, {...fields}..remove(key)),
        ),
        throwsA(isA<WatchProtocolException>()),
      );
    }
    for (final mutation in <Map<String, Object?>>[
      {WatchKeys.compressionFormat: 0},
      {WatchKeys.compressionFormat: 5},
      {WatchKeys.width: 1000000000},
      {WatchKeys.height: -1},
      {WatchKeys.totalBytes: payload.length + 1},
      {
        WatchKeys.chunkData: Uint8List(payload.length - 1),
        WatchKeys.totalBytes: payload.length - 1,
      },
    ]) {
      expect(
        () => decodeWatchTile(
          WatchMessage.command(WatchCommands.tile, {...fields, ...mutation}),
        ),
        throwsA(isA<WatchProtocolException>()),
      );
    }
  });

  test('packed nibble order matches the watch storage format', () {
    expect(
      unpackPaletteNibbles(
        Uint8List.fromList([0x21, 0x43]),
        width: 2,
        height: 2,
      ),
      [1, 2, 3, 4],
    );
  });
}
