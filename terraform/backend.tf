# Backend is configured via CLI flags in the workflow:
#   terraform init -backend-config=bucket=$TF_VAR_tf_state_bucket
##   -backend-config=key=terraform.tfstate
#   -backend-config=region=$AWS_REGION
# The empty backend "s3" {} block signals intent to use S3, so Terraform
# doesn't warn when -backend-config is passed at init time.

#################################################################################
terraform {
  backend "s3" {}
}