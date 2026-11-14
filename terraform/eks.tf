# ---------------------------------------------------------------------------
# Rede e identidades
# O Learner Lab nao permite criar IAM roles; as roles de control plane e de
# worker node ja vem provisionadas no ambiente e sao localizadas por nome.
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# us-east-1e nao suporta EKS; as demais AZs sao filtradas dinamicamente.
data "aws_subnet" "selected" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

locals {
  eks_subnet_ids = sort([
    for s in data.aws_subnet.selected : s.id
    if s.availability_zone != "us-east-1e"
  ])
}

data "aws_iam_roles" "cluster" {
  name_regex = var.eks_cluster_role_regex
}

data "aws_iam_roles" "node" {
  name_regex = var.eks_node_role_regex
}

# ---------------------------------------------------------------------------
# Cluster EKS
# ---------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = "${var.project}-eks"
  version  = var.cluster_version
  role_arn = one(data.aws_iam_roles.cluster.arns)

  vpc_config {
    subnet_ids              = local.eks_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # Logs do control plane vao para o CloudWatch (trilha de auditoria).
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = {
    Name = "${var.project}-eks"
  }
}

# Launch template dos nodes. Motivo principal: os pods usam o metadata service
# (IMDSv2) para obter a credencial da role dos nodes e falar com SQS e DynamoDB.
# Com IP próprio (VPC CNI), o pod fica a dois saltos de rede do IMDS, e o padrão
# do EKS é um salto só — o SDK falharia com "Could not load credentials".
resource "aws_launch_template" "nodes" {
  name_prefix = "${var.project}-nodes-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.project}-node" }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = one(data.aws_iam_roles.node.arns)
  subnet_ids      = local.eks_subnet_ids

  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Name = "${var.project}-nodes"
  }

  lifecycle {
    # Ajustes manuais de escala durante a demo nao devem ser revertidos no
    # proximo apply.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ---------------------------------------------------------------------------
# Addons gerenciados
# ---------------------------------------------------------------------------
locals {
  # O metrics-server alimenta o HPA de cada microsservico.
  addons = toset(["vpc-cni", "coredns", "kube-proxy", "metrics-server"])
}

data "aws_eks_addon_version" "this" {
  for_each = local.addons

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "this" {
  for_each = local.addons

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.value
  addon_version = data.aws_eks_addon_version.this[each.value].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# ---------------------------------------------------------------------------
# Acesso dos Network Load Balancers aos nodes
#
# O Service do tipo LoadBalancer sem o AWS Load Balancer Controller usa o modo
# "instance": o NLB entrega o trafego no NodePort de cada node, preservando o IP
# de origem. O security group gerenciado do EKS so libera comunicacao entre
# nodes, entao health check, VPC Link e a Lambda de token chegariam bloqueados.
#
# A faixa de NodePort e liberada apenas para dentro da VPC.
# ---------------------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "nodeport_from_vpc" {
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "NodePort a partir dos NLBs e da VPC"
  cidr_ipv4         = data.aws_vpc.default.cidr_block
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
}
