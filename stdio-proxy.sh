#!/bin/sh

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 COMMAND [ARG ...]" >&2
    exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" || exit 1

RUN_ID=$(cat /proc/sys/kernel/random/uuid) || exit 1

{
    printf 'Run ID: %s\n' "$RUN_ID"
    printf 'Started: %s\n' "$(date -Is)"
    printf 'Working directory: %s\n' "$PWD"
    printf 'Argument count: %s\n' "$#"

    i=0
    for arg do
        i=$((i + 1))
        printf 'Argument %s: <%s>\n' "$i" "$arg"
    done
} > "$LOG_DIR/$RUN_ID.args.log"

COMMAND=
for arg do
    escaped=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
    COMMAND="$COMMAND '$escaped'"
done

exec socat -v \
    STDIO \
    SYSTEM:"exec $COMMAND",pipes \
    2> "$LOG_DIR/$RUN_ID.traffic.log"
