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
echo "   Samsung Special Targeted Extractor"
echo "═══════════════════════════════════════"

URL="$1"
COMPRESSION_LEVEL="${2:-0}"
SHOW_ALL="${3:-false}"
OUTPUT_NAME="${4:-Apps}"

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-0" ;;
esac

APP_FOLDERS=$(cat targets/system/app.txt 2>/dev/null | tr '\n' ' ')
PRIVAPP_FOLDERS=$(cat targets/system/priv-app.txt 2>/dev/null | tr '\n' ' ')
ETC_FOLDERS=$(cat targets/system/etc.txt 2>/dev/null | tr '\n' ' ')
MEDIA_FILES=$(cat targets/system/media.txt 2>/dev/null | tr '\n' ' ')
LIB_FILES=$(cat targets/system/lib.txt 2>/dev/null | tr '\n' ' ')
LIB64_FILES=$(cat targets/system/lib64.txt 2>/dev/null | tr '\n' ' ')
FRAMEWORK_JARS=$(cat targets/system/framework.txt 2>/dev/null | tr '\n' ' ')
CAMERADATA_FILES=$(cat targets/system/cameradata.txt 2>/dev/null | tr '\n' ' ')

ANY_PARTITION=$(cat targets/any_partition.txt 2>/dev/null | grep -v '^$' | grep -v '^#' || true)

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

echo ""; echo "[3/7] Extracting AP..."
AP_FILE=$(find . -name "AP_*.tar.md5" -o -name "AP_*.tar" | head -n 1)
[ -z "$AP_FILE" ] && { echo "❌ AP file not found"; exit 1; }
tar -xf "$AP_FILE" >/dev/null 2>&1
rm -f "$AP_FILE"
echo "✅ Done"

find_partition_img() {
  local PART="$1"
  local IMG=""
  IMG=$(find . -maxdepth 1 -name "${PART}.img" -o -name "${PART}.img.lz4" | head -n 1)
  [ -z "$IMG" ] && IMG=$(find . -maxdepth 1 -name "${PART}_a.img" -o -name "${PART}_a.img.lz4" | head -n 1)
  [ -z "$IMG" ] && IMG=$(find . -maxdepth 1 -name "${PART}_b.img" -o -name "${PART}_b.img.lz4" | head -n 1)
  echo "$IMG"
}

resolve_ab_path() {
  local BASE_DIR="$1" REL_PATH="$2"
  for PREFIX in "" "system_a/" "system_b/" "system/"; do
    local FULL="$BASE_DIR/${PREFIX}${REL_PATH}"
    if [ -e "$FULL" ]; then echo "$FULL"; return 0; fi
  done
  return 1
}

extract_partition_img() {
  local IMG="$1" OUT_DIR="$2" PART_NAME="$3"
  
  [ ! -f "$IMG" ] && return 1
  
  if [[ "$IMG" == *.lz4 ]]; then
    lz4 -d "$IMG" "${IMG%.lz4}" 2>/dev/null
    IMG="${IMG%.lz4}"
  fi
  if file "$IMG" 2>/dev/null | grep -q "sparse"; then
    simg2img "$IMG" "${IMG}.raw" 2>/dev/null || tools/android-tools/simg2img "$IMG" "${IMG}.raw"
    IMG="${IMG}.raw"
  fi

  FS_TYPE=$(blkid -o value -s TYPE "$IMG" 2>/dev/null || file "$IMG" | grep -o 'f2fs\|erofs\|ext[234]')
  
  if [ "$FS_TYPE" = "f2fs" ]; then
    extract_f2fs_partition "$IMG" "$OUT_DIR" "$PART_NAME" || return 1
  elif tools/erofs-utils/extract.erofs -i "$IMG" -x -o "$OUT_DIR/" >/dev/null 2>&1; then
    :
  else
    return 1
  fi
  return 0
}

extract_f2fs_partition() {
  local IMG="$1" OUT_DIR="$2" PART_NAME="$3"
  sudo modprobe f2fs 2>/dev/null || true
  local MNT="/tmp/f2fs_${PART_NAME}_$$"
  mkdir -p "$MNT"
  if ! sudo mount -t f2fs -o ro,loop "$IMG" "$MNT" 2>/dev/null; then
    rm -rf "$MNT"
    return 1
  fi
  sudo cp -r "$MNT/." "$OUT_DIR/" 2>/dev/null
  sudo chown -R $(id -u):$(id -g) "$OUT_DIR/"
  sudo umount "$MNT"
  rm -rf "$MNT"
  return 0
}

