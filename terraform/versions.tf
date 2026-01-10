# terraform/versions.tf

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # [중요] 아까 만든 S3 버킷 이름을 여기에 넣으세요!
  backend "s3" {
    bucket = "my-peertube-tfstate-jki-2026"
    key    = "peertube/terraform.tfstate"
    region = "us-east-1"
    # dynamo_table = "terraform-locks" # (선택사항) 협업 시 락킹 필요하지만 지금은 생략
  }
}

provider "aws" {
  region = "us-east-1"
}