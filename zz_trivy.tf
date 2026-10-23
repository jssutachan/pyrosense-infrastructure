resource "aws_security_group_rule" "zz_trivy" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = "sg-00000000000000000"
  description       = "C1 DoD provocation"
}
