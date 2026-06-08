#!/usr/bin/env bash
# bloom_classification_accuracy.sh — Dim B: Bloom Classification Accuracy Test
# Usage: bash tests/bloom_classification_accuracy.sh [--corpus path] [--output path] [--agent ashigaru_id]
#
# Sends each task in bloom_task_corpus.yaml to Gunshi,
# and measures accuracy by comparing the classified Bloom level with expected_bloom.
#
# Acceptance Criteria:
#   exact match  >= 60%  (Exact match)
#   tolerance    >= 80%  (±1 level tolerance)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${1:-${PROJECT_ROOT}/tests/fixtures/bloom_task_corpus.yaml}"
OUTPUT="${PROJECT_ROOT}/queue/reports/bloom_accuracy_report.yaml"
GUNSHI_TASK_FILE="${PROJECT_ROOT}/queue/tasks/gunshi.yaml"
GUNSHI_REPORT="${PROJECT_ROOT}/queue/reports/gunshi_bloom_test.yaml"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --corpus) CORPUS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--corpus path] [--output path]"; exit 0 ;;
        *) shift ;;
    esac
done

echo "══ Bloom Classification Accuracy Test ══"
echo "Corpus: $CORPUS"
echo "Output:   $OUTPUT"
echo ""

if [[ ! -f "$CORPUS" ]]; then
    echo "Error: Corpus file not found: $CORPUS" >&2
    exit 1
fi

# Read corpus and process each task in Python
python3 << PYEOF
import yaml, subprocess, re, sys, json, os
from pathlib import Path
from datetime import datetime

corpus_path = "${CORPUS}"
output_path = "${OUTPUT}"
project_root = "${PROJECT_ROOT}"
gunshi_task_file = "${GUNSHI_TASK_FILE}"
gunshi_report_file = "${GUNSHI_REPORT}"

with open(corpus_path) as f:
    corpus = yaml.safe_load(f)

tasks = corpus.get('bloom_tasks', [])
total = len(tasks)
exact_match = 0
tolerance_match = 0
results = []

confusion = {}  # expected -> {got: count}

print(f"Processing all {total} tasks...")
print()

for task in tasks:
    task_id = task['id']
    expected = task['bloom_level']
    description = task['description'].strip()

    print(f"[{task_id}] expected=L{expected} | {description[:60]}...")

    # Write task to Gunshi
    task_yaml = {
        'task': {
            'task_id': f'bloom_test_{task_id}',
            'bloom_level': 'L2',  # This task itself is L2 (explanation task)
            'description': f'''Bloom Level Classification Test.
Classify which level of cognitive taxonomy (Bloom's Taxonomy) the following task belongs to.
Return only a single integer value from 1 to 6. No explanation, just the number.

Task:
{description}''',
            'status': 'assigned',
            'timestamp': datetime.now().isoformat(),
        }
    }

    with open(gunshi_task_file, 'w') as f:
        yaml.dump(task_yaml, f, allow_unicode=True)

    # Send to Gunshi via inbox_write (simulated during test run)
    # In actual VPS E2E, this would call inbox_write and wait for a response
    # This script runs in 'batch decision' mode: simulated via direct CLI call

    # *** For VPS run: uncomment the following to query Gunshi in real-time ***
    # inbox_cmd = f"bash {project_root}/scripts/inbox_write.sh gunshi 'bloom_test_{task_id} Perform decision for' task_assigned karo"
    # subprocess.run(inbox_cmd, shell=True, cwd=project_root)
    # got = wait_for_gunshi_response(task_id)  # Needs implementation

    # *** Local verification mode: query Claude directly (requires claude CLI) ***
    # Dynamically resolve path to claude CLI (supports environments without PATH set)
    claude_cmd = subprocess.run(['which', 'claude'], capture_output=True, text=True).stdout.strip()
    if not claude_cmd:
        import glob as _glob
        candidates = _glob.glob(os.path.expanduser('~/.local/bin/claude')) + \
                     _glob.glob(os.path.expanduser('~/.npm-global/bin/claude')) + \
                     _glob.glob('/usr/local/bin/claude')
        claude_cmd = next((c for c in candidates if os.path.isfile(c)), 'claude')
    try:
        result = subprocess.run(
            [claude_cmd, '-p', f'''Answer the cognitive level (Bloom's Taxonomy, 1-6) of this task with a single number.
No explanation, return only the number.

Task description:
{description}

Level definitions:
1=Remember, 2=Understand, 3=Apply,
4=Analyze, 5=Evaluate, 6=Create'''],
            capture_output=True, text=True, timeout=60
        )
        response = result.stdout.strip()
        # Extract number
        nums = re.findall(r'[1-6]', response)
        got = int(nums[0]) if nums else None
    except (subprocess.TimeoutExpired, FileNotFoundError, Exception) as e:
        got = None
        print(f"  WARNING: Claude CLI error: {e}")

    # Calculate score
    exact = (got == expected) if got is not None else False
    within1 = (abs(got - expected) <= 1) if got is not None else False

    if exact:
        exact_match += 1
        status = "✓ EXACT"
    elif within1:
        tolerance_match += 1
        status = "~ WITHIN1"
    else:
        status = "✗ MISS"

    if got is not None:
        confusion.setdefault(expected, {})
        confusion[expected][got] = confusion[expected].get(got, 0) + 1

    print(f"  got=L{got}  {status}")
    results.append({
        'task_id': task_id,
        'expected_bloom': expected,
        'got_bloom': got,
        'exact': exact,
        'within1': within1,
    })

