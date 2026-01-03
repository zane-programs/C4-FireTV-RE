#!/bin/bash

# Build script for Fire TV Remote Control4 driver
# Creates the installable .c4z driver package

set -e

OUTPUT_FILE="fire_tv_remote.c4z"

echo "Building $OUTPUT_FILE..."

# Remove old package if it exists
rm -f "$OUTPUT_FILE"

# Create the .c4z archive
# Includes all Lua files, driver.xml, icons, and www directories
zip -r "$OUTPUT_FILE" \
    driver.xml \
    *.lua \
    icons \
    www \
    -x "*.DS_Store"

echo "Build complete: $OUTPUT_FILE"
echo "Package contents:"
unzip -l "$OUTPUT_FILE"
