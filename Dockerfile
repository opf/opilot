FROM node:20-slim

RUN apt-get update && apt-get install -y \
      bash curl jq git chromium \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN git config --global --add safe.directory '*' \
 && git config --global core.crossFS true

ENV CHROME_BIN=/usr/bin/chromium
ENV CHROMIUM_FLAGS="--no-sandbox --headless --disable-gpu"
