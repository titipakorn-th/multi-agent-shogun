#!/usr/bin/env bash
# dim_d_quality_comparison.sh — Dim D: Output Quality Comparison Experiment
# Usage: bash tests/dim_d_quality_comparison.sh
#
# Executes the same L5 task on a non-Bloom-compatible model (Haiku 4.5) and a compatible model (Sonnet 4.6),
# and Gunshi (Opus 4.6) scores the quality to demonstrate the difference.
#
# Acceptance Criteria:
#   Sonnet 4.6 score >= 70 (L5 criteria: 3 options + recommendation with rationale)
#   Haiku 4.5  score <= 50 (Cannot fully process L5 task)
#   Difference >= 15 points

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${PROJECT_ROOT}/queue/reports/dim_d_quality_report.yaml"

echo "══ Dim D: Output Quality Comparison Experiment ══"
echo "Task Type: L5 (Evaluate) — Compare & Recommend Implementation Options"
echo "Non-compatible Model: claude-haiku-4-5-20251001 (max_bloom=3)"
echo "Compatible Model:   claude-sonnet-4-6         (max_bloom=5)"
echo "Evaluator:          claude-opus-4-6           (max_bloom=6)"
echo ""

python3 << PYEOF
import subprocess, re, sys, os, json
from pathlib import Path
from datetime import datetime
import yaml

project_root = Path("${PROJECT_ROOT}")

# Avoid nested detection by removing CLAUDECODE env var
env = os.environ.copy()
env.pop('CLAUDECODE', None)

# Resolve claude CLI path
import glob as _glob
claude_cmd = subprocess.run(['which', 'claude'], capture_output=True, text=True, env=env).stdout.strip()
if not claude_cmd:
    candidates = (
        _glob.glob(os.path.expanduser('~/.local/bin/claude')) +
        _glob.glob(os.path.expanduser('~/.nvm/versions/node/*/bin/claude')) +
        ['/usr/local/bin/claude']
    )
    claude_cmd = next((c for c in candidates if os.path.isfile(c)), 'claude')
print(f"claude CLI: {claude_cmd}")

# ─────────────────────────────────────────────
# L5 Task Definition
# ─────────────────────────────────────────────
L5_TASK = """We want to implement 'dynamic task allocation to idle Ashigaru' in a multi-agent system.
Compare the following 3 options and recommend the best one with rationale.

[Option A] Polling Method: Karo checks the status files of all Ashigaru every second,
           and sends tasks when an idle status is detected.

[Option B] Event-Driven Method: Ashigaru sends a 'completion notification' via inbox_write upon task completion,
           and Karo sends the next task after receiving the notification.

[Option C] Priority Queue Method: Assigns a Bloom level to tasks, selects and assigns
           the lowest-cost Ashigaru among idle Ashigaru holding compatible models.

For each option, evaluate: (1) implementation cost, (2) response latency, (3) extensibility, (4) fault tolerance,
discuss the reasons for choosing the best option."""

EVALUATOR_PROMPT_TEMPLATE = """Score the following response to the 'multi-agent task allocation implementation comparison'.

Scoring Criteria (L5 Evaluate Level):
1. Number of Options (0-20 pts): Are there comments for all 3 options?
2. Evaluation Perspectives (0-25 pts): Is it evaluated across implementation cost/latency/extensibility/fault tolerance?
3. Recommendation (0-25 pts): Is the best option clearly recommended with reasons?
4. Rationale Depth (0-30 pts): Is the comparison technical and deep rather than superficial?

Total: 100 points. Reply in JSON only (no explanations):
{"score": <integer>, "breakdown": {"options_count": <integer>, "perspectives": <integer>, "recommendation": <integer>, "depth": <integer>}, "summary": "<one_line_evaluation>"}

--- Response to score ---
"""

def run_model(model_id, prompt, timeout=120):
    """Invoke claude directly with the specified model"""
    print(f"\n[{model_id}] Running...", flush=True)
    try:
        result = subprocess.run(
            [claude_cmd, '--model', model_id, '-p', prompt],
            capture_output=True, text=True, timeout=timeout,
            env=env
        )
        out = result.stdout.strip()
        if not out and result.stderr:
            print(f"  STDERR: {result.stderr[:200]}", flush=True)
        return out
    except subprocess.TimeoutExpired:
        print(f"  TIMEOUT ({timeout}s)")
        return None
    except Exception as e:
        print(f"  ERROR: {e}")
        return None

