aws_region         = "us-east-1"
project_name       = "tf-ansible-demo"
environment        = "dev"
instance_type      = "t3.micro"
web_instance_count = 1
app_instance_count = 1
spot_max_price     = 0.020
# ssh_public_key is injected via GitHub Secret — do NOT put it here
