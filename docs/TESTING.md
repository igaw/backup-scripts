# Testing Guide

## Shell Scripts
- Use [bats](https://github.com/bats-core/bats-core) for shell script testing.
- Example test: see `tests/test_sample.sh`
- Install bats: `sudo apt-get install bats` or see bats documentation.

## Python Scripts
- Use [pytest](https://docs.pytest.org/en/stable/) for Python script testing.
- Use `unittest.mock` for mocking dependencies.
- Example test: see `tests/test_sample.py`
- Install pytest: `pip install pytest`

## Running Tests
- Shell: `bats tests/test_sample.sh`
- Python: `pytest tests/test_sample.py`
