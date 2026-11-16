#  InviGrid — Private AWS EKS Cluster with AWS SSO, SSM Proxy & Namespace RBAC

![AWS EKS](https://img.shields.io/badge/AWS-EKS%20v1.36-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white)
![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?style=for-the-badge&logo=terraform&logoColor=white)
![AWS SSO](https://img.shields.io/badge/Auth-AWS%20IAM%20Identity%20Center-232F3E?style=for-the-badge&logo=amazonaws&logoColor=white)
![Kubernetes RBAC](https://img.shields.io/badge/Security-Kubernetes%20RBAC-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)

> 🎥 **Watch the Full Walkthrough & Live Demo on Loom:**  
> 👉 **[InviGrid Private EKS + AWS SSO + RBAC Demo Video](https://www.loom.com/share/da57ebff32bd4ba89bb8c243efe62c49)**  
> `https://www.loom.com/share/da57ebff32bd4ba89bb8c243efe62c49`

---

##  Project Overview

This project implements a **hardened, private-only Amazon EKS cluster** provisioned using **Terraform**, following the **`invigrid`** naming standard. It demonstrates enterprise-grade Kubernetes security by combining:

* **Zero Public API Exposure:** The EKS control plane is reachable only from inside the private VPC.
* **Zero-Trust Access Tunneling:** Users connect securely through **AWS Systems Manager (SSM) Session Manager**—eliminating public bastion hosts, open SSH ports, and static SSH keys.
* **Federated SSO Authentication:** All human access is governed by **AWS IAM Identity Center (AWS SSO)** with short-lived session credentials and zero long-lived IAM access keys.
* **Dual-Layer Least Privilege:** **AWS IAM** restricts cloud APIs per user, while **Kubernetes RBAC** enforces namespace-level isolation inside the cluster.

---

##  Architecture & Traffic Flow

All Kubernetes API traffic follows a strictly private, authenticated path from the user's local workstation to the cluster:

1. **Identity Verification:** The user signs in through **AWS IAM Identity Center (SSO)** via OIDC browser login to assume their assigned SSO permission set role.
2. **Encrypted Tunneling:** Using the **AWS Session Manager Plugin**, the workstation opens an encrypted port-forwarding tunnel (`localhost:8888`) to the private EC2 proxy (`invigrid-ssm-proxy`).
3. **Private Proxy Routing:** Inside the VPC, a lightweight Squid forward proxy on `invigrid-ssm-proxy` forwards HTTPS traffic (`TCP 443`) to the private **EKS API Server** (`invigrid-eks`) while preserving end-to-end TLS certificate verification.
4. **In-Cluster Authorization:** EKS validates the caller's SSO IAM Role via **EKS Access Entries**, maps the user to their Kubernetes identity/group, and enforces **Kubernetes RBAC** rules per namespace.

---

##  Infrastructure & Resources Created (`invigrid`)

All AWS infrastructure is managed declaratively via Terraform (`main.tf`) in the **Asia Pacific (Mumbai) — `ap-south-1`** region, while Kubernetes namespaces and permissions are defined in `rbac.yaml`.

| Layer | Resource Name | Configuration & Purpose |
| :--- | :--- | :--- |
| **Networking** | `invigrid-vpc` | Isolated VPC (`10.10.0.0/16`) spanning 2 Availability Zones with 2 private subnets, 2 public subnets, 1 NAT Gateway, and DNS hostnames/support enabled. |
| **Kubernetes Control Plane** | `invigrid-eks` | Amazon EKS `v1.36` with **private endpoint only** (`endpoint_public_access = false`) and modern `API` authentication mode. |
| **Compute Nodes** | `invigrid-ng` | Managed Node Group running `2 x t3.medium` (Amazon Linux 2023) worker nodes inside private subnets. |
| **Cluster Add-ons** | `vpc-cni`, `coredns`, `kube-proxy` | Core networking and DNS add-ons, with `vpc-cni` initialized prior to compute nodes so worker nodes join in a `Ready` state. |
| **Secure Proxy Host** | `invigrid-ssm-proxy` | Private `t3.micro` EC2 instance with **no public IP**, **no inbound Security Group rules**, **IMDSv2 enforced**, and Squid bound strictly to localhost (`127.0.0.1:8888`). |
| **Proxy IAM & Firewall** | `invigrid-ssm-proxy-role`, `invigrid-ssm-proxy-sg` | Grants `AmazonSSMManagedInstanceCore` for SSM connectivity and permits outbound `TCP 443` from the proxy SG to the EKS cluster Security Group. |
| **EKS Access Entries** | Admin & Dev SSO Bindings | Dynamically discovers `AWSReservedSSO_*` roles and maps Admin to `AmazonEKSClusterAdminPolicy` and Dev to Kubernetes group `invigrid-dev-group`. |
| **K8s Namespaces** | `invigrid-dev`, `invigrid-prod` | Logical environment separation with distinct RBAC boundaries. |

---

## 👤 AWS IAM Identity Center (SSO) Users & Setup

Rather than creating static IAM users with long-lived access keys, two dedicated users and permission sets were configured in **AWS IAM Identity Center (`ap-south-1`)** and assigned to AWS account `462881393228`:

| SSO Username | Permission Set | AWS-Level Permissions | EKS Access Mapping |
| :--- | :--- | :--- | :--- |
| **`invigrid-admin`** | `invigrid-eks-admin` | **`AdministratorAccess`** — Full AWS & Terraform lifecycle permissions plus SSM tunnel access. | Mapped to AWS-managed **`AmazonEKSClusterAdminPolicy`** at full cluster scope. |
| **`invigrid-dev-user`** | `invigrid-eks-dev` | **Custom Least-Privilege Policy** — Strictly limited to `eks:DescribeCluster`, `eks:ListClusters`, and `ssm:StartSession` / `TerminateSession` / `ResumeSession` for port-forwarding only. Cannot view or modify any AWS resources. | Mapped to Kubernetes identity **`invigrid-dev-user`** and group **`invigrid-dev-group`** (no cluster-admin policy). |

---

## 💻 Local Workstation Setup (Windows)

To interact with the private cluster securely from a local Windows workstation without exposing any public endpoints, the following setup was performed:

1. **Client Tools Installed:** Terraform (`>= 1.5.7`), AWS CLI v2, Kubernetes CLI (`kubectl`), and the **AWS Session Manager Plugin** (`Amazon.SessionManagerPlugin`).
2. **Isolated SSO Profiles:** Configured two separate local AWS CLI SSO profiles using distinct SSO session caches (`invigrid-sso` for Admin and `invigrid-user2-sso` for Dev, authenticated via an Incognito/InPrivate browser session to prevent credential bleed).
3. **SSM Port-Forwarding Session:** Established a persistent local SSM tunnel forwarding local port `8888` to the private `invigrid-ssm-proxy` instance.
4. **Dual `kubectl` Context Configuration:** Generated two separate Kubernetes contexts (`invigrid-eks-admin` and `invigrid-eks-dev`) with independent user aliases so switching contexts cleanly switches the underlying AWS SSO profile without overwriting credentials. Both contexts route cluster API traffic through the local `127.0.0.1:8888` proxy URL.

---

## 🛡️ Kubernetes RBAC & Permission Matrix

Kubernetes permissions are enforced inside `invigrid-eks` using namespace-scoped **`RoleBinding`** resources (`rbac.yaml`) linked to Kubernetes' built-in **`edit`** and **`view`** roles for `invigrid-dev-group`:

| Access Scope / Action | `invigrid-admin` | `invigrid-dev-user` |
| :--- | :---: | :---: |
| **Terraform & AWS Infrastructure Changes** | ✅ Full Access | ❌ Denied |
| **Open Private SSM Tunnel** | ✅ Allowed | ✅ Allowed (Least Privilege) |
| **Cluster-Wide Scope (`nodes`, `namespaces`, `RBAC`)** | ✅ Full Admin | ❌ Forbidden |
| **`invigrid-dev` — View & Manage Pods / Deployments / Services** | ✅ Full Access | ✅ Allowed (`edit` role) |
| **`invigrid-dev` — Modify RBAC or Delete Namespace** | ✅ Allowed | ❌ Forbidden |
| **`invigrid-prod` — View Pods / Deployments / Logs** | ✅ Full Access | ✅ Read-Only (`view` role) |
| **`invigrid-prod` — Create / Modify / Delete Workloads** | ✅ Allowed | ❌ Forbidden |
| **`invigrid-prod` — Read Secrets or Exec into Pods** | ✅ Allowed | ❌ Forbidden |
| **`kube-system` / `default` Namespaces** | ✅ Full Access | ❌ Forbidden |

---

##  Testing & Validation Summary

Both SSO identities were tested end-to-end through the live SSM tunnel to verify authentication, user switching, and RBAC enforcement:

### 1. Admin User Validation (`invigrid-admin` -> `invigrid-eks-admin`)
| Test Case | Expected Outcome | Observed Result |
| :--- | :--- | :--- |
| Verify AWS SSO identity | Returns `AWSReservedSSO_invigrid-eks-admin` role | ✅ **Passed** |
| List cluster worker nodes | Shows both `v1.36.5` nodes in `Ready` state | ✅ **Passed** |
| Deploy & delete pod in `invigrid-prod` | Pod deploys, runs, and deletes cleanly | ✅ **Passed** |
| Deploy & delete pod in `invigrid-dev` | Pod deploys, runs, and deletes cleanly | ✅ **Passed** |

### 2. Developer User Validation (`invigrid-dev-user` -> `invigrid-eks-dev`)
| Test Case | Expected Outcome | Observed Result |
| :--- | :--- | :--- |
| Verify AWS SSO identity | Returns `AWSReservedSSO_invigrid-eks-dev` role | ✅ **Passed** |
| Open independent SSM tunnel | Dev user starts SSM port-forward using least-privilege policy | ✅ **Passed** |
| Create, list, and delete pod in `invigrid-dev` | Pod enters `Running` state and deletes cleanly | ✅ **Passed** |
| List pods in `invigrid-prod` | Read-only listing succeeds | ✅ **Passed** |
| Create pod in `invigrid-prod` | Blocked by RBAC (`Forbidden`) | ✅ **Verified Blocked** |
| List secrets in `invigrid-prod` | Blocked by RBAC (`Forbidden`) | ✅ **Verified Blocked** |
| List pods in `kube-system` | Blocked by RBAC (`Forbidden`) | ✅ **Verified Blocked** |
| List cluster-level nodes | Blocked by RBAC (`Forbidden`) | ✅ **Verified Blocked** |

---

## 💡 Key Implementation Takeaways

* **Pre-Compute CNI Initialization:** Provisioning the `vpc-cni` add-on prior to the managed node group (`before_compute = true`) along with VPC DNS hostnames enabled ensures private worker nodes become `Ready` immediately on first boot.
* **Separate Kubeconfig User Aliases:** Separating both context and user aliases prevents multiple AWS SSO profiles on the same workstation from overwriting each other in the local Kubernetes configuration.
* **Preserving Proxy Routing:** Updating `kubeconfig` via AWS CLI resets the cluster endpoint block; re-attaching the local `proxy-url` ensures `kubectl` continues routing through the SSM tunnel rather than timing out against private VPC IPs.

---

