# Specify the provider and access details

provider "aws" {
  region     = "eu-west-1"
}

provider "cloudflare" {}

### Network

# Fetch AZs in the current region
data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block = "172.17.0.0/16"
}

# Create var.az_count private subnets, each in a different AZ
resource "aws_subnet" "private" {
  count             = "${var.az_count}"
  cidr_block        = "${cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)}"
  availability_zone = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id            = "${aws_vpc.main.id}"
}

# Create var.az_count public subnets, each in a different AZ
resource "aws_subnet" "public" {
  count                   = "${var.az_count}"
  cidr_block              = "${cidrsubnet(aws_vpc.main.cidr_block, 8, var.az_count + count.index)}"
  availability_zone       = "${data.aws_availability_zones.available.names[count.index]}"
  vpc_id                  = "${aws_vpc.main.id}"
  map_public_ip_on_launch = true
}

# IGW for the public subnet
resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"
}

# Route the public subnet traffic through the IGW
resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.main.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.gw.id}"
}

# Create a NAT gateway with an EIP for each private subnet to get internet connectivity
resource "aws_eip" "gw" {
  count      = "${var.az_count}"
  vpc        = true
  depends_on = ["aws_internet_gateway.gw"]
}

resource "aws_nat_gateway" "gw" {
  count         = "${var.az_count}"
  subnet_id     = "${element(aws_subnet.public.*.id, count.index)}"
  allocation_id = "${element(aws_eip.gw.*.id, count.index)}"
}

# Create a new route table for the private subnets
# And make it route non-local traffic through the NAT gateway to the internet
resource "aws_route_table" "private" {
  count  = "${var.az_count}"
  vpc_id = "${aws_vpc.main.id}"

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${element(aws_nat_gateway.gw.*.id, count.index)}"
  }
}

# Explicitely associate the newly created route tables to the private subnets (so they don't default to the main route table)
resource "aws_route_table_association" "private" {
  count          = "${var.az_count}"
  subnet_id      = "${element(aws_subnet.private.*.id, count.index)}"
  route_table_id = "${element(aws_route_table.private.*.id, count.index)}"
}

### Security

# ALB Security group
# This is the group you need to edit if you want to restrict access to your application
resource "aws_security_group" "lb" {
  name        = "tf-${var.cluster_name}-ecs-alb"
  description = "controls access to the ALB"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Traffic to the ECS Cluster should only come from the ALB
resource "aws_security_group" "ecs_tasks" {
  name        = "tf-${var.cluster_name}-ecs-tasks"
  description = "allow inbound access from the ALB only"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    protocol        = "tcp"
    from_port       = "${var.app_port}"
    to_port         = "${var.app_port}"
    security_groups = ["${aws_security_group.lb.id}"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#KMS
resource "aws_kms_key" "app1" {
  description = "app1"
  is_enabled  = true
}

resource "aws_kms_alias" "app1" {
  name          = "alias/app1"
  target_key_id = "${aws_kms_key.app1.key_id}"
}

resource "aws_kms_ciphertext" "giphy_token" {
  key_id = "${aws_kms_key.app1.key_id}"

  plaintext = "${var.giphy_token}"
}


## ALB SSL CERT
resource "aws_acm_certificate" "cert" {
  domain_name       = "${var.acm_domain_name}"
  validation_method = "DNS"
}

resource "cloudflare_record" "cert_validation" {
  name    = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_name}"
  type    = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_type}"
  domain = "${var.cloudflare_zone}"
  value = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_value}"
  ttl     = 120
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = "${aws_acm_certificate.cert.arn}"
  validation_record_fqdns = ["${cloudflare_record.cert_validation.hostname}"]
}

### ALB

resource "aws_alb" "main" {
  name            = "tf-ecs-chat"
  subnets         = ["${aws_subnet.public.*.id}"]
  security_groups = ["${aws_security_group.lb.id}"]
}

resource "aws_alb_target_group" "app" {
  name        = "tf-${var.cluster_name}-ecs-chat"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = "${aws_vpc.main.id}"
  target_type = "ip"
}

# Redirect all traffic from the ALB to the target group
resource "aws_alb_listener" "front_end" {
  load_balancer_arn = "${aws_alb.main.id}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.app.id}"
    type             = "forward"
  }
}

resource "aws_alb_listener" "front_end_https" {
  load_balancer_arn = "${aws_alb.main.id}"
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = "${aws_acm_certificate.cert.arn}"
  depends_on = ["aws_acm_certificate_validation.cert"]

  default_action {
    target_group_arn = "${aws_alb_target_group.app.id}"
    type             = "forward"
  }
}

# ALB DOMAIN
resource "cloudflare_record" "alb_domain" {
  name    = "${var.acm_domain_name}"
  type    = "CNAME"
  domain = "${var.cloudflare_zone}"
  value = "${aws_alb.main.dns_name}"
  ttl     = 120
}

### IAM
data "aws_iam_policy_document" "admin_role_for_ecs" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "admin_for_ecs" {
 name = "admin_for_ecs"
 path               = "/"
 assume_role_policy = "${data.aws_iam_policy_document.admin_role_for_ecs.json}"
}
data "aws_iam_policy_document" "kms_access" {
  statement {

    actions = [
      "kms:*"
    ]
    resources = [
      "*",
    ]
  }
}
resource "aws_iam_policy" "kms_access" {
  name = "kms_access"
  policy = "${data.aws_iam_policy_document.kms_access.json}"
}
resource "aws_iam_role_policy_attachment" "kms_access" {
  role = "${aws_iam_role.admin_for_ecs.name}"
  policy_arn = "${aws_iam_policy.kms_access.arn}"
}

### ECS

resource "aws_ecs_cluster" "main" {
  name = "tf-${var.cluster_name}-ecs-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "${var.fargate_cpu}"
  memory                   = "${var.fargate_memory}"

  container_definitions = <<DEFINITION
[
  {
    "cpu": ${var.fargate_cpu},
    "image": "${var.app_image}",
    "memory": ${var.fargate_memory},
    "name": "app",
    "networkMode": "awsvpc",
    "TaskRoleArn": "${aws_iam_role.admin_for_ecs.arn}",
    "portMappings": [
      {
        "containerPort": ${var.app_port},
        "hostPort": ${var.app_port}
      }
    ],
    "environment": [
    {
      "name": "TOKEN",
      "value": "${aws_kms_ciphertext.giphy_token.ciphertext_blob}"
    },
    { "name": "AWS",
      "value": "true"
    }
    ]
  }
]
DEFINITION
}

resource "aws_ecs_service" "main" {
  name            = "tf-ecs-service"
  cluster         = "${aws_ecs_cluster.main.id}"
  task_definition = "${aws_ecs_task_definition.app.arn}"
  desired_count   = "${var.app_count}"
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = ["${aws_security_group.ecs_tasks.id}"]
    subnets         = ["${aws_subnet.private.*.id}"]
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.app.id}"
    container_name   = "app"
    container_port   = "${var.app_port}"
  }

  depends_on = [
    "aws_alb_listener.front_end",
  ]
}
