#!/usr/bin/env bash

set -e

zig build

for f in examples/basics/*; do
	if [ -f "$f" ]; then
		echo -e "\n\033[1;34mExecuting: $f\033[0m\n"
		./zig-out/bin/TAPE_lang run "$f"
		echo -e "\n"
	fi
done
