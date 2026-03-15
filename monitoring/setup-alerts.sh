#!/usr/bin/env bash
# monitoring/setup-alerts.sh
# Applies CNPG PrometheusRule and verifies Prometheus loaded the alerts
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

pass()  { echo -e "  ${GREEN}✓${RESET}  $*"; }
fail()  { echo -e "  ${RED}✗${RESET}  $*"; }
info()  { echo -e "  ${CYAN}→${RESET}  $*"; }
title() { echo -e "\n${BOLD}$*${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE_FILE="$SCRIPT_DIR/cnpg-prometheusrule.yaml"

# ── Apply the PrometheusRule ───────────────────────────────────────────────────
title "Step 1 — Apply CNPG PrometheusRule"
kubectl apply -f "$RULE_FILE"
pass "PrometheusRule applied"

# ── Verify Prometheus Operator picked it up ────────────────────────────────────
title "Step 2 — Verify rule was loaded"
info "Waiting 15s for Prometheus Operator to reconcile..."
sleep 15

RULE_COUNT=$(kubectl get prometheusrule cnpg-alerts -n default \
  -o jsonpath='{.spec.groups[0].rules}' 2>/dev/null | python3 -c \
  "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)

if [[ "$RULE_COUNT" -gt 0 ]]; then
  pass "$RULE_COUNT alert rules defined in PrometheusRule"
else
  fail "PrometheusRule not found or empty"
  exit 1
fi

# ── Check alerts are visible in Prometheus ─────────────────────────────────────
title "Step 3 — Verify alerts in Prometheus API"
info "Checking via Prometheus API (requires port-forward on 9090)..."

if curl -s --connect-timeout 3 "http://localhost:9090/api/v1/rules" >/dev/null 2>&1; then
  CNPG_RULES=$(curl -s "http://localhost:9090/api/v1/rules" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
rules = [r['name'] for g in data.get('data',{}).get('groups',[])
         for r in g.get('rules',[])
         if r.get('name','').startswith('CNPG')]
print('\n'.join(rules))
" 2>/dev/null || true)

  if [[ -n "$CNPG_RULES" ]]; then
    pass "CNPG alerts loaded in Prometheus:"
    echo "$CNPG_RULES" | while read -r rule; do
      echo -e "      ${GREEN}•${RESET} $rule"
    done
  else
    info "Prometheus port-forward is up but CNPG rules not visible yet"
    info "Wait 30s and check: http://localhost:9090/alerts"
  fi
else
  info "Prometheus not port-forwarded — verify manually:"
  echo ""
  echo "  kubectl port-forward -n monitoring svc/prom-stack-kube-prometheus-prometheus 9090:9090"
  echo "  Then open: http://localhost:9090/alerts"
fi

# ── Instructions ──────────────────────────────────────────────────────────────
title "Done — test your alerts"
echo ""
echo "  Run a chaos test and watch the alerts fire in real time:"
echo ""
echo -e "  ${BOLD}# Terminal 1 — watch alerts${RESET}"
echo "  kubectl port-forward -n monitoring svc/prom-stack-kube-prometheus-prometheus 9090:9090"
echo "  # Open http://localhost:9090/alerts"
echo ""
echo -e "  ${BOLD}# Terminal 2 — trigger the alerts${RESET}"
echo "  ./cnpg-chaos-test.sh"
echo ""
echo "  You should see CNPGInstanceDown fire within 15s of the pod kill,"
echo "  then resolve automatically once the new primary is elected."