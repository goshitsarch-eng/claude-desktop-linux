#!/bin/bash
set -euo pipefail

# RPM Build Script for Claude Desktop Linux
# Adapts build.sh logic for Fedora/RPM systems

# --- Architecture Detection ---
echo -e "\033[1;36m--- Architecture Detection ---\033[0m"
echo "Detecting system architecture..."
HOST_ARCH=$(uname -m)
echo "Detected host architecture: $HOST_ARCH"

# Set variables based on detected architecture
case "$HOST_ARCH" in
    x86_64)
        CLAUDE_DOWNLOAD_URL="https://downloads.claude.ai/releases/win32/x64/1.1.381/Claude-c2a39e9c82f5a4d51f511f53f532afd276312731.exe"
        ARCHITECTURE="x86_64"
        CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
        echo "Configured for x86_64 build."
        ;;
    aarch64)
        CLAUDE_DOWNLOAD_URL="https://downloads.claude.ai/releases/win32/arm64/1.1.381/Claude-c2a39e9c82f5a4d51f511f53f532afd276312731.exe"
        ARCHITECTURE="aarch64"
        CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
        echo "Configured for aarch64 build."
        ;;
    *)
        echo "Unsupported architecture: $HOST_ARCH. This script supports x86_64 and aarch64."
        exit 1
        ;;
esac
echo "Target Architecture: $ARCHITECTURE"
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"

# Check for Fedora/RPM-based system
if [ ! -f "/etc/fedora-release" ] && [ ! -f "/etc/redhat-release" ]; then
    echo "Warning: This script is designed for Fedora/RHEL-based distributions"
fi

ORIGINAL_USER=$(whoami)
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    echo "Could not determine home directory for user $ORIGINAL_USER."
    exit 1
fi
echo "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"

echo "System Information:"
if [ -f "/etc/fedora-release" ]; then
    echo "Distribution: $(cat /etc/fedora-release)"
elif [ -f "/etc/redhat-release" ]; then
    echo "Distribution: $(cat /etc/redhat-release)"
fi
echo "Target Architecture: $ARCHITECTURE"

PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
PROJECT_ROOT="$(pwd)"
WORK_DIR="$PROJECT_ROOT/build"
APP_STAGING_DIR="$WORK_DIR/electron-app"
VERSION=""

# --- Dependency Installation ---
echo -e "\033[1;36m--- Installing Dependencies ---\033[0m"
echo "Installing required packages via dnf..."

# Install all required dependencies
dnf install -y \
    p7zip \
    p7zip-plugins \
    wget \
    icoutils \
    ImageMagick \
    rpm-build \
    nodejs \
    npm \
    findutils \
    sed \
    grep \
    make \
    gcc \
    gcc-c++ \
    python3

echo "Dependencies installed successfully."
echo -e "\033[1;36m--- End Dependency Installation ---\033[0m"

# --- Prepare Build Directory ---
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$APP_STAGING_DIR"

# --- Node.js Setup ---
echo -e "\033[1;36m--- Node.js Setup ---\033[0m"
echo "Checking Node.js version..."
NODE_VERSION_OK=false
if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version | cut -d'v' -f2)
    NODE_MAJOR=$(echo "$NODE_VERSION" | cut -d'.' -f1)
    echo "System Node.js version: v$NODE_VERSION"

    if [ "$NODE_MAJOR" -ge 20 ]; then
        echo "System Node.js version is adequate (v$NODE_VERSION)"
        NODE_VERSION_OK=true
    else
        echo "System Node.js version is too old (v$NODE_VERSION). Need v20+"
    fi
else
    echo "Node.js not found in system"
fi

