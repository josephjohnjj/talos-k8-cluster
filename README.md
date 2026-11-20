# Talos Kubernetes cluster on AWS

Start from the repository root and run `cd provisioning/talos`. Keep the same
shell for the steps below so the exported variables carry forward. You’ll need
the AWS CLI, Terraform, `talosctl` v1.14.5, `kubectl`, `jq`, `curl`, and Perl.

The HCP Terraform workspace is `aws-resources/k8-talos-cluster`. For an existing cluster,
reuse its Elastic IP and original generated configuration, and skip scripts
`02` and `04`. Keep generated credentials out of Git.

If moving an existing deployment, make its Terraform state available in
`aws-resources/k8-talos-cluster` before planning or applying there.

## Prerequisites

1. You have an AWS account and have generated an AWS access key ID and secret
   access key. Configure both in the AWS CLI profile you’ll use for this deployment.
2. You have an HCP Terraform account with an organization named
   `aws-resources` and a workspace named `k8-talos-cluster`.
3. You have created an HCP Terraform variable set named `aws_credentials`
   and attached it to the `k8-talos-cluster` workspace. Create these entries
   in the variable set before running script `01`.

   | Key | Value | Category |
   |---|---|---|
   | `AWS_ACCESS_KEY_ID` | Sensitive (write-only) | Environment (`env`) |
   | `AWS_SECRET_ACCESS_KEY` | Sensitive (write-only) | Environment (`env`) |

## Create the HCP Terraform workspace variables

