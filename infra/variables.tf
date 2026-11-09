variable "region" {
  type        = string
  description = "AWS region used by the Academy environment."
  default     = "us-east-1"
}

variable "project" {
  type    = string
  default = "workshop"
}

variable "cluster_state_bucket" {
  type        = string
  description = "S3 bucket containing the cluster Terraform state. In GitHub Actions this is supplied from TFSTATE_BUCKET."
}


variable "terraform_state_key" {
  type        = string
  description = "State key shared by cluster and database states."
  default     = "cluster/terraform.tfstate"
}



variable "jwt_secret" {
  type      = string
  sensitive = true
  validation {
    condition     = length(var.jwt_secret) >= 32
    error_message = "jwt_secret must contain at least 32 characters."
  }
}



variable "lambda_handler" {
  type        = string
  description = "Handler implemented by the W4 auth core/handler PRs."
  # Apenas a classe, sem o sufixo ::handleRequest. A instrumentacao aws-lambda
  # do agente OpenTelemetry reconhece o handler pela classe; com o metodo
  # explicito ela nao carrega e nenhum span e gerado, embora metricas e logs
  # continuem sendo exportados normalmente.
  default = "com.postech.auth.handler.AuthHandler"
}

variable "adot_layer_arn" {
  type        = string
  description = "ARN of the AWS Distro for OpenTelemetry Java Lambda layer compatible with Java 21 in the selected region."
  validation {
    condition     = can(regex("^arn:[^:]+:lambda:[^:]+:[0-9]{12}:layer:[^:]+:[0-9]+$", var.adot_layer_arn))
    error_message = "adot_layer_arn must be a valid regional Lambda layer ARN."
  }
}

variable "new_relic_otlp_endpoint" {
  type        = string
  description = "New Relic OTLP/HTTP endpoint, without credentials."
  # Sem porta explicita o SDK usa 443, que e a unica saida HTTPS liberada no
  # security group. A porta 4318 exigiria abrir egress adicional sem ganho: a
  # New Relic serve o mesmo OTLP/HTTP nas duas.
  default = "https://otlp.nr-data.net"
  validation {
    condition     = can(regex("^https://", var.new_relic_otlp_endpoint))
    error_message = "new_relic_otlp_endpoint must use HTTPS."
  }
}

variable "new_relic_api_key" {
  type        = string
  description = "New Relic ingest key. Supplied by the prod environment and never emitted as an output."
  sensitive   = true
  validation {
    condition     = length(trimspace(var.new_relic_api_key)) >= 20
    error_message = "new_relic_api_key must be supplied through a secret and contain at least 20 characters."
  }
}

variable "deployment_environment" {
  type        = string
  description = "Deployment environment attached to OpenTelemetry resources."
  default     = "prod"
  validation {
    condition     = contains(["prod", "staging", "dev", "test"], var.deployment_environment)
    error_message = "deployment_environment must be one of prod, staging, dev, or test."
  }
}

variable "service_version" {
  type        = string
  description = "Immutable application version, normally the Git SHA injected by CI."
  validation {
    condition     = can(regex("^[0-9a-f]{7,64}$", var.service_version))
    error_message = "service_version must be a lowercase hexadecimal Git SHA."
  }
}

variable "lambda_artifact_path" {
  type    = string
  default = "../target/function.zip"
}

variable "api_throttling_burst_limit" {
  type    = number
  default = 50
}

variable "api_throttling_rate_limit" {
  type    = number
  default = 25
}


variable "identity_url" {
  type = string
  validation {
    condition     = can(regex("^http://[A-Za-z0-9.-]+:8081$", var.identity_url))
    error_message = "Use the private Phase4 NLB identity listener URL, http://host:8081, without path or credentials."
  }
}
variable "auth_service_token" {
  type      = string
  sensitive = true
  validation {
    condition     = length(var.auth_service_token) >= 32
    error_message = "Provide the same private AUTH_SERVICE_TOKEN to OS and Lambda."
  }
}
variable "fase4_routes_enabled" {
  type    = bool
  default = false
}
variable "fase4_nlb_name" {
  type    = string
  default = "workshop-fase4-internal"
}


variable "auth_version_override" {
  type        = string
  default     = ""
  description = "Published immutable Lambda version for deliberate alias rollback; empty preserves the currently published prod alias."
  validation {
    condition     = var.auth_version_override == "" || can(regex("^[1-9][0-9]*$", var.auth_version_override))
    error_message = "Provide an immutable published version number or leave empty."
  }
}
