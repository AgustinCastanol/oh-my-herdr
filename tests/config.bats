#!/usr/bin/env bats
# Checks for config/base.toml and config/modules/*.toml.
#
# Offline checks need python3 >= 3.11. The real-herdr checks run only when
# herdr is on PATH, always against a throwaway HOME (see herdr_isolated).

setup() {
  load helpers/common
  find_herdr_reference
  load_modules
}

# --- TOML structure -------------------------------------------------------

@test "base.toml is valid TOML" {
  run config_lint parse "$CONFIG_DIR/base.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "at least two opt-in modules exist" {
  [ "${#MODULES[@]}" -ge 2 ]
}

@test "every module documents what it adds and requires and starts with a table" {
  local module
  for module in "${MODULES[@]}"; do
    run config_lint check-module "$module"
    echo "$output"
    [ "$status" -eq 0 ]
  done
}

@test "base.toml composed with each module is valid TOML" {
  local module
  for module in "${MODULES[@]}"; do
    run config_lint parse "$CONFIG_DIR/base.toml" "$module"
    echo "$module: $output"
    [ "$status" -eq 0 ]
  done
}

@test "base.toml composed with all modules is valid TOML" {
  run config_lint parse "$CONFIG_DIR/base.toml" "${MODULES[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}

# --- Keys against the herdr config reference ------------------------------

@test "every key in base and modules exists in the vendored herdr config reference" {
  echo "reference: herdr $HERDR_REFERENCE_VERSION"
  run config_lint check-keys "$HERDR_REFERENCE" "$CONFIG_DIR/base.toml" "${MODULES[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}

# --- The checks themselves catch mistakes ---------------------------------

@test "check-keys reports unknown keys, invalid enums, and shadowed default keys" {
  local bad="$BATS_TEST_TMPDIR/bad.toml"
  cat >"$bad" <<'EOF'
[ui]
not_a_real_key = 1
pane_borders = "sometimes"

[[keys.command]]
key = "prefix+g"
type = "popup"
command = "true"
EOF
  run config_lint check-keys "$HERDR_REFERENCE" "$bad"
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "ui.not_a_real_key: unknown config key"
  assert_output_contains "ui.pane_borders: invalid value 'sometimes'"
  assert_output_contains "'prefix+g' shadows a herdr default keybinding"
}

@test "a module that redefines a table from base.toml does not compose" {
  local bad="$BATS_TEST_TMPDIR/redefines-ui.toml"
  printf '[ui]\nsidebar_width = 30\n' >"$bad"
  run config_lint parse "$CONFIG_DIR/base.toml" "$bad"
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "check-module rejects a module whose first statement is a bare key" {
  local bad="$BATS_TEST_TMPDIR/bare-key.toml"
  printf '# Adds: nothing\n# Requires: nothing\nsidebar_width = 30\n' >"$bad"
  run config_lint check-module "$bad"
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "first statement must be a table header"
}

# --- Real herdr -----------------------------------------------------------

@test "herdr config check accepts base.toml" {
  command -v herdr >/dev/null 2>&1 || skip "herdr is not on PATH"
  run herdr_isolated "$CONFIG_DIR/base.toml" config check
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "config: ok" ]
}

@test "herdr config check accepts base.toml composed with each module and with all modules" {
  command -v herdr >/dev/null 2>&1 || skip "herdr is not on PATH"
  local composed="$BATS_TEST_TMPDIR/composed.toml" module
  for module in "${MODULES[@]}"; do
    config_lint compose "$CONFIG_DIR/base.toml" "$module" >"$composed"
    run herdr_isolated "$composed" config check
    echo "$module: $output"
    [ "$status" -eq 0 ]
    [ "$output" = "config: ok" ]
  done
  config_lint compose "$CONFIG_DIR/base.toml" "${MODULES[@]}" >"$composed"
  run herdr_isolated "$composed" config check
  echo "all modules: $output"
  [ "$status" -eq 0 ]
  [ "$output" = "config: ok" ]
}