# If system Node.js is not adequate, install a local copy
if [ "$NODE_VERSION_OK" = false ]; then
    echo "Installing Node.js v20 locally in build directory..."

    # Determine Node.js download URL based on architecture
    case "$ARCHITECTURE" in
        x86_64)  NODE_ARCH="x64" ;;
        aarch64) NODE_ARCH="arm64" ;;
        *)
            echo "Unsupported architecture for Node.js: $ARCHITECTURE"
            exit 1
            ;;
    esac

    NODE_VERSION_TO_INSTALL="20.18.1"
    NODE_TARBALL="node-v${NODE_VERSION_TO_INSTALL}-linux-${NODE_ARCH}.tar.xz"
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION_TO_INSTALL}/${NODE_TARBALL}"
    NODE_INSTALL_DIR="$WORK_DIR/node"

    echo "Downloading Node.js v${NODE_VERSION_TO_INSTALL} for ${NODE_ARCH}..."
    cd "$WORK_DIR"
    if ! wget -O "$NODE_TARBALL" "$NODE_URL"; then
        echo "Failed to download Node.js from $NODE_URL"
        cd "$PROJECT_ROOT"
        exit 1
    fi

    echo "Extracting Node.js..."
    if ! tar -xf "$NODE_TARBALL"; then
        echo "Failed to extract Node.js tarball"
        cd "$PROJECT_ROOT"
        exit 1
    fi

    mv "node-v${NODE_VERSION_TO_INSTALL}-linux-${NODE_ARCH}" "$NODE_INSTALL_DIR"
    export PATH="$NODE_INSTALL_DIR/bin:$PATH"

    if command -v node &> /dev/null; then
        LOCAL_NODE_VERSION=$(node --version)
        echo "Local Node.js installed successfully: $LOCAL_NODE_VERSION"
    else
        echo "Failed to install local Node.js"
        cd "$PROJECT_ROOT"
        exit 1
    fi

    rm -f "$NODE_TARBALL"
    cd "$PROJECT_ROOT"
fi
echo -e "\033[1;36m--- End Node.js Setup ---\033[0m"

# --- Electron & Asar Handling ---
echo -e "\033[1;36m--- Electron & Asar Handling ---\033[0m"
CHOSEN_ELECTRON_MODULE_PATH=""
ASAR_EXEC=""

echo "Ensuring local Electron and Asar installation in $WORK_DIR..."
cd "$WORK_DIR"
if [ ! -f "package.json" ]; then
    echo "Creating temporary package.json in $WORK_DIR for local install..."
    echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
fi

ELECTRON_DIST_PATH="$WORK_DIR/node_modules/electron/dist"
ASAR_BIN_PATH="$WORK_DIR/node_modules/.bin/asar"

INSTALL_NEEDED=false
if [ ! -d "$ELECTRON_DIST_PATH" ]; then
    echo "Electron distribution not found."
    INSTALL_NEEDED=true
fi
if [ ! -f "$ASAR_BIN_PATH" ]; then
    echo "Asar binary not found."
    INSTALL_NEEDED=true
fi

if [ "$INSTALL_NEEDED" = true ]; then
    echo "Installing Electron and Asar locally into $WORK_DIR..."
    if ! npm install --no-save electron @electron/asar; then
        echo "Failed to install Electron and/or Asar locally."
        cd "$PROJECT_ROOT"
        exit 1
    fi
    echo "Electron and Asar installation command finished."
else
    echo "Local Electron distribution and Asar binary already present."
fi

if [ -d "$ELECTRON_DIST_PATH" ]; then
    echo "Found Electron distribution directory at $ELECTRON_DIST_PATH."
    CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
    echo "Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
else
    echo "Failed to find Electron distribution directory at '$ELECTRON_DIST_PATH' after installation attempt."
    cd "$PROJECT_ROOT"
    exit 1
fi

if [ -f "$ASAR_BIN_PATH" ]; then
    ASAR_EXEC="$(realpath "$ASAR_BIN_PATH")"
    echo "Found local Asar binary at $ASAR_EXEC."
else
    echo "Failed to find Asar binary at '$ASAR_BIN_PATH' after installation attempt."
    cd "$PROJECT_ROOT"
    exit 1
fi

