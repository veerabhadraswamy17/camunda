# Camunda 8.9 on Amazon ECS Fargate: single broker

*Console deployment guide for an AWS account with private subnets only and no AWS Cloud Map*

This guide builds Camunda 8.9 by hand in the AWS console, based on the camunda-deployment-references reference architecture `aws/containers/ecs-single-region-fargate` (basic authentication), adapted to run **one broker** so that no service discovery is needed:

- One ECS service with one Fargate task, holding two containers: the **Orchestration Cluster** (single broker) and **Connectors**. Connectors talk to the broker over `localhost`.
- Broker data on **EFS**, secondary storage in **Aurora PostgreSQL** with IAM database authentication, **S3** buckets for the node-ID lease and backups.
- An **internal Application Load Balancer** in the private subnets for the web UI and REST API, reached from the corporate network.

It assumes an existing VPC with private subnets and no internet access, an existing ECS cluster, Camunda images already in ECR, and network access to the private subnets from a corporate laptop. Settings come from the reference's root Terraform files and its modules `ecs/fargate/orchestration-cluster`, `ecs/fargate/connectors` and `aurora`; every deviation is called out.

### How to use this guide

- Anything specific to your environment is written as a `<PLACEHOLDER>`. Fill in the **deployment worksheet** (section 0.2) as you go: some values you know before starting, the rest appear at the step that creates them, marked **Record:**.
- The companion files use the same placeholders: `taskdef-camunda-single-broker.json`, `iam-execution-role-secrets-policy.json`, `iam-task-role-policy.json` and `camunda-db-seed.sql`. Once the worksheet is complete, a find-and-replace across the folder (VS Code: **Ctrl+Shift+H**) fills them in. Before pasting a file into the console, search it for `<` to make sure nothing is left.
- Resource names use the prefix `camunda-poc` (Camunda components `camunda-poc-oc1`, mirroring the reference's `<prefix>-oc1`). To use another prefix, replace it consistently in the guide and all files; keep it short (target group names are limited to 32 characters).

### What a single broker means

| | Reference (3 brokers) | This guide (1 broker) |
|---|---|---|
| High availability | Survives the loss of one broker or AZ | **None.** If the task stops, the engine is down for a few minutes until ECS starts a new one |
| Replication | Replication factor 3 | Replication factor 1. Data still survives task replacement: broker state is on EFS (multi-AZ), history in Aurora |
| Deployments | Rolling, 2 of 3 brokers stay up | **Short downtime:** the old task stops before the new one starts |
| Service discovery | ECS Service Connect (needs AWS Cloud Map) | **None needed** |
| Connectors | Separate ECS service | Second container in the broker's task |

Suitable for a PoC, not for production.

## 0. Before you start

### 0.1 Order of work

| Step | What | Roughly |
|---|---|---|
| 1 | Check VPC endpoints | 10 min |
| 2 | Security groups | 10 min |
| 3 | Secrets Manager: admin and Connectors passwords | 5 min |
| 4 | S3 buckets: node-ID and backups | 5 min |
| 5 | Aurora PostgreSQL | 15 min + ~15 min wait |
| 6 | Create the IAM database user (from your laptop) | 10 min |
| 7 | EFS file system and access point | 10 min |
| 8 | CloudWatch log group | 2 min |
| 9 | IAM roles | 10 min |
| 10 | Task definition | 10 min |
| 11 | Target group and internal ALB | 15 min |
| 12 | ECS service | 10 min + ~10 min wait |
| 13 | Verify from your laptop | 10 min |

### 0.2 Deployment worksheet

Fill in the **Value** column as you go.

| Placeholder | Value | Where it comes from | Step |
|---|---|---|---|
| `<ACCOUNT_ID>` |  | Account menu, top right of the console | Before |
| `<REGION>` |  | Region code, for example `eu-west-2` | Before |
| `<VPC_ID>` |  | VPC → Your VPCs | Before |
| `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>` |  | VPC → Subnets, filtered by the VPC: one private subnet per AZ with the most **Available IPv4 addresses** (at least ~10 free each) | Before |
| `<CORP_CIDR>` |  | Network range your laptop's traffic arrives from (network team, or the inbound rules of another internal load balancer) | Before |
| `<ECS_CLUSTER>` |  | ECS → Clusters | Before |
| `<CAMUNDA_IMAGE>` |  | ECR → repository → image → **URI** (Camunda 8.9.x) | Before |
| `<CONNECTORS_IMAGE>` |  | ECR → image **URI** (Connectors bundle, same 8.9 minor) | Before |
| `<ADMIN_SECRET_ARN>` |  | Secrets Manager | 3 |
| `<CONNECTORS_SECRET_ARN>` |  | Secrets Manager | 3 |
| `<WRITER_ENDPOINT>` |  | RDS → cluster → Connectivity & security (Writer) | 5 |
| `<CLUSTER_RESOURCE_ID>` |  | RDS → cluster → Configuration → Resource ID (`cluster-…`) | 5 |
| `<FS_ID>` |  | EFS file system ID (`fs-…`) | 7 |
| `<FSAP_ID>` |  | EFS access point ID (`fsap-…`) | 7 |
| `<ALB_DNS>` |  | EC2 → Load balancers → DNS name | 11 |

### 0.3 Checks

- **Images:** Camunda and Connectors should share the same 8.9 minor version. The reference was tested with `camunda/camunda:8.9.16` and `camunda/connectors-bundle:8.9.7`; Amazon ECS support and Aurora as secondary storage arrived with the 8.9 minor release.
- **VPC DNS:** VPC → Your VPCs → your VPC: **DNS resolution** and **DNS hostnames** both **Enabled** (endpoint private DNS and EFS mount names depend on them).
- **Organisation guardrails:** mandatory tags, IAM permission boundaries or naming rules. If a create fails with an access-denied error naming a service control policy, check with the platform team.
- **Shared cluster capacity providers:** if the ECS cluster has a default capacity provider strategy, choose **Launch type: FARGATE** explicitly in step 12.

## 1. Check VPC endpoints

With no internet route, every AWS service the task calls must be reachable through a VPC endpoint in the same VPC. **VPC → Endpoints**, filter by `<VPC_ID>` (without the filter the list includes other VPCs' endpoints).

| Service name | Type | Needed for | Present? |
|---|---|---|---|
| `com.amazonaws.<REGION>.ecr.api` | Interface | Pulling images from ECR | |
| `com.amazonaws.<REGION>.ecr.dkr` | Interface | Pulling images from ECR | |
| `com.amazonaws.<REGION>.s3` | **Gateway**, on the private subnets' route table | ECR image layers, node-ID bucket, backups | |
| `com.amazonaws.<REGION>.logs` | Interface | Container logs | |
| `com.amazonaws.<REGION>.secretsmanager` | Interface | Passwords injected into the task | |

No ECS or Cloud Map endpoints are needed, because this setup doesn't use Service Connect.

For each interface endpoint, check on the **Details** tab that **Private DNS names enabled** is **Yes**, and on the **Security groups** tab that the group allows **inbound TCP 443** from the private subnets (or from `camunda-poc-tasks` once it exists; add that rule if the group only allows specific sources).

For the S3 gateway endpoint, open its **Policy** tab. If it isn't *Full access* and lists specific buckets, the two Camunda buckets from step 4 must be allowed too, or node-ID leasing and backups fail with Access Denied.

If an endpoint is missing, ask the platform team to add it (VPC → Endpoints → Create endpoint → AWS services → the service name → VPC, one subnet per AZ, **Enable DNS name** ticked, the standard endpoint security group).

## 2. Security groups

The reference opens Camunda ports to the whole VPC CIDR. Here the broker and Connectors share a task and talk over `localhost`, so only the load balancer, EFS and Aurora need rules, and these reference security groups instead of CIDRs.

### 2.1 Create four empty groups

**EC2 → Security Groups → Create security group**, VPC `<VPC_ID>`, no inbound rules, keep the default outbound rule (all traffic; with no internet route it only reaches VPC resources and endpoints).

| Name | Description |
|---|---|
| `camunda-poc-tasks` | Camunda task |
| `camunda-poc-efs` | Camunda EFS |
| `camunda-poc-aurora` | Camunda Aurora PostgreSQL |
| `camunda-poc-alb` | Camunda internal load balancer |

### 2.2 Inbound rules

Open each group → **Inbound rules → Edit inbound rules**. Type **Custom TCP**; for a group source choose **Custom** and type `camunda-poc` to pick it.

| Group | Port | Source | Purpose |
|---|---|---|---|
| `camunda-poc-tasks` | 8080 | `camunda-poc-alb` | Web UI and REST API |
| `camunda-poc-tasks` | 9600 | `camunda-poc-alb` | Load balancer health check (readiness is checked on 9600) |
| `camunda-poc-efs` | 2049 | `camunda-poc-tasks` | NFS |
| `camunda-poc-aurora` | 5432 | `camunda-poc-tasks` | Database |
| `camunda-poc-aurora` | 5432 | `<CORP_CIDR>` | Temporary, for step 6 only |
| `camunda-poc-alb` | 80 | `<CORP_CIDR>` | Browser and API access from your laptop |

## 3. Secrets Manager

The broker creates two built-in users at startup (`camunda.tf`, basic mode): `admin` and `connectors`. Their passwords are injected as task secrets, stored as plain strings.

1. **Secrets Manager → Store a new secret → Other type of secret**.
2. Choose the **Plaintext** tab, delete the `{}`, and paste a password on its own (no quotes, no JSON). Use 24+ letters and digits; the reference's generator also allows `!#$%^()-_=+[]{}:?`. Avoid spaces and quote characters.
3. Encryption key: `aws/secretsmanager`. **Next**.
4. Secret name: `camunda-poc-oc1-admin-user-password`. **Next**, no rotation, **Store**.
5. Open the secret and copy the full **Secret ARN**.
6. Repeat with name `camunda-poc-oc1-connectors-client-auth-password`.

> **Important:** The ARN ends in a random 6-character suffix (for example `…-password-Ab12Cd`). Copy the full ARN; the name alone doesn't work in the task definition or the IAM policy.

> **Record:** the two secret ARNs → `<ADMIN_SECRET_ARN>` and `<CONNECTORS_SECRET_ARN>`.

## 4. S3 buckets

Bucket names are global, so they include the account ID. **S3 → Create bucket**, region `<REGION>`, **Block all public access** on (default).

| Bucket name | Purpose | Settings |
|---|---|---|
| `camunda-poc-oc1-bucket-<ACCOUNT_ID>` | Node-ID provider: the broker leases its node ID here | Versioning **Disable** (the module notes frequent metadata changes would add cost with no benefit). Encryption: SSE-S3 |
| `camunda-poc-backup-bucket-<ACCOUNT_ID>` | Camunda backups | Versioning **Enable**. Encryption: SSE-S3 |

The reference encrypts both buckets with customer-managed KMS keys. SSE-S3 keeps the IAM policy simpler. If the organisation requires SSE-KMS, use customer-managed keys, add `kms:Decrypt`, `kms:Encrypt`, `kms:GenerateDataKey` and `kms:DescribeKey` on those keys to the task role policy (condition `kms:ViaService = s3.<REGION>.amazonaws.com`, as in the reference), and make sure a `kms` endpoint exists.

With a single task the node-ID provider isn't strictly needed, but it is kept: its lease stops two brokers from ever using the same data directory, for example during a deployment or if ECS replaces a task that hasn't fully stopped.

## 5. Aurora PostgreSQL

### 5.1 DB subnet group

**RDS → Subnet groups → Create DB subnet group**: name `camunda-poc-camunda-db-cluster`, description `Camunda Aurora`, VPC `<VPC_ID>`, the three AZs, subnets `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>`.

### 5.2 Create the cluster

**RDS → Databases → Create database**. Values from `postgres.tf`, `variables.tf` and `modules/aurora`.

| Console setting | Value | Source |
|---|---|---|
| Creation method | Standard create | |
| Engine type | Aurora (PostgreSQL Compatible) | `engine = aurora-postgresql` |
| Engine version | **Aurora PostgreSQL 17.9** | `postgres.tf` |
| Templates | Dev/Test | |
| DB cluster identifier | `camunda-poc-camunda-db-cluster` | `cluster_name` |
| Master username | `camunda_admin` | `db_admin_username` |
| Credentials management | **Managed in AWS Secrets Manager**, key `aws/secretsmanager` | Read once in step 6 |
| Cluster storage configuration | Aurora Standard | |
| DB instance class | Burstable classes → `db.t3.medium` | `instance_class` |
| Multi-AZ deployment | Don't create an Aurora Replica | `num_instances = 1` |
| Compute resource | Don't connect to an EC2 compute resource | |
| VPC / DB subnet group | `<VPC_ID>` / `camunda-poc-camunda-db-cluster` | |
| Public access | No | |
| VPC security group | Choose existing: `camunda-poc-aurora` (remove `default`) | |
| Certificate authority | `rds-ca-rsa2048-g1` | `ca_cert_identifier` |
| Database port | 5432 | |
| Database authentication | **Password and IAM database authentication** | `iam_auth_enabled = true` (required) |
| Monitoring | Defaults | |
| Additional configuration → Initial database name | `camunda` | `db_name` |
| Encryption | Enabled, key `aws/rds` | `storage_encrypted = true` |
| Auto minor version upgrade | Off | `auto_minor_version_upgrade = false` |
| Deletion protection | Off (PoC) | `skip_final_snapshot = true` |

> **Important:** IAM database authentication must be on and the initial database must be named `camunda`. The broker connects with `jdbc:aws-wrapper:postgresql://…/camunda?wrapperPlugins=iam`; without IAM auth it fails at startup with an authentication error that doesn't name the cause.

### 5.3 Outputs

When the cluster status is **Available** (about 10–15 minutes):

- **Connectivity & security** tab: the endpoint of type **Writer** (looks like `camunda-poc-camunda-db-cluster.cluster-xxxx.<REGION>.rds.amazonaws.com`).
- **Configuration** tab: **Resource ID**, starting with `cluster-`. This is not the cluster name.

> **Record:** `<WRITER_ENDPOINT>` and `<CLUSTER_RESOURCE_ID>`.

## 6. Create the IAM database user

The broker connects as database user `camunda` with an IAM token, so that role must exist and hold `rds_iam`. The reference does this with a one-off ECS task running a public `postgres` image, which can't be pulled without internet; run the same SQL from your laptop instead (file `camunda-db-seed.sql`).

### 6.1 Get the master password

**RDS → camunda-poc-camunda-db-cluster → Configuration**: under **Master credentials ARN**, click **Manage in Secrets Manager** → **Retrieve secret value** → copy `password`.

### 6.2 Connect

Use any PostgreSQL client on the laptop. Host `<WRITER_ENDPOINT>`, port `5432`, database `camunda`, user `camunda_admin`, the password from 6.1, **SSL mode: require**.

- **psql:** `psql "host=<WRITER_ENDPOINT> port=5432 dbname=camunda user=camunda_admin sslmode=require"`
- **DBeaver or pgAdmin:** a PostgreSQL connection with the values above; SSL mode **require**.

### 6.3 Run the SQL

```sql
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

> **Tip:** If the laptop can't reach port 5432, push or mirror a `postgres:17-alpine` image into ECR and run the same SQL with `psql` in a one-off Fargate task in the private subnets (security group `camunda-poc-tasks`, master password injected as a secret), as the reference's `postgres_seed.tf` does.

## 7. EFS

The broker stores its data on an encrypted EFS file system, mounted through an access point with IAM authorization (`modules/ecs/fargate/orchestration-cluster/efs.tf` and `ecs.tf`).

### 7.1 File system

**EFS → Create file system → Customize**:

| Setting | Value | Source |
|---|---|---|
| Name | `camunda-poc-oc1-efs` | |
| File system type | Regional | |
| Automatic backups | Off for the PoC (on is fine too) | Not set by the module |
| Lifecycle management | Transition into IA: **None**; into Archive: **None** | Not set by the module |
| Encryption | Enabled, key `aws/elasticfilesystem` | `encrypted = true` |
| Throughput mode | Enhanced → **Elastic** | `efs_throughput_mode` |
| Performance mode | **General Purpose** | `efs_performance_mode` |
| Network → VPC | `<VPC_ID>` | |
| Mount targets | `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>` (one per AZ), security group `camunda-poc-efs` on each (remove `default`) | One per private subnet, so the task can start in any AZ |
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

**CloudWatch → Log groups → Create log group**: name `/ecs/camunda-poc-oc1-camunda`, retention **30 days** (`cloudwatch_retention_days`). Both containers log here, under the stream prefixes `orchestration-cluster` and `connectors`.

## 9. IAM roles

Both roles are created the same way: **IAM → Roles → Create role → Trusted entity type: AWS service → Use case: Elastic Container Service → Elastic Container Service Task** (trust principal `ecs-tasks.amazonaws.com`, as in the reference). Add any permission boundary or tags the organisation requires.

To add an inline policy: open the role → **Permissions → Add permissions → Create inline policy → JSON**, paste the file's contents with placeholders replaced, **Next**, name it, **Create policy**.

### 9.1 Task execution role

- Role name: `camunda-poc-ecs-task-execution-role`.
- Attach AWS managed policy `AmazonECSTaskExecutionRolePolicy` (ECR pulls, log writes).
- Inline policy `camunda-poc-ecs-task-secrets` from `iam-execution-role-secrets-policy.json` (replace `<ADMIN_SECRET_ARN>`, `<CONNECTORS_SECRET_ARN>`).

### 9.2 Task role

- Role name: `camunda-poc-oc1-task-role`. No managed policies.
- Inline policy `camunda-poc-oc1-task-policy` from `iam-task-role-policy.json` (replace `<ACCOUNT_ID>`, `<REGION>`, `<FS_ID>`, `<CLUSTER_RESOURCE_ID>`).

A task has one task role, shared by both containers. The policy combines what the reference attaches to the orchestration task role: the module's EFS policy (mount with IAM authorization), node-ID bucket policy and logs policy, plus `rds_db_connect_camunda` and `s3_backup_access_policy` from the root files. Connectors need nothing beyond logs, which this already covers. The module's ECS Exec (`ssmmessages`) policy is left out because Exec is off by default.

## 10. Task definition

### 10.1 Fill in the JSON

In `taskdef-camunda-single-broker.json`, replace `<ACCOUNT_ID>`, `<REGION>`, `<CAMUNDA_IMAGE>`, `<CONNECTORS_IMAGE>`, `<WRITER_ENDPOINT>`, `<ADMIN_SECRET_ARN>`, `<CONNECTORS_SECRET_ARN>`, `<FS_ID>` and `<FSAP_ID>`. Search for `<` afterwards.

### 10.2 What it contains

**Task:** family `camunda-poc-oc1-orchestration-cluster`, Fargate, Linux X86_64, **4 vCPU / 12 GB**.

**Container `orchestration-cluster`** (3 vCPU / 8 GB, essential):
- Ports 8080 (REST and web UI), 9600 (management), 26500 (gRPC), 26501, 26502.
- Health check: `wget` on `localhost:9600/actuator/health/liveness`, start period 120 s.
- EFS volume `camunda-volume` at `/usr/local/camunda/data`, encryption in transit and IAM authorization, through the access point.
- Environment from the module and `camunda.tf`, with these single-broker changes:

| Variable | Reference | Here |
|---|---|---|
| `CAMUNDA_CLUSTER_SIZE` | 3 | **1** |
| `CAMUNDA_CLUSTER_REPLICATIONFACTOR` | 3 | **1** |
| `CAMUNDA_CLUSTER_PARTITIONCOUNT` | 3 | 3 (all on the one broker) |
| `CAMUNDA_CLUSTER_INITIALCONTACTPOINTS` | `orchestration-cluster-sc:26502` | **Removed** (nothing to contact) |

Everything else matches the reference: S3 node-ID provider (15 s lease), RDBMS secondary storage with IAM auth, basic-auth users `admin` and `connectors`, S3 backups, 5 s shutdown phase.

**Container `connectors`** (1 vCPU / 4 GB, **not essential**):
- Starts only once the broker container is **HEALTHY** (`dependsOn`).
- Reaches the broker at `http://localhost:8080` (REST) and `http://localhost:26500` (gRPC), authenticating as user `connectors`.
- Listens on **8090** (`SERVER_PORT`), because containers in a task share one network and the broker already uses 8080. Context path `/connectors` as in the reference.
- Health check on `localhost:8090/connectors/actuator/health/readiness`.
- Not essential: if Connectors crash, the broker keeps running.

### 10.3 Register it

1. **ECS → Task definitions → Create new task definition → Create new task definition with JSON**.
2. Select all in the editor, paste the filled-in JSON, **Create**.

## 11. Target group and internal load balancer

Values from the module's `lb.tf`. The reference ALB is internet-facing; here it is **internal**, in the private subnets.

### 11.1 Target group

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

**Next**, register no targets (ECS does that), **Create**. Then open it → **Attributes → Edit**: deregistration delay **30** seconds; **Stickiness** on, **Load balancer generated cookie**, **12 hours**. Save.

### 11.2 Internal Application Load Balancer

**EC2 → Load balancers → Create load balancer → Application Load Balancer**:

| Setting | Value |
|---|---|
| Name | `camunda-poc-alb` |
| Scheme | **Internal** |
| IP address type | IPv4 |
| VPC / Mappings | `<VPC_ID>`; `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>` (one per AZ) |
| Security groups | `camunda-poc-alb` only (remove `default`) |
| Listener | HTTP : 80, default action **Forward to** `camunda-poc-oc1-orc-tg-8080` |

The load balancer's DNS name (`internal-camunda-poc-alb-….<REGION>.elb.amazonaws.com`) resolves to private IPs, which your laptop connects to.

> **Record:** the load balancer DNS name → `<ALB_DNS>`.

> **Tip:** The reference uses plain HTTP on port 80. For HTTPS, add a 443 listener with an ACM certificate (often from a private CA in corporate environments) and an inbound 443 rule on `camunda-poc-alb`. Connectors are not exposed through the load balancer; that is only needed for inbound connectors such as webhooks (see section 15).

## 12. ECS service

**ECS → Clusters → `<ECS_CLUSTER>` → Services → Create**.

| Console section | Setting |
|---|---|
| Compute configuration | Compute options: **Launch type**; Launch type **FARGATE**; Platform version **LATEST** |
| Deployment configuration | Task definition family `camunda-poc-oc1-orchestration-cluster`, latest revision; service name `camunda-poc-oc1-orchestration-cluster`; scheduling strategy **Replica**; desired tasks **1**; Availability Zone rebalancing **off**; health check grace period **900** seconds (module value) |
| Deployment options | Rolling update; **Min running tasks 0%**; **Max running tasks 100%**; deployment circuit breaker **off** |
| Service Connect | **Off** |
| Service discovery | **Off** |
| Networking | VPC `<VPC_ID>`; subnets `<SUBNET_A>`, `<SUBNET_B>`, `<SUBNET_C>`; security group `camunda-poc-tasks` only; Public IP **off** |
| Load balancing | Use load balancing; **Application Load Balancer**; container `orchestration-cluster 8080:8080`; use an existing load balancer `camunda-poc-alb`; use existing listener **80:HTTP**; use existing target group `camunda-poc-oc1-orc-tg-8080` |

> **Important:** Min 0% / max 100% is deliberate. With one task, the reference's 66% would round up to 1 and, together with the 100% maximum, block every deployment. 0/100 makes ECS stop the old broker before starting the new one, so two brokers never use the same EFS data. The cost is a few minutes of downtime per deployment.

**Create**. Then check **EC2 → Load balancers → camunda-poc-alb → Listeners → HTTP:80 → Rules**: only the default action should forward to the target group. Delete any extra rule the console added.

### 12.1 What to expect

The broker leases node ID 0 in the S3 bucket, mounts EFS, connects to Aurora and starts its partitions. Allow about 10 minutes until the service shows **1/1 tasks running** and the target is **healthy**. Connectors start once the broker container is healthy. Watch progress in `/ecs/camunda-poc-oc1-camunda` (streams `orchestration-cluster/…` and `connectors/…`). In the task's **Containers** tab, both containers should eventually show health **Healthy**.

## 13. Verify from your laptop

1. **Browser:** `http://<ALB_DNS>/` shows the Camunda login. Sign in as **admin** with the value of `camunda-poc-oc1-admin-user-password` (Secrets Manager → Retrieve secret value).
2. **Cluster topology** (PowerShell; use `curl.exe`, because plain `curl` is an alias there):

```
curl.exe -s -u "admin:<admin password>" http://<ALB_DNS>/v2/topology
```

A healthy result shows 1 broker, cluster size 1, partitions count 3, replication factor 1, every partition healthy.

3. **Connectors:** in the task's **Containers** tab, `connectors` is **Healthy**, and the `connectors/…` log stream shows no repeating connection errors.
4. **S3:** `camunda-poc-oc1-bucket-<ACCOUNT_ID>` contains the node-ID lease object.

## 14. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| Task stops with `CannotPullContainerError` | Image URI typo; S3 gateway endpoint policy blocks the ECR layer bucket; execution role missing `AmazonECSTaskExecutionRolePolicy` | Image URIs; endpoint policy (step 1); role 9.1 |
| `ResourceInitializationError` … secrets | Execution role can't read a secret; ARN missing its suffix | Inline policy 9.1; ARNs in the task definition |
| `ResourceInitializationError` … logs | Log group missing or misnamed | Step 8 name is exactly `/ecs/camunda-poc-oc1-camunda` |
| `ResourceInitializationError` … EFS / mount | Port 2049 blocked; no mount target in the task's subnet; task role lacks `ClientMount`/`ClientWrite`; wrong `<FS_ID>`/`<FSAP_ID>` | Step 2 rules; step 7 mount targets; policy 9.2 |
| Log errors about the node-ID bucket (Access Denied) | Task role or S3 endpoint policy | Policy 9.2; endpoint policy (step 1) |
| New task waits for a node ID after a deployment | Previous task still held the lease | Normal for up to the 15 s lease; check the old task has stopped |
| Log errors: database authentication failed | Step 6 not done; IAM auth off; wrong Resource ID in `rds-db:connect`; database not named `camunda` | `pg_has_role` check; step 5.2; policy 9.2 |
| `connectors` container stays unhealthy or keeps restarting | Wrong Connectors password secret; broker not ready | `connectors/…` log stream; `<CONNECTORS_SECRET_ARN>` is the same secret the broker uses for user `connectors` |
| Connectors never start | Broker container never reached HEALTHY | Broker logs first |
| Browser times out | `camunda-poc-alb` lacks inbound 80 from the right range; corporate routing to these subnets | `<CORP_CIDR>` |
| ALB returns 502/503 | Target unhealthy; missing 9600 rule from ALB group to tasks group | Target group health tab; step 2 rules |

## 15. Optional later changes

**Expose Connectors (inbound webhooks).** Create a second target group (IP, HTTP 8090, health check `/connectors/actuator/health/readiness` on the traffic port), add a listener rule **Path** `/connectors*` → that target group with a lower priority number than any catch-all, add an inbound 8090 rule from `camunda-poc-alb` to `camunda-poc-tasks`, and attach the target group to the service for container `connectors 8090:8090`. If the console doesn't offer a second load balancer mapping on the existing service, recreate the service with both.

**Move to 3 brokers** once a Service Connect namespace is available (Cloud Map allowed, or a namespace provided by the platform team): add the `ecs`, `ecs-agent` and `ecs-telemetry` endpoints, split Connectors into their own service, and follow the reference: cluster size and replication factor 3, contact points `orchestration-cluster-sc:26502`, Service Connect on, deployment min 66% / max 100%, ports 26500–26502 open between tasks. Changing the size of a running cluster requires Camunda's cluster scaling API, so for a PoC the simpler route is a fresh deployment with a new EFS file system and database.

## 16. Cost and teardown

Running costs come mainly from the 4 vCPU / 12 GB Fargate task, the Aurora `db.t3.medium` instance and the ALB. Set the service's desired tasks to 0 when not in use (no data is lost: it's on EFS and in Aurora); Aurora can be stopped for up to 7 days at a time.

Teardown, in this order:

1. Update the service's desired tasks to 0, then delete the service.
2. Deregister the task definition.
3. Delete the load balancer, then the target group.
4. Delete the EFS access point, then the file system.
5. Delete the Aurora instance and cluster (no final snapshot), then the DB subnet group.
6. Empty and delete both buckets (the backup bucket is versioned: delete all versions too).
7. Delete both secrets.
8. Delete both IAM roles and the log group.
9. Delete the four security groups.
