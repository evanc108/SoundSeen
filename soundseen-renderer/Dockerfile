# Image for Modal GPU workers. Bundles Node 22, Playwright + Chromium,
# FFmpeg, and the renderer build output. Modal mounts the backend's
# audio + spec from Supabase at runtime.

FROM mcr.microsoft.com/playwright:v1.49.0-jammy

# FFmpeg for video encode + audio mux.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# App layout: /app holds the renderer build, package.json, node_modules.
WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund

COPY tsconfig.json ./
COPY src ./src
RUN npx tsc -p . && \
    npx esbuild src/page/runtime.ts --bundle --format=esm --outfile=dist/page/runtime.js && \
    cp src/page/host.html dist/page/host.html

# Modal will invoke the Python wrapper, which shells out to Node.
COPY modal_app.py ./

CMD ["node", "dist/render.js"]