cd "$PROJECT_ROOT"
if [ -z "$CHOSEN_ELECTRON_MODULE_PATH" ] || [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
     echo "Critical error: Could not resolve a valid Electron module path to copy."
     exit 1
fi
echo "Using Electron module path: $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using asar executable: $ASAR_EXEC"

# --- Download Claude Executable ---
echo -e "\033[1;36m--- Download the latest Claude executable ---\033[0m"
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"
echo "Downloading Claude Desktop installer for $ARCHITECTURE..."
if ! wget -O "$CLAUDE_EXE_PATH" "$CLAUDE_DOWNLOAD_URL"; then
    echo "Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    exit 1
fi
echo "Download complete: $CLAUDE_EXE_FILENAME"

echo "Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
mkdir -p "$CLAUDE_EXTRACT_DIR"
if ! 7z x -y "$CLAUDE_EXE_PATH" -o"$CLAUDE_EXTRACT_DIR"; then
    echo "Failed to extract installer"
    cd "$PROJECT_ROOT" && exit 1
fi

cd "$CLAUDE_EXTRACT_DIR"
NUPKG_PATH_RELATIVE=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH_RELATIVE" ]; then
    echo "Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
    cd "$PROJECT_ROOT" && exit 1
fi
NUPKG_PATH="$CLAUDE_EXTRACT_DIR/$NUPKG_PATH_RELATIVE"
echo "Found nupkg: $NUPKG_PATH_RELATIVE (in $CLAUDE_EXTRACT_DIR)"

VERSION=$(echo "$NUPKG_PATH_RELATIVE" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
if [ -z "$VERSION" ]; then
    echo "Could not extract version from nupkg filename: $NUPKG_PATH_RELATIVE"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "Detected Claude version: $VERSION"

if ! 7z x -y "$NUPKG_PATH_RELATIVE"; then
    echo "Failed to extract nupkg"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "Resources extracted from nupkg"

echo "Processing app.asar..."
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
cp -a "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/"
cd "$APP_STAGING_DIR"
"$ASAR_EXEC" extract app.asar app.asar.contents

echo "Creating BrowserWindow frame fix wrapper..."
ORIGINAL_MAIN=$(node -e "const pkg = require('./app.asar.contents/package.json'); console.log(pkg.main);")
echo "Original main entry: $ORIGINAL_MAIN"

cat > app.asar.contents/frame-fix-wrapper.js << 'EOFFIX'
// Inject frame fix before main app loads
const Module = require('module');
const originalRequire = Module.prototype.require;

console.log('[Frame Fix] Wrapper loaded');

Module.prototype.require = function(id) {
  const module = originalRequire.apply(this, arguments);

  if (id === 'electron') {
    console.log('[Frame Fix] Intercepting electron module');
    const OriginalBrowserWindow = module.BrowserWindow;

    module.BrowserWindow = class BrowserWindowWithFrame extends OriginalBrowserWindow {
      constructor(options) {
        console.log('[Frame Fix] BrowserWindow constructor called');
        if (process.platform === 'linux') {
          options = options || {};
          const originalFrame = options.frame;
          // Force native frame
          options.frame = true;
          // Remove custom titlebar options
          delete options.titleBarStyle;
          delete options.titleBarOverlay;
          console.log(`[Frame Fix] Modified frame from ${originalFrame} to true`);
        }
        super(options);
      }
    };

    // Copy static methods and properties (but NOT prototype, that's already set by extends)
    for (const key of Object.getOwnPropertyNames(OriginalBrowserWindow)) {
      if (key !== 'prototype' && key !== 'length' && key !== 'name') {
        try {
          const descriptor = Object.getOwnPropertyDescriptor(OriginalBrowserWindow, key);
          if (descriptor) {
            Object.defineProperty(module.BrowserWindow, key, descriptor);
          }
        } catch (e) {
          // Ignore errors for non-configurable properties
        }
      }
    }
  }

  return module;
};
EOFFIX

cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
// Load frame fix first
require('./frame-fix-wrapper.js');
// Then load original main
require('./${ORIGINAL_MAIN}');
EOFENTRY

echo "Searching and patching BrowserWindow creation in main process files..."
find app.asar.contents/.vite/build -type f -name "*.js" -exec grep -l "BrowserWindow" {} \; > /tmp/bw-files.txt

while IFS= read -r file; do
    if [ -f "$file" ]; then
        echo "Patching $file for native frames..."
        sed -i 's/frame[[:space:]]*:[[:space:]]*false/frame:true/g' "$file"
        sed -i 's/frame[[:space:]]*:[[:space:]]*!0/frame:true/g' "$file"
        sed -i 's/frame[[:space:]]*:[[:space:]]*!1/frame:true/g' "$file"
        sed -i 's/titleBarStyle[[:space:]]*:[[:space:]]*[^,}]*/titleBarStyle:""/g' "$file"
        echo "Patched $file"
    fi
done < /tmp/bw-files.txt
rm -f /tmp/bw-files.txt

echo "Modifying package.json to load frame fix and add node-pty..."
node -e "
const fs = require('fs');
const pkg = require('./app.asar.contents/package.json');
pkg.originalMain = pkg.main;
pkg.main = 'frame-fix-entry.js';
pkg.optionalDependencies = pkg.optionalDependencies || {};
pkg.optionalDependencies['node-pty'] = '^1.0.0';
fs.writeFileSync('./app.asar.contents/package.json', JSON.stringify(pkg, null, 2));
console.log('Updated package.json: main entry and node-pty dependency');
"

echo "Creating stub native module..."
mkdir -p app.asar.contents/node_modules/@ant/claude-native
cat > app.asar.contents/node_modules/@ant/claude-native/index.js << 'EOF'
// Stub implementation of claude-native for Linux
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);

class AuthRequest {
  static isAvailable() {
    return false;
  }

  async start(url, scheme, windowHandle) {
    throw new Error('AuthRequest not available on Linux');
  }

  cancel() {
    // no-op
  }
}

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey,
  AuthRequest
};
EOF

mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n

cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/

echo "##############################################################"
echo "Removing '!' from 'if (!isWindows && isMainWindow) return null;'"
echo "detection flag to enable title bar"

SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
TARGET_PATTERN="MainWindowPage-*.js"

echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN")
NUM_FILES=$(echo "$TARGET_FILES" | grep -c .)

if [ "$NUM_FILES" -eq 0 ]; then
  echo "Error: No file matching '$TARGET_PATTERN' found within '$SEARCH_BASE'." >&2
  exit 1
elif [ "$NUM_FILES" -gt 1 ]; then
  echo "Error: Expected exactly one file matching '$TARGET_PATTERN' within '$SEARCH_BASE', but found $NUM_FILES." >&2
  echo "Found files:" >&2
  echo "$TARGET_FILES" >&2
  exit 1
else
  TARGET_FILE="$TARGET_FILES"
  echo "Found target file: $TARGET_FILE"
  echo "Attempting to replace patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE..."
  sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$TARGET_FILE"

  if ! grep -q -E 'if\(![a-zA-Z]+[[:space:]]*&&[[:space:]]*[a-zA-Z]+\)' "$TARGET_FILE"; then
    echo "Successfully replaced patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE"
  else
    echo "Error: Failed to replace patterns like 'if(!VAR1 && VAR2)' in $TARGET_FILE. Check file contents." >&2
    exit 1
  fi
fi
echo "##############################################################"

echo "Patching tray menu handler function to prevent concurrent calls and add DBus cleanup delay..."

TRAY_FUNC=$(grep -oP 'on\("menuBarEnabled",\(\)=>\{\K\w+(?=\(\)\})' app.asar.contents/.vite/build/index.js)
if [ -z "$TRAY_FUNC" ]; then
    echo "Failed to extract tray menu function name"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "  Found tray function: $TRAY_FUNC"

TRAY_VAR=$(grep -oP "\}\);let \K\w+(?==null;(?:async )?function ${TRAY_FUNC})" app.asar.contents/.vite/build/index.js)
if [ -z "$TRAY_VAR" ]; then
    echo "Failed to extract tray variable name"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "  Found tray variable: $TRAY_VAR"

sed -i "s/function ${TRAY_FUNC}(){/async function ${TRAY_FUNC}(){/g" app.asar.contents/.vite/build/index.js

FIRST_CONST=$(grep -oP "async function ${TRAY_FUNC}\(\)\{.*?const \K\w+(?==)" app.asar.contents/.vite/build/index.js | head -1)
if [ -z "$FIRST_CONST" ]; then
    echo "Failed to extract first const variable name in function"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "  Found first const variable: $FIRST_CONST"

if ! grep -q "${TRAY_FUNC}._running" app.asar.contents/.vite/build/index.js; then
    sed -i "s/async function ${TRAY_FUNC}(){/async function ${TRAY_FUNC}(){if(${TRAY_FUNC}._running)return;${TRAY_FUNC}._running=true;setTimeout(()=>${TRAY_FUNC}._running=false,500);/g" app.asar.contents/.vite/build/index.js
    echo "  Added mutex guard to ${TRAY_FUNC}()"
else
    echo "  Mutex guard already present in ${TRAY_FUNC}()"
fi

if ! grep -q "await new Promise.*setTimeout" app.asar.contents/.vite/build/index.js | grep -q "${TRAY_VAR}"; then
    sed -i "s/${TRAY_VAR}\&\&(${TRAY_VAR}\.destroy(),${TRAY_VAR}=null)/${TRAY_VAR}\&\&(${TRAY_VAR}.destroy(),${TRAY_VAR}=null,await new Promise(r=>setTimeout(r,50)))/g" app.asar.contents/.vite/build/index.js
    echo "  Added DBus cleanup delay after ${TRAY_VAR}.destroy()"
else
    echo "  DBus cleanup delay already present for ${TRAY_VAR}"
fi

