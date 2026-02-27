# NanoClaw Agent Container
# Runs Claude Agent SDK in isolated Linux VM with browser automation

FROM node:22-slim

# Install system dependencies for Chromium + VNC (retry loop handles transient CDN failures)
RUN apt-get update && \
    for i in 1 2 3; do \
        apt-get install -y \
            chromium \
            fonts-liberation \
            fonts-noto-color-emoji \
            libgbm1 \
            libnss3 \
            libatk-bridge2.0-0 \
            libgtk-3-0 \
            libx11-xcb1 \
            libxcomposite1 \
            libxdamage1 \
            libxrandr2 \
            libasound2 \
            libpangocairo-1.0-0 \
            libcups2 \
            libdrm2 \
            libxshmfence1 \
            curl \
            git \
            xvfb \
            x11vnc \
            novnc \
            websockify \
        && break || { echo "apt-get attempt $i failed, retrying..."; sleep 10; }; \
    done && \
    rm -rf /var/lib/apt/lists/*

# Set Chromium path for agent-browser
ENV AGENT_BROWSER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

# VNC: use virtual display and run browser in headed mode
ENV DISPLAY=:99
ENV AGENT_BROWSER_HEADED=1

# Install agent-browser and claude-code globally
RUN npm install -g agent-browser @anthropic-ai/claude-code

# Create app directory
WORKDIR /app

# Copy package files first for better caching
COPY agent-runner/package*.json ./

# Install dependencies
RUN npm install

# Copy source code
COPY agent-runner/ ./

# Build TypeScript
RUN npm run build

# Create workspace directories
RUN mkdir -p /workspace/group /workspace/global /workspace/extra /workspace/ipc/messages /workspace/ipc/tasks /workspace/ipc/input

# Copy entrypoint script (starts Xvfb + VNC, then runs the agent)
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Pre-create X11 socket dir with sticky bit so any user can run Xvfb
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# Set ownership to node user (non-root) for writable directories
RUN chown -R node:node /workspace && chmod 777 /home/node

# Switch to non-root user (required for --dangerously-skip-permissions)
USER node

# Set working directory to group workspace
WORKDIR /workspace/group

# Entry point reads JSON from stdin, outputs JSON to stdout
ENTRYPOINT ["/app/entrypoint.sh"]
