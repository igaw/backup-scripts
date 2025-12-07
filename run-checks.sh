#!/usr/bin/env bash
set -euo pipefail

REQUIRED_TOOLS=(shellcheck shfmt bats python3 pip flake8 black pytest mypy bandit)

fix_mode=0
if [[ "${1:-}" == "--fix" || "${1:-}" == "-f" ]]; then
	fix_mode=1
	shift
fi

missing_tools=()
for tool in "${REQUIRED_TOOLS[@]}"; do
	if ! command -v "$tool" &>/dev/null; then
		missing_tools+=("$tool")
	fi

done
if ((${#missing_tools[@]} > 0)); then
	echo "Missing required tools: ${missing_tools[*]}"
	echo "Please install them before running this script."
	echo "For shell tools: sudo apt-get update && sudo apt-get install -y shellcheck shfmt bats"
	echo "For Python tools: pip install flake8 black pytest mypy bandit"
	exit 1
fi

# This script runs the main GitHub workflow steps locally for shell and python code.
# Requires: shellcheck, shfmt, bats, python3, pip, flake8, black, pytest, mypy, bandit

# Shell workflows
run_shellcheck() {
	echo "Running ShellCheck..."
	find . -type f -name '*.sh' -print0 | xargs -0 shellcheck
}

run_shfmt() {
	if ((fix_mode)); then
		echo "Reformatting shell scripts with shfmt..."
		find . -type f -name '*.sh' ! -path './tests/*' -print0 | xargs -0 shfmt -w
	else
		echo "Running shfmt..."
		find . -type f -name '*.sh' ! -path './tests/*' -print0 | xargs -0 shfmt -d
	fi
}

run_bats() {
	echo "Running bats tests..."
	if find tests -type f -name '*.sh' -print0 | grep -q .; then
		find tests -type f -name '*.sh' -print0 | xargs -0 -n 1 bats
	else
		echo "No bats test files found."
	fi
}

# Python workflows
run_flake8() {
	echo "Running flake8..."
	flake8 --config=.flake8 src/
}

run_black() {
	if ((fix_mode)); then
		echo "Reformatting Python code with black..."
		black src/
	else
		echo "Running black..."
		black --check src/
	fi
}

run_pytest() {
	echo "Running pytest..."
	pytest tests/
}

run_mypy() {
	echo "Running mypy..."
	mypy src/
}

run_bandit() {
	echo "Running bandit..."
	bandit -r src/
}

main() {
	run_shellcheck
	run_shfmt
	run_bats
	run_flake8
	run_black
	run_pytest
	run_mypy
	run_bandit
	echo "All local workflow checks completed."
}

main "$@"