In `aws-resources/k8-talos-cluster`, create these entries as Terraform variables.
The table uses the official Talos v1.14.5 AMD64 AMI for `us-east-1`.
For a different region or architecture, use the matching entry in the
[release image list](https://github.com/siderolabs/talos/releases/download/v1.14.5/cloud-images.json).

| Variable | Value |
|---|---|
| `aws_region` | `us-east-1` |
| `target_az` | `us-east-1c` |
| `controller_ami` | `ami-0525c27ed619d7897` |
| `control_instance_type` | `t3a.2xlarge` |
| `control_node_count` | `3` |
| `login_ami` | `ami-0525c27ed619d7897` |
| `login_instance_type` | `t3a.2xlarge` |
| `login_node_count` | `1` |
| `storage_ami` | `ami-0525c27ed619d7897` |
| `storage_instance_type` | `t3a.2xlarge` |
| `storage_node_count` | `3` |
| `worker_cpu_ami` | `ami-0525c27ed619d7897` |
| `worker_cpu_instance_type` | `t3a.2xlarge` |
| `worker_node_cpu_count` | `2` |
| `worker_gpu_ami` | `ami-0525c27ed619d7897` |
| `worker_gpu_instance_type` | `t3a.2xlarge` |
| `worker_node_gpu_count` | `2` |

## 00 — Reserve the control-plane Elastic IP

This script looks up the address tagged `talos-kubernetes-api` in the selected AWS account and region, or reserves and tags one if none exists.\
Its output sets the Kubernetes endpoint for script `02` and the allocation ID for script `03`.

Set `AWS_REGION` to match Terraform’s `aws_region`. Use AWS credentials that
can describe, allocate, and tag Elastic IPs. If the cluster already has an
allocation, export its `CONTROLPLANE_API_EIP_ALLOCATION_ID` before running this.

```sh
export AWS_REGION=us-east-1
eip_exports=$(./scripts/00-reserve-controlplane-eip.sh) && eval "$eip_exports"
```

**Check.** Run this in the same shell as step `00`. It looks up the public IP
using the allocation ID and compares it with `KUBERNETES_ENDPOINT`.

```sh
if reserved_ip=$(aws ec2 describe-addresses --region "$AWS_REGION" \
  --allocation-ids "$CONTROLPLANE_API_EIP_ALLOCATION_ID" \
  --query 'Addresses[0].PublicIp' --output text) &&
  [ -n "$reserved_ip" ] && [ "$reserved_ip" != None ] &&
  [ "$KUBERNETES_ENDPOINT" = "https://$reserved_ip:6443" ]; then
  printf 'Verified %s points to %s\n' "$CONTROLPLANE_API_EIP_ALLOCATION_ID" "$KUBERNETES_ENDPOINT"
else
  printf 'Verification failed. Check the AWS region, allocation ID, and endpoint from step 00.\n' >&2
  false
fi
```

## 01 — Sync AWS credentials to HCP Terraform

This script reads the credentials configured in the AWS CLI.\
It updates the matching sensitive environment variables in an attached HCP variable set.

Sign in with an account that can update the attached variable set and write
workspace variables.

```sh
terraform login
```

Scripts `01` and `03` read the HCP token from
`~/.terraform.d/credentials.tfrc.json` by default. The attached variable set
must already contain `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, plus
`AWS_SESSION_TOKEN` if you use temporary credentials.

```sh
./scripts/01-sync-hcp-aws-credentials.sh
```

**Check.** Confirm the script prints both lines:

```text
Synced HCP environment variable: AWS_ACCESS_KEY_ID
Synced HCP environment variable: AWS_SECRET_ACCESS_KEY
```

If you use temporary credentials, also look for
`Synced HCP environment variable: AWS_SESSION_TOKEN`.

1. In HCP Terraform, open the `aws-resources` organization and select
   **Workspaces** → **k8-talos-cluster** → **Variables**.
2. Confirm `aws_credentials` appears under **Variable sets**.
3. Open `aws_credentials` and check that each expected key has category
   **Environment** (`env`) and is marked **Sensitive**. The values are write-only,
   so verify the key names and settings in the UI.

[HCP Terraform variable documentation](https://developer.hashicorp.com/terraform/cloud-docs/variables)

## 02 — Generate Talos configuration

This script uses the cluster name and Kubernetes endpoint to generate the control-plane, worker, and ingress machine configs.\
It also creates `generated/talosconfig` for administering the same cluster.

```sh
export CLUSTER_NAME=k8-talos-cluster
./scripts/02-generate-config.sh
```

**Check.** From `provisioning/talos`, run the block below. It checks that
`generated/talosconfig` is readable and nonempty, then validates the
control-plane, worker, and ingress configs in cloud mode.

```sh
(
  set -e
  if [ ! -r generated/talosconfig ] || [ ! -s generated/talosconfig ]; then
    printf 'Missing, unreadable, or empty file: generated/talosconfig\n' >&2
    exit 1
  fi

  for config in controlplane worker ingress; do
    talosctl validate --config "generated/$config.yaml" --mode cloud
  done

  printf 'Talos client config is present and all three machine configs passed validation.\n'
)
```

Continue to step `03` when you see the final success message. If validation
fails, Talos prints the error for the config being checked.

## 03 — Sync Terraform variables to HCP

This script uploads the control-plane Elastic IP allocation ID and the three Talos machine configs to the workspace.\
It replaces the API allowlist with your current public IP as a `/32`, so run it from the network you’ll use to administer the cluster.

```sh
test -n "${CONTROLPLANE_API_EIP_ALLOCATION_ID:-}" &&
test -s generated/controlplane.yaml &&
test -s generated/worker.yaml &&
test -s generated/ingress.yaml &&
./scripts/03-sync-hcp-variables.sh
```

**Check.** Look for five `Synced Terraform variable` messages. In the workspace
variables, verify `controlplane_api_eip_allocation_id` matches step `00`, the
three machine config variables are marked sensitive, and
`talos_api_allowed_cidrs` contains your expected public IPv4 address as a `/32`.

## Terraform — Create the AWS infrastructure

From `provisioning/talos`, initialize Terraform for the configured workspace
and review the plan before applying it.

```sh
terraform -chdir=.. init
terraform -chdir=.. plan
```

```sh
terraform -chdir=.. apply
```

**Check.** Confirm the apply succeeds and Terraform reports the private
control-plane addresses, the reserved API address, and exactly one ingress
Elastic IP.

```sh
terraform -chdir=.. output control_node_private_ip
terraform -chdir=.. output controlplane_api_public_ip
terraform -chdir=.. output login_node_public_ips
```

## 04 — Bootstrap a new cluster

This script connects through the public API Elastic IP and bootstraps etcd on `control1` using its private IP.\
It writes the Kubernetes client config to `generated/kubeconfig`.

Set the bootstrap addresses from Terraform and check that Talos reports both
client and server versions before bootstrapping.

```sh
CONTROL_PLANE_ENDPOINTS=$(terraform -chdir=.. output -raw controlplane_api_public_ip) &&
control_plane_ips=$(terraform -chdir=.. output -json control_node_private_ip) &&
CONTROL_PLANE_NODES=$(printf '%s\n' "$control_plane_ips" | jq -er '.[0]') &&
export CONTROL_PLANE_ENDPOINTS CONTROL_PLANE_NODES &&
talosctl --talosconfig generated/talosconfig \
  --endpoints "$CONTROL_PLANE_ENDPOINTS" --nodes "$CONTROL_PLANE_NODES" version
```

Run this once for a new cluster.

```sh
./scripts/04-bootstrap.sh
```

**Check.** Confirm the kubeconfig exists and the Kubernetes API responds. Allow
time for the nodes to join, then confirm the expected nodes report `Ready`.

```sh
test -s generated/kubeconfig &&
kubectl --kubeconfig generated/kubeconfig get nodes -o wide
```

## 05 — Render public hostnames

This script reads the ingress worker’s Elastic IP from Terraform’s `login_node_public_ips` output.\
It updates the `nip.io` hostnames in the ingress manifests and GEN3 values.

```sh
./scripts/05-render-manifests.sh
```

**Check.** Run the built-in check and list the distinct IP-based domains in the
four render targets. The list should contain only `<ingress-ip>.nip.io`, using
the ingress IP printed by Terraform.

```sh
./scripts/05-render-manifests.sh --check
grep -rEho '[0-9]{1,3}(\.[0-9]{1,3}){3}\.nip\.io' \
  ../../argocd/ingresses/ ../../manifests/ingress/ \
  ../../charts/gen3/values/gen3-values.yaml \
  ../../charts/gen3-2025.08/values/gen3-values.yaml | sort -u
```

Argo CD bootstrap, infrastructure, application, and ingress manifests are
under `argocd/`.
