#!/bin/bash
set -e

# Start virtual display (1280x800, 24-bit color)
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &

# Start VNC server on :99
x11vnc -display :99 -nopw -forever -shared -quiet -bg 2>/dev/null || true

# Start noVNC web viewer (http://localhost:6080/vnc.html)
websockify --web /usr/share/novnc/ --wrap-mode=ignore 6080 localhost:5900 &

# Run agent
cd /app && npx tsc --outDir /tmp/dist 2>&1 >&2
ln -s /app/node_modules /tmp/dist/node_modules
chmod -R a-w /tmp/dist
cat > /tmp/input.json
node /tmp/dist/index.js < /tmp/input.json
