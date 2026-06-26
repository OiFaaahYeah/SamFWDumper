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
ETC_ITEMS=$(cat targets/system/etc.txt 2>/dev/null | tr '\n' ' ')
MEDIA_FILES=$(cat targets/system/media.txt 2>/dev/null | tr '\n' ' ')
LIB_FILES=$(cat targets/system/lib.txt 2>/dev/null | tr '\n' ' ')
LIB64_FILES=$(cat targets/system/lib64.txt 2>/dev/null | tr '\n' ' ')
FRAMEWORK_JARS=$(cat targets/system/framework.txt 2>/dev/null | tr '\n' ' ')
CAMERADATA_ITEMS=$(cat targets/system/cameradata.txt 2>/dev/null | tr '\n' ' ')

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
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/app"
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
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/priv-app"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/priv-app/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/priv-app/$FOLDER"
        FOUND=true; break
      fi
    done
    if ! $FOUND; then
      for ALT in "PhotoEditor_AIFull" "PhotoEditor_Full" "PhotoEditor"; do
        [ "$ALT" = "$FOLDER" ] && continue
        for SRC_PATH in "$MNT/priv-app/$ALT" "$MNT/system/priv-app/$ALT"; do
          if sudo test -e "$SRC_PATH" 2>/dev/null; then
            mkdir -p "$OUT_DIR/priv-app"
            sudo cp -r "$SRC_PATH" "$OUT_DIR/priv-app/$FOLDER" 2>/dev/null
            sudo chown -R $(id -u):$(id -g) "$OUT_DIR/priv-app/$FOLDER"
            FOUND=true; break 2
          fi
        done
      done
    fi
    $FOUND || echo "  ⚠️ priv-app/$FOLDER not found"
  done

  for ITEM in $ETC_ITEMS; do
    FOUND=false
    for SRC_PATH in "$MNT/etc/$ITEM" "$MNT/system/etc/$ITEM"; do
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/etc"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/etc/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/etc/$ITEM"
        FOUND=true; break
      fi
    done
    $FOUND || echo "  ⚠️ etc/$ITEM not found"
  done

  for ITEM in $CAMERADATA_ITEMS; do
    FOUND=false
    for SRC_PATH in "$MNT/cameradata/$ITEM" "$MNT/system/cameradata/$ITEM"; do
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/cameradata"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/cameradata/" 2>/dev/null
        sudo chown -R $(id -u):$(id -g) "$OUT_DIR/cameradata/$ITEM"
        FOUND=true; break
      fi
    done
    $FOUND || echo "  ⚠️ cameradata/$ITEM not found"
  done

  for FILE in $MEDIA_FILES; do
    FILE_FOUND=false
    for SRC_PATH in "$MNT/media/$FILE" "$MNT/system/media/$FILE"; do
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/media"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/media/$FILE"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/media/$FILE"
        FILE_FOUND=true; break
      fi
    done
    $FILE_FOUND || echo "  ⚠️ media/$FILE not found"
  done

  for FILE in $LIB_FILES; do
    FILE_FOUND=false
    for SRC_PATH in "$MNT/lib/$FILE" "$MNT/system/lib/$FILE"; do
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/lib"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/lib/$FILE"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/lib/$FILE"
        FILE_FOUND=true; break
      fi
    done
    $FILE_FOUND || echo "  ⚠️ lib/$FILE not found"
  done

  for FILE in $LIB64_FILES; do
    FILE_FOUND=false
    for SRC_PATH in "$MNT/lib64/$FILE" "$MNT/system/lib64/$FILE"; do
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/lib64"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/lib64/$FILE"
        sudo chown $(id -u):$(id -g) "$OUT_DIR/lib64/$FILE"
        FILE_FOUND=true; break
      fi
    done
    $FILE_FOUND || echo "  ⚠️ lib64/$FILE not found"
  done

  for JAR in $FRAMEWORK_JARS; do
    JAR_FOUND=false
    for SRC_PATH in "$MNT/framework/$JAR" "$MNT/system/framework/$JAR"; do
      if sudo test -e "$SRC_PATH" 2>/dev/null; then
        mkdir -p "$OUT_DIR/framework"
        sudo cp -r "$SRC_PATH" "$OUT_DIR/framework/$JAR"
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
mkdir -p system_extracted "output/$OUTPUT_NAME/system"

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
    if [ ! -d "system_extracted/priv-app/$FOLDER" ]; then
      for ALT in "PhotoEditor_AIFull" "PhotoEditor_Full" "PhotoEditor"; do
        [ "$ALT" = "$FOLDER" ] && continue
        for TARGET in "priv-app/$ALT" "system/priv-app/$ALT"; do
          if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
            mkdir -p "system_extracted/priv-app/$FOLDER"
            debugfs -R "rdump $TARGET system_extracted/priv-app/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
            break 2
          fi
        done
      done
    fi
  done
  
  for ITEM in $ETC_ITEMS; do
    for TARGET in "etc/$ITEM" "system/etc/$ITEM"; do
      if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
        mkdir -p "system_extracted/etc"
        debugfs -R "rdump $TARGET system_extracted/etc/$ITEM" "$SYSTEM_IMG" 2>/dev/null
        break
      fi
    done
  done

  for ITEM in $CAMERADATA_ITEMS; do
    for TARGET in "cameradata/$ITEM" "system/cameradata/$ITEM"; do
      if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
        mkdir -p "system_extracted/cameradata"
        debugfs -R "rdump $TARGET system_extracted/cameradata/$ITEM" "$SYSTEM_IMG" 2>/dev/null
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

