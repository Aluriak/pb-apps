#!/bin/sh
LOG=/mnt/ext1/app-manager-log.txt
BIN="/mnt/ext1/applications/App Manager.bin"
echo "== run" >> $LOG
"$BIN" >> $LOG 2>&1
echo "exit code: $?" >> $LOG
