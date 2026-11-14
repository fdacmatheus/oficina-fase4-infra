# ---------------------------------------------------------------------------
# Observabilidade
#
# Mesmo desenho do ambiente local (local/observabilidade), dentro do cluster:
#   servicos --OTLP--> OpenTelemetry Collector --> Tempo (traces) e Loki (logs)
#   Prometheus raspa /api/metrics de cada servico e recebe do Tempo o mapa de
#   servicos (metrics-generator via remote write)
#   Grafana junta os tres: do trace para os logs e do log para o trace.
#
# Sem volumes persistentes: o driver EBS CSI exige a policy
# AmazonEBSCSIDriverPolicy na role dos nodes, e o Learner Lab nao concede
# iam:AttachRolePolicy. Tudo usa emptyDir; a retencao curta atende a demo.
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [aws_eks_node_group.this]
}

locals {
  # Enderecos internos (Service DNS) dos componentes no namespace monitoring.
  prometheus_url     = "http://kube-prometheus-stack-prometheus.monitoring:9090"
  tempo_url          = "http://tempo.monitoring:3200"
  loki_url           = "http://loki.monitoring:3100"
  otel_collector_url = "http://otel-collector.monitoring.svc.cluster.local:4318"
}

# A senha vem de segredos.tf; o chart le deste Secret e o valor nunca aparece
# nos values do release.
resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
}

# ---------------------------------------------------------------------------
# Prometheus, Alertmanager e Grafana
# ---------------------------------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "92.10.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout = 900

  values = [yamlencode({
    grafana = {
      # Chaves admin-user/admin-password: o padrao do chart.
      admin = {
        existingSecret = kubernetes_secret.grafana_admin.metadata[0].name
      }

      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
          "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
        }
      }

      # Dashboards versionados como codigo: provisionados pelos ConfigMaps
      # rotulados com grafana_dashboard (abaixo).
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          searchNamespace = "ALL"
        }
        datasources = {
          # O datasource Prometheus do chart ja nasce com uid "prometheus",
          # o mesmo do ambiente local; aqui so liga o salto exemplar -> trace.
          exemplarTraceIdDestinations = {
            datasourceUid    = "tempo"
            traceIdLabelName = "trace_id"
            urlDisplayLabel  = "Ver trace"
          }
        }
      }

      # Iguais a local/observabilidade/grafana/datasources/datasources.yaml.
      additionalDataSources = [
        {
          name   = "Tempo"
          uid    = "tempo"
          type   = "tempo"
          access = "proxy"
          url    = local.tempo_url
          jsonData = {
            serviceMap = { datasourceUid = "prometheus" }
            nodeGraph  = { enabled = true }
            # Do trace para os logs daquele trace, nos 3 servicos.
            tracesToLogsV2 = {
              datasourceUid      = "loki"
              spanStartTimeShift = "-5m"
              spanEndTimeShift   = "5m"
              filterByTraceID    = true
              customQuery        = true
              # $$ no arquivo final escapa a expansao de variaveis de
              # ambiente do provisionamento do Grafana (como no local).
              query = "{service_name=~\".+\"} | trace_id=\"$$${__trace.traceId}\""
            }
          }
        },
        {
          name   = "Loki"
          uid    = "loki"
          type   = "loki"
          access = "proxy"
          url    = local.loki_url
          jsonData = {
            # Do log para o trace: o trace_id chega como metadado do OTLP.
            derivedFields = [{
              name          = "trace_id"
              matcherType   = "label"
              matcherRegex  = "trace_id"
              datasourceUid = "tempo"
              url           = "$$${__value.raw}"
            }]
          }
        },
      ]

      "grafana.ini" = {
        "feature_toggles" = { enable = "traceqlEditor" }
      }

      defaultDashboardsTimezone = "America/Sao_Paulo"
    }

    additionalPrometheusRulesMap = local.alertas

    prometheus = merge(local.service_monitors, {
      prometheusSpec = {
        retention = "6h"

        # Recebe as metricas do mapa de servicos geradas pelo Tempo.
        enableRemoteWriteReceiver = true
        enableFeatures            = ["exemplar-storage"]

        # Descobre ServiceMonitor e regras de qualquer namespace.
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false

        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { memory = "1Gi" }
        }

        storageSpec = {
          emptyDir = { medium = "" }
        }
      }
    })

    alertmanager = {
      alertmanagerSpec = {
        resources = {
          requests = { cpu = "50m", memory = "128Mi" }
        }
      }
    }

    prometheusOperator = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
      }
    }
  })]

  depends_on = [aws_eks_addon.this]
}

