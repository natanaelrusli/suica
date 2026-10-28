# Shortcuts for the scripts and npm/swift commands of this repository. `make` lists them.
# Written for the GNU Make 3.81 that ships with macOS.

PREFIX          ?= $(or $(SUICA_PREFIX),$(HOME)/.local)
GITLAB_HOSTNAME ?= repo.madhani.one
CONFIG          ?= $(or $(SUICA_CONFIG),$(HOME)/.config/suica/config.yaml)
LOGS            := $(HOME)/Library/Logs/suica
BIN             := $(PREFIX)/bin/suica
SWIFT_PACKAGE   := macos/Suica

# The install scripts read SUICA_PREFIX.
export SUICA_PREFIX := $(PREFIX)

.DEFAULT_GOAL := help
.PHONY: help install install-cli config agent-install agent-uninstall install-app \
        update update-app uninstall uninstall-cli uninstall-app migrate \
        deps check typecheck lint format format-fix test test-app test-all run \
        status once pause resume restart logs errors release

help: ## Show this list
	@awk 'BEGIN { FS = ":.*## " } \
		/^## / { printf "\n%s\n", substr($$0, 4) } \
		/^[a-zA-Z_-]+:.*## / { printf "  make %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nVariables: PREFIX=%s  CONFIG=%s  GITLAB_HOSTNAME=%s\n' '$(PREFIX)' '$(CONFIG)' '$(GITLAB_HOSTNAME)'

## Install (CLI only)

install: install-cli config agent-install ## CLI and background agent: everything for a CLI-only setup

install-cli: ## Install the suica command under PREFIX (re-run to update)
	scripts/install-cli.sh

config: ## Write a minimal config file, unless one exists
	@if [ -e '$(CONFIG)' ]; then \
		echo 'config exists: $(CONFIG)'; \
	else \
		mkdir -p '$(dir $(CONFIG))' && \
		printf 'gitlab:\n  hostname: $(GITLAB_HOSTNAME)\n' > '$(CONFIG)' && \
		echo 'wrote $(CONFIG)'; \
	fi

agent-install: ## Start the background agent (LaunchAgent)
	'$(BIN)' agent install

agent-uninstall: ## Stop the background agent and remove its LaunchAgent
	'$(BIN)' agent uninstall

## Install (with the menu bar app)

install-app: ## Build and install Suica.app (needs the CLI)
	scripts/install-macos-app.sh

update: install-cli ## Reinstall the CLI from this checkout (restarts the agent when installed)

update-app: update install-app ## Reinstall the CLI and the app from this checkout

## Remove

uninstall: uninstall-app uninstall-cli ## Remove the app, the agent and the CLI (config, state and logs stay)

uninstall-cli: ## Remove the agent and the CLI only
	scripts/uninstall-cli.sh

uninstall-app: ## Remove Suica.app only
	scripts/uninstall-macos-app.sh

migrate: ## One-time move from the MR Review Assistant paths
	scripts/migrate-to-suica.sh

## Develop

deps: ## Install dev dependencies in the checkout
	npm ci

check: ## Typecheck, lint, prettier and tests
	npm run check

typecheck: ## TypeScript only
	npm run typecheck

lint: ## ESLint only
	npm run lint

format: ## Check formatting
	npm run format

format-fix: ## Rewrite files with prettier
	npx prettier --write .

test: ## CLI tests (vitest)
	npm test

test-app: ## Menu bar app tests (swift test)
	cd $(SWIFT_PACKAGE) && swift test

test-all: check test-app ## Every check and every test

run: ## Run the CLI from the checkout: make run ARGS="status --json"
	scripts/suica $(ARGS)

## Release

release: ## Build, sign and publish a GitHub release (DRY_RUN=1 skips publishing)
	scripts/release.sh

## Operate (the installed CLI)

status: ## Agent, last poll and tracked counts
	'$(BIN)' status

once: ## One poll now (not while the background agent runs)
	'$(BIN)' once

pause: ## Stop polling
	'$(BIN)' pause

resume: ## Resume polling
	'$(BIN)' resume

restart: ## Restart the background agent to apply config edits
	'$(BIN)' agent restart --json

logs: ## Follow the agent's output log
	tail -n 50 -f '$(LOGS)/stdout.log'

errors: ## Follow the agent's error log
	tail -n 50 -f '$(LOGS)/stderr.log'
