#!/usr/bin/env bash
# =============================================================================
# check-cert.sh — Poll ACM certificate status until ISSUED or timeout
#
# Usage:
#   chmod +x infra/check-cert.sh
#   ./infra/check-cert.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

CONFIG_FILE="infra/config.env"
[[ -f "$CONFIG_FILE" ]] || { echo "infra/config.env not found."; exit 1; }
source "$CONFIG_FILE"

[[ -z "${DOMAIN_NAME:-}" ]] && { echo "DOMAIN_NAME not set in config.env — nothing to check."; exit 0; }

echo -e "\n${BOLD}ACM Certificate Status — $DOMAIN_NAME${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Find the certificate ARN
CERT_ARN=$(aws acm list-certificates \
    --region us-east-1 \
    --query "CertificateSummaryList[?DomainName=='${DOMAIN_NAME}'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "")

if [[ -z "$CERT_ARN" || "$CERT_ARN" == "None" ]]; then
    echo "No certificate found for $DOMAIN_NAME in us-east-1."
    echo "Run infra/setup.sh to request one."
    exit 1
fi

echo "Certificate ARN: $CERT_ARN"
echo ""

# Poll every 30 seconds up to 30 minutes
MAX_WAIT=60   # 60 × 30s = 30 minutes
COUNT=0

while [[ $COUNT -lt $MAX_WAIT ]]; do
    CERT_DETAIL=$(aws acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region us-east-1 \
        --output json)

    STATUS=$(echo "$CERT_DETAIL" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['Certificate']['Status'])")

    if [[ "$STATUS" == "ISSUED" ]]; then
        echo -e "${GREEN}✓ Certificate status: ISSUED${NC}"
        echo ""
        echo "You can now run: ./infra/cloudfront-setup.sh"
        exit 0
    fi

    # Print the DNS validation records on first iteration
    if [[ $COUNT -eq 0 ]]; then
        echo -e "${YELLOW}Status: $STATUS${NC}"
        echo ""
        echo "Add these DNS CNAME records at your registrar to validate ownership:"
        echo ""
        echo "$CERT_DETAIL" | python3 -c "
import sys, json
cert = json.load(sys.stdin)['Certificate']
for opt in cert.get('DomainValidationOptions', []):
    rr = opt.get('ResourceRecord', {})
    if rr:
        print(f\"  Domain : {opt['DomainName']}\")
        print(f\"  Type   : {rr['Type']}\")
        print(f\"  Name   : {rr['Name']}\")
        print(f\"  Value  : {rr['Value']}\")
        print()
"
        echo "Polling every 30 seconds (up to 30 minutes)..."
        echo ""
    fi

    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} Status: $STATUS — waiting..."
    sleep 30
    COUNT=$((COUNT + 1))
done

echo -e "${YELLOW}Timeout reached. Certificate is still $STATUS.${NC}"
echo "DNS propagation can take up to 30 minutes after adding the records."
echo "Re-run this script to continue polling."
exit 1
