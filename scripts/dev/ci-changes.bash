#!/usr/bin/env bash
set -euo pipefail

lint=false
bats=false
runtime=false
molecule=false
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
      tests/molecule/*)
        lint=true; molecule=true ;;
      tests/bats/* | tests/fixtures/*)
        lint=true; bats=true ;;
      scripts/dev/*)
        lint=true; bats=true; packaging=true; molecule=true ;;
      scripts/* | config/*)
        full=true ;;
      rules/README.md)
        rules=true; packaging=true ;;
      rules/*)
        full=true ;;
      ansible/*.md)
        packaging=true ;;
      ansible/*)
        lint=true; molecule=true; packaging=true ;;
      README.md | LICENSE)
        packaging=true ;;
      tests/requirements.txt | .ansible-lint | .yamllint.yml | .editorconfig)
        lint=true ;;
      *.sh | *.bash | *.awk | *.rules | *.conf | *.j2)
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
  molecule=true
  packaging=true
  rules=true
fi

printf 'lint=%s\nbats=%s\nruntime=%s\nmolecule=%s\npackaging=%s\nrules=%s\n' \
  "$lint" "$bats" "$runtime" "$molecule" "$packaging" "$rules"
