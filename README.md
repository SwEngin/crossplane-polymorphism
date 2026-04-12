# Crossplane Storage Polymorphism

Platform-level **ObjectStorage** abstraction powered by [Crossplane](https://www.crossplane.io/).  
One XRD contract, two implementations — consumers pick a backend with a single label selector.

| Backend | Composition | Protocol | Use case |
|---------|-------------|----------|----------|
| **Azure Blob Storage** | `objectstorage-azure` | `s3` (via S3Proxy) | Cloud workloads on Azure |
| **Ceph / Rook (on-prem)** | `objectstorage-ceph` | `s3` (native RGW) | On-prem / private cloud |

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │          XObjectStorage              │
                    │  crossplane.compositionRef:          │
                    │    name: objectstorage-azure         │
                    │         objectstorage-ceph           │
                    └──────────┬───────────────────────────┘
                               │
              ┌────────────────┴────────────────┐
              ▼                                 ▼
  ┌───────────────────────┐       ┌───────────────────────┐
  │  Composition: Azure   │       │  Composition: Ceph    │
  │  - Resource Group     │       │  - ObjectBucketClaim  │
  │  - Storage Account    │       │  - Config/Versioning  │
  │  - Blob Container     │       │    Job (optional)     │
  │  - S3Proxy Deployment │       │                       │
  │  - S3Proxy Service    │       │  platform-managed:    │
  └───────────────────────┘       │  CephObjectStore      │
              │                   │  StorageClasses       │
              │                   └───────────────────────┘
              │                                 │
              ▼                                 ▼
  ┌───────────────────────┐       ┌───────────────────────┐
  │  Unified Status       │       │  Unified Status       │
  │  endpoint: s3proxy:80 │       │  endpoint: rgw-<n>:80 │
  │  bucketName: ...      │       │  bucketName: ...      │
  │  protocol: s3         │       │  protocol: s3         │
  │  credentialsSecretRef │       │  credentialsSecretRef │
  └───────────────────────┘       └───────────────────────┘
              │                                 │
              └─────────┬───────────────────────┘
                        ▼
               App uses S3 SDK
              (one protocol everywhere)
```

---

## Quick Start

### 1. Install Crossplane

```bash
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace
```

### 2. Install Providers & Functions

```bash
kubectl apply -f providers/
kubectl apply -f functions/
```

Wait for providers and functions to become healthy:

```bash
kubectl get providers -w
kubectl get functions -w
```

### 3. Configure Provider Credentials

**Azure** — create a secret with your service principal credentials:

```bash
kubectl create secret generic azure-creds \
  -n crossplane-system \
  --from-file=credentials=./azure-credentials.json
```

Then apply the provider configs:

```bash
kubectl apply -f providers/configs/
```

### 4. Deploy the XRD + Compositions

```bash
kubectl apply -f apis/definition.yaml
kubectl apply -f compositions/azure/composition.yaml
kubectl apply -f compositions/ceph/composition.yaml
```

Verify the CRD was generated:

```bash
kubectl get crd xobjectstorages.swengin.io
```

### 5. Create an XObjectStorage

**Azure storage:**

```bash
kubectl apply -f examples/xobjectstorage-azure.yaml
```

**Ceph** (assumes platform-managed Rook installation):

```bash
# First ensure Rook platform is installed (see Ceph section below)
kubectl apply -f examples/xobjectstorage-ceph-existing.yaml
```

### 6. Check Status

```bash
kubectl get xobjectstorages -o wide
kubectl describe xobjectstorage team-data-azure
```

The status will contain:

```yaml
status:
  endpoint: "http://s3proxy-team-data-azure.crossplane-system.svc.cluster.local:80"  # Azure
  # or: "http://rook-ceph-rgw-team-data-ceph.rook-ceph.svc.cluster.local:80"         # Ceph
  bucketName: "team-data-azure"
  protocol: "s3"
  credentialsSecretRef:
    name: "..."
    namespace: "crossplane-system"
```

---

## XRD Contract: `XObjectStorage`

### Spec (input)

**Common fields**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `class` | `standard` \| `premium` | `standard` | Storage performance tier |
| `versioning` | boolean | `false` | Enable object versioning |
| `retentionDays` | integer | `0` | Days before objects expire (0 = disabled) |

**Azure fields** (`spec.azure.*`) — Optional

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `azure.region` | string | `germanywestcentral` | Azure region |
| `azure.createResourceGroup` | boolean | `true` | Create a new Resource Group |
| `azure.resourceGroupName` | string | — | Existing RG name (required when `createResourceGroup: false`) |
| `azure.s3Proxy` | boolean | `true` | Deploy S3Proxy in front of Azure Blob |
| `azure.accessMode` | `private` \| `public-read` | `private` | Blob container ACL |

**Ceph fields** (`spec.ceph.*`) — Optional

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `ceph.namespace` | string | `rook-ceph` | Namespace where the Rook-Ceph operator is installed |
| `ceph.objectStoreName` | string | — | Override the CephObjectStore name to target |

### Status (output)

| Field | Type | Description |
|-------|------|-------------|
| `endpoint` | string | Full endpoint URL |
| `bucketName` | string | Bucket or container name |
| `protocol` | `s3` \| `azure-blob` | Protocol for consumer SDK selection |
| `credentialsSecretRef` | `{name, namespace}` | K8s Secret with access credentials |
| `ready` | boolean | Fully provisioned and reachable |

### Credentials Secret

In Crossplane v2, XR-level `connectionSecretKeys` are removed. Instead, each
composition creates a Kubernetes Secret directly. The secret name is published
via `status.credentialsSecretRef`.

| Key | Description |
|-----|-------------|
| `endpoint` | Storage endpoint URL |
| `access-key-id` | Access key / account name |
| `secret-access-key` | Secret key / account key |
| `bucket-name` | Bucket or container name |
| `protocol` | `s3` or `azure-blob` |

---

## S3Proxy: Unified S3 API Across All Backends

By default, the Azure composition deploys [S3Proxy](https://github.com/gaul/s3proxy)
(Apache 2.0) — an open-source gateway that translates S3 API calls to Azure Blob Storage.

This means **every backend speaks S3**:

| Backend | Native protocol | With S3Proxy / RGW | Consumer sees |
|---------|----------------|---------------------|---------------|
| Azure Blob | Azure Blob REST | S3Proxy translates | `protocol: s3` |
| Ceph RGW | S3 (native) | n/a | `protocol: s3` |

### How it works

```
  App (any S3 SDK)
        │
        ▼
  s3proxy-<name>.crossplane-system.svc:80    ← ClusterIP Service
        │
        ▼
  S3Proxy container (andrewgaul/s3proxy)
  Translates: S3 API → Azure Blob REST API
        │
        ▼
  Azure Storage Account (Blob endpoint)
```

S3Proxy uses [JClouds](https://jclouds.apache.org/) `azureblob` provider under the hood.
The storage account name and access key are injected from the Crossplane connection secret.

### Disabling the proxy

If your app needs raw Azure Blob access (e.g., for Azure-native SDKs or AzCopy):

```yaml
spec:
  s3Proxy: false   # status.endpoint returns the native blob URL
                   # status.protocol returns "azure-blob"
```


## Ceph: Platform-Managed Installation

The Ceph composition assumes Rook operator and CephCluster are managed by the platform team
using Helm and dedicated platform resources. This separation ensures compositions focus on
tenant resources while platform infrastructure remains stable.

### Platform Prerequisites

**1. Install Rook Operator via Helm:**

```bash
helm repo add rook-release https://charts.rook.io/release
helm upgrade --install rook-ceph rook-release/rook-ceph \
  --namespace rook-ceph --create-namespace \
  --version v1.19.3 \
  --wait --timeout=5m
```

**2. Deploy CephCluster with admin APIs enabled:**


**3. Verify cluster health:**

```bash
kubectl get cephcluster -n rook-ceph -w
# Wait for HEALTH_OK or HEALTH_WARN status
```

### How ObjectBucketClaims Work

The composition assumes a platform-managed CephObjectStore and pre-existing StorageClasses
(`standard`, `premium`).
The [`ObjectBucketClaim`](https://rook.io/docs/rook/latest-release/Storage-Configuration/Object-Storage-RGW/ceph-object-bucket-claim/)
pattern is used: declare the claim, Rook provisions the bucket and creates credentials automatically.

**Flow:**
1. Platform team manages CephObjectStore + StorageClasses (`standard`/`premium`)
2. Composition waits for CephObjectStore phase=Ready, then creates an ObjectBucketClaim
3. Rook bucket provisioner creates bucket + Secret/ConfigMap with S3 credentials
4. Optional versioning/retention Job runs once OBC is Bound
