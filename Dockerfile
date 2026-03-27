FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux \
    jq \
    procps \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user with UID 1000
RUN useradd -m -u 1000 -s /bin/bash claude-runner

# Create workspace directory and set ownership
RUN mkdir -p /workspace && chown claude-runner:claude-runner /workspace

USER claude-runner
WORKDIR /workspace
ENV HOME=/home/claude-runner

CMD ["bash"]
