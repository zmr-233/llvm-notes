#!/usr/bin/env bash
# 依次跑全部例子。成功的例子只打印一行；失败立即停下并打印完整输出。
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
for d in "$here"/[0-9][0-9]-*/; do
  name=$(basename "$d")
  if out=$(bash "$d/run.sh" 2>&1); then
    echo "ok    $name"
  else
    echo "FAIL  $name"; echo "$out"; rc=1; break
  fi
done
exit $rc
