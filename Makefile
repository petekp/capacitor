SHELL := /bin/bash

OBSERVE := ./scripts/dev/agent-observe.sh
LIMIT ?= 200
PROJECT_PATH ?= $(CURDIR)
WORKSPACE_ID ?=
QUERY ?=

.DEFAULT_GOAL := help

.PHONY: help \
	observe-help observe-check observe-paths observe-health observe-sessions observe-projects observe-shells \
	observe-activity observe-routing-snapshot observe-routing-diagnostics \
	observe-snapshot observe-briefing observe-telemetry observe-stream \
	observe-sql observe-tail-app observe-tail-daemon-stderr observe-tail-daemon-stdout \
	observe-smoke

help:
	@echo "Capacitor Make Targets"
	@echo ""
	@echo "Observability"
	@echo "  make observe-help"
	@echo "  make observe-check"
	@echo "  make observe-health"
	@echo "  make observe-projects"
	@echo "  make observe-sessions"
	@echo "  make observe-shells"
	@echo "  make observe-activity LIMIT=120"
	@echo "  make observe-snapshot"
	@echo "  make observe-briefing LIMIT=200"
	@echo "  make observe-telemetry LIMIT=200"
	@echo "  make observe-smoke [PROJECT_PATH=/abs/path] [WORKSPACE_ID=workspace-1]"
	@echo "  make observe-routing-snapshot PROJECT_PATH=/abs/path [WORKSPACE_ID=workspace-1]"
	@echo "  make observe-routing-diagnostics PROJECT_PATH=/abs/path [WORKSPACE_ID=workspace-1]"
	@echo "  make observe-sql QUERY='SELECT event_type, COUNT(*) FROM events GROUP BY event_type;'"
	@echo "  make observe-tail-app"
	@echo "  make observe-tail-daemon-stderr"
	@echo "  make observe-tail-daemon-stdout"
	@echo "  make observe-stream"

observe-help:
	@$(OBSERVE) help

observe-check:
	@$(OBSERVE) check

observe-paths:
	@$(OBSERVE) paths

observe-health:
	@$(OBSERVE) health

observe-sessions:
	@$(OBSERVE) sessions

observe-projects:
	@$(OBSERVE) projects

observe-shells:
	@$(OBSERVE) shells

observe-activity:
	@$(OBSERVE) activity "$(LIMIT)"

observe-snapshot:
	@$(OBSERVE) snapshot

observe-briefing:
	@$(OBSERVE) briefing "$(LIMIT)"

observe-telemetry:
	@$(OBSERVE) telemetry "$(LIMIT)"

observe-stream:
	@$(OBSERVE) stream

observe-routing-snapshot:
	@if [[ -z "$(PROJECT_PATH)" ]]; then \
		echo "PROJECT_PATH is required. Example:"; \
		echo "  make observe-routing-snapshot PROJECT_PATH=/Users/petepetrash/Code/capacitor"; \
		exit 1; \
	fi
	@$(OBSERVE) routing-snapshot "$(PROJECT_PATH)" "$(WORKSPACE_ID)"

observe-routing-diagnostics:
	@if [[ -z "$(PROJECT_PATH)" ]]; then \
		echo "PROJECT_PATH is required. Example:"; \
		echo "  make observe-routing-diagnostics PROJECT_PATH=/Users/petepetrash/Code/capacitor"; \
		exit 1; \
	fi
	@$(OBSERVE) routing-diagnostics "$(PROJECT_PATH)" "$(WORKSPACE_ID)"

observe-sql:
	@if [[ -z "$(QUERY)" ]]; then \
		echo "QUERY is required. Example:"; \
		echo "  make observe-sql QUERY='SELECT event_type, COUNT(*) FROM events GROUP BY event_type;'"; \
		exit 1; \
	fi
	@$(OBSERVE) sql "$(QUERY)"

observe-tail-app:
	@$(OBSERVE) tail app

observe-tail-daemon-stderr:
	@$(OBSERVE) tail daemon-stderr

observe-tail-daemon-stdout:
	@$(OBSERVE) tail daemon-stdout

observe-smoke:
	@echo "Running observability smoke checks..."
	@set -euo pipefail; \
		project_path="$(PROJECT_PATH)"; \
		$(OBSERVE) check >/dev/null; \
		echo "  ✓ check"; \
		$(OBSERVE) health >/dev/null; \
		echo "  ✓ health"; \
		$(OBSERVE) projects >/dev/null; \
		echo "  ✓ projects"; \
		$(OBSERVE) sessions >/dev/null; \
		echo "  ✓ sessions"; \
		$(OBSERVE) shells >/dev/null; \
		echo "  ✓ shells"; \
		$(OBSERVE) snapshot >/dev/null; \
		echo "  ✓ snapshot"; \
		$(OBSERVE) briefing "$(LIMIT)" >/dev/null; \
		echo "  ✓ briefing"; \
		$(OBSERVE) telemetry "$(LIMIT)" >/dev/null; \
		echo "  ✓ telemetry"; \
		if [[ -n "$$project_path" ]]; then \
			$(OBSERVE) routing-snapshot "$$project_path" "$(WORKSPACE_ID)" >/dev/null; \
			echo "  ✓ routing-snapshot ($$project_path)"; \
			$(OBSERVE) routing-diagnostics "$$project_path" "$(WORKSPACE_ID)" >/dev/null; \
			echo "  ✓ routing-diagnostics ($$project_path)"; \
		fi; \
		echo "Observability smoke checks passed."
