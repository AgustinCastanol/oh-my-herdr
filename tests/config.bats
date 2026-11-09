#!/usr/bin/env bats
# Checks for config/base.toml, config/themes/*.toml, and config/modules/*.toml.
#
# install.sh composes base, one theme, then modules; these tests compose them
# the same way. Offline checks need python3 >= 3.11. The real-herdr checks
# run only when herdr is on PATH, always against a throwaway HOME (see
# herdr_isolated).

setup() {
  load helpers/common
  find_herdr_reference
  load_modules
  load_themes
}

# --- Layout ---------------------------------------------------------------

@test "base.toml is valid TOML" {
  run config_lint parse "$CONFIG_DIR/base.toml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "at least two opt-in modules exist" {
  [ "${#MODULES[@]}" -ge 2 ]
}

@test "at least two themes exist, including the installer's default theme" {
  [ "${#THEMES[@]}" -ge 2 ]
  local default
  default="$(default_theme)"
  [ -n "$default" ]
  [ -f "$THEMES_DIR/$default.toml" ]
}

@test "every module and theme documents what it adds and requires and starts with a table" {
  local file
  for file in "${MODULES[@]}" "${THEMES[@]}"; do
    run config_lint check-module "$file"
    echo "$output"
    [ "$status" -eq 0 ]
  done
}

# --- Composition ----------------------------------------------------------

@test "base.toml composed with each theme and each module is valid TOML" {
  local theme module
  for theme in "${THEMES[@]}"; do
    for module in "${MODULES[@]}"; do
      run config_lint parse "$CONFIG_DIR/base.toml" "$theme" "$module"
      echo "$theme + $module: $output"
      [ "$status" -eq 0 ]
    done
  done
}

@test "base.toml composed with each theme and all modules is valid TOML" {
  local theme
  for theme in "${THEMES[@]}"; do
    run config_lint parse "$CONFIG_DIR/base.toml" "$theme" "${MODULES[@]}"
    echo "$theme: $output"
    [ "$status" -eq 0 ]
  done
}

# --- Keys against the herdr config reference ------------------------------

@test "every key in base, each theme, and all modules exists in the vendored herdr config reference" {
  echo "reference: herdr $HERDR_REFERENCE_VERSION"
  local theme
  for theme in "${THEMES[@]}"; do
    run config_lint check-keys "$HERDR_REFERENCE" "$CONFIG_DIR/base.toml" "$theme" "${MODULES[@]}"
    echo "$theme: $output"
    [ "$status" -eq 0 ]
  done
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
  assert_output_contains "'prefix+g' shadows a herdr keybinding"
}

@test "check-keys reports a command key that shadows a binding set in [keys]" {
  local bad="$BATS_TEST_TMPDIR/bad.toml"
  cat >"$bad" <<'EOF'
[keys]
previous_agent = "prefix+alt+k"
focus_agent = "prefix+ctrl+1..9"

[[keys.command]]
key = "prefix+alt+k"
type = "popup"
command = "true"

[[keys.command]]
key = "prefix+ctrl+3"
type = "popup"
command = "true"
EOF
  run config_lint check-keys "$HERDR_REFERENCE" "$bad"
  echo "$output"
  [ "$status" -eq 1 ]
  assert_output_contains "'prefix+alt+k' shadows a herdr keybinding"
  assert_output_contains "'prefix+ctrl+3' shadows a herdr keybinding"
}

@test "check-keys allows a command key that [keys] freed from its default" {
  local file="$BATS_TEST_TMPDIR/rebound.toml"
  cat >"$file" <<'EOF'
[keys]
goto = "prefix+shift+o"

[[keys.command]]
key = "prefix+g"
type = "popup"
command = "true"
EOF
  run config_lint check-keys "$HERDR_REFERENCE" "$file"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a module that redefines a table from base.toml or a theme does not compose" {
  local bad="$BATS_TEST_TMPDIR/redefines.toml"
  printf '[ui]\nsidebar_width = 30\n' >"$bad"
  run config_lint parse "$CONFIG_DIR/base.toml" "$bad"
  echo "$output"
  [ "$status" -eq 1 ]

  printf '[theme]\nname = "nord"\n' >"$bad"
  run config_lint parse "$CONFIG_DIR/base.toml" "$THEMES_DIR/$(default_theme).toml" "$bad"
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

@test "herdr config check accepts base.toml with the default theme" {
  command -v herdr >/dev/null 2>&1 || skip "herdr is not on PATH"
  local composed="$BATS_TEST_TMPDIR/composed.toml"
  config_lint compose "$CONFIG_DIR/base.toml" "$THEMES_DIR/$(default_theme).toml" >"$composed"
  run herdr_isolated "$composed" config check
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "config: ok" ]
}

@test "herdr config check accepts each theme with each module and with all modules" {
  command -v herdr >/dev/null 2>&1 || skip "herdr is not on PATH"
  local composed="$BATS_TEST_TMPDIR/composed.toml" theme module
  for theme in "${THEMES[@]}"; do
    for module in "${MODULES[@]}"; do
      config_lint compose "$CONFIG_DIR/base.toml" "$theme" "$module" >"$composed"
      run herdr_isolated "$composed" config check
      echo "$theme + $module: $output"
      [ "$status" -eq 0 ]
      [ "$output" = "config: ok" ]
    done
    config_lint compose "$CONFIG_DIR/base.toml" "$theme" "${MODULES[@]}" >"$composed"
    run herdr_isolated "$composed" config check
    echo "$theme + all modules: $output"
    [ "$status" -eq 0 ]
    [ "$output" = "config: ok" ]
  done
}
