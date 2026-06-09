# Backend is configured via CLI flags in the workflow:
#   terraform init -backend-config=bucket=$TF_VAR_tf_state_bucket
#   -backend-config=key=terraform.tfstate
#   -backend-config=region=$AWS_REGION
# No backend {} block here — avoids "Missing backend configuration" warning
# when -backend-config is used without a backend block.