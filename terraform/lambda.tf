# ---------------------------------------------------------------------------
# Funcoes Lambda de autenticacao
#
# As funcoes sao CRIADAS aqui com um pacote provisorio; o repositorio da Lambda
# so publica o codigo (aws lambda update-function-code). Isso quebra a
# dependencia circular de antes: o gateway precisava do ARN da Lambda e a
# Lambda precisava do endereco do servico atras do gateway. Agora este
# repositorio sobe sozinho, de ponta a ponta, e as rotas ja nascem protegidas.
#
# O pacote provisorio responde 503 na funcao de token e isAuthorized=false no
# authorizer: antes do primeiro deploy do codigo real tudo falha fechado.
# ---------------------------------------------------------------------------
data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

data "archive_file" "lambda_provisoria" {
  type        = "zip"
  output_path = "${path.module}/.build/lambda-provisoria.zip"

  source {
    filename = "index.js"
    content  = <<-JS
      // Pacote provisorio criado pelo Terraform da plataforma. O codigo real
      // e publicado pelo repositorio da Lambda (update-function-code).
      exports.handler = async () => ({
        statusCode: 503,
        isAuthorized: false,
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ mensagem: 'Funcao ainda sem codigo publicado' }),
      });
    JS
  }
}

locals {
  # A funcao de token e o VPC endpoint compartilham as mesmas duas subnets: o
  # trafego nao atravessa AZ e o endpoint custa por AZ.
  lambda_subnet_ids = slice(local.eks_subnet_ids, 0, 2)
}

# ---------------------------------------------------------------------------
# Rede da funcao de token
# Ela chama o os-service pelo NLB interno, que so existe dentro da VPC.
# ---------------------------------------------------------------------------
resource "aws_security_group" "lambda" {
  name        = "${var.project}-lambda-auth-sg"
  description = "Funcao de emissao de token"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-lambda-auth-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "lambda" {
  security_group_id = aws_security_group.lambda.id
  description       = "Saida para o NLB do os-service e o endpoint do Secrets Manager"
  cidr_ipv4         = data.aws_vpc.default.cidr_block
  ip_protocol       = "-1"
}

# ENIs de Lambda nao recebem IP publico e nao ha NAT Gateway (evitado por
# custo): sem este endpoint a chamada ao Secrets Manager fica pendurada ate o
# timeout. ~US$ 0,01/h por AZ contra ~US$ 0,045/h de um NAT.
resource "aws_security_group" "vpc_endpoint" {
  name        = "${var.project}-secretsmanager-endpoint-sg"
  description = "VPC endpoint do Secrets Manager"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Name = "${var.project}-secretsmanager-endpoint-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoint_from_lambda" {
  security_group_id            = aws_security_group.vpc_endpoint.id
  description                  = "HTTPS a partir da funcao de token"
  referenced_security_group_id = aws_security_group.lambda.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type = "Interface"

  subnet_ids          = local.lambda_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project}-secretsmanager-endpoint"
  }
}

# ---------------------------------------------------------------------------
# Funcao de token: valida o CPF, consulta o cliente no os-service
# (/api/internos/clientes com x-chave-interna) e emite um JWT de 15 minutos.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "token" {
  name              = "/aws/lambda/${var.project}-auth-token"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "token" {
  function_name = "${var.project}-auth-token"
  description   = "Valida o CPF, confirma o cliente no os-service e emite um JWT"
  role          = data.aws_iam_role.lab.arn

  filename         = data.archive_file.lambda_provisoria.output_path
  source_code_hash = data.archive_file.lambda_provisoria.output_base64sha256

  handler     = "index.handler"
  runtime     = var.lambda_runtime
  memory_size = 512
  timeout     = 20

  vpc_config {
    subnet_ids         = local.lambda_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      OS_SERVICE_URL = "http://${data.aws_lb.servico["os"].dns_name}"
      SEGREDOS_NAME  = aws_secretsmanager_secret.plataforma.name
      NODE_OPTIONS   = "--enable-source-maps"
    }
  }

  lifecycle {
    # O codigo pertence ao repositorio da Lambda.
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.token, aws_vpc_endpoint.secretsmanager]
}

# ---------------------------------------------------------------------------
# Authorizer: valida o JWT nas rotas protegidas. Nao acessa nada dentro da VPC,
# entao fica fora dela: sem ENI, com cold start menor na funcao invocada a cada
# requisicao protegida (com cache de 5 minutos no gateway).
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${var.project}-auth-authorizer"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "authorizer" {
  function_name = "${var.project}-auth-authorizer"
  description   = "Valida o JWT das rotas protegidas do API Gateway"
  role          = data.aws_iam_role.lab.arn

  filename         = data.archive_file.lambda_provisoria.output_path
  source_code_hash = data.archive_file.lambda_provisoria.output_base64sha256

  handler     = "index.handler"
  runtime     = var.lambda_runtime
  memory_size = 256
  timeout     = 10

  environment {
    variables = {
      SEGREDOS_NAME = aws_secretsmanager_secret.plataforma.name
    }
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.authorizer]
}
