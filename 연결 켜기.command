#!/bin/zsh
set -eu
cd -- "${0:A:h}"
'/Applications/Hermes Agent.app/Contents/Resources/agent-payload/venv/bin/python' -B '연결/setup.py' enable
