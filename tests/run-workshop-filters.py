#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile
root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='we-filters-') as temporary:
    binary = pathlib.Path(temporary) / 'checks'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', temporary + '/cache',
                    str(root / 'Open Wallpaper Engine/Services/WorkshopAPIService.swift'),
                    str(root / 'Open Wallpaper Engine/Services/WorkshopViewModel.swift'),
                    str(root / 'tests/WorkshopFilterTests.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
