#!/usr/bin/env bash
# Example bats test for shell scripts
# To run: bats test_sample.sh

@test "Sample test" {
  run echo "hello"
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}
