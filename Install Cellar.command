#!/bin/bash
# Double-click to build Cellar and install it to ~/Applications.
cd "$(dirname "$0")" || exit 1
echo "Building Cellar… this takes a minute or two."
echo
if /bin/bash ./build.sh --install; then
  echo
  echo "Installed. Opening Cellar…"
  open "$HOME/Applications/Cellar.app"
else
  echo
  echo "The build failed. Select everything in this window, copy it, and paste it to Claude."
fi
echo
read -n 1 -s -r -p "Press any key to close this window."