# Aggregate
valid = [r for r in results if r['got_bloom'] is not None]
valid_count = len(valid)
if valid_count > 0:
    exact_rate = sum(1 for r in valid if r['exact']) / valid_count * 100
    tolerance_rate = sum(1 for r in valid if r['within1'] or r['exact']) / valid_count * 100
else:
    exact_rate = tolerance_rate = 0.0

pass_exact = exact_rate >= 60
pass_tolerance = tolerance_rate >= 80

print()
print("══ Result Summary ══")
print(f"Valid responses: {valid_count}/{total}")
print(f"Exact match rate: {exact_rate:.1f}%  {'✓ PASS' if pass_exact else '✗ FAIL'} (Criteria ≥60%)")
print(f"±1 tolerance rate:  {tolerance_rate:.1f}%  {'✓ PASS' if pass_tolerance else '✗ FAIL'} (Criteria ≥80%)")
print()
print("Confusion matrix (expected -> got):")
for expected_level in sorted(confusion.keys()):
    row = confusion[expected_level]
    print(f"  L{expected_level}: " + " | ".join(f"L{k}:{v}" for k, v in sorted(row.items())))

# Output YAML
report = {
    'bloom_accuracy_report': {
        'timestamp': datetime.now().isoformat(),
        'corpus': corpus_path,
        'total_tasks': total,
        'valid_responses': valid_count,
        'exact_match_rate': round(exact_rate, 1),
        'tolerance_match_rate': round(tolerance_rate, 1),
        'pass_exact': pass_exact,
        'pass_tolerance': pass_tolerance,
        'verdict': 'PASS' if (pass_exact and pass_tolerance) else 'FAIL',
        'results': results,
        'confusion_matrix': {str(k): v for k, v in confusion.items()},
    }
}

Path(output_path).parent.mkdir(parents=True, exist_ok=True)
with open(output_path, 'w') as f:
    yaml.dump(report, f, allow_unicode=True)

print(f"\nReport saved: {output_path}")

verdict = 'PASS' if (pass_exact and pass_tolerance) else 'FAIL'
print(f"\nFinal Verdict: {verdict}")
sys.exit(0 if verdict == 'PASS' else 1)
PYEOF
