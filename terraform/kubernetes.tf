# ---------------------------------------------------------------------------
# Microsservicos
# A chave e o prefixo da rota no API Gateway (/os, /billing, /execution); o nome
# e o mesmo do Deployment e do Service ClusterIP do repositorio de cada servico.
# ---------------------------------------------------------------------------
locals {
  servicos = {
    os        = { nome = "oficina-os-service", porta = 3001 }
    billing   = { nome = "oficina-billing-service", porta = 3002 }
    execution = { nome = "oficina-execution-service", porta = 3003 }
  }
}

resource "kubernetes_namespace" "oficina" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/part-of" = var.project
    }
  }

  depends_on = [aws_eks_node_group.this]
}

# ---------------------------------------------------------------------------
# Um NLB interno por microsservico
#
# O Service LoadBalancer pertence a esta camada porque e ele quem provisiona o
# NLB consumido pelo API Gateway. O Deployment, o HPA e o Service ClusterIP
# pertencem ao repositorio de cada servico e sao alcancados por label selector,
# de modo que a ordem de deploy entre os repositorios e indiferente.
#
# O sufixo -nlb evita colisao com o Service ClusterIP homonimo do repositorio do
# servico. Este Service NAO leva o label "app": o ServiceMonitor seleciona por
# ele, e cada pod seria raspado duas vezes.
# ---------------------------------------------------------------------------
resource "kubernetes_service" "nlb" {
  for_each = local.servicos

  metadata {
    name      = "${each.value.nome}-nlb"
    namespace = kubernetes_namespace.oficina.metadata[0].name

    labels = {
      "app.kubernetes.io/name"      = each.value.nome
      "app.kubernetes.io/component" = "nlb"
      "app.kubernetes.io/part-of"   = var.project
    }

    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-type"             = "nlb"
      "service.beta.kubernetes.io/aws-load-balancer-internal"         = "true"
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"  = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path" = "/api/health"
    }
  }

  spec {
    type = "LoadBalancer"

    selector = {
      app = each.value.nome
    }

    port {
      name        = "http"
      port        = 80
      target_port = each.value.porta
      protocol    = "TCP"
    }
  }

  # O NLB leva alguns minutos para ficar ativo; sem isso o API Gateway e a
  # Lambda seriam criados apontando para um hostname ainda vazio.
  wait_for_load_balancer = true

  depends_on = [aws_eks_addon.this]
}

# O NLB e criado pelo controlador do Kubernetes em resposta ao Service; e
# localizado pelas tags que o proprio controlador aplica.
data "aws_lb" "servico" {
  for_each = local.servicos

  tags = {
    "kubernetes.io/service-name" = "${var.namespace}/${kubernetes_service.nlb[each.key].metadata[0].name}"
  }
}

data "aws_lb_listener" "servico" {
  for_each = local.servicos

  load_balancer_arn = data.aws_lb.servico[each.key].arn
  port              = 80
}
