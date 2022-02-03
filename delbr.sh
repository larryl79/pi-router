#!/bin/sh
[ -z "$1" ] && echo "No interface defined as parameter." && exit 1
ip link set dev $1 down
brctl delbr $1