def evaluate(response, model_label, timeout=90):
    """Calculate quality score using Opus 4.6"""
    if not response:
        return {"score": 0, "error": "no response"}
    prompt = EVALUATOR_PROMPT_TEMPLATE + response[:3000]
    print(f"\n[Gunshi/Opus Evaluation] {model_label}'s response is being scored...", flush=True)
    raw = run_model('claude-opus-4-6', prompt, timeout=timeout)
    if not raw:
        return {"score": 0, "error": "evaluator failed"}
    # JSON extraction
    match = re.search(r'\{.*\}', raw, re.DOTALL)
    if match:
        try:
            return json.loads(match.group())
        except:
            pass
    # fallback: extract only score numeric value
    nums = re.findall(r'"score"\s*:\s*(\d+)', raw)
    return {"score": int(nums[0]) if nums else 0, "raw": raw[:500]}

# ─────────────────────────────────────────────
# Run / Execute
# ─────────────────────────────────────────────
print("\n── Step 1/3: Haiku 4.5 (max_bloom=3, L5 task not supported) ──")
haiku_response = run_model('claude-haiku-4-5-20251001', L5_TASK)
if haiku_response:
    print(f"  Output ({len(haiku_response)} chars): {haiku_response[:200]}...")

print("\n── Step 2/3: Sonnet 4.6 (max_bloom=5, L5 task supported) ──")
sonnet_response = run_model('claude-sonnet-4-6', L5_TASK)
if sonnet_response:
    print(f"  Output ({len(sonnet_response)} chars): {sonnet_response[:200]}...")

print("\n── Step 3/3: Gunshi (Opus 4.6) scores both ──")
haiku_eval  = evaluate(haiku_response,  "Haiku 4.5")
sonnet_eval = evaluate(sonnet_response, "Sonnet 4.6")

haiku_score  = haiku_eval.get('score', 0)
sonnet_score = sonnet_eval.get('score', 0)
diff = sonnet_score - haiku_score

print("\n══ Result Summary ══")
print(f"Haiku 4.5  Score: {haiku_score}/100  (max_bloom=3 (max_bloom=3, L5 task not supported)")
print(f"Sonnet 4.6 Score: {sonnet_score}/100  (max_bloom=5 (max_bloom=5, L5 task supported)")
print(f"Difference:              +{diff} pts")
print()

THRESHOLD_SONNET = 70
THRESHOLD_DIFF   = 15
pass_sonnet = sonnet_score >= THRESHOLD_SONNET
pass_diff   = diff >= THRESHOLD_DIFF

print(f"Sonnet ≥ {THRESHOLD_SONNET} pts: {'✓ PASS' if pass_sonnet else '✗ FAIL'}")
print(f"Difference   ≥ {THRESHOLD_DIFF} pts: {'✓ PASS' if pass_diff else '✗ FAIL'}")

verdict = 'PASS' if (pass_sonnet and pass_diff) else 'FAIL'
print(f"\nFinal Verdict: {verdict}")
print(f"(Value of Bloom routing: {'+' if diff > 0 else ''}{diff} pts difference)")

# ─────────────────────────────────────────────
# Save Report
# ─────────────────────────────────────────────
report = {
    'dim_d_quality_report': {
        'timestamp': datetime.now().isoformat(),
        'task_bloom_level': 5,
        'task_description': L5_TASK[:200],
        'models': {
            'inappropriate': {
                'model': 'claude-haiku-4-5-20251001',
                'max_bloom': 3,
                'score': haiku_score,
                'evaluation': haiku_eval,
                'response_length': len(haiku_response) if haiku_response else 0,
                'response_preview': (haiku_response or '')[:500],
            },
            'appropriate': {
                'model': 'claude-sonnet-4-6',
                'max_bloom': 5,
                'score': sonnet_score,
                'evaluation': sonnet_eval,
                'response_length': len(sonnet_response) if sonnet_response else 0,
                'response_preview': (sonnet_response or '')[:500],
            },
        },
        'score_diff': diff,
        'thresholds': {
            'sonnet_min': THRESHOLD_SONNET,
            'diff_min':   THRESHOLD_DIFF,
        },
        'pass_sonnet': pass_sonnet,
        'pass_diff':   pass_diff,
        'verdict': verdict,
    }
}

output_path = Path(project_root) / 'queue' / 'reports' / 'dim_d_quality_report.yaml'
output_path.parent.mkdir(parents=True, exist_ok=True)
with open(output_path, 'w') as f:
    yaml.dump(report, f, allow_unicode=True)
print(f"\nReport saved: {output_path}")

sys.exit(0 if verdict == 'PASS' else 1)
PYEOF
