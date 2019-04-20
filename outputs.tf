output "alb_hostname" {
  value = "${aws_alb.main.dns_name}"
}

output "domain_ecs" {
  value = "${cloudflare_record.alb_domain.hostname}"
}
