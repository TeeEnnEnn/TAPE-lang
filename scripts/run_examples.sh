#!/usr/bin/env bash

set -e

while getopts "sl" opt; do
    echo $opt;
    case ${opt} in
        s)
            gc_stress=1
            ;;
        l)
            gc_log=1
            ;;
        \?)
            echo "Invalid option: -$OPTARG">&2
            exit 1
            ;;
    esac
done

if [[ $gc_stress -eq 1 ]]  && [[ $gc_log -eq 1 ]]; then
    zig build -Dstress_gc=true -Dlog_gc=true
elif [[ $gc_stress -eq 1 ]]; then
    zig build -Dstress_gc=true
elif [[ $gc_log -eq 1 ]]; then
   zig build -Dlog_gc=true
else
    zig build
fi

for f in examples/basics/*; do
	if [ -f "$f" ]; then
		echo -e "\n\033[1;34mExecuting: $f\033[0m\n"
		./zig-out/bin/TAPE_lang run "$f"
		echo -e "\n"
	fi
done

for f in examples/multimodule/main.tape examples/taskflow/main.tape; do
	if [ -f "$f" ]; then
		echo -e "\n\033[1;34mExecuting: $f\033[0m\n"
		./zig-out/bin/TAPE_lang run "$f"
		echo -e "\n"
	fi
done
