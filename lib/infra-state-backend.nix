# Generates Terraform resource configuration for OpenTofu remote state storage.
#
# Creates an S3 bucket (versioned, encrypted, no public access) and a DynamoDB
# table for state locking. Use this as the `configs` input to infra-workspace.nix.
#
# Usage:
#   stateResources = import "${substrate}/lib/infra-state-backend.nix" {
#     bucket = "my-org-terraform-state";
#     dynamodbTable = "my-org-terraform-locks";
#   };
#   # stateResources is a Nix attrset suitable for "main.tf.json"
#
# Returns: { resource = { aws_s3_bucket, aws_s3_bucket_versioning, ... }; }
{
  bucket,
  dynamodbTable,
  region ? "us-east-1",
  tags ? {},
}:

let
  baseTags = {
    ManagedBy = "opentofu";
    Purpose   = "terraform-state";
  } // tags;

in {
  resource = {
    # ── S3 bucket for state storage ───────────────────────────────────

    aws_s3_bucket.state = {
      bucket = bucket;
      tags   = baseTags // { Name = bucket; };

      lifecycle = {
        prevent_destroy = true;
      };
    };

    aws_s3_bucket_versioning.state = {
      bucket = "\${aws_s3_bucket.state.id}";

      versioning_configuration = {
        status = "Enabled";
      };
    };

    aws_s3_bucket_server_side_encryption_configuration.state = {
      bucket = "\${aws_s3_bucket.state.id}";

      rule = {
        apply_server_side_encryption_by_default = {
          sse_algorithm = "aws:kms";
        };
        bucket_key_enabled = true;
      };
    };

    aws_s3_bucket_public_access_block.state = {
      bucket                  = "\${aws_s3_bucket.state.id}";
      block_public_acls       = true;
      block_public_policy     = true;
      ignore_public_acls      = true;
      restrict_public_buckets = true;
    };

    # ── DynamoDB table for state locking ──────────────────────────────

    aws_dynamodb_table.locks = {
      name         = dynamodbTable;
      billing_mode = "PAY_PER_REQUEST";
      hash_key     = "LockID";

      attribute = [{
        name = "LockID";
        type = "S";
      }];

      tags = baseTags // { Name = dynamodbTable; };

      lifecycle = {
        prevent_destroy = true;
      };
    };
  };

  # ── Outputs for reference by other workspaces ─────────────────────

  output = {
    state_bucket_arn = {
      value       = "\${aws_s3_bucket.state.arn}";
      description = "ARN of the S3 state bucket";
    };
    state_bucket_name = {
      value       = "\${aws_s3_bucket.state.id}";
      description = "Name of the S3 state bucket";
    };
    lock_table_arn = {
      value       = "\${aws_dynamodb_table.locks.arn}";
      description = "ARN of the DynamoDB lock table";
    };
    lock_table_name = {
      value       = "\${aws_dynamodb_table.locks.name}";
      description = "Name of the DynamoDB lock table";
    };
  };
}