extract_f2fs_mount() {
  local IMG="$1" OUT_DIR="$2"
  sudo modprobe f2fs 2>/dev/null || true
  local MNT="/tmp/f2fs_mount_$$"
  mkdir -p "$MNT"
  if ! sudo mount -t f2fs -o ro,loop "$IMG" "$MNT" 2>/dev/null; then
    echo "  ❌ f2fs mount failed"
    rm -rf "$MNT"
    return 1
  fi
  echo "  ✅ Mounted f2fs successfully"

  for FOLDER in $APP_FOLDERS; do
    FOUND=false
    for SRC_PATH in "$MNT/app/$FOLDER" "$MNT/system/app/$FOLDER"; do
      if sudo test -d "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/app/$FOLDER"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/app/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/app/$FOLDER"
        FOUND=true; break
      fi
    done
    $FOUND || echo "  ⚠️ app/$FOLDER not found"
  done

  for FOLDER in $PRIVAPP_FOLDERS; do
    FOUND=false
    for SRC_PATH in "$MNT/priv-app/$FOLDER" "$MNT/system/priv-app/$FOLDER"; do
      if sudo test -d "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/priv-app/$FOLDER"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/priv-app/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/priv-app/$FOLDER"
        FOUND=true; break
      fi
    done
    if ! $FOUND && [ "$FOLDER" = "PhotoEditor_AIFull" ]; then
      for SRC_PATH in "$MNT/priv-app/PhotoEditor_Full" "$MNT/system/priv-app/PhotoEditor_Full"; do
        if sudo test -d "$SRC_PATH" 2>/dev/null; then
          mkdir -p "$OUT_DIR/priv-app/PhotoEditor_AIFull"
          sudo cp -r "$SRC_PATH" "$OUT_DIR/priv-app/PhotoEditor_AIFull" 2>/dev/null
          sudo chown -R $(id -u):$(id -g) "$OUT_DIR/priv-app/PhotoEditor_AIFull"
          FOUND=true; break
        fi
      done
    fi
    $FOUND || echo "  ⚠️ priv-app/$FOLDER not found"
  done

  for FOLDER in $ETC_FOLDERS; do
    FOUND=false
    for SRC_PATH in "$MNT/etc/$FOLDER" "$MNT/system/etc/$FOLDER"; do
      if sudo test -d "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/etc/$FOLDER"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/etc/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/etc/$FOLDER"
        FOUND=true; break
      fi
    done
    $FOUND || echo "  ⚠️ etc/$FOLDER not found"
  done

  for FOLDER in $CAMERADATA_FILES; do
    FOUND=false
    for SRC_PATH in "$MNT/cameradata/$FOLDER" "$MNT/system/cameradata/$FOLDER"; do
      if sudo test -d "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/cameradata/$FOLDER"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/cameradata/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/cameradata/$FOLDER"
        FOUND=true; break
      fi
    done
    $FOUND || echo "  ⚠️ cameradata/$FOLDER not found"
  done

  for FILE in $MEDIA_FILES; do
    FILE_FOUND=false
    for SRC_PATH in "$MNT/media/$FILE" "$MNT/system/media/$FILE"; do
      if sudo test -f "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/media"
        sudo cp "$SRC_PATH" "$OUT_DIR/media/$FILE"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/media/$FILE"
        FILE_FOUND=true; break
      fi
    done
    $FILE_FOUND || echo "  ⚠️ media/$FILE not found"
  done

  for FILE in $LIB_FILES; do
    FILE_FOUND=false
    for SRC_PATH in "$MNT/lib/$FILE" "$MNT/system/lib/$FILE"; do
      if sudo test -f "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/lib"
        sudo cp "$SRC_PATH" "$OUT_DIR/lib/$FILE"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/lib/$FILE"
        FILE_FOUND=true; break
      fi
    done
    $FILE_FOUND || echo "  ⚠️ lib/$FILE not found"
  done

  for FILE in $LIB64_FILES; do
    FILE_FOUND=false
    for SRC_PATH in "$MNT/lib64/$FILE" "$MNT/system/lib64/$FILE"; do
      if sudo test -f "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/lib64"
        sudo cp "$SRC_PATH" "$OUT_DIR/lib64/$FILE"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/lib64/$FILE"
        FILE_FOUND=true; break
      fi
    done
    $FILE_FOUND || echo "  ⚠️ lib64/$FILE not found"
  done

  for JAR in $FRAMEWORK_JARS; do
    JAR_FOUND=false
    for SRC_PATH in "$MNT/framework/$JAR" "$MNT/system/framework/$JAR"; do
      if sudo test -f "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/framework"
        sudo cp "$SRC_PATH" "$OUT_DIR/framework/$JAR"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/framework/$JAR"
        JAR_FOUND=true; break
      fi
    done
    $JAR_FOUND || echo "  ⚠️ framework/$JAR not found"
  done

  sudo umount "$MNT"
  rm -rf "$MNT"
  return 0
}

