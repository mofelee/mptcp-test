.PHONY: up apply verify status adopt destroy

up:
	./scripts/lab.sh up

apply:
	./scripts/lab.sh apply

verify:
	./scripts/lab.sh verify

status:
	./scripts/lab.sh status

adopt:
	./scripts/lab.sh adopt

destroy:
	./scripts/lab.sh destroy
