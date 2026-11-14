# ---------------------------------------------------------------------------
# Segredos da plataforma
#
# Fonte unica dos segredos compartilhados. A Lambda le em tempo de execucao e
# os pipelines dos tres microsservicos leem no deploy para montar o Secret do
# Kubernetes de cada um. Nenhum segredo vive em GitHub Secrets alem das
# credenciais de sessao da AWS.
#
# recovery_window_in_days = 0: o laboratorio e destruido e recriado com
# frequencia, e a janela padrao de 30 dias bloquearia recriar o mesmo nome.
# ---------------------------------------------------------------------------
resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "random_password" "jwt_refresh" {
  length  = 64
  special = false
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_password" "chave_interna" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "plataforma" {
  name                    = "${var.project}/plataforma/segredos"
  description             = "JWT, senha do admin e chave interna compartilhados pelos microsservicos e pela Lambda de autenticacao"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "plataforma" {
  secret_id = aws_secretsmanager_secret.plataforma.id

  secret_string = jsonencode({
    JWT_SECRET         = random_password.jwt.result
    JWT_REFRESH_SECRET = random_password.jwt_refresh.result
    ADMIN_PASSWORD     = random_password.admin.result
    INTERNAL_API_KEY   = random_password.chave_interna.result
  })
}

# Senha do Grafana: gerada aqui e entregue ao chart por um Secret do
# Kubernetes (observabilidade.tf), nunca por valor versionado.
resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.project}/plataforma/grafana"
  description             = "Credenciais do usuario admin do Grafana"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id = aws_secretsmanager_secret.grafana.id

  secret_string = jsonencode({
    usuario = "admin"
    senha   = random_password.grafana.result
  })
}
