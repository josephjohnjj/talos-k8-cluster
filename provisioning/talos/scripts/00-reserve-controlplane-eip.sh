#!/bin/sh
set -eu

: "${AWS_REGION:?Set AWS_REGION to the Terraform aws_region}"

for command in aws jq; do
  command -v "$command" >/dev/null || {
    printf 'Required command not found: %s\n' "$command" >&2
    exit 1
  }
done

AWS_PAGER=
export AWS_PAGER
address_name=talos-kubernetes-api

if [ -n "${CONTROLPLANE_API_EIP_ALLOCATION_ID:-}" ]; then
  set -- --allocation-ids "$CONTROLPLANE_API_EIP_ALLOCATION_ID"
else
  set -- --filters "Name=tag:Name,Values=$address_name"
fi

addresses=$(aws ec2 describe-addresses --region "$AWS_REGION" "$@" --output json)
count=$(printf '%s\n' "$addresses" | jq -er '.Addresses | arrays | length')

case "$count" in
  0)
    if [ -n "${CONTROLPLANE_API_EIP_ALLOCATION_ID:-}" ]; then
      printf 'The requested Elastic IP allocation was not found.\n' >&2
      exit 1
    fi
    address=$(aws ec2 allocate-address --region "$AWS_REGION" --domain vpc \
      --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$address_name}]" \
      --output json)
    ;;
  1)
    address=$(printf '%s\n' "$addresses" | jq -ce '.Addresses[0]')
    ;;
  *)
    printf 'Multiple Elastic IPs have Name=%s. Set CONTROLPLANE_API_EIP_ALLOCATION_ID to select one.\n' \
      "$address_name" >&2
    exit 1
    ;;
esac

printf '%s\n' "$address" | jq -er '
  if (.PublicIp | strings | test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$")) == true
    and (.AllocationId | strings | test("^eipalloc-[0-9a-f]+$")) == true
  then
    "export CONTROLPLANE_EIP=\(.PublicIp)",
    "export CONTROLPLANE_API_EIP_ALLOCATION_ID=\(.AllocationId)",
    "export KUBERNETES_ENDPOINT=https://\(.PublicIp):6443"
  else error("AWS did not return a public IPv4 address and allocation ID")
  end
'
