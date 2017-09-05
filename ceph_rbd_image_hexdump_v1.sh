#!/bin/bash

dev_name='/dev/loop0'
line_bytes='128'


if [[ "$#" -eq "1" ]]; then
    offset=$1
    hexdump -s ${offset} -v -e '/${line_bytes} "%010_ad |"' -e '${line_bytes}/1 "%_p" "|\n"' ${dev_name} | less
else
    hexdump -v -e '/${line_bytes} "%010_ad |"' -e '${line_bytes}/1 "%_p" "|\n"' ${dev_name} | less
fi

