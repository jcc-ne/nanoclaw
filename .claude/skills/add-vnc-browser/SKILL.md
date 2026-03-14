---
name: add-vnc-browser
description: Add headed browser with noVNC viewer so you can watch the agent's browser activity in real time. Runs Chromium in a virtual display (Xvfb) inside the container and exposes it via a noVNC web viewer on the host. Triggers on "vnc", "watch browser", "headed browser", "see browser", "add vnc".
---

# Add VNC Browser Viewer

Installs a headed Chromium + noVNC stack into the agent container so you can watch the agent browse in real time. Each container gets a dynamically assigned host port (starting at 6080); the URL is logged when the container starts.

**Scope:** local desktop installs only. The noVNC URL is `http://localhost:<port>/vnc.html` — only meaningful when NanoClaw runs on the same machine you're sitting at.

## What this installs

1. **`container/Dockerfile`** — adds Xvfb, x11vnc, novnc, websockify; sets `DISPLAY=:99` and `AGENT_BROWSER_HEADED=1`; switches to an external `entrypoint.sh`
2. **`container/entrypoint.sh`** — starts Xvfb + VNC + noVNC before running the agent
3. **`src/config.ts`** — adds `CONTAINER_MEMORY` export (default `2g`)
4. **`src/container-runner.ts`** — TOCTOU-safe port allocator; passes `--memory` and `-p <hostPort>:6080` to the container runtime

---

## Step 1 — Modify `container/Dockerfile`

Replace the existing `RUN apt-get update && apt-get install -y ...` block and everything below it up to (but not including) the `USER node` line with the following. The packages already present (chromium, fonts-*, lib*) must be kept; this just adds the VNC packages and restructures the entrypoint.

**Replace** the apt-get install block:

```dockerfile
# Install system dependencies for Chromium + VNC (retry loop handles transient CDN failures)
RUN apt-get update && \
    for i in 1 2 3; do \
        apt-get install -y \
            chromium \
            fonts-liberation \
            fonts-noto-cjk \
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
```

**Replace** the inline `RUN printf ... entrypoint.sh` line with:

```dockerfile
# VNC: use virtual display and run browser in headed mode
ENV DISPLAY=:99
ENV AGENT_BROWSER_HEADED=1

# Copy entrypoint script (starts Xvfb + VNC, then runs the agent)
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Pre-create X11 socket dir with sticky bit so any user can run Xvfb
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
```

---

## Step 2 — Create `container/entrypoint.sh`

Create this file (it does not exist upstream):

```bash
#!/bin/bash
set -e

# Start virtual display (1280x800, 24-bit color)
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &

# Start VNC server on display :99
x11vnc -display :99 -nopw -forever -shared -quiet -bg 2>/dev/null || true

# Start noVNC web viewer (http://localhost:6080/vnc.html)
websockify --web /usr/share/novnc/ --wrap-mode=ignore 6080 localhost:5900 &

# Run agent
cd /app && npx tsc --outDir /tmp/dist 2>&1 >&2
ln -s /app/node_modules /tmp/dist/node_modules
chmod -R a-w /tmp/dist
cat > /tmp/input.json
node /tmp/dist/index.js < /tmp/input.json
```

---

## Step 3 — Modify `src/config.ts`

Add after the existing `CONTAINER_IMAGE` export:

```typescript
export const CONTAINER_MEMORY =
  process.env.CONTAINER_MEMORY || '2g';
```

---

## Step 4 — Modify `src/container-runner.ts`

### 4a. Add `net` import

Add `net` to the existing Node built-in imports at the top of the file:

```typescript
import net from 'net';
```

### 4b. Add `CONTAINER_MEMORY` to the config import

In the import from `'./config.js'`, add `CONTAINER_MEMORY` to the destructured list.

### 4c. Add port allocator (insert before `buildContainerArgs`)

