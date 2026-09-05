"""Verify the distributed APK embeds only the configured Google Maps SDK key."""

import os
from pathlib import Path
import re
import sys
from zipfile import ZipFile


def verify(apk_path, sdk_key):
    if not re.fullmatch(r"AIza[0-9A-Za-z_-]{16,}", sdk_key):
        raise ValueError("MAPPY_ANDROID_SDK_API_KEY is missing or malformed.")
    encoded_keys = (sdk_key.encode("ascii"), sdk_key.encode("utf-16le"))
    patterns = (
        re.compile(rb"AIza[0-9A-Za-z_-]{16,}"),
        re.compile(rb"A\x00I\x00z\x00a\x00(?:[0-9A-Za-z_-]\x00){16,}"),
    )
    with ZipFile(apk_path) as apk:
        if apk.testzip() is not None:
            raise ValueError("Release APK failed its integrity check.")
        manifest = apk.read("AndroidManifest.xml")
        if not any(key in manifest for key in encoded_keys):
            raise ValueError("The configured Maps SDK key is absent from the APK manifest.")
        for entry in apk.infolist():
            data = apk.read(entry)
            for pattern, allowed in zip(patterns, encoded_keys):
                if any(match.group() != allowed for match in pattern.finditer(data)):
                    raise ValueError("An unexpected Google API key was found in the APK.")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]), os.environ.get("MAPPY_ANDROID_SDK_API_KEY", "").strip())
    except (ValueError, OSError) as error:
        sys.exit(str(error))
    print("APK contains the configured Maps SDK key and no unexpected Google keys.")