echo ""; echo "[4/7] Extracting partitions..."
mkdir -p super_dump partitions_extracted output/$OUTPUT_NAME

SUPER_FILE=$(find . -maxdepth 1 -name "super.img*" -o -name "super.img" | head -n 1)
HAS_SUPER=false
if [ -n "$SUPER_FILE" ]; then
  if [[ "$SUPER_FILE" == *.lz4 ]]; then
    lz4 -d "$SUPER_FILE" "super.img" 2>/dev/null
    SUPER_FILE="super.img"
  fi
  if file "$SUPER_FILE" 2>/dev/null | grep -q "sparse"; then
    simg2img "$SUPER_FILE" "super.raw.img" 2>/dev/null || tools/android-tools/simg2img "$SUPER_FILE" "super.raw.img"
    SUPER_FILE="super.raw.img"
  fi
  tools/android-tools/lpunpack "$SUPER_FILE" super_dump 2>/dev/null
  HAS_SUPER=true
fi

NEEDED_PARTITIONS="system"
if [ -n "$ANY_PARTITION" ]; then
  while IFS= read -r line; do
    PART=$(echo "$line" | cut -d'/' -f1)
    [ -n "$PART" ] && NEEDED_PARTITIONS="$NEEDED_PARTITIONS $PART"
  done <<< "$ANY_PARTITION"
