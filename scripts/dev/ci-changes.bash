#!/usr/bin/env bash
set -euo pipefail

lint=false
bats=false
runtime=false
packaging=false
rules=false
full=false

if [[ ${1:-} == --all ]]; then
  full=true
elif [[ $# != 0 ]]; then
  exit 1
else
  while IFS= read -r -d '' path; do
    case "$path" in
      .github/workflows/* | scripts/dev/ci-changes.bash | tests/bats/ci-changes.bats)
        full=true ;;
      tests/ci/real-kernel.sh | tests/ci/container-install.sh)
        lint=true; runtime=true ;;
      tests/bats/* | tests/fixtures/*)
        lint=true; bats=true ;;
      scripts/dev/*)
        lint=true; bats=true; packaging=true ;;
      scripts/* | config/*)
        full=true ;;
      rules/README.md)
        rules=true; packaging=true ;;
      rules/*)
        full=true ;;
      README.md | LICENSE)
        packaging=true ;;
      tests/requirements.txt | .yamllint.yml | .editorconfig)
        lint=true ;;
      *.sh | *.bash | *.awk | *.rules | *.conf)
        full=true ;;
      *.yml | *.yaml)
        lint=true ;;
      *.md | .github/CODEOWNERS)
        ;;
      *)
        full=true ;;
    esac
  done
fi

if [[ $full == true ]]; then
  lint=true
  bats=true
  runtime=true
  packaging=true
  rules=true
fi

printf 'lint=%s\nbats=%s\nruntime=%s\npackaging=%s\nrules=%s\n' \
  "$lint" "$bats" "$runtime" "$packaging" "$rules"
