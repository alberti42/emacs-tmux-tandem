.PHONY: version-bump push-release-draft

## Usage: make version-bump TAG=v1.2.3
version-bump:
	@[ -n "$(TAG)" ] || { echo "error: TAG is required (e.g. make version-bump TAG=v1.2.3)"; exit 1; }
	@echo "$(TAG)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' \
		|| { echo "error: TAG must match vX.Y.Z (got '$(TAG)')"; exit 1; }
	@git rev-parse --verify "$(TAG)" >/dev/null 2>&1 \
		&& { echo "error: tag $(TAG) already exists"; exit 1; } || true
	@git diff --quiet && git diff --cached --quiet \
		|| { echo "error: working tree is not clean"; exit 1; }
	@sed -i '' "s/^;; Version:.*$$/;; Version: $$(echo $(TAG) | sed 's/^v//')/" tmux-tandem.el
	@touch "release-notes/release-$(TAG).md"
	@git add tmux-tandem.el "release-notes/release-$(TAG).md"
	@git commit -m "chore(release): bump to $(TAG)"
	@git tag "$(TAG)"
	@echo "Bumped to $(TAG). Fill in release-notes/release-$(TAG).md, then run: make push-release-draft TAG=$(TAG)"

## Usage: make push-release-draft
push-release-draft:
	@TAG=$$(git describe --tags --abbrev=0 2>/dev/null) \
		|| { echo "error: no tags found"; exit 1; }; \
	git push origin HEAD:main "$$TAG" && \
	echo "Draft release triggered for $$TAG."