fi
NEEDED_PARTITIONS=$(echo "$NEEDED_PARTITIONS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

for PART in $NEEDED_PARTITIONS; do
  PART_DIR="partitions_extracted/$PART"
  mkdir -p "$PART_DIR"
  
  PART_IMG=""
  if $HAS_SUPER; then
    PART_IMG=$(find super_dump -name "${PART}.img" -o -name "${PART}_a.img" -o -name "${PART}_b.img" | head -n 1)
  fi
  [ -z "$PART_IMG" ] && PART_IMG=$(find_partition_img "$PART")
  
  if [ -n "$PART_IMG" ] && [ -f "$PART_IMG" ]; then
    echo "  Extracting $PART ($(basename $PART_IMG))..."
    extract_partition_img "$PART_IMG" "$PART_DIR" "$PART" && echo "    ✓ $PART" || echo "    ⚠️ $PART extraction failed"
  else
    echo "  ⚠️ $PART.img not found"
  fi
done

SYSTEM_DIR="partitions_extracted/system"
SYSTEM_IMG=""
if [ -f "$SYSTEM_DIR" ]; then
  :
else
  SYSTEM_IMG=$(find . -maxdepth 1 -name "system.img.lz4" -o -name "system.img" | head -n 1)
  if [ -n "$SYSTEM_IMG" ]; then
    if [[ "$SYSTEM_IMG" == *.lz4 ]]; then
      lz4 -d "$SYSTEM_IMG" "system_raw.img" 2>/dev/null
      SYSTEM_IMG="system_raw.img"
    fi
    if [ -n "$SYSTEM_IMG" ] && file "$SYSTEM_IMG" 2>/dev/null | grep -q "sparse"; then
      simg2img "$SYSTEM_IMG" "system_unsparse.img" 2>/dev/null
      SYSTEM_IMG="system_unsparse.img"
    fi
  fi
fi

if [ -z "$SYSTEM_IMG" ] && [ ! -d "$SYSTEM_DIR" ]; then
  echo "❌ system.img not found"
  exit 1
fi

echo ""; echo "[5/7] Extracting system targets..."
mkdir -p system_extracted

if [ -n "$SYSTEM_IMG" ] && [ -f "$SYSTEM_IMG" ]; then
  FS_TYPE=$(blkid -o value -s TYPE "$SYSTEM_IMG" 2>/dev/null || file "$SYSTEM_IMG" | grep -o 'f2fs\|erofs\|ext[234]')

  if [ "$FS_TYPE" = "f2fs" ]; then
    echo "  Detected f2fs filesystem - mounting..."
    extract_f2fs_mount "$SYSTEM_IMG" "system_extracted" || true
  elif tools/erofs-utils/extract.erofs -i "$SYSTEM_IMG" -x -o system_extracted/ >/dev/null 2>&1; then
    echo "  ✅ Extracted via erofs"
  else
    echo "  erofs failed - trying debugfs..."
    
    for FOLDER in $APP_FOLDERS; do
      for TARGET in "app/$FOLDER" "system/app/$FOLDER"; do
        if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
          mkdir -p "system_extracted/app/$FOLDER"
          debugfs -R "rdump $TARGET system_extracted/app/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done
    
    for FOLDER in $PRIVAPP_FOLDERS; do
      for TARGET in "priv-app/$FOLDER" "system/priv-app/$FOLDER"; do
        if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
          mkdir -p "system_extracted/priv-app/$FOLDER"
          debugfs -R "rdump $TARGET system_extracted/priv-app/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done
    
    for TARGET in "priv-app/PhotoEditor_Full" "system/priv-app/PhotoEditor_Full"; do
      if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
        mkdir -p "system_extracted/priv-app/PhotoEditor_AIFull"
        debugfs -R "rdump $TARGET system_extracted/priv-app/PhotoEditor_AIFull" "$SYSTEM_IMG" 2>/dev/null
        break
      fi
    done
    
    for FOLDER in $ETC_FOLDERS; do
      for TARGET in "etc/$FOLDER" "system/etc/$FOLDER"; do
        if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
          mkdir -p "system_extracted/etc/$FOLDER"
          debugfs -R "rdump $TARGET system_extracted/etc/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done

    for FOLDER in $CAMERADATA_FILES; do
      for TARGET in "cameradata/$FOLDER" "system/cameradata/$FOLDER"; do
        if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
          mkdir -p "system_extracted/cameradata/$FOLDER"
          debugfs -R "rdump $TARGET system_extracted/cameradata/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done
    
    for FILE in $MEDIA_FILES; do
      for SRC in "media/$FILE" "system/media/$FILE"; do
        if debugfs -R "stat $SRC" "$SYSTEM_IMG" 2>/dev/null | grep -q "Type: regular"; then
          mkdir -p "system_extracted/media"
          debugfs -R "dump $SRC system_extracted/media/$FILE" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done

    for FILE in $LIB_FILES; do
      for SRC in "lib/$FILE" "system/lib/$FILE"; do
        if debugfs -R "stat $SRC" "$SYSTEM_IMG" 2>/dev/null | grep -q "Type: regular"; then
          mkdir -p "system_extracted/lib"
          debugfs -R "dump $SRC system_extracted/lib/$FILE" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done
    
    for FILE in $LIB64_FILES; do
      for SRC in "lib64/$FILE" "system/lib64/$FILE"; do
        if debugfs -R "stat $SRC" "$SYSTEM_IMG" 2>/dev/null | grep -q "Type: regular"; then
          mkdir -p "system_extracted/lib64"
          debugfs -R "dump $SRC system_extracted/lib64/$FILE" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done
    
    for JAR in $FRAMEWORK_JARS; do
      for SRC in "framework/$JAR" "system/framework/$JAR"; do
        if debugfs -R "stat $SRC" "$SYSTEM_IMG" 2>/dev/null | grep -q "Type: regular"; then
          mkdir -p "system_extracted/framework"
          debugfs -R "dump $SRC system_extracted/framework/$JAR" "$SYSTEM_IMG" 2>/dev/null
          break
        fi
      done
    done
  fi
fi

echo ""; echo "[6/7] Processing any_partition.txt entries..."
if [ -n "$ANY_PARTITION" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    PART=$(echo "$line" | cut -d'/' -f1)
    REST=$(echo "$line" | cut -d'/' -f2-)
    PART_DIR="partitions_extracted/$PART"
    DEST="$OUTPUT_NAME/$line"
    
    if [ "$PART" = "system" ] && [ -d "system_extracted" ]; then
      SRC=$(resolve_ab_path "system_extracted" "$REST")
    else
      SRC=$(resolve_ab_path "$PART_DIR" "$REST")
    fi
    
    if [ -n "$SRC" ] && [ -e "$SRC" ]; then
      mkdir -p "$(dirname "$DEST")"
      cp -r "$SRC" "$DEST"
      SIZE=$(du -sh "$SRC" 2>/dev/null | cut -f1)
      echo "    ✓ $line ($SIZE)"
    else
      echo "    ❌ $line not found"
    fi
  done <<< "$ANY_PARTITION"
fi

echo ""; echo "[7/7] Copying system targets..."

get_size() {
  local BYTES
  if [ -f "$1" ]; then
    BYTES=$(stat -c%s "$1" 2>/dev/null)
  elif [ -d "$1" ]; then
    BYTES=$(du -sb "$1" 2>/dev/null | cut -f1)
  else
    echo "?"
    return
  fi
  if [ -z "$BYTES" ]; then echo "?"; return; fi
  if [ "$BYTES" -ge 1048576 ]; then
    echo "$(( (BYTES + 524288) / 1048576 ))M"
  else
    echo "$(( (BYTES + 512) / 1024 ))K"
  fi
}

is_target() {
  local item="$1" list="$2"
  for i in $list; do
    [ "$i" = "$item" ] && return 0
  done
  return 1
}

SYSTEM_BASE="system_extracted"
SYS_OUT="$OUTPUT_NAME/system"

if [ "$SHOW_ALL" = "true" ]; then
  echo ""
  echo "--- system/app ---"
  APP_FOUND=false
  for BASE in \
    "$SYSTEM_BASE/app" \
    "$SYSTEM_BASE/system/app" \
    "$SYSTEM_BASE/system_a/app" \
    "$SYSTEM_BASE/system/system/app" \
    "$SYSTEM_BASE/system_a/system/app"; do
    if [ -d "$BASE" ]; then
      for ITEM in "$BASE/"*/; do
        [ -d "$ITEM" ] || continue
        NAME=$(basename "$ITEM")
        SIZE=$(get_size "$ITEM")
        if is_target "$NAME" "$APP_FOLDERS"; then
          printf "    ✓ %-40s %8s\n" "$NAME" "$SIZE"
          mkdir -p "$SYS_OUT/app"
          cp -r "$ITEM" "$SYS_OUT/app/$NAME"
        else
          printf "      %-40s %8s\n" "$NAME" "$SIZE"
        fi
      done
      APP_FOUND=true
      break
    fi
  done
  $APP_FOUND || echo "    (empty)"
else
  for FOLDER in $APP_FOLDERS; do
    FOUND=false
    for BASE in \
      "$SYSTEM_BASE/app/$FOLDER" \
      "$SYSTEM_BASE/system/app/$FOLDER" \
      "$SYSTEM_BASE/system_a/app/$FOLDER" \
      "$SYSTEM_BASE/system/system/app/$FOLDER" \
      "$SYSTEM_BASE/system_a/system/app/$FOLDER"; do
      if [ -d "$BASE" ]; then
        mkdir -p "$SYS_OUT/app"
        cp -r "$BASE" "$SYS_OUT/app/$FOLDER"
        echo "    ✓ app/$FOLDER"
        FOUND=true
        break
      fi
    done
    $FOUND || echo "  ❌ $FOLDER not found"
  done
fi

if [ "$SHOW_ALL" = "true" ]; then
  echo ""
  echo "--- system/priv-app ---"
  PRIVAPP_FOUND=false
  for BASE in \
    "$SYSTEM_BASE/priv-app" \
    "$SYSTEM_BASE/system/priv-app" \
    "$SYSTEM_BASE/system_a/priv-app" \
    "$SYSTEM_BASE/system/system/priv-app" \
    "$SYSTEM_BASE/system_a/system/priv-app"; do
    if [ -d "$BASE" ]; then
      for ITEM in "$BASE/"*/; do
        [ -d "$ITEM" ] || continue
        NAME=$(basename "$ITEM")
        SIZE=$(get_size "$ITEM")
        if is_target "$NAME" "$PRIVAPP_FOLDERS"; then
          printf "    ✓ %-40s %8s\n" "$NAME" "$SIZE"
          mkdir -p "$SYS_OUT/priv-app"
          cp -r "$ITEM" "$SYS_OUT/priv-app/$NAME"
        else
          printf "      %-40s %8s\n" "$NAME" "$SIZE"
        fi
      done
      PRIVAPP_FOUND=true
      break
    fi
  done
  $PRIVAPP_FOUND || echo "    (empty)"
  
  for FOLDER in $PRIVAPP_FOLDERS; do
    [ -d "$SYS_OUT/priv-app/$FOLDER" ] && continue
    FOUND=false
    for BASE in \
      "$SYSTEM_BASE/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system_a/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system/system/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system_a/system/priv-app/$FOLDER"; do
      if [ -d "$BASE" ]; then
        mkdir -p "$SYS_OUT/priv-app"
        cp -r "$BASE" "$SYS_OUT/priv-app/$FOLDER"
        FOUND=true
        break
      fi
    done
    if ! $FOUND && [ "$FOLDER" = "PhotoEditor_AIFull" ]; then
      for BASE in \
        "$SYSTEM_BASE/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system_a/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system/system/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system_a/system/priv-app/PhotoEditor_Full"; do
        if [ -d "$BASE" ]; then
          mkdir -p "$SYS_OUT/priv-app"
          cp -r "$BASE" "$SYS_OUT/priv-app/PhotoEditor_AIFull"
          break
        fi
      done
    fi
  done
else
  for FOLDER in $PRIVAPP_FOLDERS; do
    FOUND=false
    for BASE in \
      "$SYSTEM_BASE/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system_a/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system/system/priv-app/$FOLDER" \
      "$SYSTEM_BASE/system_a/system/priv-app/$FOLDER"; do
      if [ -d "$BASE" ]; then
        mkdir -p "$SYS_OUT/priv-app"
        cp -r "$BASE" "$SYS_OUT/priv-app/$FOLDER"
        echo "    ✓ priv-app/$FOLDER"
        FOUND=true
        break
      fi
    done
    if ! $FOUND && [ "$FOLDER" = "PhotoEditor_AIFull" ]; then
      for BASE in \
        "$SYSTEM_BASE/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system_a/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system/system/priv-app/PhotoEditor_Full" \
        "$SYSTEM_BASE/system_a/system/priv-app/PhotoEditor_Full"; do
        if [ -d "$BASE" ]; then
          mkdir -p "$SYS_OUT/priv-app"
          cp -r "$BASE" "$SYS_OUT/priv-app/PhotoEditor_AIFull"
          echo "    ✓ priv-app/PhotoEditor_AIFull (found as PhotoEditor_Full)"
          FOUND=true
          break
        fi
      done
    fi
    $FOUND || echo "  ❌ $FOLDER not found"
  done
fi

for FOLDER in $ETC_FOLDERS; do
  FOUND=false
  for BASE in \
    "$SYSTEM_BASE/etc/$FOLDER" \
    "$SYSTEM_BASE/system/etc/$FOLDER" \
    "$SYSTEM_BASE/system_a/etc/$FOLDER" \
    "$SYSTEM_BASE/system/system/etc/$FOLDER" \
    "$SYSTEM_BASE/system_a/system/etc/$FOLDER"; do
    if [ -d "$BASE" ]; then
      mkdir -p "$SYS_OUT/etc"
      cp -r "$BASE" "$SYS_OUT/etc/$FOLDER"
      echo "    ✓ etc/$FOLDER"
      FOUND=true
      break
    fi
  done
  $FOUND || echo "  ❌ $FOLDER not found"
done

for FOLDER in $CAMERADATA_FILES; do
  FOUND=false
  for BASE in \
    "$SYSTEM_BASE/cameradata/$FOLDER" \
    "$SYSTEM_BASE/system/cameradata/$FOLDER" \
    "$SYSTEM_BASE/system_a/cameradata/$FOLDER" \
    "$SYSTEM_BASE/system/system/cameradata/$FOLDER" \
    "$SYSTEM_BASE/system_a/system/cameradata/$FOLDER"; do
    if [ -d "$BASE" ]; then
      mkdir -p "$SYS_OUT/cameradata"
      cp -r "$BASE" "$SYS_OUT/cameradata/$FOLDER"
      echo "    ✓ cameradata/$FOLDER"
      FOUND=true
      break
    fi
  done
  $FOUND || echo "  ❌ $FOLDER not found"
done

for FILE in $MEDIA_FILES; do
  FILE_FOUND=false
  for BASE in \
    "$SYSTEM_BASE/media/$FILE" \
    "$SYSTEM_BASE/system/media/$FILE" \
    "$SYSTEM_BASE/system_a/media/$FILE" \
    "$SYSTEM_BASE/system/system/media/$FILE" \
    "$SYSTEM_BASE/system_a/system/media/$FILE"; do
    if [ -f "$BASE" ]; then
      mkdir -p "$SYS_OUT/media"
      cp "$BASE" "$SYS_OUT/media/$FILE"
      echo "    ✓ media/$FILE"
      FILE_FOUND=true
      break
    fi
  done
  $FILE_FOUND || echo "  ❌ $FILE not found"
done

for FILE in $LIB_FILES; do
  FILE_FOUND=false
  for BASE in \
    "$SYSTEM_BASE/lib/$FILE" \
    "$SYSTEM_BASE/system/lib/$FILE" \
    "$SYSTEM_BASE/system_a/lib/$FILE" \
    "$SYSTEM_BASE/system/system/lib/$FILE" \
    "$SYSTEM_BASE/system_a/system/lib/$FILE"; do
    if [ -f "$BASE" ]; then
      mkdir -p "$SYS_OUT/lib"
      cp "$BASE" "$SYS_OUT/lib/$FILE"
      echo "    ✓ lib/$FILE"
      FILE_FOUND=true
      break
    fi
  done
  $FILE_FOUND || echo "  ❌ $FILE not found"
done

for FILE in $LIB64_FILES; do
  FILE_FOUND=false
  for BASE in \
    "$SYSTEM_BASE/lib64/$FILE" \
    "$SYSTEM_BASE/system/lib64/$FILE" \
    "$SYSTEM_BASE/system_a/lib64/$FILE" \
    "$SYSTEM_BASE/system/system/lib64/$FILE" \
    "$SYSTEM_BASE/system_a/system/lib64/$FILE"; do
    if [ -f "$BASE" ]; then
      mkdir -p "$SYS_OUT/lib64"
      cp "$BASE" "$SYS_OUT/lib64/$FILE"
      echo "    ✓ lib64/$FILE"
      FILE_FOUND=true
      break
    fi
  done
  $FILE_FOUND || echo "  ❌ $FILE not found"
done

for JAR in $FRAMEWORK_JARS; do
  JAR_FOUND=false
  for BASE in \
    "$SYSTEM_BASE/framework/$JAR" \
    "$SYSTEM_BASE/system/framework/$JAR" \
    "$SYSTEM_BASE/system_a/framework/$JAR" \
    "$SYSTEM_BASE/system/system/framework/$JAR" \
    "$SYSTEM_BASE/system_a/system/framework/$JAR"; do
    if [ -f "$BASE" ]; then
      mkdir -p "$SYS_OUT/framework"
      cp "$BASE" "$SYS_OUT/framework/$JAR"
      echo "    ✓ framework/$JAR"
      JAR_FOUND=true
      break
    fi
  done
  $JAR_FOUND || echo "  ❌ $JAR not found"
done

rm -rf system_extracted partitions_extracted super_dump *.img

echo ""; echo "Packaging..."
cd output
PKG_NAME="${OUTPUT_NAME}.zip"
if [ "$COMPRESSION_LEVEL" != "0" ]; then
  tar -cf - "$OUTPUT_NAME" | xz $XZ_FLAGS -T0 2>/dev/null > "${OUTPUT_NAME}.tar.xz"
  rm -rf "$OUTPUT_NAME"
  echo "    ✓ ${OUTPUT_NAME}.tar.xz"
else
  zip -r "$PKG_NAME" "$OUTPUT_NAME" >/dev/null 2>&1
  rm -rf "$OUTPUT_NAME"
  echo "    ✓ $PKG_NAME"
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
