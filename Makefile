SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: setup help deps test credo dialyzer coverage check format clean release publish-release setup-hooks setup-db reset-db logs git-push pre-push-cleanup push-and-publish deploy-bot

help:
	@echo "Para Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks + setup database)"
	@echo "  make setup-hooks     - Install git hooks for pre-push validation"
	@echo "  make setup-db        - Create and migrate test database (required for testing)"
	@echo "  make reset-db        - Drop and recreate test database (useful for troubleshooting)"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail server log with grc (auto-detected by repo name; make -C .. install-grc)"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"
	@echo ""

setup: init deps setup-hooks setup-db
	@echo "✓ Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Configure .env with your database settings (if needed)"
	@echo "  2. Run: make test"
	@echo "  3. Start developing!"
	@echo ""

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

setup-db:
	@echo "Setting up test database..."
	@MIX_ENV=test $(MIX) ecto.create || true
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database created and migrations applied"

reset-db:
	@echo "⚠️  Resetting test database (dropping and recreating)..."
	@MIX_ENV=test $(MIX) ecto.drop || true
	@MIX_ENV=test $(MIX) ecto.create
	@MIX_ENV=test $(MIX) ecto.migrate
	@echo "✓ Test database reset complete"

init:
	@if [ ! -d .git ]; then git init; echo "Git initialized."; else echo "Git already initialized."; fi

deps:
	$(MIX) deps.get

test:
	$(MIX) test

credo:
	$(MIX) credo

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo dialyzer
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/para_bot
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "✓ Release built successfully"
	@echo "Location: _build/prod/rel/para_bot/"
	@echo ""

test-release-smoke:
	@echo "==============================================="
	@echo "Running release smoke test"
	@echo "==============================================="
	@RELEASE_NAME=para_bot NATS_SERVERS=nats://localhost:4224 \
		bash $(SCRIPTS_DIRECTORY)/test_release_smoke.sh

sync-release-version:
	@VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "❌ Failed to resolve version from mix.exs"; exit 1; \
	fi; \
	TIMESTAMP=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	echo "$$VERSION $$TIMESTAMP" > .release-published; \
	echo "✅ Synced release version: v$$VERSION ($$TIMESTAMP)"

publish-release: release
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL="para_bot-$$VERSION.tar.gz"; \
	echo "Version: $$VERSION"; \
	echo ""; \
	if [ -f "$$TARBALL" ]; then \
		echo "✓ Tarball already exists locally: $$TARBALL (skipping rebuild)"; \
	else \
		echo "📦 Building release (tarball not found locally)..."; \
		$(MAKE) test-release-smoke || echo "⚠️  Smoke test warnings (non-blocking) - continuing"; \
		echo "Creating release tarball..."; \
		tar -czf "$$TARBALL" -C _build/prod/rel para_bot/; \
		echo "✓ Tarball created: $$TARBALL"; \
	fi; \
	echo ""; \
	echo "==============================================="; \
	echo "Publishing release to GitHub"; \
	echo "==============================================="; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Para Bot Elixir release v$$VERSION. Download and deploy with Salt." \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"; \
	$(MAKE) sync-release-version; \
	echo ""

pre-push-cleanup:
	@echo "🧹 Cleaning up pre-push artifacts..."
	@if git diff --quiet git-hooks/pre-push; then \
		echo "✓ No hook changes"; \
	else \
		echo "📋 Staging hook changes..."; \
		git add git-hooks/pre-push; \
		git commit -m "chore: sync pre-push hook" || true; \
	fi
	@if git diff --quiet mix.lock; then \
		echo "✓ No lock file changes"; \
	else \
		echo "📋 Staging lock file changes..."; \
		git add mix.lock; \
		git commit -m "chore: lock file updates from pre-push validation" || true; \
	fi
	@echo "✓ Ready to push"

git-push: pre-push-cleanup
	@BOT_NAME=para; \
	LOG_FILE="/tmp/git-push-$${BOT_NAME}-$$(date +%s).log"; \
	echo "Pushing to origin/main and logging to $$LOG_FILE..."; \
	git push 2>&1 | tee "$$LOG_FILE"; \
	echo "✓ Log saved: $$LOG_FILE"

push-and-publish: git-push publish-release

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh

## Deploy bot via bot_army_infra (called by: make deploy-bot BOT=para from monorepo)
## This target is invoked by bot_army_infra's deploy-bot target
deploy-bot: publish-release
	@echo "✓ Deploy-bot complete: GitHub release published"
	@echo "  Infra will now handle: sync → apply Salt state → restart"