# ---------------------------------------------------------------------------
# Tempo (monolitico): traces e mapa de servicos
# ---------------------------------------------------------------------------
resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = "1.24.3"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [yamlencode({
    tempo = {
      retention = "24h"

      # So OTLP: o collector e a unica porta de entrada da telemetria.
      receivers = {
        otlp = {
          protocols = {
            grpc = { endpoint = "0.0.0.0:4317" }
            http = { endpoint = "0.0.0.0:4318" }
          }
        }
      }

      # Deriva quem-chama-quem dos spans e grava no Prometheus, alimentando o
      # Service Graph do Grafana.
      metricsGenerator = {
        enabled        = true
        remoteWriteUrl = "${local.prometheus_url}/api/v1/write"
        registry = {
          external_labels = { source = "tempo" }
        }
      }

      overrides = {
        defaults = {
          metrics_generator = {
            processors = ["service-graphs", "span-metrics", "local-blocks"]
          }
        }
      }

      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------------------------------------------------------------------------
# Loki (single binary, filesystem): logs dos servicos via OTLP
# ---------------------------------------------------------------------------
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.55.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  timeout = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"

    loki = {
      auth_enabled  = false
      commonConfig  = { replication_factor = 1 }
      storage       = { type = "filesystem" }
      useTestSchema = false
      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "filesystem"
          schema       = "v13"
          index        = { prefix = "loki_index_", period = "24h" }
        }]
      }
      # O OTLP grava trace_id/span_id como structured metadata.
      limits_config = {
        allow_structured_metadata = true
        volume_enabled            = true
      }
    }

    singleBinary = {
      replicas    = 1
      persistence = { enabled = false }
      # Sem PVC o chart nao monta /var/loki; o emptyDir substitui o volume
      # (o sistema de arquivos raiz do container e somente leitura).
      extraVolumes      = [{ name = "data", emptyDir = {} }]
      extraVolumeMounts = [{ name = "data", mountPath = "/var/loki" }]
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    # Modo monolitico: desliga os componentes do modo escalavel e os caches.
    backend      = { replicas = 0 }
    read         = { replicas = 0 }
    write        = { replicas = 0 }
    gateway      = { enabled = false }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    sidecar      = { rules = { enabled = false } }
  })]

  depends_on = [aws_eks_addon.this]
}

# ---------------------------------------------------------------------------
# OpenTelemetry Collector: porta unica de entrada OTLP dos servicos.
# Mesma configuracao de local/observabilidade/otel-collector.yaml.
# ---------------------------------------------------------------------------
resource "helm_release" "otel_collector" {
  name       = "otel-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.175.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [yamlencode({
    mode             = "deployment"
    fullnameOverride = "otel-collector"

    image = {
      repository = "otel/opentelemetry-collector-contrib"
    }

    config = {
      exporters = {
        "otlp/tempo" = {
          endpoint = "tempo.monitoring:4317"
          tls      = { insecure = true }
        }
        "otlphttp/loki" = {
          endpoint = "${local.loki_url}/otlp"
        }
      }
      service = {
        pipelines = {
          traces = {
            receivers  = ["otlp"]
            processors = ["memory_limiter", "batch"]
            exporters  = ["otlp/tempo"]
          }
          logs = {
            receivers  = ["otlp"]
            processors = ["memory_limiter", "batch"]
            exporters  = ["otlphttp/loki"]
          }
        }
      }
    }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "512Mi" }
    }
  })]

  depends_on = [helm_release.tempo, helm_release.loki]
}

