#!/usr/bin/env bash
# Data travels as bounded base64 records; user paths and arguments never become shell code.
set -uo pipefail
mode=${1:-}
shift || exit 2
encode() { printf '%s' "$1" | base64 -w0; }
case "$mode" in
  scan)
    shopt -s nullglob dotglob
    for directory in "$@"; do
      if [[ ! -d $directory || ! -r $directory ]]; then
        printf 'E:%s\n' "$(encode "Cannot read script directory: $directory")"
        continue
      fi
      for file in "$directory"/*; do
        [[ -f $file && -x $file && ${file##*/} != *.template.* ]] || continue
        size=$(stat -Lc %s -- "$file") || continue
        ((size > 0 && size <= 2097152)) || continue
        # Header records alone are needed by the parser, not a copy of the whole script.
        header=$(LC_ALL=C grep -aiE '^(#|REM|::|//)[[:space:]]*@raycast\.[[:alnum:]_]+[[:space:]]+' -- "$file")
        [[ -n $header ]] || continue
        printf 'S:%s:%s\n' "$(encode "$file")" "$(encode "$header")"
      done
    done
    ;;
  environment)
    "$1" -lc 'env -0' | while IFS= read -r -d '' entry; do
      printf 'E:%s\n' "$(encode "$entry")"
    done
    ;;
  create)
    directory=$1 file=$2 body=$3
    [[ $file != */* && $file != . && $file != .. && -n $file ]] || exit 2
    mkdir -p -- "$directory" || exit
    # noclobber also rejects symlinks and never overwrites an existing script.
    (set -o noclobber; umask 077; printf '%s' "$body" > "$directory/$file") || exit
    chmod 700 -- "$directory/$file" || exit
    ;;
  run)
    directory=$1
    shift
    cd -- "$directory" || exit
    temporary=$(mktemp -d) || exit
    child= out= err=
    cleanup() {
      trap '' TERM INT HUP
      if [[ -n $child ]]; then
        kill -TERM -- "-$child" 2>/dev/null || :
        kill -KILL -- "-$child" 2>/dev/null || :
      fi
      [[ -z $out ]] || kill "$out" 2>/dev/null || :
      [[ -z $err ]] || kill "$err" 2>/dev/null || :
      rm -rf -- "$temporary"
    }
    trap 'cleanup; exit 130' TERM INT HUP
    trap cleanup EXIT
    mkfifo -- "$temporary/out" "$temporary/err" || exit
    stream() {
      local tag=$1 chunk status
      while :; do
        chunk=
        IFS= read -r -n 256 chunk
        status=$?
        if ((status != 0)) && [[ -z $chunk ]]; then break; fi
        # read -n keeps memory bounded even for an infinite line, while emitting
        # short newline-terminated output immediately rather than buffering it.
        if ((${#chunk} < 256)); then chunk+=$'\n'; fi
        printf '%s:%s\n' "$tag" "$(encode "$chunk")"
        ((status == 0)) || break
      done
    }
    stream O < "$temporary/out" & out=$!
    stream E < "$temporary/err" & err=$!
    # A private session lets cancellation kill the script and all its children.
    # setsid execs the executable file: its arguments are never shell-expanded.
    setsid -- "$@" < /dev/null > "$temporary/out" 2> "$temporary/err" & child=$!
    wait "$child"
    status=$?
    kill -KILL -- "-$child" 2>/dev/null || :
    child=
    wait "$out" "$err" 2>/dev/null || :
    out= err=
    exit "$status"
    ;;
  *) printf 'Unknown script helper operation\n' >&2; exit 2 ;;
esac
