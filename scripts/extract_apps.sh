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
SHOW_ALL="${3:-false}"

chmod +x tools/android-tools/* tools/erofs-utils/* 2>/dev/null || true

case "$COMPRESSION_LEVEL" in
  0) XZ_FLAGS="-0" ;;
  3) XZ_FLAGS="-3" ;;
  6) XZ_FLAGS="-6" ;;
  9) XZ_FLAGS="-9" ;;
  *) XZ_FLAGS="-0" ;;
esac

# Define targets from txt files
APP_FOLDERS=$(cat targets/app.txt 2>/dev/null | tr '\n' ' ')
PRIVAPP_FOLDERS=$(cat targets/priv-app.txt 2>/dev/null | tr '\n' ' ')
ETC_FOLDERS=$(cat targets/etc.txt 2>/dev/null | tr '\n' ' ')
MEDIA_FILES=$(cat targets/media.txt 2>/dev/null | tr '\n' ' ')
LIB64_FILES=$(cat targets/lib64.txt 2>/dev/null | tr '\n' ' ')
FRAMEWORK_JARS=$(cat targets/framework.txt 2>/dev/null | tr '\n' ' ')

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
mkdir -p system_extracted output/Apps/system

if tools/erofs-utils/extract.erofs -i "$SYSTEM_IMG" -x -o system_extracted/ >/dev/null 2>&1; then
  echo "  ✅ Extracted via erofs"
else
  echo "  erofs failed - trying debugfs..."
  
  # Extract app folders
  for FOLDER in $APP_FOLDERS; do
    for TARGET in "app/$FOLDER" "system/app/$FOLDER"; do
      if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
        mkdir -p "system_extracted/app/$FOLDER"
        debugfs -R "rdump $TARGET system_extracted/app/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
        break
      fi
    done
  done
  
  # Extract priv-app folders
  for FOLDER in $PRIVAPP_FOLDERS; do
    for TARGET in "priv-app/$FOLDER" "system/priv-app/$FOLDER"; do
      if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
        mkdir -p "system_extracted/priv-app/$FOLDER"
        debugfs -R "rdump $TARGET system_extracted/priv-app/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
        break
      fi
    done
  done
  
  # Fallback: PhotoEditor_AIFull -> PhotoEditor_Full
  for TARGET in "priv-app/PhotoEditor_Full" "system/priv-app/PhotoEditor_Full"; do
    if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
      mkdir -p "system_extracted/priv-app/PhotoEditor_AIFull"
      debugfs -R "rdump $TARGET system_extracted/priv-app/PhotoEditor_AIFull" "$SYSTEM_IMG" 2>/dev/null
      break
    fi
  done
  
  # Extract etc folders
  for FOLDER in $ETC_FOLDERS; do
    for TARGET in "etc/$FOLDER" "system/etc/$FOLDER"; do
      if debugfs -R "ls $TARGET" "$SYSTEM_IMG" 2>/dev/null | grep -q .; then
        mkdir -p "system_extracted/etc/$FOLDER"
        debugfs -R "rdump $TARGET system_extracted/etc/$FOLDER" "$SYSTEM_IMG" 2>/dev/null
        break
      fi
    done
  done
  
  # Extract media files
  for FILE in $MEDIA_FILES; do
    for SRC in "media/$FILE" "system/media/$FILE"; do
      if debugfs -R "stat $SRC" "$SYSTEM_IMG" 2>/dev/null | grep -q "Type: regular"; then
        mkdir -p "system_extracted/media"
        debugfs -R "dump $SRC system_extracted/media/$FILE" "$SYSTEM_IMG" 2>/dev/null
        break
      fi
    done
  done
  
  # Extract lib64 files
  for FILE in $LIB64_FILES; do
    for SRC in "lib64/$FILE" "system/lib64/$FILE"; do
      if debugfs -R "stat $SRC" "$SYSTEM_IMG" 2>/dev/null | grep -q "Type: regular"; then
        mkdir -p "system_extracted/lib64"
        debugfs -R "dump $SRC system_extracted/lib64/$FILE" "$SYSTEM_IMG" 2>/dev/null
        break
      fi
    done
  done
  
  # Extract framework JARs
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

# Helper: size
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

# --- app/ ---
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
          mkdir -p "output/Apps/system/app"
          cp -r "$ITEM" "output/Apps/system/app/$NAME"
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
      if [ -d "$BASE" ]; then
        mkdir -p "output/Apps/system/app"
        cp -r "$BASE" "output/Apps/system/app/$FOLDER"
        echo "    ✓ app/$FOLDER"
        FOUND=true
        break
      fi
    done
    $FOUND || echo "  ❌ $FOLDER not found"
  done
fi

# --- priv-app/ ---
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
          mkdir -p "output/Apps/system/priv-app"
          cp -r "$ITEM" "output/Apps/system/priv-app/$NAME"
        else
          printf "      %-40s %8s\n" "$NAME" "$SIZE"
        fi
      done
      PRIVAPP_FOUND=true
      break
    fi
  done
  $PRIVAPP_FOUND || echo "    (empty)"
  
  # Also copy any targets not found in full dump (fallbacks)
  for FOLDER in $PRIVAPP_FOLDERS; do
    [ -d "output/Apps/system/priv-app/$FOLDER" ] && continue
    FOUND=false
    for BASE in \
      "system_extracted/priv-app/$FOLDER" \
      "system_extracted/system/priv-app/$FOLDER" \
      "system_extracted/system_a/priv-app/$FOLDER" \
      "system_extracted/system/system/priv-app/$FOLDER" \
      "system_extracted/system_a/system/priv-app/$FOLDER"; do
      if [ -d "$BASE" ]; then
        mkdir -p "output/Apps/system/priv-app"
        cp -r "$BASE" "output/Apps/system/priv-app/$FOLDER"
        FOUND=true
        break
      fi
    done
    if ! $FOUND && [ "$FOLDER" = "PhotoEditor_AIFull" ]; then
      for BASE in \
        "system_extracted/priv-app/PhotoEditor_Full" \
        "system_extracted/system/priv-app/PhotoEditor_Full" \
        "system_extracted/system_a/priv-app/PhotoEditor_Full" \
        "system_extracted/system/system/priv-app/PhotoEditor_Full" \
        "system_extracted/system_a/system/priv-app/PhotoEditor_Full"; do
        if [ -d "$BASE" ]; then
          mkdir -p "output/Apps/system/priv-app"
          cp -r "$BASE" "output/Apps/system/priv-app/PhotoEditor_AIFull"
          break
        fi
      done
    fi
  done
else
  for FOLDER in $PRIVAPP_FOLDERS; do
    FOUND=false
    for BASE in \
      "system_extracted/priv-app/$FOLDER" \
      "system_extracted/system/priv-app/$FOLDER" \
      "system_extracted/system_a/priv-app/$FOLDER" \
      "system_extracted/system/system/priv-app/$FOLDER" \
      "system_extracted/system_a/system/priv-app/$FOLDER"; do
      if [ -d "$BASE" ]; then
        mkdir -p "output/Apps/system/priv-app"
        cp -r "$BASE" "output/Apps/system/priv-app/$FOLDER"
        echo "    ✓ priv-app/$FOLDER"
        FOUND=true
        break
      fi
    done
    if ! $FOUND && [ "$FOLDER" = "PhotoEditor_AIFull" ]; then
      for BASE in \
        "system_extracted/priv-app/PhotoEditor_Full" \
        "system_extracted/system/priv-app/PhotoEditor_Full" \
        "system_extracted/system_a/priv-app/PhotoEditor_Full" \
        "system_extracted/system/system/priv-app/PhotoEditor_Full" \
        "system_extracted/system_a/system/priv-app/PhotoEditor_Full"; do
        if [ -d "$BASE" ]; then
          mkdir -p "output/Apps/system/priv-app"
          cp -r "$BASE" "output/Apps/system/priv-app/PhotoEditor_AIFull"
          echo "    ✓ priv-app/PhotoEditor_AIFull (found as PhotoEditor_Full)"
          FOUND=true
          break
        fi
      done
    fi
    $FOUND || echo "  ❌ $FOLDER not found"
  done
fi

# --- etc/ ---
for FOLDER in $ETC_FOLDERS; do
  FOUND=false
  for BASE in \
    "system_extracted/etc/$FOLDER" \
    "system_extracted/system/etc/$FOLDER" \
    "system_extracted/system_a/etc/$FOLDER" \
    "system_extracted/system/system/etc/$FOLDER" \
    "system_extracted/system_a/system/etc/$FOLDER"; do
    if [ -d "$BASE" ]; then
      mkdir -p "output/Apps/system/etc"
      cp -r "$BASE" "output/Apps/system/etc/$FOLDER"
      echo "    ✓ etc/$FOLDER"
      FOUND=true
      break
    fi
  done
  $FOUND || echo "  ❌ $FOLDER not found"
done

# --- media/ ---
mkdir -p "output/Apps/system/media"
for FILE in $MEDIA_FILES; do
  FILE_FOUND=false
  for BASE in \
    "system_extracted/media/$FILE" \
    "system_extracted/system/media/$FILE" \
    "system_extracted/system_a/media/$FILE" \
    "system_extracted/system/system/media/$FILE" \
    "system_extracted/system_a/system/media/$FILE"; do
    if [ -f "$BASE" ]; then
      cp "$BASE" "output/Apps/system/media/$FILE"
      echo "    ✓ media/$FILE"
      FILE_FOUND=true
      break
    fi
  done
  $FILE_FOUND || echo "  ❌ $FILE not found"
done

# --- lib64/ ---
mkdir -p "output/Apps/system/lib64"
for FILE in $LIB64_FILES; do
  FILE_FOUND=false
  for BASE in \
    "system_extracted/lib64/$FILE" \
    "system_extracted/system/lib64/$FILE" \
    "system_extracted/system_a/lib64/$FILE" \
    "system_extracted/system/system/lib64/$FILE" \
    "system_extracted/system_a/system/lib64/$FILE"; do
    if [ -f "$BASE" ]; then
      cp "$BASE" "output/Apps/system/lib64/$FILE"
      echo "    ✓ lib64/$FILE"
      FILE_FOUND=true
      break
    fi
  done
  $FILE_FOUND || echo "  ❌ $FILE not found"
done

# --- framework/ ---
mkdir -p "output/Apps/system/framework"
for JAR in $FRAMEWORK_JARS; do
  JAR_FOUND=false
  for BASE in \
    "system_extracted/framework/$JAR" \
    "system_extracted/system/framework/$JAR" \
    "system_extracted/system_a/framework/$JAR" \
    "system_extracted/system/system/framework/$JAR" \
    "system_extracted/system_a/system/framework/$JAR"; do
    if [ -f "$BASE" ]; then
      cp "$BASE" "output/Apps/system/framework/$JAR"
      echo "    ✓ framework/$JAR"
      JAR_FOUND=true
      break
    fi
  done
  $JAR_FOUND || echo "  ❌ $JAR not found"
done

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