echo ""; echo "[6/6] Copying targets..."

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

SYS_OUT="output/$OUTPUT_NAME/system"
HAS_ANY=false

copy_item() {
  local SRC="$1" DST_DIR="$2" DST_NAME="$3" LABEL="$4"
  if [ -e "$SRC" ]; then
    mkdir -p "$DST_DIR"
    cp -r "$SRC" "$DST_DIR/$DST_NAME"
    echo "    ✓ $LABEL"
    return 0
  fi
  return 1
}

if [ -n "$APP_FOLDERS" ]; then
  if [ "$SHOW_ALL" = "true" ]; then
    echo ""
    echo "--- system/app ---"
    APP_FOUND=false
    for BASE in \
      "system_extracted/app" \
      "system_extracted/system/app" \
      "system_extracted/system_a/app" \
      "system_extracted/system/system/app" \
      "system_extracted/system_a/system/app"; do
      if [ -d "$BASE" ]; then
        for ITEM in "$BASE/"*/; do
          [ -d "$ITEM" ] || continue
          NAME=$(basename "$ITEM")
          SIZE=$(get_size "$ITEM")
          if is_target "$NAME" "$APP_FOLDERS"; then
            printf "    ✓ %-40s %8s\n" "$NAME" "$SIZE"
            mkdir -p "$SYS_OUT/app"
            cp -r "$ITEM" "$SYS_OUT/app/$NAME"
            HAS_ANY=true
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
        "system_extracted/app/$FOLDER" \
        "system_extracted/system/app/$FOLDER" \
        "system_extracted/system_a/app/$FOLDER" \
        "system_extracted/system/system/app/$FOLDER" \
        "system_extracted/system_a/system/app/$FOLDER"; do
        if [ -e "$BASE" ]; then
          copy_item "$BASE" "$SYS_OUT/app" "$FOLDER" "app/$FOLDER" && HAS_ANY=true && FOUND=true && break
        fi
      done
      $FOUND || echo "    ❌ app/$FOLDER not found"
    done
  fi
fi

if [ -n "$PRIVAPP_FOLDERS" ]; then
  if [ "$SHOW_ALL" = "true" ]; then
    echo ""
    echo "--- system/priv-app ---"
    PRIVAPP_FOUND=false
    for BASE in \
      "system_extracted/priv-app" \
      "system_extracted/system/priv-app" \
      "system_extracted/system_a/priv-app" \
      "system_extracted/system/system/priv-app" \
      "system_extracted/system_a/system/priv-app"; do
      if [ -d "$BASE" ]; then
        for ITEM in "$BASE/"*/; do
          [ -d "$ITEM" ] || continue
          NAME=$(basename "$ITEM")
          SIZE=$(get_size "$ITEM")
          if is_target "$NAME" "$PRIVAPP_FOLDERS"; then
            printf "    ✓ %-40s %8s\n" "$NAME" "$SIZE"
            mkdir -p "$SYS_OUT/priv-app"
            cp -r "$ITEM" "$SYS_OUT/priv-app/$NAME"
            HAS_ANY=true
          else
            printf "      %-40s %8s\n" "$NAME" "$SIZE"
          fi
        done
        PRIVAPP_FOUND=true
        break
      fi
    done
    $PRIVAPP_FOUND || echo "    (empty)"
  else
    for FOLDER in $PRIVAPP_FOLDERS; do
      FOUND=false
      for BASE in \
        "system_extracted/priv-app/$FOLDER" \
        "system_extracted/system/priv-app/$FOLDER" \
        "system_extracted/system_a/priv-app/$FOLDER" \
        "system_extracted/system/system/priv-app/$FOLDER" \
        "system_extracted/system_a/system/priv-app/$FOLDER"; do
        if [ -e "$BASE" ]; then
          copy_item "$BASE" "$SYS_OUT/priv-app" "$FOLDER" "priv-app/$FOLDER" && HAS_ANY=true && FOUND=true && break
        fi
      done
      if ! $FOUND; then
        for ALT in "PhotoEditor_AIFull" "PhotoEditor_Full" "PhotoEditor"; do
          [ "$ALT" = "$FOLDER" ] && continue
          for BASE in \
            "system_extracted/priv-app/$ALT" \
            "system_extracted/system/priv-app/$ALT" \
            "system_extracted/system_a/priv-app/$ALT" \
            "system_extracted/system/system/priv-app/$ALT" \
            "system_extracted/system_a/system/priv-app/$ALT"; do
            if [ -e "$BASE" ]; then
              copy_item "$BASE" "$SYS_OUT/priv-app" "$FOLDER" "priv-app/$FOLDER (found as $ALT)" && HAS_ANY=true && FOUND=true && break 2
            fi
          done
        done
      fi
      $FOUND || echo "    ❌ priv-app/$FOLDER not found"
    done
  fi
