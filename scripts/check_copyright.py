# Copyright (c) 2026 Basil Innovations LLC.
# SPDX-License-Identifier: Apache-2.0
"""Pre-commit hook: verify the copyright header is present in every checked file.

A file passes when its first 4 KiB name the copyright holder and the SPDX
license identifier. Binary files are skipped.
"""

import sys

COPYRIGHT = "Basil Innovations LLC"
LICENSE = "SPDX-License-Identifier: Apache-2.0"

failures = []
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read(4096)
    except (OSError, UnicodeDecodeError):
        continue
    if COPYRIGHT not in content or LICENSE not in content:
        failures.append(path)

if failures:
    print("Missing copyright header:")
    for p in failures:
        print(f"  {p}")
    sys.exit(1)
