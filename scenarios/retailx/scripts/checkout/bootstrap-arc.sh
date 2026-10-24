#!/bin/bash
# Azure-hosted evaluation only: Azure owns the VM; Arc owns guest management.
set -euo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive
export MSFT_ARC_TEST=true

readonly SUBSCRIPTION_ID='__SUBSCRIPTION_ID__'
readonly TENANT_ID='__TENANT_ID__'
readonly RESOURCE_GROUP='__RESOURCE_GROUP__'
readonly LOCATION='__LOCATION__'
readonly MACHINE_NAME='__MACHINE_NAME__'
readonly CLIENT_ID='__CLIENT_ID__'
readonly OWNER_TOKEN='__OWNER_TOKEN__'
readonly ENVIRONMENT_NAME='__ENVIRONMENT_NAME__'

install -d -m 0700 /var/lib/retailtx-checkout
trap 'logger -p local0.err -t RetailTxCheckout "Arc bootstrap failed at line ${LINENO}"' ERR
apt-get update -qq
apt-get install -y -qq curl ca-certificates iptables rsyslog
installer=$(mktemp)
trap 'rm -f "$installer"; unset token' EXIT
curl --fail --silent --show-error --location --retry 3 https://aka.ms/azcmagent -o "$installer"

# Acquire the short-lived onboarding token before switching identity endpoints.
token=$(curl --fail --silent --show-error --retry 10 --retry-delay 10 \
    --header Metadata:true \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F&client_id=${CLIENT_ID}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
test -n "$token"
systemctl set-environment MSFT_ARC_TEST=true
if ! grep -qx 'MSFT_ARC_TEST=true' /etc/environment; then
    printf '\nMSFT_ARC_TEST=true\n' >> /etc/environment
fi
cat > /usr/local/sbin/retailtx-block-imds <<'SCRIPT'
#!/bin/bash
set -euo pipefail
for address in 169.254.169.254 169.254.169.253; do
    if ! iptables -C OUTPUT -d "$address" -j REJECT 2>/dev/null; then
        iptables -I OUTPUT 1 -d "$address" -j REJECT
    fi
done
SCRIPT
chmod 0700 /usr/local/sbin/retailtx-block-imds
cat > /etc/systemd/system/retailtx-block-imds.service <<'UNIT'
[Unit]
Description=Use only the Arc identity endpoint on the evaluation host
Before=himdsd.service gcad.service extd.service
After=network-pre.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/retailtx-block-imds
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl disable --now walinuxagent
systemctl enable --now retailtx-block-imds.service
bash "$installer"
connected=false
for attempt in $(seq 1 12); do
    if azcmagent connect --subscription-id "$SUBSCRIPTION_ID" --tenant-id "$TENANT_ID" \
        --resource-group "$RESOURCE_GROUP" --location "$LOCATION" \
        --resource-name "$MACHINE_NAME" --access-token "$token" \
        --tags "demo=retailtx,environmentId=${ENVIRONMENT_NAME},ownerToken=${OWNER_TOKEN},managedBy=invoke-checkoutdemo,site=dc1"; then
        connected=true
        break
    fi
    logger -p local0.warning -t RetailTxCheckout "Arc onboarding attempt ${attempt} failed"
    sleep 15
done
unset token
if [[ "$connected" != true ]]; then
    echo "Arc onboarding did not complete in its bounded window." >&2
    exit 1
fi
touch /var/lib/retailtx-checkout/arc-bootstrap-complete
logger -p local0.info -t RetailTxCheckout "Arc evaluation onboarding complete"
