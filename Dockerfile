# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build
# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*
# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"
RUN corepack enable
WORKDIR /openclaw
# Pin to a known ref (tag/branch). If it doesn't exist, fall back to main.
ARG OPENCLAW_GIT_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .
# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done
RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build
# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production
# ============================================
# SYSTEM PACKAGES & CLI TOOLS
# ============================================
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    vim \
    htop \
    jq \
    tree \
    less \
    tmux \
    unzip \
    gnupg \
    apt-transport-https \
    python3 \
    python3-pip \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*
# ============================================
# 1PASSWORD CLI
# ============================================
RUN curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main" | \
    tee /etc/apt/sources.list.d/1password.list && \
    apt-get update && apt-get install -y 1password-cli && \
    rm -rf /var/lib/apt/lists/*
# ============================================
# GOOGLE CLOUD CLI (gcloud)
# ============================================
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
    tee /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl -sS https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    apt-get update && apt-get install -y google-cloud-cli && \
    rm -rf /var/lib/apt/lists/*
# ============================================
# UV (Fast Python package manager)
# ============================================
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"
# ============================================
# PYTHON PACKAGES (global)
# ============================================
RUN pip3 install --no-cache-dir --break-system-packages \
    boto3 \
    botocore \
    requests \
    google-api-python-client \
    google-auth-oauthlib \
    google-auth \
    google-generativeai \
    ruff
# ============================================
# CLOUDFLARE CLI (wrangler)
# ============================================
RUN npm install -g wrangler
# ============================================
# CLAUDE CODE (Anthropic CLI)
# ============================================
RUN npm install -g @anthropic-ai/claude-code
# ============================================
# GEMINI CLI (Google AI CLI)
# ============================================
RUN npm install -g @google/gemini-cli || echo "Gemini CLI not available via npm, using Python SDK"
# ============================================
# OPENCODE (Terminal AI tool)
# ============================================
RUN OPENCODE_VERSION=$(curl -s https://api.github.com/repos/opencode-ai/opencode/releases/latest | jq -r .tag_name) && \
    curl -LO "https://github.com/opencode-ai/opencode/releases/download/${OPENCODE_VERSION}/opencode_Linux_x86_64.tar.gz" && \
    tar -xzf opencode_Linux_x86_64.tar.gz -C /usr/local/bin opencode && \
    rm opencode_Linux_x86_64.tar.gz && \
    chmod +x /usr/local/bin/opencode
# ============================================
# CUSTOM .bashrc
# ============================================
RUN echo '' >> /root/.bashrc && \
    echo '# Custom aliases' >> /root/.bashrc && \
    echo 'alias ll="ls -la"' >> /root/.bashrc && \
    echo 'alias la="ls -A"' >> /root/.bashrc && \
    echo 'alias l="ls -CF"' >> /root/.bashrc && \
    echo 'alias gs="git status"' >> /root/.bashrc && \
    echo 'alias gd="git diff"' >> /root/.bashrc && \
    echo 'alias gl="git log --oneline -10"' >> /root/.bashrc && \
    echo '' >> /root/.bashrc && \
    echo '# Environment' >> /root/.bashrc && \
    echo 'export EDITOR=vim' >> /root/.bashrc && \
    echo 'export PYTHONDONTWRITEBYTECODE=1' >> /root/.bashrc && \
    echo 'export PATH="/root/.local/bin:$PATH"' >> /root/.bashrc
# ============================================
# APP SETUP (original template code)
# ============================================
WORKDIR /app
# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw
# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw
COPY src ./src
# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
CMD ["node", "src/server.js"]