fi

if [ -n "$ETC_ITEMS" ]; then
  for ITEM in $ETC_ITEMS; do
    FOUND=false
    for BASE in \
      "system_extracted/etc/$ITEM" \
      "system_extracted/system/etc/$ITEM" \
      "system_extracted/system_a/etc/$ITEM" \
      "system_extracted/system/system/etc/$ITEM" \
      "system_extracted/system_a/system/etc/$ITEM"; do
      if [ -e "$BASE" ]; then
        copy_item "$BASE" "$SYS_OUT/etc" "$ITEM" "etc/$ITEM" && HAS_ANY=true && FOUND=true && break
      fi
    done
    $FOUND || echo "    ❌ etc/$ITEM not found"
  done
fi

if [ -n "$CAMERADATA_ITEMS" ]; then
  for ITEM in $CAMERADATA_ITEMS; do
    FOUND=false
    for BASE in \
      "system_extracted/cameradata/$ITEM" \
      "system_extracted/system/cameradata/$ITEM" \
      "system_extracted/system_a/cameradata/$ITEM" \
      "system_extracted/system/system/cameradata/$ITEM" \
      "system_extracted/system_a/system/cameradata/$ITEM"; do
      if [ -e "$BASE" ]; then
        copy_item "$BASE" "$SYS_OUT/cameradata" "$ITEM" "cameradata/$ITEM" && HAS_ANY=true && FOUND=true && break
      fi
    done
    $FOUND || echo "    ❌ cameradata/$ITEM not found"
  done
fi

if [ -n "$MEDIA_FILES" ]; then
  for FILE in $MEDIA_FILES; do
    FOUND=false
    for BASE in \
      "system_extracted/media/$FILE" \
      "system_extracted/system/media/$FILE" \
      "system_extracted/system_a/media/$FILE" \
      "system_extracted/system/system/media/$FILE" \
      "system_extracted/system_a/system/media/$FILE"; do
      if [ -e "$BASE" ]; then
        copy_item "$BASE" "$SYS_OUT/media" "$FILE" "media/$FILE" && HAS_ANY=true && FOUND=true && break
      fi
    done
    $FOUND || echo "    ❌ media/$FILE not found"
  done
fi

if [ -n "$LIB_FILES" ]; then
  for FILE in $LIB_FILES; do
    FOUND=false
    for BASE in \
      "system_extracted/lib/$FILE" \
      "system_extracted/system/lib/$FILE" \
      "system_extracted/system_a/lib/$FILE" \
      "system_extracted/system/system/lib/$FILE" \
      "system_extracted/system_a/system/lib/$FILE"; do
      if [ -e "$BASE" ]; then
        copy_item "$BASE" "$SYS_OUT/lib" "$FILE" "lib/$FILE" && HAS_ANY=true && FOUND=true && break
      fi
    done
    $FOUND || echo "    ❌ lib/$FILE not found"
  done
fi

if [ -n "$LIB64_FILES" ]; then
  for FILE in $LIB64_FILES; do
    FOUND=false
    for BASE in \
      "system_extracted/lib64/$FILE" \
      "system_extracted/system/lib64/$FILE" \
      "system_extracted/system_a/lib64/$FILE" \
      "system_extracted/system/system/lib64/$FILE" \
      "system_extracted/system_a/system/lib64/$FILE"; do
      if [ -e "$BASE" ]; then
        copy_item "$BASE" "$SYS_OUT/lib64" "$FILE" "lib64/$FILE" && HAS_ANY=true && FOUND=true && break
      fi
    done
    $FOUND || echo "    ❌ lib64/$FILE not found"
  done
fi

if [ -n "$FRAMEWORK_JARS" ]; then
  for JAR in $FRAMEWORK_JARS; do
    FOUND=false
    for BASE in \
      "system_extracted/framework/$JAR" \
      "system_extracted/system/framework/$JAR" \
      "system_extracted/system_a/framework/$JAR" \
      "system_extracted/system/system/framework/$JAR" \
      "system_extracted/system_a/system/framework/$JAR"; do
      if [ -e "$BASE" ]; then
        copy_item "$BASE" "$SYS_OUT/framework" "$JAR" "framework/$JAR" && HAS_ANY=true && FOUND=true && break
      fi
    done
    $FOUND || echo "    ❌ framework/$JAR not found"
  done
fi

rm -rf system_extracted super_dump *.img

if ! $HAS_ANY; then
  echo ""
  echo "❌ Nothing extracted!"
  exit 1
fi

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
TOTAL_SIZE=$(du -sh . | cut -f1)
echo "✅ Extracted $FILE_COUNT items"
echo "Total size: $TOTAL_SIZE"
ls -lh
echo "═══════════════════════════════════════"
echo "✅ Done!"
