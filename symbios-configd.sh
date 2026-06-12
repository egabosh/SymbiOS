#!/bin/bash

. /etc/bash/gaboshlib.include

g_lockfile

# look for new configs
inotifywait -m -r -q -e close_write --format '%:e %w%f' /home/docker/SymbiOS/config | 
while read -r change file
do
  g_echo_note "close_write $file"
done

