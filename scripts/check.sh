#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project"
for tool in shellcheck shfmt bats python3 jq; do command -v "$tool" >/dev/null; done
while IFS= read -r file; do bash -n "$file"; done < <(find lib src scripts tests -type f \( -name '*.sh' -o -name '*.bash' \))
bash -n xray_reality_bootstrap.sh
shellcheck -x lib/*.sh src/*.sh scripts/*.sh tests/*.sh tests/*.bash tests/*.bats tests/integration/*.sh xray_reality_bootstrap.sh
shfmt -d -i 2 -ci lib/*.sh src/*.sh scripts/*.sh tests/*.sh tests/*.bash tests/*.bats tests/integration/*.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
bats tests/*.bats
python3 -m py_compile lib/data.py tests/*.py tests/integration/*.py
for json_file in examples/*.json; do python3 lib/data.py profile "$json_file" >/dev/null; done
temporary=$(mktemp)
trap 'rm -f -- "$temporary"' EXIT
bash scripts/build.sh "$temporary"
cmp "$temporary" xray_reality_bootstrap.sh
python3 tests/check_docs.py
