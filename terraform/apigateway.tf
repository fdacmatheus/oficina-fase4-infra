# ---------------------------------------------------------------------------
# API Gateway
# Unico ponto de entrada do sistema. Os NLBs dos microsservicos sao internos,
# entao nao existe caminho que alcance um servico sem passar pelo gateway e, nas
# rotas sensiveis, pelo authorizer.
# ---------------------------------------------------------------------------
resource "aws_security_group" "vpc_link" {
  name        = "${var.project}-vpc-link-sg"
  description = "VPC Link entre o API Gateway e os NLBs internos"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-vpc-link-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link" {
  security_group_id = aws_security_group.vpc_link.id
  description       = "Saida para os NLBs internos"
  cidr_ipv4         = data.aws_vpc.default.cidr_block
  ip_protocol       = "-1"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.project}-vpc-link"
  subnet_ids         = local.eks_subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]

  tags = {
    Name = "${var.project}-vpc-link"
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
  description   = "Gateway da Oficina - Tech Challenge SOAT Fase 4 (microsservicos)"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_headers = ["content-type", "authorization"]
    max_age       = 300
  }
}

# ---------------------------------------------------------------------------
# Tabela de rotas
#
# Cada servico ganha um prefixo (/os, /billing, /execution) que o gateway
# remove antes de encaminhar: GET /os/api/clientes chega ao os-service como
# GET /api/clientes. A reescrita e feita pelo parameter mapping da integracao
# ("overwrite:path"), que no HTTP API e definido por integracao — por isso cada
# rota tem a sua, com o caminho de destino montado a partir do parametro guloso
# {proxy+}: ${request.path.proxy}, a forma com chaves que a documentacao pede
# ao combinar texto fixo e variavel (no HCL, escrita com $$ de escape). A
# query string segue intacta.
#
# Precedencia: o HTTP API escolhe a rota mais especifica, entao
# /os/api/publico/{proxy+} vence /os/api/{proxy+} sem depender de ordem.
# ---------------------------------------------------------------------------
locals {
  rotas_por_servico = merge([
    for k, s in local.servicos : {
      "GET /${k}/api/health"    = { servico = k, caminho = "/api/health", protegida = false }
      "ANY /${k}/api/{proxy+}"  = { servico = k, caminho = "/api/$${request.path.proxy}", protegida = true }
      "ANY /${k}/docs"          = { servico = k, caminho = "/docs", protegida = false }
      "ANY /${k}/docs/{proxy+}" = { servico = k, caminho = "/docs/$${request.path.proxy}", protegida = false }
      "ANY /${k}/docs-json"     = { servico = k, caminho = "/docs-json", protegida = false }
    }
  ]...)

  rotas = merge(local.rotas_por_servico, {
    # Consulta publica de status da OS pelo numero.
    "ANY /os/api/publico/{proxy+}" = { servico = "os", caminho = "/api/publico/$${request.path.proxy}", protegida = false }

    # Login do administrador: exigir token para obter um token deixaria o
    # operador sem caminho de entrada.
    "POST /os/api/auth/{proxy+}" = { servico = "os", caminho = "/api/auth/$${request.path.proxy}", protegida = false }

    # Rotas internas (/api/internos) sao usadas so pela Lambda de token, que
    # chama o NLB do os-service por dentro da VPC. No gateway elas nao existem:
    # a rota mais especifica captura o prefixo e reescreve para um caminho
    # inexistente, e o os-service responde 404. Mesmo que a chave interna
    # vazasse, nao ha como usa-la pela internet. O os-service ainda exige o
    # header x-chave-interna (defesa em profundidade).
    "ANY /os/api/internos/{proxy+}" = { servico = "os", caminho = "/api/rota-indisponivel-no-gateway", protegida = false }

    # Link de aprovacao/pagamento do orcamento, aberto pelo cliente a partir do
    # e-mail; protegido pelo token do proprio link.
    "ANY /billing/api/publico/{proxy+}" = { servico = "billing", caminho = "/api/publico/$${request.path.proxy}", protegida = false }

    # Webhook do Mercado Pago; protegido pela assinatura x-signature.
    "ANY /billing/api/webhooks/{proxy+}" = { servico = "billing", caminho = "/api/webhooks/$${request.path.proxy}", protegida = false }
  })
}

resource "aws_apigatewayv2_integration" "servico" {
  for_each = local.rotas

  api_id             = aws_apigatewayv2_api.this.id
  description        = "${each.key} -> ${local.servicos[each.value.servico].nome}${each.value.caminho}"
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = data.aws_lb_listener.servico[each.value.servico].arn

  connection_type = "VPC_LINK"
  connection_id   = aws_apigatewayv2_vpc_link.this.id

  payload_format_version = "1.0"
  timeout_milliseconds   = 30000

  request_parameters = {
    "overwrite:path" = each.value.caminho
  }
}

resource "aws_apigatewayv2_route" "servico" {
  for_each = local.rotas

  api_id    = aws_apigatewayv2_api.this.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.servico[each.key].id}"

  authorization_type = each.value.protegida ? "CUSTOM" : "NONE"
  authorizer_id      = each.value.protegida ? aws_apigatewayv2_authorizer.jwt.id : null
}

# ---------------------------------------------------------------------------
# Emissao de token por CPF: publica por definicao.
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_integration" "auth" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.token.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 20000
}

resource "aws_apigatewayv2_route" "auth" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /auth"
  target    = "integrations/${aws_apigatewayv2_integration.auth.id}"
}

# ---------------------------------------------------------------------------
# Authorizer
# O authorizer JWT nativo exige um emissor OIDC com JWKS publico; o token e
# HS256 assinado pela propria Lambda, entao a validacao e um authorizer Lambda
# do tipo REQUEST com respostas simples e cache de 5 minutos.
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id          = aws_apigatewayv2_api.this.id
  authorizer_type = "REQUEST"
  authorizer_uri  = aws_lambda_function.authorizer.invoke_arn

  identity_sources                  = ["$request.header.Authorization"]
  name                              = "${var.project}-jwt-authorizer"
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 300
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.jwt.id}"
}

resource "aws_lambda_permission" "token" {
  statement_id  = "AllowAPIGatewayInvokeToken"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.token.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*/auth"
}

# ---------------------------------------------------------------------------
# Stage e logs
# Logs de acesso em JSON estruturado, com o requestId para correlacionar a
# requisicao do gateway com o trace e os logs dos servicos.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn

    format = jsonencode({
      requestId        = "$context.requestId"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      path             = "$context.path"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLatency  = "$context.responseLatency"
      integrationError = "$context.integrationErrorMessage"
      authorizerError  = "$context.authorizer.error"
      sourceIp         = "$context.identity.sourceIp"
      userAgent        = "$context.identity.userAgent"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 200
    throttling_rate_limit    = 100
  }
}
