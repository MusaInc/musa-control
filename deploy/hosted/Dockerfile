FROM node:22-bookworm-slim
ARG CODEX_VERSION=0.170.0
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends tmux git python3 ca-certificates curl procps iproute2 tini \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --omit=dev --no-audit --no-fund @openai/codex@${CODEX_VERSION} \
 && useradd --uid 11001 --create-home --shell /bin/bash hafsa
WORKDIR /opt/musa
COPY server/package*.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY server/src ./src
COPY server/bin ./bin
COPY server/web ./web
COPY deploy/hosted/config.json /etc/musa-hosted.json
COPY deploy/hosted/codex /usr/local/bin/hafsa-codex
COPY deploy/hosted/start.sh /opt/musa/start.sh
RUN chmod 755 /usr/local/bin/hafsa-codex /opt/musa/start.sh
ENV HOME=/home/hafsa CODEX_HOME=/home/hafsa/.codex MUSA_CONTROL_PROFILE=companion MUSA_CONTROL_CONFIG=/etc/musa-hosted.json MUSA_HOSTED=1
USER 11001:11001
WORKDIR /home/hafsa
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/musa/start.sh"]
