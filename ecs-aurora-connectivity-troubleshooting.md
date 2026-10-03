# Troubleshooting: ECS Fargate task can't connect to Aurora PostgreSQL

*Runbook for Camunda 8 (or any JDBC application) on ECS Fargate failing at startup with a database connection error. Uses only read-only AWS CLI commands until the "Fix" section.*

---

## 1. Recognise the symptom

The application starts, then stops within a minute or two. The container log (CloudWatch Logs) contains a long chain of Spring `UnsatisfiedDependencyException` errors ending in something like:

```
Error occurred when getting DB product name.
...
Caused by: org.postgresql.util.PSQLException: The connection attempt failed.
...
Caused by: java.net.SocketTimeoutException: Connect timed out
```

**Always read the *last* `Caused by:` line.** Everything above it is a consequence. In the CloudWatch console, open the log stream and type `"Caused by"` (with quotes) in **Filter events**.

| Last `Caused by:` says | Category | Go to |
|---|---|---|
| `SocketTimeoutException: Connect timed out` / `Connection timed out` | **Network path blocked** (security group, NACL, VPC, routing) or database not running | Section 3 (this runbook) |
| `Connection refused` | Something answered but nothing listens on that port: wrong port, or wrong host | Step 3.3, 3.4 |
| `UnknownHostException` | Hostname in the JDBC URL is wrong or can't be resolved | Step 3.3, 3.6 |
| `PAM authentication failed for user "<DB_USER>"` | Network is fine; IAM database authentication rejected | Section 6 |
| `password authentication failed` | Network is fine; the IAM plugin isn't being used, or the wrong user/password | Section 6 |
| `database "<DB_NAME>" does not exist` | Network and auth fine; wrong database name | Step 3.3 |
| `no pg_hba.conf entry ... no encryption` | SSL required by the server but not used | Section 6 |

A timeout means the TCP packets never got an answer. Credentials, IAM and SQL are **not** involved yet.

---

## 2. Before you start

### 2.1 Which shell

Commands are written for **Windows Command Prompt (cmd)** and also work unchanged in **bash** (Linux, macOS, AWS CloudShell, Git Bash).

- **PowerShell:** they work too, except that PowerShell may treat `{`, `}` or `@` specially. If a `--query` fails to parse, wrap the whole query in single quotes and the inner literals in double quotes, or run the commands in cmd instead.
- Add `--profile <PROFILE>` to every command if you use a named profile.
- Read-only commands change nothing. Commands that change something are only in Section 5 and are marked.

### 2.2 Worksheet

Fill these in as you go. Each step says which values it produces.

| Placeholder | Meaning | Value | From step |
|---|---|---|---|
| `<REGION>` | AWS region, e.g. `eu-west-2` | | Before |
| `<ECS_CLUSTER>` | ECS cluster name | | Before |
| `<ECS_SERVICE>` | ECS service name | | Before / 3.2 |
| `<DB_CLUSTER_ID>` | Aurora cluster identifier | | Before |
| `<CONTAINER_NAME>` | Container that connects to the DB, e.g. `orchestration-cluster` | | Before |
| `<DB_URL_ENV>` | Env var holding the JDBC URL, e.g. `CAMUNDA_DATA_SECONDARYSTORAGE_RDBMS_URL` | | Before |
| `<LOG_GROUP>` | CloudWatch log group of the task | | Before |
| `<TASK_SUBNET_IDS>` | Subnets the service starts tasks in | | 3.2 |
| `<TASK_SG_IDS>` | Security groups the service gives its tasks | | 3.2 |
| `<TASK_DEF_ARN>` | Task definition revision the service runs | | 3.2 |
| `<DB_HOST>` | Hostname in the task's JDBC URL | | 3.3 |
| `<DB_WRITER_ENDPOINT>` | Aurora writer endpoint | | 3.4 |
| `<DB_SG_IDS>` | Security groups attached to Aurora | | 3.4 |
| `<DB_IP>` | Private IP `<DB_HOST>` resolves to | | 3.6 |
| `<DB_ENI>` / `<DB_SUBNET_ID>` | Aurora's network interface and subnet | | 3.7 |
| `<TASK_ID>` / `<TASK_ENI>` / `<TASK_SUBNET_ID>` / `<TASK_IP>` | A specific task's details | | 3.12 |

