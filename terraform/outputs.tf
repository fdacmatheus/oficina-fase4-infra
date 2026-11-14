output "cluster_name" {
  description = "Nome do cluster EKS (EKS_CLUSTER nos pipelines dos servicos)."
  value       = aws_eks_cluster.this.name
}

output "kubeconfig_command" {
  description = "Comando para configurar o kubectl."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}"
}

output "namespace" {
  description = "Namespace dos microsservicos."
  value       = kubernetes_namespace.oficina.metadata[0].name
}

output "api_gateway_url" {
  description = "URL publica do sistema. Unico ponto de entrada."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "grafana_url" {
  description = "URL publica do Grafana (usuario admin; senha no secret de grafana_secret_name)."
  value       = try("http://${data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].hostname}", "")
}

output "nlb_dns" {
  description = "DNS interno do NLB de cada microsservico."
  value       = { for k, lb in data.aws_lb.servico : k => lb.dns_name }
}

output "otel_exporter_otlp_endpoint" {
  description = "Valor de OTEL_EXPORTER_OTLP_ENDPOINT nos ConfigMaps dos servicos."
  value       = local.otel_collector_url
}

output "segredos_secret_name" {
  description = "Secret com JWT_SECRET, JWT_REFRESH_SECRET, ADMIN_PASSWORD e INTERNAL_API_KEY."
  value       = aws_secretsmanager_secret.plataforma.name
}

output "grafana_secret_name" {
  description = "Secret com as credenciais do Grafana."
  value       = aws_secretsmanager_secret.grafana.name
}

output "lambda_token_name" {
  description = "Funcao de emissao de token; o repositorio da Lambda publica o codigo nela."
  value       = aws_lambda_function.token.function_name
}

output "lambda_authorizer_name" {
  description = "Funcao authorizer; o repositorio da Lambda publica o codigo nela."
  value       = aws_lambda_function.authorizer.function_name
}

output "vpc_id" {
  description = "VPC onde o cluster foi criado."
  value       = data.aws_vpc.default.id
}

output "cluster_security_group_id" {
  description = "Security group gerenciado do cluster."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
