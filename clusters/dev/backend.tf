# Local state by default. Swap to S3/GCS/Azure when ready.
#
# Example remote backend (S3):
#
# terraform {
#   backend "s3" {
#     bucket         = "shane-agent-platform-tfstate"
#     key            = "clusters/dev/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "agent-platform-tf-locks"
#     encrypt        = true
#   }
# }