---

## 3. Diagnose, step by step

### 3.1 Confirm you're in the right account

```cmd
aws sts get-caller-identity --region <REGION>
```

**Look for:** the expected account ID. Every later command uses these credentials.

---

### 3.2 The service's network settings

```cmd
aws ecs describe-services --cluster <ECS_CLUSTER> --services <ECS_SERVICE> --region <REGION> --query "services[0].{Status:status,Running:runningCount,Desired:desiredCount,Net:networkConfiguration.awsvpcConfiguration,TaskDef:taskDefinition}" --output json
```

**Record:** `subnets` → `<TASK_SUBNET_IDS>`, `securityGroups` → `<TASK_SG_IDS>`, `TaskDef` → `<TASK_DEF_ARN>`.

**Look for:** the security groups are the ones you expect (for example your `*-tasks` group). A recreated service, or one created by Service Catalog or a template, can silently get a different or default group. The database rule in step 3.8 must reference **these** IDs.

Don't know the service name? `aws ecs list-services --cluster <ECS_CLUSTER> --region <REGION> --output text`

---

### 3.3 The database host the task actually uses

```cmd
aws ecs describe-task-definition --task-definition <TASK_DEF_ARN> --region <REGION> --query "taskDefinition.containerDefinitions[?name=='<CONTAINER_NAME>'].environment[] | [?name=='<DB_URL_ENV>'].value" --output text
```

**Record:** the hostname between `postgresql://` and `:5432` → `<DB_HOST>`. Also note the port and the database name after the `/`.

**Look for:** a full Aurora hostname ending in `.rds.amazonaws.com`, with no leftover placeholder such as `<WRITER_ENDPOINT>`, no spaces, and port `5432`.

---

### 3.4 The Aurora cluster

```cmd
aws rds describe-db-clusters --db-cluster-identifier <DB_CLUSTER_ID> --region <REGION> --query "DBClusters[0].{Status:Status,Writer:Endpoint,Port:Port,IAMAuth:IAMDatabaseAuthenticationEnabled,SGs:VpcSecurityGroups[].VpcSecurityGroupId,SubnetGroup:DBSubnetGroup,Members:DBClusterMembers[].DBInstanceIdentifier}" --output json
```

**Record:** `Writer` → `<DB_WRITER_ENDPOINT>`, `SGs` → `<DB_SG_IDS>`.

**Look for:**
- `Status` is `available` (not `stopped`, `stopping`, `starting`, `modifying`).
- `<DB_HOST>` from step 3.3 is **exactly** `<DB_WRITER_ENDPOINT>`.
- `Port` matches the URL.
- `SGs` are the groups you expect. A cluster created with the console wizard may carry `default` or a wizard-created group instead of your Aurora group.

---

### 3.5 The Aurora instance

```cmd
aws rds describe-db-instances --filters Name=db-cluster-id,Values=<DB_CLUSTER_ID> --region <REGION> --query "DBInstances[].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,AZ:AvailabilityZone,Public:PubliclyAccessible,SubnetGroupVpc:DBSubnetGroup.VpcId}" --output table
```

**Look for:** at least one instance with status `available`. A cluster with no running instance can't accept connections. Note `SubnetGroupVpc`; it is used in step 3.7.

---

### 3.6 Resolve the database hostname

```cmd
nslookup <DB_HOST>
```

**Record:** the address → `<DB_IP>`. Aurora's private endpoints resolve to private IPs from anywhere, including your laptop.

**Look for:** a private address inside your VPC's range. If it doesn't resolve, the hostname is wrong (see step 3.3).

---

### 3.7 Aurora's network interface

