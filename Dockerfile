FROM node:22-bookworm-slim

 ENV DEBIAN_FRONTEND=noninteractive

 RUN apt-get update && apt-get install -y --no-install-recommends \
       tmux git curl ca-certificates python3 openssh-client jq \
       docker.io \
     && rm -rf /var/lib/apt/lists/*

 RUN npm install -g @anthropic-ai/claude-code claude-auto-retry

 COPY entrypoint.sh /usr/local/bin/entrypoint.sh
 RUN chmod +x /usr/local/bin/entrypoint.sh

 WORKDIR /projects

 ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
