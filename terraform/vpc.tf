# terraform/vpc.tf

# AWS 공식 VPC 모듈 사용 (Best Practice)
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "5.5.0" # 최신 안정 버전 사용

  name = "peertube-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"] # 가용 영역 2개 사용 (고가용성)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"] # 앱, DB가 들어갈 곳 (보안)
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"] # 로드밸런서가 들어갈 곳

  # EKS를 위한 필수 태그 설정 (매우 중요!)
  enable_nat_gateway = true   # Private Subnet에서 인터넷 되게 하려면 필수 (비용 발생 주의)
  single_nat_gateway = true   # 테스트용이므로 1개만 생성 (비용 절감)
  enable_dns_hostnames = true

  # EKS가 서브넷을 찾을 때 사용하는 태그
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = {
    Environment = "dev"
    Project     = "peertube"
  }
}