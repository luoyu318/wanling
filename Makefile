# 万灵 Harness — 三端统一入口
# 用法见 CLAUDE.md，或 make help

.PHONY: help install-tools install-hooks lint typecheck test secscan check custom-checks lint-sdk test-sdk dev build clean docs-dev docs-build

help: ## 显示所有目标
	@awk 'BEGIN {FS = ":.*##"; printf "\n万灵 Harness 目标:\n\n"} \
	  /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ 基础

install-tools: ## 安装所有 lint/scan 工具（一键装齐，已装则跳过）
	@echo "🔧 检查并安装 Go 工具（走 GOPROXY=https://goproxy.cn,direct）..."
	@command -v golangci-lint >/dev/null 2>&1 || GOPROXY=https://goproxy.cn,direct go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
	@command -v gosec >/dev/null 2>&1 || GOPROXY=https://goproxy.cn,direct go install github.com/securego/gosec/v2/cmd/gosec@latest
	@command -v gitleaks >/dev/null 2>&1 || GOPROXY=https://goproxy.cn,direct go install github.com/gitleaks/gitleaks/v2/cmd/gitleaks@latest
	@echo "🔧 检查 semgrep..."
	@command -v semgrep >/dev/null 2>&1 || pip install semgrep
	@echo "🔧 检查 Plugin eslint 依赖..."
	@cd plugin/opencode-plugin && npm install 2>/dev/null || true
	@echo ""
	@echo "✅ 工具就绪："
	@for t in golangci-lint gosec gitleaks semgrep; do \
	  if command -v $$t >/dev/null 2>&1; then \
	    printf "  \033[32m✓\033[0m %-15s %s\n" "$$t" "$$( $$t --version 2>&1 | head -1 )"; \
	  else \
	    printf "  \033[31m✗\033[0m %-15s 未安装\n" "$$t"; \
	  fi; \
	done

install-hooks: ## 配置 git hooks（clone 后必跑一次）
	@git config core.hooksPath .githooks
	@echo "✅ git hooks 已配置到 .githooks/（clone 后必跑一次）"

##@ 检查（后续任务填充）
lint: ## 三端 lint
	@echo "🔍 [Go] golangci-lint..."
	@cd server && golangci-lint run --timeout 5m ./...
	@echo "🔍 [Flutter/app] dart analyze..."
	@cd app && dart analyze lib 2>&1 | tee /dev/stderr | (! grep 'error •')
	@echo "🔍 [Flutter/desktop] dart analyze..."
	@cd desktop && dart analyze lib test 2>&1 | tee /dev/stderr | (! grep 'error •')
	@echo "🔍 [Plugin] eslint..."
	@cd plugin/opencode-plugin && npx eslint src/
	@echo "🔍 [SDK/TS] eslint..."
	@cd sdk/ts && npx eslint src/ test/
	@echo "🔍 [SDK/Py] ruff..."
	@cd sdk/python && uv run ruff check wanling_sdk tests

typecheck: ## 三端类型检查
	@echo "🔍 [Go] go vet..."
	@cd server && go vet ./...
	@echo "🔍 [Plugin] tsc --noEmit..."
	@cd plugin/opencode-plugin && npx tsc --noEmit
	@echo "🔍 [SDK/TS] tsc --noEmit..."
	@cd sdk/ts && npx tsc --noEmit

test: ## 三端测试
	@echo "🔍 [Go] go test -race..."
	@cd server && go test -race -count=1 ./...
	@echo "🔍 [Flutter/app] flutter test..."
	@cd app && flutter test
	@echo "🔍 [Flutter/desktop] flutter test..."
	@cd desktop && flutter test
	@echo "🔍 [Plugin] vitest run..."
	@cd plugin/opencode-plugin && npx vitest run
	@echo "🔍 [SDK/TS] vitest run..."
	@cd sdk/ts && npx vitest run
	@echo "🔍 [SDK/Py] pytest..."
	@cd sdk/python && uv run pytest

secscan: ## 安全扫描（gosec + semgrep + gitleaks）
	@echo "🔍 [Go] gosec..."
	@cd server && gosec -quiet -exclude G104 ./...
	@echo "🔍 [All] semgrep（万灵自定义规则）..."
	@semgrep --config secscan/semgrep-rules.yml server/ plugin/
	@echo "🔍 [All] gitleaks（工作区）..."
	@gitleaks detect --source . --config secscan/.gitleaks.toml --no-git --verbose

check: lint typecheck test secscan custom-checks lint-sdk test-sdk ## 全量检查（push 前一键跑）
	@echo ""
	@echo "✅ All checks passed"

.PHONY: custom-checks
custom-checks: ## 项目特有检查
	@echo "🔍 [Go] check-repo-ctx.sh..."
	@./scripts/check-repo-ctx.sh

lint-sdk: ## SDK 双语言 lint
	@echo "🔍 [SDK/TS] eslint..."
	@cd sdk/ts && npx eslint src/ test/
	@echo "🔍 [SDK/Py] ruff..."
	@cd sdk/python && uv run ruff check wanling_sdk tests

test-sdk: ## SDK 双语言测试
	@echo "🔍 [SDK/TS] vitest run..."
	@cd sdk/ts && npx vitest run
	@echo "🔍 [SDK/Py] pytest..."
	@cd sdk/python && uv run pytest

##@ 开发（后续填充）
dev: ## 启动三端
	@echo "⚠️  dev 目标后续填充"

build: ## 构建三端
	@echo "⚠️  build 目标后续填充"

docs-dev: ## 文档站本地开发预览（localhost:4321/docs/）
	cd docs-site && npm run dev

docs-build: ## 构建文档站静态产物到 docs-site/dist/
	cd docs-site && npm run build

clean: ## 清理
	@echo "⚠️  clean 目标后续填充"