echo "Tray menu handler patched: function=${TRAY_FUNC}, tray_var=${TRAY_VAR}, check_var=${FIRST_CONST}"
echo "##############################################################"

# Fix quick window submit issue by adding blur() call before hide()
if ! grep -q 'e.blur(),e.hide()' app.asar.contents/.vite/build/index.js; then
    sed -i 's/e.hide()/e.blur(),e.hide()/' app.asar.contents/.vite/build/index.js
    echo "Added blur() call to fix quick window submit issue"
fi

# Allow claude code installation
if ! grep -q 'process.arch==="arm64"?"linux-arm64":"linux-x64"' app.asar.contents/.vite/build/index.js; then
    sed -i 's/if(process.platform==="win32")return"win32-x64";/if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return process.arch==="arm64"?"linux-arm64":"linux-x64";/' app.asar.contents/.vite/build/index.js
    echo "Added support for linux claude code binary"
else
    echo "Linux claude code binary support already present"
fi

echo -e "\033[1;36m--- Installing node-pty for terminal support ---\033[0m"
NODE_PTY_BUILD_DIR="$WORK_DIR/node-pty-build"
mkdir -p "$NODE_PTY_BUILD_DIR"
cd "$NODE_PTY_BUILD_DIR"
echo '{"name":"node-pty-build","version":"1.0.0","private":true}' > package.json
echo "Installing node-pty (this will compile native module for Linux)..."
if npm install node-pty 2>&1; then
    echo "node-pty installed successfully"

    if [ -d "$NODE_PTY_BUILD_DIR/node_modules/node-pty" ]; then
        echo "Copying node-pty JavaScript files into app.asar.contents..."
        mkdir -p "$APP_STAGING_DIR/app.asar.contents/node_modules/node-pty"
        cp -r "$NODE_PTY_BUILD_DIR/node_modules/node-pty/lib" "$APP_STAGING_DIR/app.asar.contents/node_modules/node-pty/"
        cp "$NODE_PTY_BUILD_DIR/node_modules/node-pty/package.json" "$APP_STAGING_DIR/app.asar.contents/node_modules/node-pty/"
        echo "node-pty JavaScript files copied"
    else
        echo "Warning: node-pty installation directory not found"
    fi
else
    echo "Warning: Failed to install node-pty - terminal features may not work"
fi
cd "$APP_STAGING_DIR"
echo -e "\033[1;36m--- End node-pty installation ---\033[0m"

"$ASAR_EXEC" pack app.asar.contents app.asar

mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/@ant/claude-native"
cat > "$APP_STAGING_DIR/app.asar.unpacked/node_modules/@ant/claude-native/index.js" << 'EOF'
// Stub implementation of claude-native for Linux
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);

class AuthRequest {
  static isAvailable() {
    return false;
  }

  async start(url, scheme, windowHandle) {
    throw new Error('AuthRequest not available on Linux');
  }

  cancel() {
    // no-op
  }
}

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey,
  AuthRequest
};
EOF

# Copy node-pty native binaries to unpacked directory
if [ -d "$NODE_PTY_BUILD_DIR/node_modules/node-pty/build/Release" ]; then
    echo "Copying node-pty native binaries to unpacked directory..."
    mkdir -p "$APP_STAGING_DIR/app.asar.unpacked/node_modules/node-pty/build/Release"
    cp -r "$NODE_PTY_BUILD_DIR/node_modules/node-pty/build/Release/"* "$APP_STAGING_DIR/app.asar.unpacked/node_modules/node-pty/build/Release/"
    chmod +x "$APP_STAGING_DIR/app.asar.unpacked/node_modules/node-pty/build/Release/"* 2>/dev/null || true
    echo "node-pty native binaries copied"
else
    echo "Warning: node-pty native binaries not found - terminal features may not work"
fi

echo "Copying chosen electron installation to staging area..."
mkdir -p "$APP_STAGING_DIR/node_modules/"
ELECTRON_DIR_NAME=$(basename "$CHOSEN_ELECTRON_MODULE_PATH")
echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/"
STAGED_ELECTRON_BIN="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/electron"
if [ -f "$STAGED_ELECTRON_BIN" ]; then
    echo "Setting executable permission on staged Electron binary: $STAGED_ELECTRON_BIN"
    chmod +x "$STAGED_ELECTRON_BIN"
else
    echo "Warning: Staged Electron binary not found at expected path: $STAGED_ELECTRON_BIN"
fi

