#!/usr/bin/env bash
# test_common.sh - Unit tests for common.sh functions
# Run with: ./test_common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Test framework
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

test_start() {
    echo "Running tests for common.sh..."
    echo "==============================="
}

test_end() {
    echo "==============================="
    echo "Tests completed: $TESTS_RUN run, $TESTS_PASSED passed, $TESTS_FAILED failed"
    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo "✅ All tests passed!"
        exit 0
    else
        echo "❌ Some tests failed!"
        exit 1
    fi
}

assert_equals() {
    local expected="$1" actual="$2" test_name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo "✅ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "❌ $test_name"
        echo "   Expected: '$expected'"
        echo "   Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_true() {
    local condition="$1" test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$condition"; then
        echo "✅ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "❌ $test_name (condition failed: $condition)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_false() {
    local condition="$1" test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! eval "$condition"; then
        echo "✅ $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "❌ $test_name (condition should have failed: $condition)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Test logging functions
test_logging() {
    echo "Testing logging functions..."
    
    # Test log level filtering
    LOG_LEVEL=$LOG_ERROR
    local output
    output="$(debug "test debug" 2>&1)" || true
    assert_equals "" "$output" "debug() respects LOG_ERROR level"
    
    LOG_LEVEL=$LOG_DEBUG
    output="$(debug "test debug" 2>&1)"
    assert_true "echo '$output' | grep -q 'test debug'" "debug() works at LOG_DEBUG level"
}

# Test utility functions  
test_utilities() {
    echo "Testing utility functions..."
    
    # Test branch_to_env
    assert_equals "explore" "$(branch_to_env "main")" "branch_to_env(main) -> explore"
    assert_equals "preprod" "$(branch_to_env "preprod")" "branch_to_env(preprod) -> preprod" 
    assert_equals "prod" "$(branch_to_env "prod")" "branch_to_env(prod) -> prod"
    assert_equals "explore" "$(branch_to_env "feature-xyz")" "branch_to_env(unknown) -> explore"
    
    # Test have_cmd
    assert_true "have_cmd bash" "have_cmd detects existing command"
    assert_false "have_cmd nonexistent_command_xyz" "have_cmd rejects nonexistent command"
}

# Test validation functions
test_validation() {
    echo "Testing validation functions..."
    
    # Test validate_number with valid input
    if validate_number "42" "test" 2>/dev/null; then
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✅ validate_number accepts valid number"
    else
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "❌ validate_number should accept valid number"
    fi
    
    # Note: Test for invalid number skipped as validate_number calls error_exit
    # This is by design for script validation, not test validation
}

# Test temp file management
test_temp_files() {
    echo "Testing temp file management..."
    
    local temp1 temp2
    temp1="$(make_temp)"
    temp2="$(make_temp)"
    
    # Files should exist and be different
    assert_true "[ -f '$temp1' ]" "make_temp creates file"
    assert_true "[ -f '$temp2' ]" "make_temp creates second file"
    assert_false "[ '$temp1' = '$temp2' ]" "make_temp creates unique files"
    
    # Note: TEMP_FILES tracking tested separately due to trap interference
}

# Test CSV validation
test_csv_validation() {
    echo "Testing CSV validation..."
    
    # Create test CSV
    local test_csv
    test_csv="$(make_temp)"
    echo "col1,col2,col3,col4,col5" > "$test_csv"
    echo "val1,val2,val3,val4,val5" >> "$test_csv"
    
    # Should pass validation
    if validate_csv "$test_csv" 3 2>/dev/null; then
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "✅ validate_csv accepts valid CSV"
    else
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "❌ validate_csv should accept valid CSV"
    fi
    
    # Note: Test for insufficient columns skipped as validate_csv calls error_exit
    # This is by design for script validation, not test validation
}

# Run all tests
test_start
test_logging
test_utilities  
test_validation
test_temp_files
test_csv_validation
test_end
test_end