# ---------------------------------------------------------------------------
# Dashboards como codigo
# O sidecar do Grafana carrega todo ConfigMap rotulado com grafana_dashboard.
# ---------------------------------------------------------------------------
resource "kubernetes_config_map" "dashboards" {
  for_each = fileset("${path.module}/dashboards", "*.json")

  metadata {
    name      = "grafana-dashboard-${trimsuffix(each.value, ".json")}"
    namespace = kubernetes_namespace.monitoring.metadata[0].name

    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    (each.value) = file("${path.module}/dashboards/${each.value}")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# URL publica do Grafana: o NLB internet-facing do Service do chart.
data "kubernetes_service" "grafana" {
  metadata {
    name      = "kube-prometheus-stack-grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

# ---------------------------------------------------------------------------
# ServiceMonitor e PrometheusRule
# Entregues como values do chart, que os renderiza depois de instalar as CRDs;
# com kubernetes_manifest a CRD precisaria existir ja no plan.
# ---------------------------------------------------------------------------
locals {
  # Um ServiceMonitor por servico, selecionando o Service ClusterIP do
  # repositorio do servico (label app, porta nomeada http). O label job das
  # series fica igual ao nome do Service, o mesmo do ambiente local.
  service_monitors = {
    additionalServiceMonitors = [
      for s in values(local.servicos) : {
        name              = s.nome
        namespaceSelector = { matchNames = [var.namespace] }
        selector          = { matchLabels = { app = s.nome } }
        endpoints = [{
          port     = "http"
          path     = "/api/metrics"
          interval = "15s"
        }]
      }
    ]
  }

  # Seletor dos tres servicos nas expressoes PromQL.
  jobs = "job=~\"oficina-(os|billing|execution)-service\""

  alertas = {
    "oficina-disponibilidade" = {
      groups = [{
        name = "oficina.disponibilidade"
        rules = [
          {
            alert  = "ServicoIndisponivel"
            expr   = "up{${local.jobs}} == 0"
            for    = "2m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "{{ $labels.job }} fora do ar"
              description = "O alvo {{ $labels.instance }} nao responde ao scrape ha 2 minutos."
            }
          },
          {
            alert  = "ServicoSemReplicas"
            expr   = "absent(up{job=\"oficina-os-service\"} == 1) or absent(up{job=\"oficina-billing-service\"} == 1) or absent(up{job=\"oficina-execution-service\"} == 1)"
            for    = "5m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Algum microsservico esta sem nenhuma replica no ar"
              description = "Nenhum alvo saudavel de pelo menos um servico ha 5 minutos."
            }
          },
          {
            alert  = "PodsReiniciandoEmLoop"
            expr   = "increase(kube_pod_container_status_restarts_total{namespace=\"${var.namespace}\"}[15m]) > 3"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Pod {{ $labels.pod }} reiniciando repetidamente"
              description = "Mais de 3 reinicios em 15 minutos, provavel falha de liveness probe."
            }
          },
        ]
      }]
    }

    "oficina-desempenho" = {
      groups = [{
        name = "oficina.desempenho"
        rules = [
          {
            alert  = "LatenciaAlta"
            expr   = "histogram_quantile(0.95, sum by (job, le) (rate(http_request_duration_seconds_bucket{${local.jobs}}[5m]))) > 1"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Latencia p95 acima de 1 segundo em {{ $labels.job }}"
              description = "O percentil 95 das requisicoes esta em {{ $value }}s."
            }
          },
          {
            alert  = "TaxaErro5xxAlta"
            expr   = "sum by (job) (rate(http_requests_total{${local.jobs},status=~\"5..\"}[5m])) / clamp_min(sum by (job) (rate(http_requests_total{${local.jobs}}[5m])), 0.001) > 0.05"
            for    = "5m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Mais de 5% de erros 5xx em {{ $labels.job }}"
              description = "Taxa atual: {{ $value | humanizePercentage }}."
            }
          },
          {
            alert  = "HpaNoTeto"
            expr   = "kube_horizontalpodautoscaler_status_current_replicas{namespace=\"${var.namespace}\"} >= kube_horizontalpodautoscaler_spec_max_replicas{namespace=\"${var.namespace}\"}"
            for    = "10m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "HPA {{ $labels.horizontalpodautoscaler }} no numero maximo de replicas"
              description = "No teto de escala ha 10 minutos; avaliar aumento do maxReplicas."
            }
          },
        ]
      }]
    }

    "oficina-saga" = {
      groups = [{
        name = "oficina.saga"
        rules = [
          {
            alert  = "CompensacoesEmAlta"
            expr   = "sum(increase(oficina_saga_compensacoes_total[15m])) > 5"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Muitas compensacoes na saga"
              description = "{{ $value }} compensacoes em 15 minutos; verificar pagamento, estoque e execucao."
            }
          },
          {
            alert  = "OutboxPendenteAlta"
            expr   = "sum by (job) (oficina_outbox_pendentes) > 50"
            for    = "5m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Outbox acumulando mensagens em {{ $labels.job }}"
              description = "{{ $value }} mensagens sem publicar no SQS: a saga esta parada."
            }
          },
          {
            alert  = "FalhaProcessamentoOrdemServico"
            expr   = "increase(oficina_ordem_servico_erros_total[10m]) > 0"
            for    = "1m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Falha no processamento de ordens de servico"
              description = "{{ $value }} erro(s) nos ultimos 10 minutos, operacao {{ $labels.operacao }}."
            }
          },
          {
            alert  = "FalhaIntegracao"
            expr   = "sum by (job, integracao) (increase(oficina_integracao_falhas_total[15m])) > 5"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Integracao {{ $labels.integracao }} falhando em {{ $labels.job }}"
              description = "Mais de 5 falhas em 15 minutos (e-mail, Mercado Pago ou SQS)."
            }
          },
          {
            alert  = "OrdensParadasAguardandoAprovacao"
            expr   = "sum(oficina_ordens_servico_por_status{status=\"AGUARDANDO_APROVACAO\"}) > 20"
            for    = "30m"
            labels = { severity = "info" }
            annotations = {
              summary     = "Acumulo de ordens aguardando aprovacao do cliente"
              description = "{{ $value }} ordens aguardando resposta do orcamento."
            }
          },
        ]
      }]
    }
  }
}
