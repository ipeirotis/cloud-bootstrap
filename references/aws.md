# AWS Reference

## User Prerequisites

The user's AWS account needs **IAM full access** or at minimum:
- `iam:CreateUser`
- `iam:CreateAccessKey`
- `iam:AttachUserPolicy` / `iam:PutUserPolicy`

## Bootstrap Token Command

Tell the user to run locally:

```bash
aws sts get-session-token --duration-seconds 3600
```

This returns `AccessKeyId`, `SecretAccessKey`, and `SessionToken`, valid for 1 hour.

Alternatively, if the user has the AWS CLI configured, they can provide their temporary credentials directly:

```bash
# Simpler: just provide the existing credentials context
aws sts get-caller-identity   # to verify they're logged in
```

Then ask them to provide the output of:
```bash
echo '{"access_key":"'$AWS_ACCESS_KEY_ID'","secret_key":"'$AWS_SECRET_ACCESS_KEY'","session_token":"'$AWS_SESSION_TOKEN'"}'
```

## API Approach

Use the AWS CLI (`aws`) if available in the environment. Otherwise, use signed API calls with the temporary credentials.

## Create IAM User

```bash
# Export bootstrap credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."

# Create the user
aws iam create-user --user-name claude-agent

# Create access key
aws iam create-access-key --user-name claude-agent > credentials.json
```

The credentials file will contain `AccessKey.AccessKeyId` and `AccessKey.SecretAccessKey`.

Reformat `credentials.json` to a clean structure before encrypting:

```bash
cat credentials.json | jq '{
  access_key_id: .AccessKey.AccessKeyId,
  secret_access_key: .AccessKey.SecretAccessKey,
  region: "us-east-1"
}' > credentials_clean.json
mv credentials_clean.json credentials.json
```

Ask the user which AWS region to use if not obvious from the repo.

## Grant Roles (Attach Policies)

For AWS managed policies:

```bash
aws iam attach-user-policy \
  --user-name claude-agent \
  --policy-arn arn:aws:iam::aws:policy/POLICY_NAME
```

For inline policies (more granular):

```bash
aws iam put-user-policy \
  --user-name claude-agent \
  --policy-name descriptive-name \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    }]
  }'
```

Prefer inline policies scoped to specific resources over broad managed policies.

## Activate (Subsequent Sessions)

After decrypting credentials to `/tmp/credentials.json`:

```bash
export AWS_ACCESS_KEY_ID=$(jq -r .access_key_id /tmp/credentials.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r .secret_access_key /tmp/credentials.json)
export AWS_DEFAULT_REGION=$(jq -r .region /tmp/credentials.json)
rm -f /tmp/credentials.json

# Verify
aws sts get-caller-identity
```

**Note:** Unlike GCP, AWS credentials are exported as environment variables, not activated via a CLI command. They persist for the duration of the shell session.

## Common Policies Reference

| Need | Managed Policy |
|------|---------------|
| Deploy Lambda | `AWSLambda_FullAccess` (or scoped inline) |
| Manage S3 | `AmazonS3FullAccess` (prefer inline with bucket scope) |
| Manage DynamoDB | `AmazonDynamoDBFullAccess` |
| Deploy via CloudFormation | `AWSCloudFormationFullAccess` |
| Manage SQS | `AmazonSQSFullAccess` |
| Manage SNS | `AmazonSNSFullAccess` |
| Read CloudWatch logs | `CloudWatchLogsReadOnlyAccess` |
| Manage API Gateway | `AmazonAPIGatewayAdministrator` |
| Manage ECS/Fargate | `AmazonECS_FullAccess` |
| Manage Secrets Manager | `SecretsManagerReadWrite` |

**Prefer inline policies scoped to specific resources over these broad managed policies.**
