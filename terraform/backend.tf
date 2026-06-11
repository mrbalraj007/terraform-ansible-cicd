terraform {
  backend "s3" {
    bucket         = "aws-oidc-terraform-ansible-cicd-20260611"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true
  }
}
