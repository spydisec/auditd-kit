#!/usr/bin/env bats

repo=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)

route() {
  printf '%s\0' "$@" | bash "$repo/scripts/dev/ci-changes.bash"
}

@test "README selects packaging but no runtime tests" {
  run route README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"packaging=true"* ]]
  [[ "$output" == *"runtime=false"* ]]
  [[ "$output" == *"bats=false"* ]]
}

@test "ordinary Markdown skips test groups" {
  run route docs/adr/example.md CONTRIBUTING.md
  [ "$status" -eq 0 ]
  [[ "$output" != *"=true"* ]]
}

@test "rules README selects its content test" {
  run route rules/README.md
  [[ "$output" == *"rules=true"* ]]
  [[ "$output" == *"packaging=true"* ]]
  [[ "$output" == *"runtime=false"* ]]
}

@test "runtime paths and code extensions outside known directories select all tests" {
  for path in scripts/lib/common.sh config/auditd/small.conf rules/10-minimal.rules \
    new/tool.sh new/helper.bash new/parser.awk new/profile.rules new/audit.conf new/report.j2 \
    new/code.py docs/unrecognized.data; do
    run route "$path"
    [ "$status" -eq 0 ]
    [[ "$output" != *"=false"* ]]
  done
}

@test "Ansible changes select lint Molecule and packaging without host tests" {
  run route ansible/playbooks/templates/stats.csv.j2
  [[ "$output" == *"lint=true"* ]]
  [[ "$output" == *"molecule=true"* ]]
  [[ "$output" == *"packaging=true"* ]]
  [[ "$output" == *"runtime=false"* ]]
}

@test "test inputs select their owning groups" {
  run route tests/fixtures/audit-logs/basic/audit.log
  [[ "$output" == *"bats=true"* ]]
  [[ "$output" == *"runtime=false"* ]]
  run route tests/molecule/survey/verify.yml
  [[ "$output" == *"molecule=true"* ]]
  [[ "$output" == *"runtime=false"* ]]
  run route tests/ci/real-kernel.sh
  [[ "$output" == *"runtime=true"* ]]
}

@test "workflow and routing changes select all tests" {
  for path in .github/workflows/lint.yml scripts/dev/ci-changes.bash tests/bats/ci-changes.bats; do
    run route "$path"
    [[ "$output" != *"=false"* ]]
  done
}

@test "YAML extensions select lint outside known directories" {
  run route new/settings.yaml .github/ISSUE_TEMPLATE/bug.yml
  [[ "$output" == *"lint=true"* ]]
}

@test "mixed changes include every selected group regardless of order" {
  run route README.md tests/molecule/survey/verify.yml tests/bats/stats.bats
  first=$output
  run route tests/bats/stats.bats tests/molecule/survey/verify.yml README.md
  [ "$output" = "$first" ]
  [[ "$output" == *"bats=true"* ]]
  [[ "$output" == *"molecule=true"* ]]
  [[ "$output" == *"packaging=true"* ]]
}

@test "NUL input preserves spaces and newlines in paths" {
  run route "docs/a file.md" $'docs/a\nfile.md'
  [[ "$output" != *"=true"* ]]
  run route $'docs/a.md\ncode.sh'
  [[ "$output" != *"=false"* ]]
}

@test "renamed and deleted paths are classified without opening files" {
  run route scripts/deleted.sh docs/renamed.md
  [[ "$output" != *"=false"* ]]
}

@test "force all selects all tests and unexpected arguments fail" {
  run bash "$repo/scripts/dev/ci-changes.bash" --all
  [ "$status" -eq 0 ]
  [[ "$output" != *"=false"* ]]
  run bash "$repo/scripts/dev/ci-changes.bash" --unknown
  [ "$status" -ne 0 ]
}