```cmd
aws ec2 describe-network-interfaces --filters Name=addresses.private-ip-address,Values=<DB_IP> --region <REGION> --query "NetworkInterfaces[0].{ENI:NetworkInterfaceId,Subnet:SubnetId,Vpc:VpcId,AZ:AvailabilityZone,SGs:Groups[].GroupId,Desc:Description}" --output json
```

**Record:** `ENI` → `<DB_ENI>`, `Subnet` → `<DB_SUBNET_ID>`.

**Look for:**
- A result at all. `null` means that IP isn't in this account and region: the URL points at another database.
- `SGs` matching `<DB_SG_IDS>` from step 3.4.

---

### 3.8 Are tasks and database in the same VPC?

List the task subnets (space-separated) and the database subnet:

```cmd
aws ec2 describe-subnets --subnet-ids <TASK_SUBNET_IDS> <DB_SUBNET_ID> --region <REGION> --query "Subnets[].[SubnetId,VpcId,CidrBlock,AvailabilityZone]" --output table
```

**Look for:** every row shows the **same `VpcId`**. If the database is in another VPC, you need peering or Transit Gateway routing (step 3.11), or rebuild the database in the tasks' VPC. Note each task subnet's `CidrBlock`; step 3.9 uses them.

---

### 3.9 Does the database's security group let the tasks in?

Run once per ID in `<DB_SG_IDS>`:

```cmd
aws ec2 describe-security-groups --group-ids <DB_SG_ID> --region <REGION> --query "SecurityGroups[0].{Name:GroupName,Inbound:IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,CIDRs:IpRanges[].CidrIp,FromGroups:UserIdGroupPairs[].GroupId,PrefixLists:PrefixListIds[].PrefixListId}}" --output json
```

**Look for** at least one inbound rule where:
- `Proto` is `tcp` with `From`/`To` covering **5432**, or `Proto` is `-1` (all traffic), **and**
- `FromGroups` contains **one of `<TASK_SG_IDS>`**, or `CIDRs` contains a range covering **every** task subnet's CIDR from step 3.8.

**The most common cause of this error:** the rule exists, but references a different group than the service actually uses (compare with step 3.2), or the CIDR rule only covers one of the task subnets.

---

### 3.10 Does the task's security group let traffic out?

Run once per ID in `<TASK_SG_IDS>`:

```cmd
aws ec2 describe-security-groups --group-ids <TASK_SG_ID> --region <REGION> --query "SecurityGroups[0].{Name:GroupName,Outbound:IpPermissionsEgress[].{Proto:IpProtocol,From:FromPort,To:ToPort,CIDRs:IpRanges[].CidrIp,ToGroups:UserIdGroupPairs[].GroupId,PrefixLists:PrefixListIds[].PrefixListId}}" --output json
```

**Look for** an outbound rule allowing 5432 (or all traffic, `-1`) to `0.0.0.0/0`, to a CIDR containing `<DB_IP>`, or to one of `<DB_SG_IDS>`. Security groups are stateful: if outbound is allowed, the reply is allowed automatically.

---

### 3.11 Network ACLs and routes

NACLs are **stateless** and evaluated lowest rule number first. Check the task subnets and the database subnet:

```cmd
aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=<SUBNET_ID> --region <REGION> --query "NetworkAcls[0].Entries[].[Egress,RuleNumber,Protocol,RuleAction,CidrBlock,PortRange.From,PortRange.To]" --output table
```

**Look for:**

| Subnet | Direction | Must allow |
|---|---|---|
| Task subnet | Outbound | TCP 5432 to `<DB_IP>` |
| Task subnet | Inbound | TCP 1024–65535 from `<DB_IP>` (replies) |
| DB subnet | Inbound | TCP 5432 from the task subnets |
| DB subnet | Outbound | TCP 1024–65535 to the task subnets (replies) |

A NACL with only `100 allow all (-1)` plus the final `* deny` allows everything. `Egress` `True` means outbound. Protocol `6` is TCP, `-1` is all.

Only if the subnets are in **different VPCs** (step 3.8), check the routes:

```cmd
aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=<SUBNET_ID> --region <REGION> --query "RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,TransitGatewayId,VpcPeeringConnectionId,State]" --output table
```

