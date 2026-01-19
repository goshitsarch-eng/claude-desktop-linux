#!/bin/bash
set -e

# Arguments passed from the main script
VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3"
APP_STAGING_DIR="$4"
PACKAGE_NAME="$5"
MAINTAINER="$6"
DESCRIPTION="$7"

echo "--- Starting RPM Package Build ---"
echo "Version: $VERSION"
echo "Architecture: $ARCHITECTURE"
echo "Work Directory: $WORK_DIR"
echo "App Staging Directory: $APP_STAGING_DIR"
echo "Package Name: $PACKAGE_NAME"

# Setup RPM build directories
RPM_BUILD_ROOT="$WORK_DIR/rpmbuild"
mkdir -p "$RPM_BUILD_ROOT"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

INSTALL_ROOT="$RPM_BUILD_ROOT/BUILDROOT/${PACKAGE_NAME}-${VERSION}-1.${ARCHITECTURE}"
INSTALL_DIR="$INSTALL_ROOT/usr"

# Clean previous package structure if it exists
rm -rf "$INSTALL_ROOT"

# Create RPM package structure
echo "Creating package structure in $INSTALL_ROOT..."
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

# --- Icon Installation ---
echo "Installing icons..."
declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    icon_source_path="$WORK_DIR/${icon_files[$size]}"
    if [ -f "$icon_source_path" ]; then
        echo "Installing ${size}x${size} icon from $icon_source_path..."
        install -Dm 644 "$icon_source_path" "$icon_dir/claude-desktop.png"
    else
        echo "Warning: Missing ${size}x${size} icon at $icon_source_path"
    fi
done
echo "Icons installed"

# --- Copy Application Files ---
echo "Copying application files from $APP_STAGING_DIR..."

if [ -d "$APP_STAGING_DIR/node_modules" ]; then
    echo "Copying packaged electron..."
    cp -r "$APP_STAGING_DIR/node_modules" "$INSTALL_DIR/lib/$PACKAGE_NAME/"
fi

# Install app.asar in Electron's resources directory where process.resourcesPath points
RESOURCES_DIR="$INSTALL_DIR/lib/$PACKAGE_NAME/node_modules/electron/dist/resources"
mkdir -p "$RESOURCES_DIR"
cp "$APP_STAGING_DIR/app.asar" "$RESOURCES_DIR/"
cp -r "$APP_STAGING_DIR/app.asar.unpacked" "$RESOURCES_DIR/"
echo "Application files copied to Electron resources directory"

# --- Create Desktop Entry ---
echo "Creating desktop entry..."
cat > "$INSTALL_DIR/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=/usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF
echo "Desktop entry created"

# --- Create Launcher Script ---
echo "Creating launcher script..."
cat > "$INSTALL_DIR/bin/claude-desktop" << EOF
#!/bin/bash
LOG_DIR="\${XDG_CACHE_HOME:-\$HOME/.cache}/claude-desktop"
mkdir -p "\$LOG_DIR"
LOG_FILE="\$LOG_DIR/launcher.log"
echo "--- Claude Desktop Launcher Start ---" > "\$LOG_FILE"
echo "Timestamp: \$(date)" >> "\$LOG_FILE"
echo "Arguments: \$@" >> "\$LOG_FILE"

export ELECTRON_FORCE_IS_PACKAGED=true

# Detect if Wayland is likely running
IS_WAYLAND=false
if [ ! -z "\$WAYLAND_DISPLAY" ]; then
  IS_WAYLAND=true
  echo "Wayland detected" >> "\$LOG_FILE"
fi

# Check for display issues
if [ -z "\$DISPLAY" ] && [ -z "\$WAYLAND_DISPLAY" ]; then
  echo "No display detected (TTY session) - cannot start graphical application" >> "\$LOG_FILE"
  echo "Error: Claude Desktop requires a graphical desktop environment." >&2
  echo "Please run from within an X11 or Wayland session, not from a TTY." >&2
  exit 1
fi

# Determine display backend mode
USE_X11_ON_WAYLAND=true
if [ "\$CLAUDE_USE_WAYLAND" = "1" ]; then
  USE_X11_ON_WAYLAND=false
  echo "CLAUDE_USE_WAYLAND=1 set, using native Wayland backend" >> "\$LOG_FILE"
  echo "Note: Global hotkeys (quick window) may not work in native Wayland mode" >> "\$LOG_FILE"
fi

# Determine Electron executable path
ELECTRON_EXEC="electron"
LOCAL_ELECTRON_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/electron"
if [ -f "\$LOCAL_ELECTRON_PATH" ]; then
    ELECTRON_EXEC="\$LOCAL_ELECTRON_PATH"
    echo "Using local Electron: \$ELECTRON_EXEC" >> "\$LOG_FILE"
else
    if command -v electron &> /dev/null; then
        echo "Using global Electron: \$ELECTRON_EXEC" >> "\$LOG_FILE"
    else
        echo "Error: Electron executable not found (checked local \$LOCAL_ELECTRON_PATH and global path)." >> "\$LOG_FILE"
        if command -v zenity &> /dev/null; then
            zenity --error --text="Claude Desktop cannot start because the Electron framework is missing. Please ensure Electron is installed globally or reinstall Claude Desktop."
        elif command -v kdialog &> /dev/null; then
            kdialog --error "Claude Desktop cannot start because the Electron framework is missing. Please ensure Electron is installed globally or reinstall Claude Desktop."
        fi
        exit 1
    fi
