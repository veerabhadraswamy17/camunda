# Camunda 8.9 on Amazon ECS Fargate

*Console deployment guide for an AWS account with private subnets only*

This guide builds a full replica of the camunda-deployment-references reference architecture `aws/containers/ecs-single-region-fargate` (basic authentication) by hand in the AWS console: a 3-broker Orchestration Cluster on EFS, Aurora PostgreSQL with IAM database authentication, S3 node-ID and backup buckets, Connectors, an internal Application Load Balancer and ECS Service Connect.

It assumes an existing VPC with private subnets and no internet access, an existing ECS cluster, Camunda images already in ECR, and access to the private network from a corporate laptop. Settings are taken from the reference's root Terraform files and the modules `ecs/fargate/orchestration-cluster`, `ecs/fargate/connectors` and `aurora`.

### How to use this guide

- Anything specific to your environment is written as a `<PLACEHOLDER>`. Fill in the **deployment worksheet** (section 0.2) as you go: some values you know before starting, the rest appear at the step that creates them, marked **Record:**.
- The companion files (`taskdef-orchestration-cluster.json`, `taskdef-connectors.json`, `iam-execution-role-secrets-policy.json`, `iam-orchestration-task-policy.json`, `iam-connectors-task-policy.json`, `camunda-db-seed.sql`) use the same placeholders. Once the worksheet is complete, a find-and-replace across the folder (for example in VS Code: **Ctrl+Shift+H**) fills them all in one go. Before pasting a file into the console, search it for `<` to make sure nothing is left.
- Resource names use the prefix `camunda-poc` (Camunda components `camunda-poc-oc1`, mirroring the reference's `<prefix>-oc1`). To use another prefix, replace it consistently in the guide and all files; keep it short (target group names are limited to 32 characters).

## 0. Before you start

### 0.1 Order of work

| Step | What | Roughly |
|---|---|---|
| 1 | VPC endpoints (check, and add any that are missing) | 10 min + approval |
| 2 | Security groups | 15 min |
| 3 | Secrets Manager: admin and Connectors passwords | 5 min |
| 4 | S3 buckets: node-ID and backups | 5 min |
| 5 | Aurora PostgreSQL | 15 min + ~15 min wait |
| 6 | Create the IAM database user (from your laptop) | 10 min |
| 7 | EFS file system and access point | 10 min |
| 8 | CloudWatch log group | 2 min |
| 9 | IAM roles | 15 min |
| 10 | Cloud Map namespaces | 5 min |
| 11 | Task definitions | 10 min |
| 12 | Target groups and internal ALB | 15 min |
| 13 | ECS service: Orchestration Cluster | 10 min + ~10-15 min wait |
| 14 | ECS service: Connectors | 5 min + ~5 min wait |
| 15 | Verify from your laptop | 10 min |

### 0.2 Deployment worksheet

Fill in the **Value** column as you go.

| Placeholder | Value | Where it comes from | Step |
|---|---|---|---|
| `<ACCOUNT_ID>` |  | Account menu, top right of the console | Before |
| `<REGION>` |  | Region code, for example `eu-west-2` | Before |
| `<VPC_ID>` |  | VPC → Your VPCs | Before |
| `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>` |  | VPC → Subnets, filtered by the VPC: one private subnet per AZ with the most **Available IPv4 addresses** (at least ~15 free each) | Before |
| `<CORP_CIDR>` |  | Network range your laptop's traffic arrives from (network team, or the inbound rules of another internal load balancer) | Before |
| `<ECS_CLUSTER>` |  | ECS → Clusters | Before |
| `<CAMUNDA_IMAGE>` |  | ECR → repository → image → **URI** (Camunda 8.9.x) | Before |
| `<CONNECTORS_IMAGE>` |  | ECR → image **URI** (Connectors bundle, same 8.9 minor) | Before |
| `<ENDPOINT_SG>` |  | Security group of the existing interface endpoints | 1 |
| `<ADMIN_SECRET_ARN>` |  | Secrets Manager | 3 |
| `<CONNECTORS_SECRET_ARN>` |  | Secrets Manager | 3 |
| `<WRITER_ENDPOINT>` |  | RDS → cluster → Connectivity & security (Writer) | 5 |
| `<CLUSTER_RESOURCE_ID>` |  | RDS → cluster → Configuration → Resource ID (`cluster-…`) | 5 |
| `<FS_ID>` |  | EFS file system ID (`fs-…`) | 7 |
| `<FSAP_ID>` |  | EFS access point ID (`fsap-…`) | 7 |
| `<ALB_DNS>` |  | EC2 → Load balancers → DNS name | 12 |

### 0.3 Checks

- **Images:** Camunda and Connectors should share the same 8.9 minor version. The reference was tested with `camunda/camunda:8.9.16` and `camunda/connectors-bundle:8.9.7`; Amazon ECS support and Aurora as secondary storage arrived with the 8.9 minor release.
- **VPC DNS:** VPC → Your VPCs → your VPC: **DNS resolution** and **DNS hostnames** must both be **Enabled** (needed for endpoint private DNS and the Cloud Map DNS namespace).
- **Organisation guardrails:** mandatory tags, IAM permission boundaries or naming rules. If a create fails with an access-denied error naming a service control policy, check with the platform team.
- **Shared cluster capacity providers:** if the ECS cluster has a default capacity provider strategy, choose **Launch type: FARGATE** explicitly when creating services (steps 13 and 14).

## 1. VPC endpoints

With no internet route, every AWS service the tasks call must be reachable through a VPC endpoint in the same VPC.

### 1.1 Check what exists

**VPC → Endpoints**, filter by `<VPC_ID>` (without the filter the list includes other VPCs' endpoints).

| Service name | Type | Needed for | Present? |
|---|---|---|---|
| `com.amazonaws.<REGION>.ecr.api` | Interface | Pulling images from ECR |  |
| `com.amazonaws.<REGION>.ecr.dkr` | Interface | Pulling images from ECR |  |
| `com.amazonaws.<REGION>.s3` | **Gateway**, on the private subnets' route table | ECR image layers, node-ID bucket, backups |  |
| `com.amazonaws.<REGION>.logs` | Interface | Container logs |  |
| `com.amazonaws.<REGION>.secretsmanager` | Interface | Passwords injected into tasks |  |
| `com.amazonaws.<REGION>.ecs` | Interface | Service Connect |  |
| `com.amazonaws.<REGION>.ecs-agent` | Interface | Service Connect (Envoy proxy management) |  |
| `com.amazonaws.<REGION>.ecs-telemetry` | Interface | Service Connect |  |
| `com.amazonaws.<REGION>.kms` | Interface | Only if you use customer-managed KMS keys (not needed with the AWS-managed keys in this guide) |  |

For the existing interface endpoints, check on the **Details** tab that **Private DNS names enabled** is **Yes**, and on the **Security groups** tab that the group allows **inbound TCP 443** from the private subnets (or from `camunda-poc-tasks` once it exists).

> **Record:** the security group used by the existing interface endpoints → `<ENDPOINT_SG>`.

For the S3 gateway endpoint, open its **Policy** tab. If it isn't *Full access* and lists specific buckets, the two Camunda buckets from step 4 must be allowed as well, or node-ID assignment and backups fail with Access Denied.

### 1.2 Why the three ECS endpoints matter

The brokers find each other through ECS Service Connect (`CAMUNDA_CLUSTER_INITIALCONTACTPOINTS=orchestration-cluster-sc:26502`), and Connectors reach the cluster the same way. AWS documents that Service Connect's Envoy proxy is managed through the `ecs-agent` endpoint, and that `ecs`, `ecs-agent` and `ecs-telemetry` should exist together; otherwise traffic falls back to public endpoints, which are unreachable without internet. Without them the cluster won't form.

> **Important:** If the ECS cluster is shared, tell its owners before adding ECS endpoints. AWS notes that EC2 container instances only pick up new ECS endpoints after the ECS agent is restarted. Fargate tasks are not affected.

### 1.3 Create a missing interface endpoint

For each missing interface endpoint (typically `ecs-agent` and `ecs-telemetry`):

1. **VPC → Endpoints → Create endpoint**.
2. Name tag: the service's short name, for example `ecs-agent`. Type: **AWS services**.
3. Services: search the short name and select `com.amazonaws.<REGION>.<service>` (Type: Interface).
4. Network settings: VPC `<VPC_ID>`. Expand **Additional settings** and tick **Enable DNS name**. DNS record IP type: IPv4.
5. Subnets: one per AZ, preferably the same subnets as the existing interface endpoints. IP address type: IPv4.
6. Security groups: `<ENDPOINT_SG>`.
7. Policy: **Full access** (or the organisation's standard endpoint policy).
8. **Create endpoint** and wait for Status **Available**.

### 1.4 Verify

Each new endpoint shows **Private DNS names enabled: Yes**. For the ECS endpoints, AWS states the private DNS names are `ecs-a.<REGION>.amazonaws.com` (agent) and `ecs-t.<REGION>.amazonaws.com` (telemetry).

> **Tip:** If creation fails because a private DNS name conflicts, the organisation probably manages AWS service DNS centrally (shared Route 53 private hosted zones). Ask the platform team to add the records for this VPC instead.

## 2. Security groups

The Terraform opens Camunda ports to the whole VPC CIDR. In a shared VPC (possibly with several CIDR blocks) it is tighter and simpler to reference security groups instead. Ports come from `variables.tf` (`var.ports`, basic mode).

### 2.1 Create four empty groups

**EC2 → Security Groups → Create security group**, VPC `<VPC_ID>`, no inbound rules, keep the default outbound rule (all traffic; with no internet route it only reaches VPC resources and endpoints).

| Name | Description |
|---|---|
| `camunda-poc-tasks` | Camunda orchestration and connectors tasks |
| `camunda-poc-efs` | Camunda EFS |
| `camunda-poc-aurora` | Camunda Aurora PostgreSQL |
| `camunda-poc-alb` | Camunda internal load balancer |

### 2.2 Inbound rules

Open each group → **Inbound rules → Edit inbound rules**. Type **Custom TCP**; for a group source choose **Custom** and type `camunda-poc` to pick it.

| Group | Port | Source | Purpose |
|---|---|---|---|
| `camunda-poc-tasks` | 8080 | `camunda-poc-tasks` | REST between tasks (Connectors → cluster) |
| `camunda-poc-tasks` | 9600 | `camunda-poc-tasks` | Management |
| `camunda-poc-tasks` | 26500 | `camunda-poc-tasks` | gRPC gateway |
| `camunda-poc-tasks` | 26501 | `camunda-poc-tasks` | Broker command API |
| `camunda-poc-tasks` | 26502 | `camunda-poc-tasks` | Cluster communication |
| `camunda-poc-tasks` | 8080 | `camunda-poc-alb` | Load balancer traffic; Connectors health check |
| `camunda-poc-tasks` | 9600 | `camunda-poc-alb` | Cluster health check (the target group checks readiness on 9600) |
| `camunda-poc-efs` | 2049 | `camunda-poc-tasks` | NFS |
| `camunda-poc-aurora` | 5432 | `camunda-poc-tasks` | Database |
| `camunda-poc-aurora` | 5432 | `<CORP_CIDR>` | Temporary, for step 6 only |
| `camunda-poc-alb` | 80 | `<CORP_CIDR>` | Browser and API access from your laptop |

If `<ENDPOINT_SG>` only allows specific sources, add an inbound **443** rule from `camunda-poc-tasks` to it.

## 3. Secrets Manager

The cluster creates two built-in users at startup (`camunda.tf`, basic mode): `admin` and `connectors`. Their passwords are injected as task secrets. Terraform stores each as a plain string.

1. **Secrets Manager → Store a new secret → Other type of secret**.
2. Choose the **Plaintext** tab, delete the `{}`, and paste a password on its own (no quotes, no JSON). Use 24+ characters of letters and digits; Terraform's generator also allowed `!#$%^()-_=+[]{}:?`. Avoid spaces and quote characters.
3. Encryption key: `aws/secretsmanager`. **Next**.
4. Secret name: `camunda-poc-oc1-admin-user-password`. **Next**, no rotation, **Store**.
5. Open the secret and copy the full **Secret ARN**.
6. Repeat with name `camunda-poc-oc1-connectors-client-auth-password`.

> **Record:** the two secret ARNs → `<ADMIN_SECRET_ARN>` and `<CONNECTORS_SECRET_ARN>`.

> **Important:** The ARN ends in a random 6-character suffix (for example `…-password-Ab12Cd`). Copy the full ARN; the name alone does not work in the task definition or the IAM policy.

## 4. S3 buckets

Bucket names are global, so they include the account ID. **S3 → Create bucket**, region `<REGION>`, **Block all public access** on (default).

| Bucket name | Purpose | Settings |
|---|---|---|
| `camunda-poc-oc1-bucket-<ACCOUNT_ID>` | Node-ID provider: brokers lease their node IDs here | Versioning **Disable** (the module notes frequent metadata changes would add cost with no benefit). Encryption: SSE-S3 |
| `camunda-poc-backup-bucket-<ACCOUNT_ID>` | Camunda backups | Versioning **Enable** (`s3.tf`). Encryption: SSE-S3 |

Terraform encrypts both buckets with customer-managed KMS keys. SSE-S3 keeps the IAM policies simpler for a PoC. If the organisation requires SSE-KMS, use customer-managed keys, add `kms:Decrypt`, `kms:Encrypt`, `kms:GenerateDataKey` and `kms:DescribeKey` on those keys to the Orchestration Cluster task policy (with condition `kms:ViaService = s3.<REGION>.amazonaws.com`, as in the reference), and make sure the `kms` endpoint exists.

## 5. Aurora PostgreSQL

### 5.1 DB subnet group

**RDS → Subnet groups → Create DB subnet group**: name `camunda-poc-camunda-db-cluster`, description `Camunda Aurora`, VPC `<VPC_ID>`, Availability Zones the three AZs, subnets `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>`.

### 5.2 Create the cluster

**RDS → Databases → Create database**. Values from `postgres.tf`, `variables.tf` and `modules/aurora`.

| Console setting | Value | Source |
|---|---|---|
| Creation method | Standard create |  |
| Engine type | Aurora (PostgreSQL Compatible) | `engine = aurora-postgresql` |
| Engine version | **Aurora PostgreSQL 17.9** | `postgres.tf` in your plan |
| Templates | Dev/Test |  |
| DB cluster identifier | `camunda-poc-camunda-db-cluster` | `cluster_name` |
| Master username | `camunda_admin` | `db_admin_username` |
| Credentials management | **Managed in AWS Secrets Manager**, key `aws/secretsmanager` | You read it once in step 6 |
| Cluster storage configuration | Aurora Standard |  |
| DB instance class | Burstable classes → `db.t3.medium` | `instance_class` |
| Multi-AZ deployment | Don't create an Aurora Replica | `num_instances = 1` |
| Compute resource | Don't connect to an EC2 compute resource |  |
| VPC / DB subnet group | `<VPC_ID>` / `camunda-poc-camunda-db-cluster` |  |
| Public access | No |  |
| VPC security group | Choose existing: `camunda-poc-aurora` (remove `default`) |  |
| Certificate authority | `rds-ca-rsa2048-g1` | `ca_cert_identifier` |
| Database port | 5432 |  |
| Database authentication | **Password and IAM database authentication** | `iam_auth_enabled = true` (required) |
| Monitoring | Defaults (Database Insights Standard is fine) |  |
| Additional configuration → Initial database name | `camunda` | `db_name` |
| Encryption | Enabled, key `aws/rds` | `storage_encrypted = true` |
| Auto minor version upgrade | Off | `auto_minor_version_upgrade = false` |
| Deletion protection | Off (PoC) | `skip_final_snapshot = true` |

> **Important:** IAM database authentication must be on and the initial database must be named `camunda`. The Orchestration Cluster connects with `jdbc:aws-wrapper:postgresql://…/camunda?wrapperPlugins=iam`; without IAM auth it fails at startup with an authentication error that doesn't name the cause.

### 5.3 Record the outputs

When the cluster status is **Available** (about 10–15 minutes):

- **Connectivity & security** tab: the endpoint of type **Writer** → `<WRITER_ENDPOINT>` (looks like `camunda-poc-camunda-db-cluster.cluster-xxxx.<REGION>.rds.amazonaws.com`).
- **Configuration** tab: **Resource ID** (starts with `cluster-`) → `<CLUSTER_RESOURCE_ID>`. This is not the cluster name.

> **Record:** `<WRITER_ENDPOINT>` and `<CLUSTER_RESOURCE_ID>`.

## 6. Create the IAM database user

The cluster connects as database user `camunda` using an IAM token, so that role must exist and hold `rds_iam`. Terraform does this with a one-off ECS task running a public `postgres` image, which can't be pulled here. Run the same SQL from your laptop instead (file `camunda-db-seed.sql`).

### 6.1 Get the master password

**RDS → camunda-poc-camunda-db-cluster → Configuration**: under **Master credentials ARN**, click **Manage in Secrets Manager** → **Retrieve secret value** → copy `password`.

### 6.2 Connect

Use any PostgreSQL client available on the corporate laptop. Connection settings: host `<WRITER_ENDPOINT>`, port `5432`, database `camunda`, user `camunda_admin`, the password from 6.1, **SSL mode: require**.

- **psql:** `psql "host=<WRITER_ENDPOINT> port=5432 dbname=camunda user=camunda_admin sslmode=require"`
- **DBeaver or pgAdmin:** create a PostgreSQL connection with the values above; on the SSL tab set mode to **require**.

### 6.3 Run the SQL

```
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'camunda') THEN
    CREATE ROLE "camunda" WITH LOGIN;
  END IF;
END $$;
ALTER ROLE "camunda" WITH LOGIN;
GRANT rds_iam TO "camunda";
GRANT ALL PRIVILEGES ON DATABASE "camunda" TO "camunda";
GRANT USAGE, CREATE ON SCHEMA public TO "camunda";

SELECT pg_has_role('camunda', 'rds_iam', 'member') AS has_rds_iam;  -- expect: true
```

Then delete the temporary `<CORP_CIDR>` rule on port 5432 from `camunda-poc-aurora`.

> **Tip:** If the laptop can't reach port 5432 (corporate firewall), the fallback is a one-off Fargate task running a `postgres` client image. Push or mirror a `postgres:17-alpine` image into ECR and run the SQL from step 6.3 with `psql` in a Fargate task in the private subnets, security group `camunda-poc-tasks`, with the master password injected as a secret (as the reference's `postgres_seed.tf` does).

## 7. EFS

All broker tasks share one encrypted EFS file system, mounted through an access point with IAM authorization (`modules/ecs/fargate/orchestration-cluster/efs.tf` and `ecs.tf`).

### 7.1 File system

**EFS → Create file system → Customize**:

| Setting | Value | Source |
|---|---|---|
| Name | `camunda-poc-oc1-efs` |  |
| File system type | Regional |  |
| Automatic backups | Off for the PoC (on is fine too) | Not set by the module |
| Lifecycle management | Transition into IA: **None**; into Archive: **None** | Not set by the module |
| Encryption | Enabled, key `aws/elasticfilesystem` | `encrypted = true` |
| Throughput mode | Enhanced → **Elastic** | `efs_throughput_mode = elastic` |
| Performance mode | **General Purpose** | `efs_performance_mode` |
| Network → VPC | `<VPC_ID>` |  |
| Mount targets | `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>` (one per AZ); security group `camunda-poc-efs` on each (remove `default`) | One per private subnet |
| File system policy | Leave empty; don't tick any options | Module sets none |

**Create**.

> **Record:** the file system ID → `<FS_ID>` (`fs-…`).

### 7.2 Access point

Open the file system → **Access points → Create access point**:

| Setting | Value |
|---|---|
| Name | `camunda-poc-oc1-camunda-data-access-point` |
| Root directory path | `/usr/local/camunda/data` |
| POSIX user: User ID / Group ID | `1000` / `1000` |
| Root directory creation permissions: Owner user ID / Owner group ID / Permissions | `1000` / `1000` / `755` |

**Create**. The 1000 values must be exact: Camunda writes its data as that user.

> **Record:** the access point ID → `<FSAP_ID>` (`fsap-…`).

## 8. CloudWatch log group

**CloudWatch → Log groups → Create log group**: name `/ecs/camunda-poc-oc1-camunda`, retention **30 days** (`cloudwatch_retention_days`). Connectors log into the same group (`log_group_name = module.orchestration_cluster.log_group_name`).

## 9. IAM roles

All three roles are created the same way: **IAM → Roles → Create role → Trusted entity type: AWS service → Use case: Elastic Container Service → Elastic Container Service Task**. This sets the trust principal `ecs-tasks.amazonaws.com`, as in the Terraform. Add any permission boundary or tags the organisation requires.

To add an inline policy afterwards: open the role → **Permissions → Add permissions → Create inline policy → JSON**, paste the file's contents with placeholders replaced, **Next**, give it a name, **Create policy**.

### 9.1 Task execution role

- Role name: `camunda-poc-ecs-task-execution-role`.
- On the **Add permissions** page attach AWS managed policy `AmazonECSTaskExecutionRolePolicy` (ECR pulls and log writes).
- Inline policy `camunda-poc-ecs-task-secrets` from `iam-execution-role-secrets-policy.json`, replacing `<ADMIN_SECRET_ARN>` and `<CONNECTORS_SECRET_ARN>`.

### 9.2 Orchestration Cluster task role

- Role name: `camunda-poc-oc1-orchestration-task-role`. No managed policies.
- Inline policy `camunda-poc-oc1-orchestration-task-policy` from `iam-orchestration-task-policy.json`, replacing `<FS_ID>` (4 places) and `<CLUSTER_RESOURCE_ID>`.

That one policy combines everything Terraform attaches to this role: the module's EFS policy (mount with IAM authorization), its node-ID bucket policy, its logs policy, plus `rds_db_connect_camunda` and `s3_backup_access_policy` from the root files. The module's ECS Exec (`ssmmessages`) policy is left out because Exec is off by default (`task_enable_execute_command = false`) and there's no `ssmmessages` endpoint.

### 9.3 Connectors task role

- Role name: `camunda-poc-oc1-connectors-task-role`. No managed policies.
- Inline policy `camunda-poc-oc1-connectors-task-policy` from `iam-connectors-task-policy.json` (logs only; no placeholders).

## 10. Cloud Map namespaces

The orchestration module creates two namespaces (`dns.tf`).

### 10.1 Service Connect namespace (required)

**AWS Cloud Map → Namespaces → Create namespace**: name `camunda-poc-oc1-sc`, description `Service Connect namespace for Camunda`, instance discovery **API calls**. Create.

### 10.2 DNS namespace (for parity with the reference)

**Create namespace** again: name `camunda-poc-oc1.service.local`, instance discovery **API calls and DNS queries in VPCs**, VPC `<VPC_ID>`. Create.

The module registers the brokers here as `orchestration-cluster.camunda-poc-oc1.service.local` (A records, TTL 10, multivalue). Nothing in the configuration reads this name (the contact points use Service Connect), so it's useful only for debugging. If creating a private hosted zone is restricted in your account, skip 10.2 and the **Service discovery** part of step 13.

## 11. Task definitions

### 11.1 Fill in the JSON files

| File | Replace |
|---|---|
| `taskdef-orchestration-cluster.json` | `<WRITER_ENDPOINT>`, `<ADMIN_SECRET_ARN>`, `<CONNECTORS_SECRET_ARN>`, `<FS_ID>`, `<FSAP_ID>` |
| `taskdef-connectors.json` | `<CONNECTORS_SECRET_ARN>` |

These come on top of `<ACCOUNT_ID>`, `<REGION>`, `<CAMUNDA_IMAGE>` and `<CONNECTORS_IMAGE>`, which appear in role ARNs, image URIs, bucket names and the log configuration. Search each file for `<` afterwards to confirm nothing is left.

### 11.2 What the Orchestration Cluster definition contains

- Family `camunda-poc-oc1-orchestration-cluster`, Fargate, Linux X86_64, 4 vCPU / 8 GB (module defaults).
- Container `orchestration-cluster` with ports 26500 (`grpc`), 26501, 26502 (`internal-api`), 9600 (`management`), 8080 (`rest`). The port names must stay as they are; Service Connect refers to them.
- Health check: `wget` on `localhost:9600/actuator/health/liveness`, start period 120 s.
- EFS volume `camunda-volume` mounted at `/usr/local/camunda/data`, transit encryption and IAM authorization on, through the access point.
- The module's environment (shutdown timeout, data directory, contact points `orchestration-cluster-sc:26502`, cluster size 3, S3 node-ID provider with 15 s lease) plus the root `camunda.tf` environment (replication factor 3, 3 partitions, RDBMS secondary storage, basic-auth users, S3 backups).

### 11.3 Register both

1. **ECS → Task definitions → Create new task definition → Create new task definition with JSON**.
2. Select all in the editor, paste the filled-in `taskdef-orchestration-cluster.json`, **Create**.
3. Repeat with `taskdef-connectors.json`.

The Connectors definition sets `SERVER_SERVLET_CONTEXT_PATH=/connectors` (so it can share the load balancer) and points at `http://orchestration-cluster-rest:8080` and `http://orchestration-cluster-grpc:26500`, which are the Service Connect names created in step 13.

## 12. Target groups and internal load balancer

Values from the modules' `lb.tf`. The reference ALB is internet-facing; here it is **internal**, in the private subnets, reached from the corporate network.

### 12.1 Orchestration Cluster target group

**EC2 → Target groups → Create target group**:

| Setting | Value |
|---|---|
| Target type | **IP addresses** |
| Name | `camunda-poc-oc1-orc-tg-8080` |
| Protocol : Port | HTTP : 8080 |
| VPC / Protocol version | `<VPC_ID>` / HTTP1 |
| Health check protocol / path | HTTP / `/actuator/health/readiness` |
| Advanced → Health check port | **Override: 9600** |
| Healthy / unhealthy threshold | 2 / 2 |
| Timeout / interval / success codes | 5 s / 30 s / 200 |

**Next**, register no targets (ECS does it), **Create**. Then open it → **Attributes → Edit**: deregistration delay **30** seconds; **Stickiness** on, type **Load balancer generated cookie**, duration **12 hours**. Save.

### 12.2 Connectors target group

Same as 12.1 except: name `camunda-poc-oc1-con-tg-8080`, health check path `/connectors/actuator/health/readiness`, health check port **Traffic port** (8080). Same attributes: deregistration delay 30, stickiness 12 hours.

### 12.3 Internal Application Load Balancer

**EC2 → Load balancers → Create load balancer → Application Load Balancer**:

| Setting | Value |
|---|---|
| Name | `camunda-poc-alb` |
| Scheme | **Internal** |
| IP address type | IPv4 |
| VPC / Mappings | `<VPC_ID>`; `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>` (one per AZ) |
| Security groups | `camunda-poc-alb` only (remove `default`) |
| Listener | HTTP : 80, default action **Forward to** `camunda-poc-oc1-orc-tg-8080` |

After it is created: **Listeners → HTTP:80 → Manage rules → Add rule**: name `connectors`, condition **Path** = `/connectors*`, action **Forward to** `camunda-poc-oc1-con-tg-8080`, priority **50** (the module's value). Everything else falls through to the default action and reaches the Orchestration Cluster, as the reference's `/*` rule does.

The load balancer's DNS name (`internal-camunda-poc-alb-….<REGION>.elb.amazonaws.com`) resolves to private IPs, which is what your laptop connects to.

> **Record:** the load balancer DNS name → `<ALB_DNS>`.

> **Tip:** The reference uses plain HTTP on port 80. For HTTPS, add a 443 listener with a certificate from ACM (often from a private CA in corporate environments) and an inbound 443 rule on `camunda-poc-alb`. The reference's gRPC NLB is left out: the REST API covers UI, API and deployments. If you need gRPC from outside the VPC, add an internal Network Load Balancer with a TCP 26500 listener and a TCP target group (health check HTTP `/actuator/health/readiness` on port 9600), and attach it to the Orchestration Cluster service.

## 13. ECS service: Orchestration Cluster

**ECS → Clusters → `<ECS_CLUSTER>` → Services → Create**. Values from `aws_ecs_service.orchestration_cluster` in the module.

| Console section | Setting |
|---|---|
| Compute configuration | Compute options: **Launch type**; Launch type **FARGATE**; Platform version **LATEST** |
| Deployment configuration | Task definition family `camunda-poc-oc1-orchestration-cluster`, latest revision; service name `camunda-poc-oc1-orchestration-cluster`; scheduling strategy **Replica**; desired tasks **3**; Availability Zone rebalancing **off**; health check grace period **900** seconds |
| Deployment options | Rolling update; Min running tasks **66**%; Max running tasks **100**%; Deployment circuit breaker **off** |
| Service Connect | **Turn on**; **Client and server**; namespace `camunda-poc-oc1-sc`. Add the three port mappings below |
| Service discovery (if you did 10.2) | Use service discovery; namespace `camunda-poc-oc1.service.local`; create new service discovery service named `orchestration-cluster`; DNS record type **A**; TTL **10** |
| Networking | VPC `<VPC_ID>`; subnets `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>`; security group `camunda-poc-tasks` only; Public IP **off** |
| Load balancing | Use load balancing; **Application Load Balancer**; container `orchestration-cluster 8080:8080`; use an existing load balancer `camunda-poc-alb`; use existing listener **80:HTTP**; use existing target group `camunda-poc-oc1-orc-tg-8080` |

**Service Connect port mappings** (each row: Port alias, Discovery name, DNS, Port):

| Port alias | Discovery name | DNS | Port |
|---|---|---|---|
| `grpc` | `orchestration-cluster-grpc` | `orchestration-cluster-grpc` | 26500 |
| `internal-api` | `orchestration-cluster-sc` | `orchestration-cluster-sc` | 26502 |
| `rest` | `orchestration-cluster-rest` | `orchestration-cluster-rest` | 8080 |

> **Important:** These names must match exactly. `orchestration-cluster-sc:26502` is how brokers find each other; `orchestration-cluster-rest` and `orchestration-cluster-grpc` are how Connectors reach the cluster.

**Create**. Then check **EC2 → Load balancers → camunda-poc-alb → Listeners → HTTP:80 → Rules**: only the default action and the `/connectors*` rule should exist. Delete any rule the console added.

### 13.1 What to expect

Each broker starts, leases a node ID in the S3 bucket, mounts EFS, finds the others through Service Connect, and only then reports ready. The minimum of 66% keeps 2 of 3 brokers up during later deployments so the cluster keeps quorum. Allow 10–15 minutes until the service shows **3/3 tasks running** and all three targets in `camunda-poc-oc1-orc-tg-8080` are **healthy**. Watch progress in the log group `/ecs/camunda-poc-oc1-camunda` (streams `orchestration-cluster/…`).

## 14. ECS service: Connectors

Create after the cluster is healthy. Values from `aws_ecs_service.connectors`.

| Console section | Setting |
|---|---|
| Compute configuration | Launch type **FARGATE**, platform **LATEST** |
| Deployment configuration | Family `camunda-poc-oc1-connectors`; service name `camunda-poc-oc1-connectors`; Replica; desired tasks **1**; health check grace period **300** seconds |
| Deployment options | Rolling update; Min **50**%; Max **200**%; circuit breaker off |
| Service Connect | **Turn on**; **Client side only**; namespace `camunda-poc-oc1-sc` |
| Service discovery | Off |
| Networking | Same VPC and subnets; security group `camunda-poc-tasks`; Public IP off |
| Load balancing | ALB `camunda-poc-alb`, existing listener 80:HTTP, existing target group `camunda-poc-oc1-con-tg-8080`, container `connectors 8080:8080` |

Wait for 1/1 tasks running and the target healthy (about 5 minutes).

## 15. Verify from your laptop

1. **Browser:** `http://<ALB_DNS>/` shows the Camunda login. Sign in as **admin** with the value of `camunda-poc-oc1-admin-user-password` (Secrets Manager → Retrieve secret value).
2. **Connectors:** `http://<ALB_DNS>/connectors/actuator/health/readiness` returns status `UP`.
3. **Cluster topology** (PowerShell; use `curl.exe`, because plain `curl` is an alias in PowerShell):

```
curl.exe -s -u "admin:<admin password>" http://<ALB_DNS>/v2/topology
```

A healthy result lists 3 brokers, cluster size 3, partitions count 3, replication factor 3, with every partition healthy.

- **S3:** `camunda-poc-oc1-bucket-<ACCOUNT_ID>` contains node-ID lease objects.
- **Logs:** no repeating errors in `/ecs/camunda-poc-oc1-camunda`.

## 16. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Task stops with `CannotPullContainerError` | Image URI typo; S3 gateway endpoint policy blocks the ECR layer bucket; execution role missing `AmazonECSTaskExecutionRolePolicy` | Image URI in the task definition; S3 gateway endpoint policy (1.1); role 9.1 |
| `ResourceInitializationError` … secrets | Execution role can't read a secret; wrong ARN (missing suffix) | Inline policy 9.1; ARNs in the task definition |
| `ResourceInitializationError` … logs | Log group missing or misnamed | Step 8 name is exactly `/ecs/camunda-poc-oc1-camunda` |
| `ResourceInitializationError` … EFS / mount | Port 2049 blocked; mount target missing in a subnet; task role lacks `ClientMount`/`ClientWrite`; wrong `<FS_ID>`/`<FSAP_ID>` | Step 2 rules; step 7 mount targets; policy 9.2 |
| Tasks start but never become healthy; logs show no peers | Service Connect not working: `ecs-agent`/`ecs-telemetry` endpoints missing or private DNS off; port names or discovery names wrong | Step 1; step 13 table; ports 26501/26502 self-rules |
| Log errors about the node-ID bucket (Access Denied) | Task role or S3 endpoint policy | Policy 9.2; S3 gateway endpoint policy (1.1) |
| Log errors: database authentication failed | Step 6 not done; IAM auth off; wrong Resource ID in `rds-db:connect`; database not named `camunda` | `pg_has_role` check; step 5.2; policy 9.2 |
| Connectors log connection refused / unknown host | Cluster not healthy yet; Service Connect not enabled as client on Connectors | Step 13 health; step 14 Service Connect |
| Browser times out | `camunda-poc-alb` lacks inbound 80 from the right range; corporate routing to these subnets | `<CORP_CIDR>`; try from another resource in the VPC |
| ALB returns 502/503 | Targets unhealthy; missing 9600 rule from ALB SG to tasks SG | Target group health tab; step 2 rules |

## 17. Cost and teardown

Running costs come mainly from 3 × (4 vCPU, 8 GB) plus 1 × (2 vCPU, 4 GB) Fargate tasks, the Aurora `db.t3.medium` instance, the ALB and the two new interface endpoints (charged per AZ-hour). Scale both services to 0 when not in use; Aurora can be stopped for up to 7 days at a time.

Teardown, in this order:

1. Connectors service, then the Orchestration Cluster service: update desired tasks to 0, then delete.
2. Deregister both task definitions.
3. Delete the load balancer, then both target groups.
4. Delete the EFS access point, then the file system.
5. Delete the Aurora instance and cluster (no final snapshot), then the DB subnet group.
6. Empty and delete both buckets (the backup bucket is versioned: also delete all versions).
7. Delete both secrets.
8. Delete the three IAM roles, the log group, and both Cloud Map namespaces.
9. Delete the four security groups.
10. Leave the `ecs-agent`/`ecs-telemetry` endpoints if other workloads use them; otherwise agree removal with the platform team.
