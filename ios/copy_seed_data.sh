#!/bin/sh
# Copies the app's shipped data files into the iOS app bundle, under
# seed_data/. On first launch lib/ios_seed.dart copies each one into the app's
# Documents folder - the iOS Root Folder - when it is not there yet, so a new
# install has a catalog, costs and schema without a file server.
#
# Run by the "Copy Seed Data" build phase of the Runner target. The files are
# the ones at the repository root; nothing here is edited by the build.
set -e

SRC="${SRCROOT}/.."
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/seed_data"

rm -rf "$DEST"
mkdir -p "$DEST"

for f in \
  config.json processors.json buildings.json ui_schema.json key_map.json \
  av_devices.json av_flow_rules.json base_costs.json labor_rates.json \
  delivery_locations.json vendor_list.json
do
  if [ -f "$SRC/$f" ]; then
    cp "$SRC/$f" "$DEST/$f"
  else
    echo "warning: seed data file $f not found at the repository root"
  fi
done

if [ -d "$SRC/room_presets" ]; then
  cp -R "$SRC/room_presets" "$DEST/room_presets"
fi
