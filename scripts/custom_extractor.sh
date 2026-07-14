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
echo "   Samsung Custom File Extractor"
echo "═══════════════════════════════════════"

URL="$1"
FILE_PATH="$2"
PARTITION="${3:-auto}"
COMPRESSION_LEVEL="${4:-0}"

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-0" ;;
esac

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

search_in_image() {
  local IMG="$1" FS="$2" SEARCH="$3" OUT_DIR="$4"
  local FOUND=false

  if [ "$FS" = "f2fs" ]; then
    sudo modprobe f2fs 2>/dev/null || true
    local MNT="/tmp/custom_f2fs_$$"
    mkdir -p "$MNT"
    if ! sudo mount -t f2fs -o ro,loop "$IMG" "$MNT" 2>/dev/null; then
      echo "  ❌ f2fs mount failed"
      rm -rf "$MNT"
      return 1
    fi
    local MATCHES=$(sudo find "$MNT" -path "*/$SEARCH" 2>/dev/null)
    if [ -n "$MATCHES" ]; then
      while IFS= read -r SRC; do
        local REL="${SRC#$MNT/}"
        mkdir -p "$OUT_DIR/$(dirname "$REL")"
        sudo cp -r "$SRC" "$OUT_DIR/$REL" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/$REL"
        echo "    ✓ $REL"
        FOUND=true
      done <<< "$MATCHES"
    fi
    sudo umount "$MNT"
    rm -rf "$MNT"
  elif [ "$FS" = "erofs" ]; then
    local TMP_DIR="/tmp/custom_erofs_$$"
    mkdir -p "$TMP_DIR"
    tools/erofs-utils/extract.erofs -i "$IMG" -x -o "$TMP_DIR/" >/dev/null 2>&1 || {
      echo "  ❌ erofs extraction failed"
      rm -rf "$TMP_DIR"
      return 1
    }
    local MATCHES=$(find "$TMP_DIR" -path "*/$SEARCH" 2>/dev/null)
    if [ -n "$MATCHES" ]; then
      while IFS= read -r SRC; do
        local REL="${SRC#$TMP_DIR/}"
        mkdir -p "$OUT_DIR/$(dirname "$REL")"
        cp -r "$SRC" "$OUT_DIR/$REL" 2>/dev/null
        echo "    ✓ $REL"
        FOUND=true
      done <<< "$MATCHES"
    fi
    rm -rf "$TMP_DIR"
  else
    local IS_FILE_PATH=false
    if echo "$SEARCH" | grep -q "/"; then
      IS_FILE_PATH=true
    fi
    if $IS_FILE_PATH; then
      local PARENT=$(dirname "$SEARCH")
      local NAME=$(basename "$SEARCH")
      for PREFIX in "" "system/"; do
        local TRY_PATH="${PREFIX}${PARENT}"
        if debugfs -R "ls $TRY_PATH" "$IMG" 2>/dev/null | grep -q "$NAME"; then
          local DST="$OUT_DIR/$SEARCH"
          mkdir -p "$(dirname "$DST")"
          if debugfs -R "stat $TRY_PATH/$NAME" "$IMG" 2>/dev/null | grep -q "Type: regular"; then
            debugfs -R "dump $TRY_PATH/$NAME $DST" "$IMG" 2>/dev/null
          else
            mkdir -p "$DST"
            debugfs -R "rdump $TRY_PATH/$NAME $DST" "$IMG" 2>/dev/null
          fi
          echo "    ✓ $SEARCH"
          FOUND=true
          break
        fi
      done
    else
      for PREFIX in "" "system/"; do
        if debugfs -R "stat ${PREFIX}${SEARCH}" "$IMG" 2>/dev/null | grep -q "Type: regular"; then
          mkdir -p "$OUT_DIR"
          debugfs -R "dump ${PREFIX}${SEARCH} $OUT_DIR/$SEARCH" "$IMG" 2>/dev/null
          echo "    ✓ $SEARCH"
          FOUND=true
          break
        elif debugfs -R "ls ${PREFIX}${SEARCH}" "$IMG" 2>/dev/null | grep -q .; then
          mkdir -p "$OUT_DIR/$SEARCH"
          debugfs -R "rdump ${PREFIX}${SEARCH} $OUT_DIR/$SEARCH" "$IMG" 2>/dev/null
          echo "    ✓ $SEARCH"
          FOUND=true
          break
        fi
      done
    fi
  fi

  $FOUND && return 0 || return 1
}

echo ""; echo "[1/7] Downloading..."
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

echo ""; echo "[2/7] Extracting ZIP..."
unzip -o "$ZIP_FILE" >/dev/null 2>&1
rm -f "$ZIP_FILE"
echo "✅ Done"

mkdir -p output

echo ""; echo "[3/7] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" -o -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
echo "  Extracting: $(basename "$AP_FILE")"
tar -xf "$AP_FILE" >/dev/null 2>&1
echo "  Contents:"
for file in *.img *.img.lz4; do
  [ -f "$file" ] && echo "    $file"
done
rm -f "$AP_FILE"
echo "✅ Done"

echo ""; echo "[4/7] Processing super.img..."
SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" -o -name "super.img" | head -n 1)