Within one VPC, the built-in `local` route always connects subnets.

---

### 3.12 Details of a specific task (optional)

Tasks that keep failing are replaced quickly. Stopped tasks stay visible for about an hour.

```cmd
aws ecs list-tasks --cluster <ECS_CLUSTER> --service-name <ECS_SERVICE> --desired-status STOPPED --region <REGION> --output text
```

```cmd
aws ecs describe-tasks --cluster <ECS_CLUSTER> --tasks <TASK_ID> --region <REGION> --query "tasks[0].{Status:lastStatus,StopCode:stopCode,Reason:stoppedReason,Containers:containers[].{Name:name,Exit:exitCode,Reason:reason},Net:attachments[0].details}" --output json
```

**Record:** `networkInterfaceId` → `<TASK_ENI>`, `subnetId` → `<TASK_SUBNET_ID>`, `privateIPv4Address` → `<TASK_IP>`.

**Look for:** `stoppedReason` like `Essential container in task exited` (application failure, as here) versus `ResourceInitializationError` (image, secrets, logs or EFS problem before the application even started).

---

### 3.13 Let AWS trace the path (optional, small cost)

**VPC Reachability Analyzer** checks every hop and names the exact security group, NACL or route that blocks the traffic. It needs a **running** task, because a stopped task's network interface is deleted. Each analysis costs about USD 0.10, and it creates a "path" object you delete afterwards.

1. Get a live task (run step 3.12 with `--desired-status RUNNING`) and its `<TASK_ENI>`.
2. Create the path. **This creates a resource.**

```cmd
aws ec2 create-network-insights-path --source <TASK_ENI> --destination <DB_ENI> --protocol tcp --destination-port 5432 --region <REGION> --query "NetworkInsightsPath.NetworkInsightsPathId" --output text
```

3. Start the analysis with the returned `<PATH_ID>`:

```cmd
aws ec2 start-network-insights-analysis --network-insights-path-id <PATH_ID> --region <REGION> --query "NetworkInsightsAnalysis.NetworkInsightsAnalysisId" --output text
```

4. Wait about 30 seconds, then read the result with the returned `<ANALYSIS_ID>`:

```cmd
aws ec2 describe-network-insights-analyses --network-insights-analysis-ids <ANALYSIS_ID> --region <REGION> --query "NetworkInsightsAnalyses[0].{Status:Status,PathFound:NetworkPathFound,Why:Explanations[].{Code:ExplanationCode,Component:Component.Id,SG:SecurityGroup.Id,ACL:Acl.Id}}" --output json
```

**Look for:** `PathFound: false` and the component named under `Why`. If `Status` is `running`, wait and repeat.

5. Clean up:

```cmd
aws ec2 delete-network-insights-analysis --network-insights-analysis-id <ANALYSIS_ID> --region <REGION>
aws ec2 delete-network-insights-path --network-insights-path-id <PATH_ID> --region <REGION>
```

The same analysis is available in the console under **VPC → Reachability Analyzer**.

---

## 4. Common causes

| Finding | Cause | Fix (Section 5) |
|---|---|---|
| Step 3.4 `SGs` isn't your Aurora group | Cluster created with `default` or a wizard-created group | 5.1 |
| Step 3.9: rule references a different group than step 3.2 shows | Service uses another security group than the one the DB rule allows (common after recreating the service) | 5.2 or 5.3 |
| Step 3.9: CIDR rule covers only some task subnets | Task started in a subnet outside the allowed range | 5.2 |
| Step 3.8: different `VpcId` | Database and tasks in different VPCs | Routing/peering, or rebuild the DB in the right VPC |
| Step 3.11: NACL deny | Custom NACL blocks 5432 or the reply ports | Ask the network owner to allow the ranges in 3.11 |
| Step 3.3 host ≠ step 3.4 writer, or step 3.7 `null` | Wrong endpoint in the task definition | New task definition revision with the correct URL |
| Step 3.4/3.5 status not `available` | Database stopped or still being created | Start it or wait |

