#!/usr/bin/env bash
# Installs dependencies into lib/ (pinned versions, not as git submodules)
set -euo pipefail
forge install foundry-rs/forge-std@v1.9.4 OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git
