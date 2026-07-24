#!/bin/bash
# =============================================================================
# SamFWDumper - Automated Samsung Firmware Extraction
# Copyright (C) 2026 Xiatsuma
# Licensed under PolyForm Noncommercial License 1.0.0
# https://polyformproject.org/licenses/noncommercial/1.0.0
#
# You may NOT use this file except in compliance with the License.
# Commercial use, removal of this header, or distribution without attribution
# is strictly prohibited. For permissions: https://github.com/Xiatsuma
# =============================================================================
set -e

echo "═══════════════════════════════════════"
echo "   Samsung Images Extractor"
echo "═══════════════════════════════════════"

URL="$1"
COMPRESSION_LEVEL="${2:-6}"
SELECTED_PARTITIONS="$3"

[ -z "$URL" ] && { echo "❌ No URL"; exit 1; }
[ -z "$SELECTED_PARTITIONS" ] && { echo "❌ No partitions selected"; exit 1; }

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-6" ;;
esac

echo "Compression level: $COMPRESSION_LEVEL"
echo "Partitions to extract: $SELECTED_PARTITIONS"

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

SUPER_PARTS="system system_ext product vendor vendor_dlkm system_dlkm odm odm_dlkm"
NEED_SUPER=false
for PART in $SELECTED_PARTITIONS; do
  for SP in $SUPER_PARTS; do
    if [ "$PART" = "$SP" ]; then
      NEED_SUPER=true
      break 2
    fi
  done
done

detect_fs_type() {
  local IMG="$1"
  local FS_TYPE=""
  FS_TYPE=$(blkid -o value -s TYPE "$IMG" 2>/dev/null)
  if [ -z "$FS_TYPE" ]; then
    local FILE_OUTPUT=$(file "$IMG" 2>/dev/null)
    if echo "$FILE_OUTPUT" | grep -qi "f2fs"; then
      FS_TYPE="f2fs"
    elif echo "$FILE_OUTPUT" | grep -qi "erofs"; then
      FS_TYPE="erofs"
    elif echo "$FILE_OUTPUT" | grep -qi "ext4\|ext3\|ext2"; then
      FS_TYPE="ext4"
    elif echo "$FILE_OUTPUT" | grep -qi "android sparse"; then
      FS_TYPE="sparse"
    fi
  fi
  if [ -z "$FS_TYPE" ]; then
    local MAGIC=$(xxd -l 4 -p "$IMG" 2>/dev/null)
    case "$MAGIC" in
      1020f5f2) FS_TYPE="f2fs" ;;
      e2e1f5e0) FS_TYPE="erofs" ;;
      53ef*)    FS_TYPE="ext4" ;;
      3aff*)    FS_TYPE="sparse" ;;
    esac
  fi
  echo "$FS_TYPE"
}

is_selected() {
  local name="$1"
  for P in $SELECTED_PARTITIONS; do
    [ "$P" = "$name" ] && return 0
  done
  return 1
}

echo ""; echo "[1/5] Downloading..."
wget --no-check-certificate --content-disposition "$URL" 2>&1 | tail -3
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

mv "$ZIP_FILE" firmware.zip

echo ""; echo "[2/5] Extracting ZIP..."
unzip -o "firmware.zip" >/dev/null 2>&1
rm -f "firmware.zip"
echo "✅ Done"

echo ""; echo "[3/5] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" -o -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
echo "  Extracting: $(basename "$AP_FILE")"

EXTRACT_ARGS=()
for PART in $SELECTED_PARTITIONS; do
  EXTRACT_ARGS+=("*${PART}.img*" "*${PART}_a.img*" "*${PART}_b.img*")
done
$NEED_SUPER && EXTRACT_ARGS+=("*super.img*")

tar --no-anchored --wildcards -xf "$AP_FILE" "${EXTRACT_ARGS[@]}" 2>/dev/null || tar -xf "$AP_FILE" >/dev/null 2>&1

echo ""
echo "  Contents:"
echo "  ┌─────────────────────────────────────────────┐"

for file in *.img *.img.lz4; do
  [ -f "$file" ] || continue
  BASE=$(echo "$file" | sed 's/\.lz4$//' | sed 's/\.img$//' | sed 's/-verified//')
  MARK=" "
  is_selected "$BASE" && MARK="✓"
  printf "  │ %-40s %s\n" "$file" "$MARK"
done

echo "  └─────────────────────────────────────────────┘"

rm -f "$AP_FILE"
echo "✅ Done"

echo ""; echo "[4/5] Extracting partitions..."
mkdir -p processed

