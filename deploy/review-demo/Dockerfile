# Sandboxed demo computer for App Review / TestFlight reviewers: the
# companion plus a sample project, running as an unprivileged user inside a
# container with no access to the host's files.
FROM node:22-bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends tmux git python3 ca-certificates curl procps && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash reviewer
COPY musa-companion.tgz /tmp/c.tgz
USER reviewer
WORKDIR /home/reviewer
RUN mkdir -p in && tar xzf /tmp/c.tgz -C in && MUSA_COMPANION_NO_SERVICE=1 sh in/musa-companion/bin/install.sh >/dev/null 2>&1 || true; pkill -f musa-companion || true \
 && mkdir -p projects/hello-web && cd projects/hello-web && git init -q -b main \
 && printf '<!doctype html><title>Hello</title><h1>Hello from the demo computer</h1>\n' > index.html \
 && printf '# Hello web\nA tiny sample site for trying Musa Control.\n' > README.md \
 && git -c user.email=demo@example.com -c user.name=Demo add -A && git -c user.email=demo@example.com -c user.name=Demo commit -qm "Sample site"
ENV MUSA_CONTROL_PROFILE=companion PATH=/home/reviewer/.local/bin:$PATH
CMD ["sh", "-c", "exec node --no-warnings /home/reviewer/.musa-companion/app/bin/musa-companion.js start"]
