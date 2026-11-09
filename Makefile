# Development tasks for oh-my-herdr.
# Requires shellcheck, bats, and python3 >= 3.11. herdr is optional: tests
# that run it are skipped when it is not on PATH.

.PHONY: check lint test

check: lint test

# Shellcheck every shell script, bats helper, and bats test that git tracks
# or would track (ignored files are skipped). Succeeds when there are none.
lint:
	@files="$$(git ls-files --cached --others --exclude-standard -- '*.sh' '*.bash' '*.bats')"; \
	if [ -z "$$files" ]; then \
		echo "lint: no shell files to check"; \
	else \
		echo "shellcheck" $$files; \
		shellcheck $$files; \
	fi

test:
	bats tests/
