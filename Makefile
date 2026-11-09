# Development tasks for oh-my-herdr.
# Requires shellcheck, bats, and python3 >= 3.11. herdr is optional: tests
# that run it are skipped when it is not on PATH.

.PHONY: check lint test

check: lint test

# Shellcheck every shell script, bats helper, bats test, and test stub that
# git tracks or would track (ignored files are skipped). Succeeds when there
# are none. Stubs have no extension because they stand in for real commands.
lint:
	@files="$$(git ls-files --cached --others --exclude-standard -- '*.sh' '*.bash' '*.bats' 'tests/stubs/*')"; \
	if [ -z "$$files" ]; then \
		echo "lint: no shell files to check"; \
	else \
		echo "shellcheck" $$files; \
		shellcheck $$files; \
	fi

test:
	bats tests/
