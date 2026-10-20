data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "instance" {
  name        = "${var.name}-instance"
  description = "No inbound rules: deploys come through SSM"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "SSM, ECR, CloudWatch and image layers"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "instance" {
  name = "${var.name}-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "instance_ecr_pull" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

# The SSM agent writes the command output with the instance role.
resource "aws_iam_role_policy" "instance_logs" {
  name = "deploy-output"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.deploy.arn}:*"
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  associate_public_ip_address = true

  # IMDSv2 only, and one hop: containers can't reach the instance role through IMDS.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  # AL2023 ships the SSM agent and the AWS CLI; docker comes from the distro.
  user_data = <<-EOF
    #!/bin/sh
    dnf install -y docker
    systemctl enable --now docker
  EOF

  tags = {
    Name = var.name
  }
}
