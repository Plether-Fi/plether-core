#!/bin/bash

# Usage: ./scripts/mutation-test.sh <ContractName> [start_id] [end_id]
# Example: ./scripts/mutation-test.sh SyntheticSplitter
# Example: ./scripts/mutation-test.sh ZapRouter 1 50
# Example: ./scripts/mutation-test.sh BasketOracle 1 50  (finds src/oracles/BasketOracle.sol)

set -e

# Parse arguments
CONTRACT_NAME=${1:-}
START_ID=${2:-1}
END_ID=${3:-999999}

if [ -z "$CONTRACT_NAME" ]; then
    echo "Usage: $0 <ContractName> [start_id] [end_id]"
    echo ""
    echo "Examples:"
    echo "  $0 SyntheticSplitter        # Test all mutants"
    echo "  $0 ZapRouter 1 50           # Test mutants 1-50"
    echo "  $0 BasketOracle             # Finds src/oracles/BasketOracle.sol"
    echo ""
    echo "Prerequisites:"
    echo "  1. Update gambit.json with target contract"
    echo "  2. Run: gambit mutate --json gambit.json"
    exit 1
fi

GAMBIT_OUT="gambit_out"
RESULTS_FILE="$GAMBIT_OUT/mutation_results.csv"

# Find source file (supports subdirectories like src/oracles/)
ORIGINAL_FILE=$(find src -name "${CONTRACT_NAME}.sol" -type f | head -1)
if [ -z "$ORIGINAL_FILE" ]; then
    echo "Error: Source file not found: ${CONTRACT_NAME}.sol in src/"
    exit 1
fi

BACKUP_FILE="$GAMBIT_OUT/${CONTRACT_NAME}.sol.backup"
TEST_PATTERN="test/${CONTRACT_NAME}*.t.sol"

# Verify mutants directory exists
if [ ! -d "$GAMBIT_OUT/mutants" ]; then
    echo "Error: No mutants found. Run 'gambit mutate --json gambit.json' first."
    exit 1
fi

# Verify test files exist
if ! ls $TEST_PATTERN 1>/dev/null 2>&1; then
    echo "Warning: No test files matching pattern: $TEST_PATTERN"
    echo "Will run all tests instead."
    TEST_PATTERN=""
fi

echo "Contract: $CONTRACT_NAME"
echo "Source: $ORIGINAL_FILE"
echo "Tests: ${TEST_PATTERN:-all tests}"
echo ""

# Backup original if not already done
if [ ! -f "$BACKUP_FILE" ]; then
    cp "$ORIGINAL_FILE" "$BACKUP_FILE"
    echo "Backed up original to $BACKUP_FILE"
fi

# Initialize results file if starting fresh
if [ ! -f "$RESULTS_FILE" ] || [ "$START_ID" -eq 1 ]; then
    echo "id,status,description" > "$RESULTS_FILE"
fi

# Get total mutant count
TOTAL_MUTANTS=$(ls -d $GAMBIT_OUT/mutants/*/ 2>/dev/null | wc -l | tr -d ' ')
echo "Total mutants: $TOTAL_MUTANTS"
echo "Testing mutants from $START_ID to $END_ID"
echo ""

# Function to restore original
restore_original() {
    if [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$ORIGINAL_FILE"
    fi
}

# Trap to restore on exit
trap restore_original EXIT

# Build test command
if [ -n "$TEST_PATTERN" ]; then
    TEST_CMD="forge test --match-path \"$TEST_PATTERN\" --fail-fast -q"
else
    TEST_CMD="forge test --fail-fast -q"
fi

# Test each mutant
for MUTANT_DIR in $(ls -d $GAMBIT_OUT/mutants/*/ | sort -t/ -k3 -n); do
    MUTANT_ID=$(basename "$MUTANT_DIR")

    # Skip if outside range
    if [ "$MUTANT_ID" -lt "$START_ID" ] || [ "$MUTANT_ID" -gt "$END_ID" ]; then
        continue
    fi

    # Skip if already tested
    if grep -q "^$MUTANT_ID," "$RESULTS_FILE" 2>/dev/null; then
        continue
    fi

    MUTANT_FILE="$MUTANT_DIR/$ORIGINAL_FILE"

    if [ ! -f "$MUTANT_FILE" ]; then
        echo "[$MUTANT_ID/$TOTAL_MUTANTS] Mutant file not found, skipping"
        continue
    fi

    # Get mutation description from the diff comment in the file
    DESCRIPTION=$(grep "/// " "$MUTANT_FILE" | head -1 | sed 's|.*/// ||' | tr ',' ';')

    # Apply mutant
    cp "$MUTANT_FILE" "$ORIGINAL_FILE"

    # Run tests
    echo -n "[$MUTANT_ID/$TOTAL_MUTANTS] Testing... "

    if eval $TEST_CMD 2>/dev/null; then
        echo "SURVIVED - $DESCRIPTION"
        echo "$MUTANT_ID,SURVIVED,$DESCRIPTION" >> "$RESULTS_FILE"
    else
        echo "KILLED"
        echo "$MUTANT_ID,KILLED,$DESCRIPTION" >> "$RESULTS_FILE"
    fi
done

# Restore original
restore_original

# Summary
echo ""
echo "=== MUTATION TESTING COMPLETE ==="
KILLED=$(grep ",KILLED," "$RESULTS_FILE" | wc -l | tr -d ' ')
SURVIVED=$(grep ",SURVIVED," "$RESULTS_FILE" | wc -l | tr -d ' ')
TOTAL=$((KILLED + SURVIVED))
if [ "$TOTAL" -gt 0 ]; then
    SCORE=$(echo "scale=2; $KILLED * 100 / $TOTAL" | bc)
    echo "Killed: $KILLED"
    echo "Survived: $SURVIVED"
    echo "Mutation Score: $SCORE%"
    echo ""
    echo "Surviving mutants:"
    grep ",SURVIVED," "$RESULTS_FILE" | cut -d',' -f1 | tr '\n' ' '
    echo ""
    echo ""
    echo "Review: $RESULTS_FILE"
fi
