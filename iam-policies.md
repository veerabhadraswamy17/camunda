# IAM policies for the Camunda ECS PoC (console paste-ins)

Region: eu-west-2 (London). Replace `<ACCOUNT_ID>`, `<NODE_ID_BUCKET>`, `<EFS_FILE_SYSTEM_ID>` and the secret ARNs.
All roles use the trust policy "AWS service → Elastic Container Service → Elastic Container Service Task" (principal `ecs-tasks.amazonaws.com`).

## 1. camunda-ecs-task-execution-role (shared by both task definitions)

Attach AWS managed policy: `AmazonECSTaskExecutionRolePolicy` (covers ECR pulls in this account + CloudWatch Logs).

Add inline policy `camunda-ecs-task-secrets`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": [
        "<ADMIN_PASSWORD_SECRET_ARN>",
        "<CONNECTORS_PASSWORD_SECRET_ARN>",
        "<DB_PASSWORD_SECRET_ARN>"
      ]
    }
  ]
}
```

(No KMS statement needed as long as the secrets use the default `aws/secretsmanager` key.)

## 2. camunda-oc1-orchestration-task-role

Inline policy `camunda-oc1-orchestration`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NodeIdBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<NODE_ID_BUCKET>"
    },
    {
      "Sid": "NodeIdObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<NODE_ID_BUCKET>/*"
    },
    {
      "Sid": "EfsClient",
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:ClientMount",
        "elasticfilesystem:ClientWrite",
        "elasticfilesystem:ClientRootAccess"
      ],
      "Resource": "arn:aws:elasticfilesystem:eu-west-2:<ACCOUNT_ID>:file-system/<EFS_FILE_SYSTEM_ID>",
      "Condition": { "Bool": { "aws:SecureTransport": "true" } }
    },
    {
      "Sid": "EcsExec",
      "Effect": "Allow",
      "Action": [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    }
  ]
}
```

## 3. camunda-oc1-connectors-task-role

Inline policy `camunda-oc1-connectors` (only needed for ECS Exec; connectors themselves need no AWS permissions unless your outbound connectors call AWS services):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcsExec",
      "Effect": "Allow",
      "Action": [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    }
  ]
}
```
