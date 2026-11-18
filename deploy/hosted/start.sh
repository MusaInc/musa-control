#!/bin/sh
set -eu
umask 077
mkdir -p /home/hafsa/projects /home/hafsa/.codex
# Auth config is independent of the owner's account and is never copied in.
if [ ! -f /home/hafsa/.codex/config.toml ]; then
  printf 'forced_login_method = "chatgpt"\ncli_auth_credentials_store = "file"\n' > /home/hafsa/.codex/config.toml
fi
exec node --no-warnings /opt/musa/src/main.js
