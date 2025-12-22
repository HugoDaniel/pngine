#!/bin/bash
# Generate LLM-readable coverage report from kcov output
#
# Usage: ./scripts/coverage-report.sh [coverage-dir]
#
# Output format is designed to be actionable by LLMs:
# - Summary with overall percentage
# - Files sorted by coverage (lowest first)
# - Uncovered lines with file:line format for easy navigation

set -e

COVERAGE_DIR="${1:-coverage}"
REPORT_FILE="coverage/COVERAGE_REPORT.md"

# Find the test output directory (kcov creates test.XXXX subdirectory)
KCOV_DIR=$(find "$COVERAGE_DIR" -maxdepth 1 -type d -name "test.*" | head -1)

if [ -z "$KCOV_DIR" ]; then
    KCOV_DIR="$COVERAGE_DIR/test"
fi

CODECOV_JSON="$KCOV_DIR/codecov.json"

if [ ! -f "$CODECOV_JSON" ]; then
    echo "Error: codecov.json not found at '$CODECOV_JSON'"
    echo "Run: zig build coverage"
    exit 1
fi

echo "Processing coverage from: $KCOV_DIR"

# Create the report using jq to parse JSON
{
    echo "# Coverage Report"
    echo ""
    echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""

    # Calculate summary stats
    echo "## Summary"
    echo ""

    STATS=$(jq -r '
        .coverage | to_entries |
        map(
            .value | to_entries |
            map(.value | split("/") | {covered: (.[0] | tonumber), total: (.[1] | tonumber)})
        ) | flatten |
        {
            total: (map(.total) | add),
            covered: (map(select(.covered > 0)) | length)
        } |
        "\(.covered) \(.total)"
    ' "$CODECOV_JSON")

    COVERED=$(echo "$STATS" | cut -d' ' -f1)
    TOTAL=$(echo "$STATS" | cut -d' ' -f2)

    if [ "$TOTAL" -gt 0 ]; then
        PERCENT=$(echo "scale=1; $COVERED * 100 / $TOTAL" | bc)
    else
        PERCENT="0"
    fi

    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Lines with coverage data | $TOTAL |"
    echo "| Lines executed | $COVERED |"
    echo "| Coverage | $PERCENT% |"
    echo ""

    echo "## Files by Coverage (Lowest First)"
    echo ""
    echo "Files with <80% coverage need attention:"
    echo ""
    echo "| File | Coverage | Lines |"
    echo "|------|----------|-------|"

    # Parse each file's coverage and sort by percentage
    jq -r '
        .coverage | to_entries | map(
            .key as $file |
            .value | to_entries |
            {
                file: $file,
                total: length,
                covered: (map(select(.value | split("/") | .[0] | tonumber > 0)) | length)
            } |
            {
                file: .file,
                total: .total,
                covered: .covered,
                percent: (if .total > 0 then (.covered * 100 / .total) else 0 end)
            }
        ) |
        sort_by(.percent) |
        .[] |
        "| \(.file) | \(.percent | floor)% | \(.covered)/\(.total) |"
    ' "$CODECOV_JSON" | head -30

    echo ""
    echo "## Uncovered Lines (Top Priority)"
    echo ""
    echo "These lines have 0 execution count. Format: \`file:line\` for easy navigation."
    echo ""
    echo '```'

    # Extract lines with 0 coverage, grouped by file
    jq -r '
        .coverage | to_entries | map(
            .key as $file |
            .value | to_entries |
            map(select(.value | startswith("0/"))) |
            map("\($file):\(.key)")
        ) | flatten | .[]
    ' "$CODECOV_JSON" | head -100

    echo '```'
    echo ""

    echo "## Low Coverage Files (Need Attention)"
    echo ""
    echo "Files below 80% coverage - consider adding tests:"
    echo ""

    # Show files with less than 80% coverage with their uncovered line ranges
    jq -r '
        .coverage | to_entries | map(
            .key as $file |
            .value | to_entries |
            {
                file: $file,
                total: length,
                covered: (map(select(.value | split("/") | .[0] | tonumber > 0)) | length),
                uncovered: (map(select(.value | startswith("0/"))) | map(.key | tonumber) | sort)
            } |
            select(.total > 0) |
            {
                file: .file,
                percent: (.covered * 100 / .total),
                uncovered: .uncovered
            } |
            select(.percent < 80)
        ) |
        sort_by(.percent) |
        .[] |
        "### \(.file) (\(.percent | floor)%)\n\(.uncovered | map("- Line \(.)") | join("\n"))"
    ' "$CODECOV_JSON" 2>/dev/null | head -100 || echo "(all files above 80%)"

    echo ""

    echo "## How to Improve Coverage"
    echo ""
    echo "1. **Zero coverage lines**: Add tests that execute these paths"
    echo "2. **Partial coverage**: Add tests for untested branches (if/else, error cases)"
    echo "3. **Priority files**: Focus on core logic (emitter, analyzer, parser, dispatcher)"
    echo "4. **Skip**: Test files (*_test.zig) and unreachable/panic lines are expected gaps"
    echo ""
    echo "Commands:"
    echo '```bash'
    echo "# Regenerate coverage"
    echo "zig build coverage && ./scripts/coverage-report.sh"
    echo ""
    echo "# Run specific test to improve coverage"
    echo 'zig build test --test-filter "Emitter:"'
    echo '```'

} > "$REPORT_FILE"

echo ""
echo "Coverage report written to: $REPORT_FILE"
echo ""

# Print summary to stdout
head -25 "$REPORT_FILE"
echo "..."
echo ""
echo "See full report: $REPORT_FILE"
echo "Or open HTML: open $KCOV_DIR/index.html"
