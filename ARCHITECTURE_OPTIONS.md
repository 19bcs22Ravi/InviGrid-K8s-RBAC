#  InviGrid — Architecture Options, Trade-Offs & Chosen Design

A concise comparison of architectural options for deploying a **private Amazon EKS cluster** with **secure user access**, **SSO authentication**, and **namespace-level RBAC**.

---

## 1. Network Access Options (Reaching a Private EKS API)

| Option | How It Works | Pros | Cons |
| :--- | :--- | :--- | :--- |
| **1. SSM Session Manager + Private Proxy EC2** ✅ *(Used)* | Private EC2 (`invigrid-ssm-proxy`) runs Squid on `127.0.0.1:8888`. Users open an encrypted SSM port-forward tunnel and point `kubectl` `proxy-url` to localhost. | • Zero public IPs or open inbound ports<br>• No SSH keys to manage<br>• Preserves per-user SSO identity & TLS verification<br>• Low cost (`t3.micro`) | • Requires local SSM Plugin & `proxy-url` in kubeconfig<br>• Single proxy EC2 unless scaled/ASG-backed |
| **2. AWS Client VPN / Site-to-Site VPN** | Encrypted VPN tunnel routes workstation traffic directly into VPC private subnets. | • Native `kubectl` (no proxy config)<br>• Direct access to all internal VPC apps/dashboards<br>• Enterprise-ready for large teams | • High fixed hourly + per-connection cost<br>• Complex PKI/certificates & private DNS setup<br>• Overkill for small teams/labs |
| **3. Public Bastion Host (SSH Jump Box)** | Public EC2 with port `22` open; users SSH tunnel or run `kubectl` directly from the bastion. | • Simple, familiar setup<br>• No SSM Plugin required | • Exposes SSH (`22`) to the internet<br>• SSH key rotation/management overhead<br>• Running `kubectl` on bastion shares EC2 IAM role (breaks per-user audit) |
| **4. Public EKS Endpoint + IP Allowlist** | EKS public endpoint enabled (`endpoint_public_access = true`) restricted to specific CIDR IPs. | • Zero proxy/VPN cost or maintenance<br>• Simplest `kubectl` experience | • Not a true private cluster (internet-facing API)<br>• Breaks frequently when user home/ISP IPs change |
| **5. GitOps / VPC CI Runners Only** | In-cluster agents (ArgoCD/Flux) or private CI runners deploy from Git; no direct user `kubectl`. | • Strongest production posture (no manual mutations)<br>• Full Git audit trail | • No interactive `kubectl` debugging (`logs`, `exec`) without pairing with SSM or VPN |

---

## 2. User Authentication Options (AWS Layer)

| Option | Pros | Cons |
| :--- | :--- | :--- |
| **1. AWS IAM Identity Center (SSO) + EKS Access Entries** ✅ *(Used)* | • Centralized user/group management<br>• Temporary short-lived credentials (no static keys)<br>• Native EKS API auth (no `aws-auth` ConfigMap editing) | • Requires IAM Identity Center setup<br>• Users must refresh expired SSO tokens periodically |
| **2. Standard IAM Users + `aws-auth` ConfigMap** | • No IAM Identity Center dependency | • Static access key security risk<br>• Manual `aws-auth` ConfigMap edits risk cluster lockout (legacy approach) |
| **3. Direct External OIDC (Okta / Azure AD to EKS)** | • Direct IdP group sync to Kubernetes without AWS IAM mapping | • Extra OIDC setup<br>• Still requires AWS IAM permissions separately if tunneling via SSM |

---

## 3. Authorization Options (Kubernetes Layer)

| Option | Pros | Cons |
| :--- | :--- | :--- |
| **1. EKS Access Entries + Native K8s RBAC (`RoleBinding`)** ✅ *(Used)* | • Fine-grained control per namespace (`edit` in dev, `view` in prod blocking Secrets)<br>• Standard, portable Kubernetes YAML | • RBAC manifests (`rbac.yaml`) managed separately from AWS Terraform infra |
| **2. EKS Managed Access Policies Only** | • Managed 100% inside Terraform AWS provider (`AmazonEKSEditPolicy` / `AmazonEKSViewPolicy`) | • Less granular than custom K8s Roles<br>• AWS-specific (not portable across K8s distros) |
| **3. Namespace-Scoped ClusterRoles / Custom Roles** | • Exact verb/resource control down to individual API objects | • Higher YAML maintenance overhead than built-in `edit` / `view` roles |

---

## 4. Infrastructure Provisioning Options

| Option | Pros | Cons |
| :--- | :--- | :--- |
| **1. Single Terraform `main.tf` (AWS) + `rbac.yaml` (K8s)** ✅ *(Used)* | • Clean separation between VPC/EKS creation and private API K8s setup<br>• Simple, single-state Terraform lifecycle | • Two-step apply (`terraform apply` -> SSM tunnel -> `kubectl apply`) |
| **2. Two-Stage Terraform (Infra State + K8s Provider State)** | • 100% Terraform-managed including namespaces/RBAC | • Requires SSM tunnel open before running stage-2 Terraform; extra state management |
| **3. AWS Console / `eksctl` CLI** | • Quick one-off setup | • Not easily reproducible or drift-checked like Terraform |

---

##  Final Architecture Selected (`InviGrid`)

* **Cluster & Network:** Private EKS `v1.36` (`invigrid-eks`) inside `invigrid-vpc` (`endpoint_public_access = false`, `vpc-cni` initialized pre-compute, NAT Gateway for private subnet egress).
* **Secure Access Path:** Private `t3.micro` EC2 (`invigrid-ssm-proxy`) running Squid (`127.0.0.1:8888`) accessed solely via **AWS SSM Session Manager** (zero inbound ports, zero SSH keys).
* **Authentication:** **AWS IAM Identity Center (SSO)** with two users (`invigrid-admin` & `invigrid-dev-user`) mapped via **EKS Access Entries**.
* **Authorization:**
  * **AWS Layer:** Admin has `AdministratorAccess`; Dev has least-privilege (`eks:DescribeCluster`, `eks:ListClusters`, `ssm:StartSession` only).
  * **Kubernetes Layer:** Admin has `AmazonEKSClusterAdminPolicy`; Dev (`invigrid-dev-group`) has **`edit`** in `invigrid-dev`, **`view` (read-only, no Secrets)** in `invigrid-prod`, and **no access** elsewhere.
* **Why This Won:** Delivers enterprise-grade zero-trust security, true private networking, per-user SSO auditing, and strict namespace RBAC at minimal cost (~`$0.01/hr` for the proxy EC2 vs. high VPN costs).