# Mappy

Mappy is a free and open-source map and navigation system for Pebble watches.
The watch app is intentionally network-blind; a dedicated mobile companion owns
location, provider access, routing, tile generation, settings, and diagnostics.

## Layout

- `apps/pebble-watch` - Pebble SDK watch app targeting Pebble Time 2.
- `apps/mobile-companion` - dedicated Flutter Android companion app pinned to
  Flutter 3.44.1.
- `specs` - product, architecture, MVP, provider, protocol, and
  layer behavior specifications.
- `tooling` - local setup helpers for development environments.
- `.agents/skills/pebble-emulator` - repository-scoped Codex workflow for
  building and testing the watch app in the Pebble emulator.

## Current Scope

The app is backend-free: the user supplies a Google Maps Platform API key, and
the Android companion performs map, route, tile, location, and diagnostic work
locally. The current implementation includes the native Android bridge, BYOK
provider path, Flutter welcome/Navigate/Status/Setup UI, watch transport, map
tile/routing workers, diagnostics, and local tests. Final release signing and
hardware/device acceptance remain release gates.