fi

APP_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/resources/app.asar"
ELECTRON_ARGS=("\$APP_PATH")

if [ "\$IS_WAYLAND" = true ]; then
  if [ "\$USE_X11_ON_WAYLAND" = true ]; then
    echo "Using X11 backend via XWayland (for global hotkey support)" >> "\$LOG_FILE"
    ELECTRON_ARGS+=("--no-sandbox")
    ELECTRON_ARGS+=("--ozone-platform=x11")
    echo "To use native Wayland instead, set CLAUDE_USE_WAYLAND=1" >> "\$LOG_FILE"
  else
    echo "Using native Wayland backend" >> "\$LOG_FILE"
    ELECTRON_ARGS+=("--no-sandbox")
    ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations")
    ELECTRON_ARGS+=("--ozone-platform=wayland")
    ELECTRON_ARGS+=("--enable-wayland-ime")
    ELECTRON_ARGS+=("--wayland-text-input-version=3")
    echo "Warning: Global hotkeys may not work in native Wayland mode" >> "\$LOG_FILE"
  fi
else
  echo "X11 session detected" >> "\$LOG_FILE"
fi

ELECTRON_ARGS+=("--disable-features=CustomTitlebar")
export ELECTRON_USE_SYSTEM_TITLE_BAR=1

APP_DIR="/usr/lib/$PACKAGE_NAME"
echo "Changing directory to \$APP_DIR" >> "\$LOG_FILE"
cd "\$APP_DIR" || { echo "Failed to cd to \$APP_DIR" >> "\$LOG_FILE"; exit 1; }

FINAL_CMD="\"\$ELECTRON_EXEC\" \"\${ELECTRON_ARGS[@]}\" \"\$@\""
echo "Executing: \$FINAL_CMD" >> "\$LOG_FILE"
"\$ELECTRON_EXEC" "\${ELECTRON_ARGS[@]}" "\$@" >> "\$LOG_FILE" 2>&1
EXIT_CODE=\$?
echo "Electron exited with code: \$EXIT_CODE" >> "\$LOG_FILE"
echo "--- Claude Desktop Launcher End ---" >> "\$LOG_FILE"
exit \$EXIT_CODE
EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"
echo "Launcher script created"

# --- Create RPM Spec File ---
echo "Creating RPM spec file..."
SPEC_FILE="$RPM_BUILD_ROOT/SPECS/${PACKAGE_NAME}.spec"

cat > "$SPEC_FILE" << EOF
Name:           $PACKAGE_NAME
Version:        $VERSION
Release:        1%{?dist}
Summary:        $DESCRIPTION

License:        Proprietary
URL:            https://claude.ai

# Disable automatic dependency scanning (bundled Electron has its own deps)
AutoReq:        no
AutoProv:       no

# Architecture
ExclusiveArch:  $ARCHITECTURE

%description
Claude is an AI assistant from Anthropic.
This package provides the desktop interface for Claude.

Supported on Fedora, RHEL, CentOS, and other RPM-based Linux distributions.

%install
# Copy pre-built files from BUILDROOT
cp -a %{buildroot}/* %{buildroot}/ 2>/dev/null || true

%post
# Update desktop database for MIME types
update-desktop-database /usr/share/applications &> /dev/null || true

# Set correct permissions for chrome-sandbox
SANDBOX_PATH="/usr/lib/$PACKAGE_NAME/node_modules/electron/dist/chrome-sandbox"
if [ -f "\$SANDBOX_PATH" ]; then
    echo "Setting chrome-sandbox permissions..."
    chown root:root "\$SANDBOX_PATH" || echo "Warning: Failed to chown chrome-sandbox"
    chmod 4755 "\$SANDBOX_PATH" || echo "Warning: Failed to chmod chrome-sandbox"
fi

%files
%defattr(-,root,root,-)
/usr/bin/claude-desktop
/usr/lib/$PACKAGE_NAME
/usr/share/applications/claude-desktop.desktop
/usr/share/icons/hicolor/*/apps/claude-desktop.png

%changelog
* $(date "+%a %b %d %Y") $MAINTAINER - $VERSION-1
- Initial RPM package for Claude Desktop
EOF

echo "RPM spec file created at $SPEC_FILE"

# --- Build RPM Package ---
echo "Building RPM package..."

# Build the RPM
rpmbuild --define "_topdir $RPM_BUILD_ROOT" \
         --define "buildroot $INSTALL_ROOT" \
         -bb "$SPEC_FILE"

# Find and move the built RPM
RPM_OUTPUT=$(find "$RPM_BUILD_ROOT/RPMS" -name "*.rpm" | head -n 1)
if [ -n "$RPM_OUTPUT" ] && [ -f "$RPM_OUTPUT" ]; then
    FINAL_RPM="$WORK_DIR/${PACKAGE_NAME}-${VERSION}-1.${ARCHITECTURE}.rpm"
    mv "$RPM_OUTPUT" "$FINAL_RPM"
    echo "RPM package built successfully: $FINAL_RPM"
else
    echo "Failed to find built RPM package"
    exit 1
fi

echo "--- RPM Package Build Finished ---"

exit 0