```typescript
// Tracks ports currently reserved by running containers in this process.
// Prevents TOCTOU races where two containers both pass the isPortFree check
// before either has actually bound the port via the container runtime.
const reservedNoVncPorts = new Set<number>();

function isPortFree(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(false));
    server.once('listening', () => server.close(() => resolve(true)));
    // Bind on 0.0.0.0 explicitly to detect IPv4 ports held by Docker.
    // Without this, Node.js binds to :: (IPv6) which on macOS does NOT conflict
    // with 0.0.0.0:PORT (IPv4), causing false positives — isPortFree returns true
    // even when Docker already has the port allocated.
    server.listen(port, '0.0.0.0');
  });
}

async function reserveNoVncPort(start = 6080): Promise<number> {
  for (let port = start; port < start + 100; port++) {
    if (reservedNoVncPorts.has(port)) continue;
    // Optimistically reserve before the async check so concurrent callers
    // see it as taken and skip to the next port (prevents TOCTOU race).
    reservedNoVncPorts.add(port);
    if (await isPortFree(port)) {
      return port;
    }
    // Port is actually in use — un-reserve and try the next one.
    reservedNoVncPorts.delete(port);
  }
  throw new Error(`No free noVNC port found in range ${start}–${start + 99}`);
}
```

### 4d. Update `buildContainerArgs` signature and body

Change the signature from:
```typescript
function buildContainerArgs(
  mounts: VolumeMount[],
  containerName: string,
): string[]
```
to:
```typescript
function buildContainerArgs(
  mounts: VolumeMount[],
  containerName: string,
  noVncPort: number,
): string[]
```

At the start of the function body (right after `const args = [...]`), add:

```typescript
  // Memory limit (overridable via CONTAINER_MEMORY env var)
  args.push('--memory', CONTAINER_MEMORY);

  // Expose noVNC web viewer on a dynamically-assigned host port starting at 6080
  // (avoids conflicts when multiple containers run concurrently)
  args.push('-p', `${noVncPort}:6080`);
```

### 4e. Update `runContainerAgent` to allocate a port

In `runContainerAgent`, replace:
```typescript
  const containerArgs = buildContainerArgs(mounts, containerName);
```
with:
```typescript
  const noVncPort = await reserveNoVncPort(6080);
  const containerArgs = buildContainerArgs(mounts, containerName, noVncPort);
```

Add `noVncUrl` to the existing `logger.info` / `logger.debug` call that logs container startup so the port is visible in logs:
```typescript
  noVncUrl: `http://localhost:${noVncPort}/vnc.html`,
```

Release the port when the container exits. Find the two places where the container process ends (success and error/timeout paths) and add:
```typescript
  reservedNoVncPorts.delete(noVncPort);
```

---

## Step 5 — Build and verify

```bash
./container/build.sh
npm run build
```

If the build cache causes stale files (symptoms: entrypoint.sh changes not reflected), prune the builder first:

```bash
docker buildx prune -f   # Docker
# or for Apple Container: the image cache is per-build, no prune needed
./container/build.sh
```

---

## Usage

When the service starts a container, the log line `Spawning container agent` includes `noVncUrl`. Check logs:

```bash
# macOS
tail -f logs/nanoclaw.log | grep noVncUrl

# Linux
journalctl --user -u nanoclaw -f | grep noVncUrl
```

Open the URL in a browser to watch the agent's browser activity live.

---

## Removal

1. Revert `container/Dockerfile` apt-get block to the original single `RUN apt-get install -y ...` form (remove xvfb, x11vnc, novnc, websockify); remove the `ENV DISPLAY`, `ENV AGENT_BROWSER_HEADED`, `COPY entrypoint.sh`, `RUN chmod`, and `RUN mkdir /tmp/.X11-unix` lines; restore the inline `RUN printf ...` entrypoint
2. Delete `container/entrypoint.sh`
3. Remove `CONTAINER_MEMORY` from `src/config.ts`
4. Remove `net` import, `reservedNoVncPorts`, `isPortFree`, `reserveNoVncPort` from `src/container-runner.ts`; revert `buildContainerArgs` signature and body; revert `runContainerAgent` to `buildContainerArgs(mounts, containerName)`
5. Rebuild: `./container/build.sh && npm run build`