**Why pgAdmin from your laptop works but the task doesn't:** the laptop arrives from the corporate network range, which usually has its own inbound rule on the database group. That rule says nothing about the tasks.

---

## 5. Fix

**These commands change resources.** The console works just as well (EC2 → Security Groups → Edit inbound rules; RDS → Modify; ECS → Update service).

### 5.1 Attach the right security group to Aurora

```cmd
aws rds modify-db-cluster --db-cluster-identifier <DB_CLUSTER_ID> --vpc-security-group-ids <DB_SG_ID> --apply-immediately --region <REGION>
```

This **replaces** the cluster's groups. List every group it should keep.

### 5.2 Allow the tasks' security group on the database group (preferred)

```cmd
aws ec2 authorize-security-group-ingress --group-id <DB_SG_ID> --ip-permissions IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=<TASK_SG_ID>,Description="App tasks to Aurora"}] --region <REGION>
```

In PowerShell, put the whole `--ip-permissions` value in single quotes.

To test quickly whether security groups are the problem, you can instead allow the task subnets' CIDRs temporarily (`IpRanges=[{CidrIp=<TASK_SUBNET_CIDR>}]`). Replace that with the group-based rule once it works.

### 5.3 Or give the service the expected security group

```cmd
aws ecs update-service --cluster <ECS_CLUSTER> --service <ECS_SERVICE> --network-configuration "awsvpcConfiguration={subnets=[<SUBNET_A>,<SUBNET_B>,<SUBNET_C>],securityGroups=[<TASK_SG_ID>],assignPublicIp=DISABLED}" --force-new-deployment --region <REGION>
```

If the service is managed by Service Catalog or CloudFormation, change it there instead, or the next stack update reverts it.

### 5.4 Restart and watch

Security group changes apply immediately, but a crash-looping task only retries on its next start. Force one:

```cmd
aws ecs update-service --cluster <ECS_CLUSTER> --service <ECS_SERVICE> --force-new-deployment --region <REGION>
```

Then follow the log for the root-cause line (AWS CLI v2):

```cmd
aws logs tail <LOG_GROUP> --since 10m --follow --filter-pattern "\"Caused by\"" --region <REGION>
```

**Success:** no new `Caused by` lines. The application log moves past the database step (for Camunda: schema creation, partitions installed), and the load balancer target becomes **healthy**.

---

## 6. If the error changes after the network is fixed

The timeout disappearing and a new error appearing means the network is now fine. Next layer:

| New `Caused by:` | Check |
|---|---|
| `PAM authentication failed for user "<DB_USER>"` | (1) Cluster has **IAM DB authentication enabled** (step 3.4 `IAMAuth: true`). (2) The DB user exists and has the `rds_iam` role (run `SELECT pg_has_role('<DB_USER>','rds_iam','member');` as the master user). (3) The task role allows `rds-db:connect` on `arn:aws:rds-db:<REGION>:<ACCOUNT_ID>:dbuser:<DB_CLUSTER_RESOURCE_ID>/<DB_USER>`, where `<DB_CLUSTER_RESOURCE_ID>` is the `cluster-…` **Resource ID**, not the cluster name. (4) The task definition's `taskRoleArn` is that role. |
| `password authentication failed` | The JDBC URL must be `jdbc:aws-wrapper:postgresql://...?wrapperPlugins=iam` with driver class `software.amazon.jdbc.Driver`; otherwise the IAM plugin isn't used. |
| `Unable to load credentials` / `AccessDenied` | The task has no task role, or the role can't be assumed (trust principal must be `ecs-tasks.amazonaws.com`). |
| `database "<DB_NAME>" does not exist` | Database name after the `/` in the URL must match the cluster's initial database name, or create it. |
| `no pg_hba.conf entry ... no encryption` | Use SSL: add `sslmode=require` to the URL parameters. |

Find the resource ID for the IAM policy:

```cmd
aws rds describe-db-clusters --db-cluster-identifier <DB_CLUSTER_ID> --region <REGION> --query "DBClusters[0].DbClusterResourceId" --output text
```
