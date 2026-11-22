# Talos Kubernetes cluster on AWS

To remove a deployment, follow [04 — Tear down the AWS cluster](#04--tear-down-the-aws-cluster)
to review the destroy plan and release both Elastic IPs.

Run the commands below from the repository root. The playbooks run locally
and manage AWS and HCP Terraform through Ansible modules. Install Ansible,
AWS CLI v2, Terraform, `talosctl` v1.14.5, and `kubectl`. Install `boto3` and
`botocore` in the Python environment used by Ansible, then install the AWS
collection.

```sh
ansible-galaxy collection install -r provisioning/01-prepare-talos/00-ansible-requirements.yml
```

## Prerequisites

1. You have an AWS account and have generated an AWS access key ID and secret
   access key. Configure both in the AWS CLI profile you’ll use for this deployment.
2. You have an HCP Terraform account with an organization named
   `aws-resources` and a workspace named `k8-talos-cluster`.
3. You have created an HCP Terraform variable set named `aws_credentials`
   and attached it to the `k8-talos-cluster` workspace. Create these entries
   in the variable set before running the preparation playbook. For temporary AWS credentials,
   also create `AWS_SESSION_TOKEN` as a sensitive environment variable.

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

## 01 — Prepare Talos and HCP Terraform

The playbook reserves or looks up the control-plane Elastic IP and validates
the Talos configs. It then syncs AWS credentials and Terraform workspace
variables to HCP.

Sign in with an account that can update the attached variable set and workspace
variables. Set `AWS_REGION` to match the workspace’s `aws_region`.

```sh
terraform login
export AWS_REGION=us-east-1
ansible-playbook -i localhost, provisioning/01-prepare-talos/01-prepare-talos.yml -e new_cluster=true
```

For an existing cluster, keep its original files in
`provisioning/01-prepare-talos/generated/`, export its
`CONTROLPLANE_API_EIP_ALLOCATION_ID`, and run with `-e new_cluster=false`.
Add `-e sync_aws_credentials=false` if the attached variable set already has
valid AWS credentials. Run from the network you’ll administer the cluster from,
because the playbook sets the API allowlist to your public IPv4 address.
If a run fails after generating valid configs, keep them, export the allocation
ID for that endpoint, and rerun with `-e new_cluster=false`.

**Check.** The play recap should show `failed=0`, and the final task should
show the allocation ID and Kubernetes endpoint. In HCP Terraform, open
**Workspaces → k8-talos-cluster → Variables** and confirm the attached
`aws_credentials` set, the allocation ID, the three sensitive machine
configs, and the expected API allowlist.

## 02 — Terraform plan and apply

Terraform creates the AWS infrastructure and attaches the reserved API address
to `control1`. For an existing deployment, make its state available in
`aws-resources/k8-talos-cluster` before planning or applying there.

```sh
terraform -chdir=provisioning/02-terraform init
terraform -chdir=provisioning/02-terraform plan
```

Review the plan, then apply it.

```sh
terraform -chdir=provisioning/02-terraform apply
```

**Check.** Confirm the apply succeeds and lists the public API address, the
control-plane private addresses, and exactly one ingress Elastic IP.

```sh
terraform -chdir=provisioning/02-terraform output controlplane_api_public_ip
terraform -chdir=provisioning/02-terraform output control_node_private_ip
terraform -chdir=provisioning/02-terraform output login_node_public_ips
```

## 03 — Bootstrap Talos and render ingress hostnames

The playbook reads the ingress IP from Terraform and renders the public
hostnames. For a new cluster, explicitly enable the one-time etcd bootstrap
and kubeconfig retrieval.

```sh
ansible-playbook -i localhost, provisioning/03-bootstrap-talos/03-bootstrap-and-render.yml -e bootstrap_cluster=true
```

If the bootstrap request was sent and kubeconfig retrieval failed, confirm
bootstrap succeeded, then retry retrieval without sending another bootstrap
request.

```sh
ansible-playbook -i localhost, provisioning/03-bootstrap-talos/03-bootstrap-and-render.yml -e retrieve_kubeconfig=true
```

For an existing cluster or to render hostnames again, run without either flag.

```sh
ansible-playbook -i localhost, provisioning/03-bootstrap-talos/03-bootstrap-and-render.yml
```

**Check.** The play recap should show `failed=0`. After bootstrap, allow the
expected nodes time to reach `Ready` and verify the rendered hostname changes.

```sh
kubectl --kubeconfig provisioning/01-prepare-talos/generated/kubeconfig get nodes -o wide
git diff -- argocd/ingresses manifests/ingress charts/gen3/values charts/gen3-2025.08/values
```

Argo CD bootstrap, infrastructure, application, and ingress manifests are
under `argocd/`.

## 04 — Tear down the AWS cluster

This permanently deletes the infrastructure managed by the Terraform workspace,
including the EC2 nodes and their Terraform-managed storage and ingress IP.
After Terraform succeeds, the playbook releases the separately reserved
control-plane Elastic IP by its allocation ID.

Back up any data you need, then review the destroy plan from the repository root.
Use the same AWS account and region as stage `01`.

```sh
export AWS_REGION=us-east-1
terraform -chdir=provisioning/02-terraform init
terraform -chdir=provisioning/02-terraform plan -destroy
```

After reviewing the plan, explicitly confirm the teardown.

```sh
ansible-playbook -i localhost, provisioning/04-tear-down/04-tear-down.yml -e confirm_teardown=true
```

If provisioning stopped before Terraform wrote its outputs, export
`CONTROLPLANE_API_EIP_ALLOCATION_ID` for the reservation before running teardown.
If teardown fails after Terraform destroys the cluster, rerun the same command
from the same checkout. The playbook keeps the allocation ID locally until AWS
confirms the address is gone.

**Check.** Confirm the play recap reports `failed=0` and HCP Terraform shows no
managed resources in the workspace. The HCP workspace and its variable sets,
local generated configs, and AWS resources outside this workflow are retained.