if [ -n "$SUPER_FILE" ]; then
  echo "  Found: $(basename "$SUPER_FILE")"

  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    echo "  Decompressing LZ4..."
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null
    SUPER_FILE="super.img"
    echo "  ✅ Decompressed"
  fi

  SUPER_FS=$(detect_fs_type "$SUPER_FILE")
  echo "  Super format: $SUPER_FS"

  if [ "$SUPER_FS" = "sparse" ]; then
    echo "  Converting sparse to raw..."
    simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null || tools/android-tools/simg2img "$SUPER_FILE" "super.raw.img"
    SUPER_FILE="super.raw.img"
    SUPER_FS=$(detect_fs_type "$SUPER_FILE")
    echo "  ✅ Converted - new format: $SUPER_FS"
  fi

  echo "  Unpacking partitions..."
  mkdir -p super_dump
  tools/android-tools/lpunpack "$SUPER_FILE" super_dump >/dev/null 2>&1 || { echo "  ❌ lpunpack failed"; exit 1; }

  echo ""
  echo "  Partitions detected:"
  echo "  ┌─────────────────────────────────────────────┐"

  declare -A PART_IMAGES
  declare -A PART_FSTYPES

  for img in super_dump/*.img; do
    [ -f "$img" ] || continue
    PART_NAME=$(basename "$img" .img)
    PART_FS=$(detect_fs_type "$img")
    PART_SIZE=$(numfmt --to=iec $(stat -c%s "$img") 2>/dev/null || echo "?")

    printf "  │ %-15s → %-6s (%s)\n" "$PART_NAME" "$PART_FS" "$PART_SIZE"

    BASE_NAME="${PART_NAME%_a}"
    BASE_NAME="${BASE_NAME%_b}"
    PART_IMAGES["$BASE_NAME"]="$img"
    PART_FSTYPES["$BASE_NAME"]="$PART_FS"
  done

  echo "  └─────────────────────────────────────────────┘"

else
  echo "  No super.img found - legacy device"

  declare -A PART_IMAGES
  declare -A PART_FSTYPES

  for PART in system product vendor; do
    PART_IMG=$(find . -maxdepth 1 -name "${PART}.img.lz4" -o -name "${PART}.img" | head -n 1)
    if [ -n "$PART_IMG" ]; then
      if [[ "$PART_IMG" == *.lz4 ]]; then
        lz4 -d "$PART_IMG" "${PART}_raw.img" 2>/dev/null
        PART_IMG="${PART}_raw.img"
      fi
      PART_FS=$(detect_fs_type "$PART_IMG")
      if [ "$PART_FS" = "sparse" ]; then
        simg2img "$PART_IMG" "${PART}_unsparse.img" 2>/dev/null
        PART_IMG="${PART}_unsparse.img"
        PART_FS=$(detect_fs_type "$PART_IMG")
      fi
      PART_IMAGES["$PART"]="$PART_IMG"
      PART_FSTYPES["$PART"]="$PART_FS"
      echo "  $PART: $(basename "$PART_IMG") ($PART_FS)"
    fi
  done
fi
echo "✅ Done"

echo ""; echo "[5/7] Searching for: $FILE_PATH"

FOUND_ANY=false

if [ "$PARTITION" = "auto" ]; then
  SEARCH_ORDER="system product vendor"
else
  SEARCH_ORDER="$PARTITION"
fi

for PART in $SEARCH_ORDER; do
  IMG="${PART_IMAGES[$PART]}"
  FS="${PART_FSTYPES[$PART]}"
  [ -z "$IMG" ] || [ ! -f "$IMG" ] && continue

  echo ""; echo "  Searching $PART ($FS)..."

  if search_in_image "$IMG" "$FS" "$FILE_PATH" "output"; then
    FOUND_ANY=true
    echo "  ✅ Found in $PART"
    break
  else
    echo "  ⚠️ Not found in $PART"
  fi
done

if ! $FOUND_ANY; then
  echo ""; echo "  Searching direct .img files..."
  for PART in system product vendor; do
    IMG="${PART_IMAGES[$PART]}"
    FS="${PART_FSTYPES[$PART]}"
    [ -z "$IMG" ] || [ ! -f "$IMG" ] && continue

    STRIPPED="${FILE_PATH#system/}"
    STRIPPED="${STRIPPED#system_a/}"
    STRIPPED="${STRIPPED#system_b/}"
    if [ "$STRIPPED" != "$FILE_PATH" ] && search_in_image "$IMG" "$FS" "$STRIPPED" "output"; then
      FOUND_ANY=true
      echo "  ✅ Found in $PART (stripped prefix)"
      break
    fi
  done
fi

rm -rf super_dump super.img super.raw.img *_raw.img *_unsparse.img

if ! $FOUND_ANY; then
  echo ""
  echo "❌ File not found: $FILE_PATH"
  exit 1
fi

echo ""; echo "[6/7] Packaging output..."
for ITEM in output/*; do
  [ -e "$ITEM" ] || continue
  NAME=$(basename "$ITEM")
  if [ -d "$ITEM" ]; then
    if [ "$COMPRESSION_LEVEL" != "0" ]; then
      tar -cf - -C output "$NAME" | xz $XZ_FLAGS -T0 2>/dev/null > "output/${NAME}.tar.xz" && rm -rf "$ITEM"
      echo "    ✓ ${NAME}.tar.xz"
    else
      tar -cf "output/${NAME}.tar" -C output "$NAME" && rm -rf "$ITEM"
      echo "    ✓ ${NAME}.tar"
    fi
  elif [ -f "$ITEM" ] && [ "$COMPRESSION_LEVEL" != "0" ] && [[ "$ITEM" != *.xz ]]; then
    xz $XZ_FLAGS -T0 "$ITEM" 2>/dev/null && echo "    ✓ ${NAME}.xz" || true
  fi
done

echo ""; echo "[7/7] Done"
echo "═══════════════════════════════════════"
FILE_COUNT=$(ls -1 output 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh output | cut -f1)
echo "✅ Extracted $FILE_COUNT items"
echo "Total size: $TOTAL_SIZE"
echo ""; echo "Files:"
ls -lh output
echo "═══════════════════════════════════════"
echo "✅ Done!"
