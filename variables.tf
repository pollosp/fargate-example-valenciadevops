variable "aws_region" {
  description = "The AWS region to create things in."
  default     = "us-east-1"
}

variable "az_count" {
  description = "Number of AZs to cover in a given AWS region"
  default     = "2"
}

variable "app_image" {
  description = "Docker image to run in the ECS cluster"
  default     = "gcr.io/cloudrun/hello"
}

variable "app_port" {
  description = "Port exposed by the docker image to redirect traffic to"
  default     = 8080
}

variable "app_count" {
  description = "Number of docker containers to run"
  default     = 2
}

variable "fargate_cpu" {
  description = "Fargate instance CPU units to provision (1 vCPU = 1024 CPU units)"
  default     = "256"
}

variable "fargate_memory" {
  description = "Fargate instance memory to provision (in MiB)"
  default     = "512"
}

variable "acm_domain_name" {
  description = "Certificate domain name"
  default     = "fargate.omarlopez.dev"
}

variable "cloudflare_zone" {
  description = "Cloudflare domain zone"
  default     = "omarlopez.dev"
}

variable "cluster_name" {
  description = "Cluster name"
  default     = "vlcdevops"
}

variable "giphy_token" {
  description = "Giphy token"
}
