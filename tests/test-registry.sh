#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/registry.sh
source "$ROOT_DIR/lib/registry.sh"

ph_registry_find ai-dev-lxc
[[ $HELPER_NAME == 'AI Development LXC' ]]
[[ $HELPER_CATEGORY == development ]]
[[ $HELPER_VERSION == 2.2.2 ]]
[[ $PH_HELPER_DIR == "$ROOT_DIR/helpers/ai-dev-lxc" ]]
[[ -x $PH_HELPER_DIR/$HELPER_ENTRYPOINT ]]

count=$(ph_registry_list_tsv | wc -l)
((count >= 1))
printf 'Registry test passed with %d helper(s).\n' "$count"
