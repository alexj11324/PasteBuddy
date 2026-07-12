#!/bin/zsh
set -euo pipefail

exec "${0:A:h}/monitor_card_switch_latency.py" --max-total-ms 100 --sample-count 10
