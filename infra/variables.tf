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

variable "database_state_bucket" {
  type        = string
  description = "S3 bucket containing the database Terraform state. In GitHub Actions this is supplied from TFSTATE_BUCKET."
}

variable "terraform_state_key" {
  type        = string
  description = "State key shared by cluster and database states."
  default     = "cluster/terraform.tfstate"
}

variable "database_state_key" {
  type    = string
  default = "database/terraform.tfstate"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "jwt_secret" {
  type      = string
  sensitive = true
  validation {
    condition     = length(var.jwt_secret) >= 32
    error_message = "jwt_secret must contain at least 32 characters."
  }
}

variable "db_username" {
  type    = string
  default = "workshop"
}

variable "db_name" {
  type    = string
  default = "workshop"
}

variable "lambda_handler" {
  type        = string
  description = "Handler implemented by the W4 auth core/handler PRs."
  default     = "com.postech.auth.handler.AuthHandler::handleRequest"
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
