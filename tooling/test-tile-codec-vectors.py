#!/usr/bin/env python3
"""Compile production watch codecs with shared Kotlin/Dart golden vectors."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    source = ROOT / "tooling/tile-codec-vectors.json"
    vectors = json.loads(source.read_text())
    if isinstance(vectors, dict):
        vectors = vectors["vectors"]
    with tempfile.TemporaryDirectory(prefix="mappy-codec-") as temporary:
        directory = Path(temporary)
        header = []
        entries = []
        for index, vector in enumerate(vectors):
            for field in ("payload", "packed"):
                values = vector[field]
                if not values or any(not isinstance(b, int) or b < 0 or b > 255 for b in values):
                    raise ValueError("Invalid bytes in " + vector["name"])
                header.append("static const uint8_t v%d_%s[] = {%s};" %
                              (index, field, ",".join(map(str, values))))
            entries.append('{%s,%d,%d,%d,v%d_payload,sizeof(v%d_payload),v%d_packed,sizeof(v%d_packed)}' %
                           (json.dumps(vector["name"]), vector["width"], vector["height"],
                            vector["format"], index, index, index, index))
        header.append("static const CodecVector s_vectors[] = {" + ",".join(entries) + "};")
        (directory / "tile-codec-vectors.generated.h").write_text("\n".join(header))
        binary = directory / "codec-test"
        command = [os.environ.get("CC", "cc"), "-std=c99", "-Wall", "-Wextra", "-Werror",
                   "-DMAPPY_CODEC_GOLDENS", "-I" + str(directory),
                   "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-g",
                   str(ROOT / "tooling/test-tile-lz4.c"),
                   str(ROOT / "apps/pebble-watch/src/c/tile_codec.c"), "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], check=True)
        assembly = directory / "assembly-test"
        command = [os.environ.get("CC", "cc"), "-std=c99", "-Wall", "-Wextra", "-Werror",
                   "-I" + str(directory), "-fsanitize=address,undefined",
                   "-fno-omit-frame-pointer", "-g",
                   str(ROOT / "tooling/test-tile-assembly.c"),
                   str(ROOT / "apps/pebble-watch/src/c/tile_codec.c"),
                   str(ROOT / "apps/pebble-watch/src/c/tile_storage.c"), "-o", str(assembly)]
        subprocess.run(command, check=True)
        subprocess.run([str(assembly)], check=True)

if __name__ == "__main__":
    main()
