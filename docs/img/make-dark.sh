#!/usr/bin/env bash
# Regenerate each *-dark.svg from its *-light.svg by swapping the GitHub light
# palette for the dark one. Edit only the light files, then run this.
set -euo pipefail
cd "$(dirname "$0")"
for light in *-light.svg; do
  sed -e 's/#1f2328/#f0f6fc/g' \
      -e 's/#59636e/#9198a1/g' \
      -e 's/#f6f8fa/#151b23/g' \
      -e 's/#d1d9e0/#3d444d/g' \
      -e 's/#8c959f/#7d8590/g' \
      -e 's/#ffffff/#0d1117/g' \
      -e 's/#0969da/#4493f8/g' \
      -e 's/#ddf4ff/#12233d/g' \
      -e 's/#1a7f37/#3fb950/g' \
      -e 's/#dafbe1/#122d1b/g' \
      -e 's/#8250df/#ab7df8/g' \
      -e 's/#fbefff/#251a3d/g' \
      -e 's/#bc4c00/#f0883e/g' \
      -e 's/#fff1e5/#33200f/g' \
      "$light" > "${light%-light.svg}-dark.svg"
done