for PART in $SELECTED_PARTITIONS; do
  [ -f "processed/${PART}.img.xz" ] && continue
  [ -f "processed/${PART}_a.img.xz" ] && continue
  [ -f "processed/${PART}_b.img.xz" ] && continue

  FILE=$(find . -maxdepth 1 \( -name "${PART}.img.lz4" -o -name "${PART}.img" -o -name "${PART}_a.img.lz4" -o -name "${PART}_a.img" -o -name "${PART}_b.img.lz4" -o -name "${PART}_b.img" \) | head -n 1)
  if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    if [[ "$FILE" == *.lz4 ]]; then
      lz4 -d "$FILE" "${FILE%.lz4}" 2>/dev/null || true
      FILE="${FILE%.lz4}"
    fi
    
    BASENAME=$(basename "$FILE")
    if xz $XZ_FLAGS -T0 "$FILE" 2>/dev/null; then
      mv "${FILE}.xz" "processed/${BASENAME}.xz"
    else
      cp "$FILE" "processed/${BASENAME}"
    fi
  fi
done

SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" | head -n 1)
if $NEED_SUPER && [ -n "$SUPER_FILE" ] && [ -f "$SUPER_FILE" ]; then
  echo ""; echo "  Processing super.img..."
  echo "    Found: $(basename "$SUPER_FILE")"

  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "    Decompressing LZ4..."
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null || { echo "    ❌ LZ4 failed"; exit 1; }
    SUPER_FILE="super.img"
    echo "    ✅ Decompressed"
  fi

  SUPER_FS=$(detect_fs_type "$SUPER_FILE")
  echo "    Super format: $SUPER_FS"

  if [ "$SUPER_FS" = "sparse" ]; then
    echo "    Converting sparse to raw..."
    if command -v simg2img &>/dev/null; then
      simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null
    elif [ -f "tools/android-tools/simg2img" ]; then
      tools/android-tools/simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null
    else
      echo "    ⚠️ simg2img not found"
      exit 1
    fi
    [ -f "super.raw.img" ] && SUPER_FILE="super.raw.img"
    echo "    ✅ Converted"
  fi

  echo "    Unpacking partitions..."
  mkdir -p super_dump

  if [ -f "tools/android-tools/lpunpack" ]; then
    tools/android-tools/lpunpack "$SUPER_FILE" super_dump >/dev/null 2>&1 || { echo "      ❌ lpunpack failed"; exit 1; }
  else
    echo "      ❌ lpunpack not found"
    exit 1
  fi

  echo ""
  echo "    Partitions detected:"
  echo "    ┌─────────────────────────────────────────────┐"

  for img in super_dump/*.img; do
    [ -f "$img" ] || continue
    PART_NAME=$(basename "$img" .img)
    BASE_NAME="${PART_NAME%_a}"
    BASE_NAME="${BASE_NAME%_b}"
    PART_FS=$(detect_fs_type "$img")
    PART_SIZE=$(numfmt --to=iec $(stat -c%s "$img") 2>/dev/null || echo "?")

    MARK=" "
    is_selected "$BASE_NAME" && MARK="✓"

    printf "    │ %-15s → %-6s (%s)   %s\n" "$PART_NAME" "$PART_FS" "$PART_SIZE" "$MARK"
  done

  echo "    └─────────────────────────────────────────────┘"

  for PART in $SELECTED_PARTITIONS; do
    for SUFFIX in "_a" "" "_b"; do
      IMG_FILE="super_dump/${PART}${SUFFIX}.img"
      if [ -f "$IMG_FILE" ]; then
        BASENAME="${PART}${SUFFIX}.img"
        if xz $XZ_FLAGS -T0 "$IMG_FILE" 2>/dev/null; then
          mv "${IMG_FILE}.xz" "processed/${BASENAME}.xz"
        else
          cp "$IMG_FILE" "processed/${BASENAME}"
        fi
        break
      fi
    done
  done

  rm -rf super_dump super.img super.raw.img
elif $NEED_SUPER; then
  echo "  ⚠️ super.img not found"
fi

echo ""; echo "[5/5] Results:"; cd processed
FILE_COUNT=$(ls -1 | wc -l)
[ "$FILE_COUNT" -eq 0 ] && { echo "❌ Nothing extracted!"; exit 1; }

TOTAL_SIZE=$(du -sh . | cut -f1)
echo "═══════════════════════════════════════"
echo "✅ Extracted $FILE_COUNT partitions"
echo "Total size: $TOTAL_SIZE"
echo "Compression: Level $COMPRESSION_LEVEL"
echo ""; echo "Files:"
ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
