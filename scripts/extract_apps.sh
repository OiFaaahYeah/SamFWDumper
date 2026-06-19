#!/bin/bash
# =============================================================================
# SamFW Apps Extractor - Extract specific app folders from Samsung firmware
# Copyright (C) 2026 Xiatsuma
# Licensed under PolyForm Noncommercial License 1.0.0
# https://polyformproject.org/licenses/noncommercial/1.0.0
# =============================================================================
set -e

echo "═══════════════════════════════════════"
echo "   Samsung Firmware Apps Extractor"
echo "═══════════════════════════════════════"

URL="$1"
COMPRESSION_LEVEL="${2:-0}"

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-0" ;;
esac

echo ""; echo "[1/6] Downloading..."
wget -q --no-check-certificate --content-disposition "$URL"
ZIP_FILE=$(ls -t *.zip 2>/dev/null | head -1)
[ ! -f "$ZIP_FILE" ] && { echo "❌ Download failed"; exit 1; }
FILESIZE=$(stat -c%s "$ZIP_FILE")
[ "$FILESIZE" -eq 0 ] && { echo "❌ Empty file"; exit 1; }
echo "✅ Downloaded: $(numfmt --to=iec $FILESIZE)"

CSC_CODE=$(echo "$ZIP_FILE" | sed 's/\.zip$//' | tr '_' '\n' | grep -E '^[A-Z]{3}$' | grep -v -E '^(COM|SAM|FAC)$' | head -1)
AP_CODE=$(echo "$ZIP_FILE" | sed 's/\.zip$//' | tr '_' '\n' | grep -E '^[A-Z][A-Z0-9]{11,}$' | head -1)
echo "$CSC_CODE" > csc_code.txt
echo "$AP_CODE" > ap_code.txt
echo "Firmware: $AP_CODE | CSC: $CSC_CODE"

echo ""; echo "[2/6] Extracting ZIP..."
unzip -o "$ZIP_FILE" >/dev/null 2>&1
rm -f "$ZIP_FILE"
echo "✅ Done"

echo ""; echo "[3/6] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" -o -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
tar -xf "$AP_FILE" >/dev/null 2>&1
rm -f "$AP_FILE"
echo "✅ Done"

echo ""; echo "[4/6] Getting system.img..."
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" -o -name "super.img" | head -n 1)
if [ -n "$SUPER_FILE" ]; then
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null
    SUPER_FILE="super.img"
  fi
  if file "$SUPER_FILE" 2>/dev/null | grep -q "sparse"; then
    simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null || tools/android-tools/simg2img "$SUPER_FILE" "super.raw.img"
    SUPER_FILE="super.raw.img"
  fi
  mkdir -p super_dump
  tools/android-tools/lpunpack "$SUPER_FILE" super_dump 2>/dev/null
  SYSTEM_IMG=$(find super_dump -name "system.img" -o -name "system_a.img" | head -n 1)
else
  SYSTEM_IMG=$(find . -maxdepth 1 -name "system.img.lz4" -o -name "system.img" | head -n 1)
  if [[ "$SYSTEM_IMG" == *.lz4 ]]; then
    lz4 -d "$SYSTEM_IMG" "system_raw.img" 2>/dev/null
    SYSTEM_IMG="system_raw.img"
  fi
  if [ -n "$SYSTEM_IMG" ] && file "$SYSTEM_IMG" 2>/dev/null | grep -q "sparse"; then
    simg2img "$SYSTEM_IMG" "system_unsparse.img" 2>/dev/null
    SYSTEM_IMG="system_unsparse.img"
  fi
fi

[ -z "$SYSTEM_IMG" ] || [ ! -f "$SYSTEM_IMG" ] && { echo "❌ system.img not found"; exit 1; }

echo ""; echo "[5/6] Extracting system.img..."
mkdir -p system_extracted output

if tools/erofs-utils/extract.erofs -i "$SYSTEM_IMG" -x -o system_extracted/ >/dev/null 2>&1; then
  echo "  ✅ Extracted via erofs"
else
  echo "  erofs failed - trying debugfs..."
  for TARGET in "app/SketchBook" "system/app/SketchBook"; do
    if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
      mkdir -p "system_extracted/app/SketchBook"
      debugfs -R "rdump $TARGET system_extracted/app/SketchBook" "$SYSTEM_IMG" 2>/dev/null
      break
    fi
  done
fi

echo ""; echo "[6/6] Copying SketchBook..."
FOUND=false
for BASE in \
  "system_extracted/app/SketchBook" \
  "system_extracted/system/app/SketchBook" \
  "system_extracted/system_a/app/SketchBook" \
  "system_extracted/system/system/app/SketchBook" \
  "system_extracted/system_a/system/app/SketchBook"; do
  if [ -d "$BASE" ]; then
    mkdir -p "output/Apps"
    cp -r "$BASE" "output/Apps/SketchBook"
    echo "    ✓ SketchBook"
    FOUND=true
    break
  fi
done

if ! $FOUND; then
  echo "  ❌ SketchBook folder not found!"
  rm -rf system_extracted super_dump *.img
  exit 1
fi

rm -rf system_extracted super_dump *.img

echo ""; echo "Packaging..."
cd output
if [ "$COMPRESSION_LEVEL" != "0" ]; then
  tar -cf - "Apps" | xz $XZ_FLAGS -T0 2>/dev/null > "Apps.tar.xz"
  rm -rf "Apps"
  echo "    ✓ Apps.tar.xz"
else
  zip -r "Apps.zip" "Apps" >/dev/null 2>&1
  rm -rf "Apps"
  echo "    ✓ Apps.zip"
fi

echo ""; echo "═══════════════════════════════════════"
FILE_COUNT=$(ls -1 2>/dev/null | wc -l)
[ "$FILE_COUNT" -eq 0 ] && { echo "❌ Nothing extracted!"; exit 1; }
TOTAL_SIZE=$(du -sh . | cut -f1)
echo "✅ Extracted $FILE_COUNT items"
echo "Total size: $TOTAL_SIZE"
ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
