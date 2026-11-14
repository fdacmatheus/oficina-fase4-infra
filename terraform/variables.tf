variable "region" {
  description = "Regiao AWS. O AWS Academy Learner Lab so libera us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo aplicado ao nome dos recursos."
  type        = string
  default     = "oficina"
}

variable "cluster_version" {
  description = "Versao do Kubernetes no EKS."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Tipo das instancias do node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Quantidade desejada de nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimo de nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximo de nodes."
  type        = number
  default     = 4
}

variable "namespace" {
  description = "Namespace dos microsservicos."
  type        = string
  default     = "oficina"
}

# As roles do Learner Lab tem sufixo aleatorio por conta (ex.:
# c2215...-LabEksClusterRole-adNS6kIo8yJd); a busca por expressao regular evita
# versionar o nome, que muda a cada laboratorio.
variable "eks_cluster_role_regex" {
  description = "Expressao regular do nome da role de control plane pre-criada pelo Learner Lab."
  type        = string
  default     = ".*LabEksClusterRole.*"
}

variable "eks_node_role_regex" {
  description = "Expressao regular do nome da role dos worker nodes pre-criada pelo Learner Lab."
  type        = string
  default     = ".*LabEksNodeRole.*"
}

variable "lab_role_name" {
  description = "Role de execucao das Lambdas. O Learner Lab nao concede iam:CreateRole."
  type        = string
  default     = "LabRole"
}

variable "lambda_runtime" {
  description = "Runtime das funcoes de autenticacao."
  type        = string
  default     = "nodejs20.x"
}

variable "log_retention_days" {
  description = "Retencao dos logs no CloudWatch (gateway e Lambdas)."
  type        = number
  default     = 7
}
