#!/usr/bin/env bash
# The fast tier now runs through scripts/test.sh (parallel, same check names
# and --only). Run `scripts/test.sh --help` for the full set of options.
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test.sh" "$@"
