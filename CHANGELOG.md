# Changelog

Versions here are assigned in commit order: minor is a plain integer
counter (0.1 for the first commit, 0.2 for the second, and so on); major
is only ever advanced manually. Newest at top.

## 0.10 
- Add ttyd browser-based terminal to the image (LAN-only, password-gated via TTYD_CREDENTIAL; starts only if a credential is set).
- Add ttyd presence check to the container smoke test.

## 0.9

- Fixed graceful shutdown: `entrypoint.sh` previously ended with a
  synchronous `tail -f /dev/null` as PID 1, which does not receive a
  handler for SIGTERM/SIGINT, so `docker stop` took the full kill timeout
  (~10s). Replaced it with an explicit trap plus a backgrounded
  sleep-loop/`wait`, so the container now stops in well under a second
  while preserving all existing startup behaviour (GH_TOKEN/git/gh setup,
  tmux session creation, ready message).

## 0.8

- Configure GitHub auth in entrypoint.sh

## 0.7

- Add GitHub CLI installation to Dockerfile

## 0.6

- Refactor Dockerfile for &NBSP errors

## 0.5

- Add GitHub Actions workflow for building Docker image

## 0.4

- Initialize tmux session for agent in entrypoint.sh

## 0.3

- Add shebang and set options in entrypoint.sh

## 0.2

- Add Dockerfile for Node.js environment setup

## 0.1

- Initial commit
