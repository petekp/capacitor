#!/bin/bash
pkill -x ClaudeHUD 2>/dev/null
sleep 0.5
swift run 2>&1 &
