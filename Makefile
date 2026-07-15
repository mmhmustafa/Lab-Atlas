# AtlasLab - Makefile
#
# Thin wrapper around scripts/*.sh. Every target accepts LAB=<name> to
# target a specific lab under labs/ (defaults to the flagship 20-router
# enterprise topology, 06-atlas-demo).
#
# Examples:
#   make verify
#   make deploy
#   make deploy LAB=01-basic
#   make test LAB=02-ospf
#   make destroy LAB=01-basic YES=1

SHELL := /usr/bin/env bash
LAB   ?= 06-atlas-demo

.PHONY: help verify deploy inspect test diagnostics destroy generate generate-multicity redeploy list-labs

help:
	@echo "AtlasLab make targets (LAB=$(LAB)):"
	@echo "  make verify                 - check the local environment is ready"
	@echo "  make generate                - render FRR configs + topology from inventory/devices.yaml (06-atlas-demo)"
	@echo "  make generate-multicity      - render labs/07-multi-city from inventory/multi-city.yaml"
	@echo "  make deploy      [LAB=name] - deploy a lab"
	@echo "  make inspect     [LAB=name] - show deployed lab state"
	@echo "  make test        [LAB=name] - run OSPF/BGP/reachability regression tests"
	@echo "  make diagnostics [LAB=name] - collect a full diagnostics bundle"
	@echo "  make destroy     [LAB=name] [YES=1] - destroy a deployed lab"
	@echo "  make redeploy    [LAB=name] - destroy then deploy (reproducibility check)"
	@echo "  make list-labs               - list available labs"

verify:
	./scripts/verify-environment.sh

generate:
	python3 scripts/generate-configs.py --lab $(LAB)

generate-multicity:
	python3 scripts/generate-multicity.py

deploy:
	./scripts/deploy-lab.sh $(LAB)

inspect:
	./scripts/inspect-lab.sh $(LAB)

test:
	./scripts/test-connectivity.sh $(LAB)

diagnostics:
	./scripts/collect-diagnostics.sh $(LAB)

destroy:
ifdef YES
	./scripts/destroy-lab.sh $(LAB) --yes
else
	./scripts/destroy-lab.sh $(LAB)
endif

redeploy:
	./scripts/destroy-lab.sh $(LAB) --yes
	./scripts/deploy-lab.sh $(LAB)

list-labs:
	@find labs -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
