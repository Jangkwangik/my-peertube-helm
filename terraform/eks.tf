# =============================================================================
# 1. IAM 역할 및 정책 (신분증 발급소)
# =============================================================================

# -----------------------------------------------------------------------------
# [Cluster Role] EKS 지휘 본부(Control Plane)가 사용할 역할
# -----------------------------------------------------------------------------
resource "aws_iam_role" "cluster_role" {
  name = "peertube-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster_role.name
}

# -----------------------------------------------------------------------------
# [Node Role] 워커 노드(EC2)들이 사용할 통합 역할 ⭐ (여기가 핵심!)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "node_role" {
  name = "peertube-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# [필수 권한 1] 노드가 클러스터에 합류하고 워크로드를 실행할 권한
resource "aws_iam_role_policy_attachment" "node_policy_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role.name
}

# [필수 권한 2] 노드가 VPC IP 주소를 할당받을 권한 (CNI)
resource "aws_iam_role_policy_attachment" "node_policy_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role.name
}

# [필수 권한 3] ECR에서 컨테이너 이미지를 다운로드할 권한
resource "aws_iam_role_policy_attachment" "node_policy_registry" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role.name
}

# [핵심 권한 4] EBS 하드디스크를 생성/연결할 권한 (드라이버 에러 방지용)
resource "aws_iam_role_policy_attachment" "node_policy_ebs" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.node_role.name
}

# =============================================================================
# 2. 보안 그룹 (Security Group)
# =============================================================================
resource "aws_security_group" "cluster_sg" {
  name        = "peertube-cluster-sg"
  description = "EKS cluster communication"
  vpc_id      = module.vpc.vpc_id

  # 아웃바운드: 모든 통신 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "peertube-cluster-sg" }
}

# =============================================================================
# 3. EKS 클러스터 (Control Plane)
# =============================================================================
resource "aws_eks_cluster" "this" {
  name     = "peertube-cluster"
  version  = "1.31" # 안정적인 버전 사용
  role_arn = aws_iam_role.cluster_role.arn

  vpc_config {
    subnet_ids              = concat(module.vpc.public_subnets, module.vpc.private_subnets)
    security_group_ids      = [aws_security_group.cluster_sg.id]
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # 역할 생성 후 클러스터 생성 시작
  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# =============================================================================
# 4. 노드 그룹 (Worker Nodes)
# =============================================================================

# (1) ArgoCD Node
resource "aws_eks_node_group" "argocd" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "argocd-node-group"
  node_role_arn   = aws_iam_role.node_role.arn # ⭐ 통합 역할 사용
  subnet_ids      = module.vpc.private_subnets

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 2
  }

  instance_types = ["t3.medium"]
  disk_size      = 20
  labels         = { role = "argocd" }

  depends_on = [
    aws_iam_role_policy_attachment.node_policy_worker,
    aws_iam_role_policy_attachment.node_policy_cni,
    aws_iam_role_policy_attachment.node_policy_registry,
    aws_iam_role_policy_attachment.node_policy_ebs
  ]
}

# (2) Monitoring Node
resource "aws_eks_node_group" "monitoring" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "monitoring-node-group"
  node_role_arn   = aws_iam_role.node_role.arn # ⭐ 통합 역할 사용
  subnet_ids      = module.vpc.private_subnets

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 3
  }

  instance_types = ["t3.large"]
  disk_size      = 50
  labels         = { role = "monitoring" }

  depends_on = [aws_iam_role_policy_attachment.node_policy_ebs]
}

# (3) App Node
resource "aws_eks_node_group" "app" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "app-node-group"
  node_role_arn   = aws_iam_role.node_role.arn # ⭐ 통합 역할 사용
  subnet_ids      = module.vpc.private_subnets

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 5
  }

  instance_types = ["t3.medium"]
  disk_size      = 20
  labels         = { role = "app" }

  tags = {
    "k8s.io/cluster-autoscaler/enabled" = "true"
    "k8s.io/cluster-autoscaler/peertube-cluster" = "owned"
  }

  depends_on = [aws_iam_role_policy_attachment.node_policy_ebs]
}

# =============================================================================
# 5. 애드온 (Add-ons)
# =============================================================================
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  
  # CoreDNS는 노드가 있어야 실행 가능하므로 의존성 추가
  depends_on = [
    aws_eks_node_group.app,
    aws_eks_node_group.monitoring,
    aws_eks_node_group.argocd
  ]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"

  # ⭐ 노드가 먼저 생성되어야 드라이버가 설치됨
  depends_on = [
    aws_eks_node_group.app,
    aws_eks_node_group.monitoring,
    aws_eks_node_group.argocd
  ]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
}