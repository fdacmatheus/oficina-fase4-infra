# ---------------------------------------------------------------------------
# MailHog: caixa de entrada de teste para os e-mails ao cliente (link de
# aprovação e pagamento do orçamento, avisos de status da OS).
# Ambiente acadêmico: não há SMTP real. O serviço é só interno (ClusterIP); a
# interface web é acessada com:
#   kubectl -n oficina port-forward svc/mailhog 8025:8025
# ---------------------------------------------------------------------------
resource "kubernetes_deployment" "mailhog" {
  metadata {
    name      = "mailhog"
    namespace = kubernetes_namespace.oficina.metadata[0].name
    labels    = { app = "mailhog" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "mailhog" }
    }

    template {
      metadata {
        labels = { app = "mailhog" }
      }

      spec {
        container {
          name  = "mailhog"
          image = "mailhog/mailhog:v1.0.1"

          port {
            name           = "smtp"
            container_port = 1025
          }

          port {
            name           = "http"
            container_port = 8025
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mailhog" {
  metadata {
    name      = "mailhog"
    namespace = kubernetes_namespace.oficina.metadata[0].name
  }

  spec {
    selector = { app = "mailhog" }

    port {
      name        = "smtp"
      port        = 1025
      target_port = "smtp"
    }

    port {
      name        = "http"
      port        = 8025
      target_port = "http"
    }
  }
}