# Ensure Electron locale files are available
ELECTRON_RESOURCES_SRC="$CHOSEN_ELECTRON_MODULE_PATH/dist/resources"
ELECTRON_RESOURCES_DEST="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/resources"
if [ -d "$ELECTRON_RESOURCES_SRC" ]; then
    echo "Copying Electron locale resources..."
    mkdir -p "$ELECTRON_RESOURCES_DEST"
    cp -a "$ELECTRON_RESOURCES_SRC"/* "$ELECTRON_RESOURCES_DEST/"
    echo "Electron locale resources copied"
else
    echo "Warning: Electron resources directory not found at $ELECTRON_RESOURCES_SRC"
fi

echo -e "\033[1;36m--- Icon Processing ---\033[0m"
cd "$CLAUDE_EXTRACT_DIR"
EXE_RELATIVE_PATH="lib/net45/claude.exe"
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "Cannot find claude.exe at expected path within extraction dir: $CLAUDE_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "Extracting application icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then
    echo "Failed to extract icons from exe"
    cd "$PROJECT_ROOT" && exit 1
fi

if ! icotool -x claude.ico; then
    echo "Failed to convert icons"
    cd "$PROJECT_ROOT" && exit 1
fi
cp claude_*.png "$WORK_DIR/"
echo "Application icons extracted and copied to $WORK_DIR"

cd "$PROJECT_ROOT"

# Copy tray icon files to Electron resources directory for runtime access
CLAUDE_LOCALE_SRC="$CLAUDE_EXTRACT_DIR/lib/net45/resources"
echo "Copying tray icon files to Electron resources directory..."
if [ -d "$CLAUDE_LOCALE_SRC" ]; then
    cp "$CLAUDE_LOCALE_SRC/Tray"* "$ELECTRON_RESOURCES_DEST/" 2>/dev/null || echo "Warning: No tray icon files found at $CLAUDE_LOCALE_SRC/Tray*"
    echo "Tray icon files copied to Electron resources directory"
else
    echo "Warning: Claude resources directory not found at $CLAUDE_LOCALE_SRC"
fi
echo -e "\033[1;36m--- End Icon Processing ---\033[0m"

# Copy Claude locale JSON files to Electron resources directory where they're expected
echo "Copying Claude locale JSON files to Electron resources directory..."
if [ -d "$CLAUDE_LOCALE_SRC" ]; then
    cp "$CLAUDE_LOCALE_SRC/"*-*.json "$ELECTRON_RESOURCES_DEST/"
    echo "Claude locale JSON files copied to Electron resources directory"
else
    echo "Warning: Claude locale source directory not found at $CLAUDE_LOCALE_SRC"
fi

echo "app.asar processed and staged in $APP_STAGING_DIR"

cd "$PROJECT_ROOT"

# --- Call RPM Packaging Script ---
echo -e "\033[1;36m--- Call Packaging Script ---\033[0m"
echo "Calling RPM packaging script for $ARCHITECTURE..."
chmod +x scripts/build-rpm-package.sh
if ! scripts/build-rpm-package.sh \
    "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
    "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
    echo "RPM packaging script failed."
    exit 1
fi

RPM_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}-${VERSION}-*.${ARCHITECTURE}.rpm" | head -n 1)
echo "RPM Build complete!"
if [ -n "$RPM_FILE" ] && [ -f "$RPM_FILE" ]; then
    FINAL_OUTPUT_PATH="./$(basename "$RPM_FILE")"
    mv "$RPM_FILE" "$FINAL_OUTPUT_PATH"
    echo "Package created at: $FINAL_OUTPUT_PATH"
else
    echo "Warning: Could not determine final .rpm file path from $WORK_DIR for ${ARCHITECTURE}."
    FINAL_OUTPUT_PATH="Not Found"
fi

echo -e "\033[1;36m--- Cleanup ---\033[0m"
echo "Cleaning up intermediate build files in $WORK_DIR..."
if rm -rf "$WORK_DIR"; then
    echo "Cleanup complete ($WORK_DIR removed)."
else
    echo "Warning: Cleanup command (rm -rf $WORK_DIR) failed."
fi

echo "Build process finished."

echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
    echo -e "To install the RPM package, run:"
    echo -e "   \033[1;32msudo dnf install $FINAL_OUTPUT_PATH\033[0m"
    echo -e "   (or 'sudo rpm -i $FINAL_OUTPUT_PATH')"
else
    echo -e "RPM package file not found. Cannot provide installation instructions."
fi
echo -e "\033[1;34m======================\033[0m"

exit 0
