SHELL = bash

# --no-print-directory avoids verbose logging when invoking targets that utilize sub-makes
MAKE_OPTS ?= --no-print-directory

REGISTRY ?= $(USER)
VERSION ?= $(shell git describe --tags 2> /dev/null || echo v0)
PERMALINK ?= $(shell git describe --tags --exact-match &> /dev/null && echo latest || echo canary)

KUBECONFIG  ?= $(HOME)/.kube/config
PORTER_HOME = bin

CLIENT_PLATFORM = $(shell go env GOOS)
CLIENT_ARCH = $(shell go env GOARCH)
CLIENT_GOPATH = $(shell go env GOPATH)
RUNTIME_PLATFORM = linux
RUNTIME_ARCH = amd64
BASEURL_FLAG ?=

GO = GO111MODULE=on go

ifeq ($(CLIENT_PLATFORM),windows)
FILE_EXT=.exe
else ifeq ($(RUNTIME_PLATFORM),windows)
FILE_EXT=.exe
else
FILE_EXT=
endif

INT_MIXINS = exec
EXT_MIXINS = helm arm terraform kubernetes
MIXIN_TAG ?= canary
MIXINS_URL = https://cdn.porter.sh/mixins

.PHONY: build
build: build-porter docs-gen build-mixins clean-packr get-mixins

build-porter: generate
	$(MAKE) $(MAKE_OPTS) build MIXIN=porter -f mixin.mk BINDIR=bin

build-porter-client: generate
	$(MAKE) $(MAKE_OPTS) build-client MIXIN=porter -f mixin.mk BINDIR=bin
	$(MAKE) $(MAKE_OPTS) clean-packr

build-mixins: $(addprefix build-mixin-,$(INT_MIXINS))
build-mixin-%: generate
	$(MAKE) $(MAKE_OPTS) build MIXIN=$* -f mixin.mk

generate: packr2
	$(GO) mod tidy
	$(GO) generate ./...

HAS_PACKR2 := $(shell command -v packr2)
HAS_GOBIN_IN_PATH := $(shell re='(:|^)$(CLIENT_GOPATH)/bin/?(:|$$)'; if [[ "$${PATH}" =~ $${re} ]];then echo $${GOPATH}/bin;fi)
packr2:
ifndef HAS_PACKR2
ifndef HAS_GOBIN_IN_PATH
	$(error "$(CLIENT_GOPATH)/bin is not in path and packr2 is not installed. Install packr2 or add "$(CLIENT_GOPATH)/bin to your path")
endif
	curl -SLo /tmp/packr.tar.gz https://github.com/gobuffalo/packr/releases/download/v2.6.0/packr_2.6.0_$(CLIENT_PLATFORM)_$(CLIENT_ARCH).tar.gz
	cd /tmp && tar -xzf /tmp/packr.tar.gz
	install /tmp/packr2 $(CLIENT_GOPATH)/bin/
endif

xbuild-all: xbuild-porter xbuild-mixins

xbuild-porter: generate
	$(MAKE) $(MAKE_OPTS) xbuild-all MIXIN=porter -f mixin.mk BINDIR=bin

xbuild-mixins: $(addprefix xbuild-mixin-,$(INT_MIXINS))
xbuild-mixin-%: generate
	$(MAKE) $(MAKE_OPTS) xbuild-all MIXIN=$* -f mixin.mk

get-mixins:
	$(foreach MIXIN, $(EXT_MIXINS), \
		bin/porter mixin install $(MIXIN) --version $(MIXIN_TAG) --url $(MIXINS_URL)/$(MIXIN); \
	)

verify:
	@echo 'verify does nothing for now but keeping it as a placeholder for a bit'

test: clean-last-testrun test-unit test-integration test-cli

test-unit:
	$(GO) test ./...

test-integration: clean-last-testrun build start-local-docker-registry
	$(GO) build -o $(PORTER_HOME)/testplugin ./cmd/testplugin
	PROJECT_ROOT=$(shell pwd) $(GO) test -timeout 30m -tags=integration ./...

test-cli: clean-last-testrun build init-porter-home-for-ci start-local-docker-registry
	REGISTRY=$(REGISTRY) KUBECONFIG=$(KUBECONFIG) ./scripts/test/test-cli.sh

init-porter-home-for-ci:
	cp -R build/testdata/credentials $(PORTER_HOME)
	sed -i.bak 's|KUBECONFIGPATH|$(KUBECONFIG)|g' $(PORTER_HOME)/credentials/ci.json
	cp -R build/testdata/bundles $(PORTER_HOME)

.PHONY: docs
docs:
	hugo --source docs/ $(BASEURL_FLAG)

docs-gen:
	$(GO) run --tags=docs ./cmd/porter docs

docs-preview: docs-stop-preview
	@docker run -d -v $$PWD/docs:/src -p 1313:1313 --name porter-docs \
	klakegg/hugo:0.53-ext-alpine server --noHTTPCache --watch --bind=0.0.0.0
	@open "http://localhost:1313/docs/"

docs-stop-preview:
	@docker rm -f porter-docs &> /dev/null || true

publish: publish-bin publish-mixins publish-images

publish-bin:
	mkdir -p bin/$(VERSION)
	VERSION=$(VERSION) PERMALINK=$(PERMALINK) ./scripts/prep-install-scripts.sh

	# AZURE_STORAGE_CONNECTION_STRING will be used for auth in the following commands
	if [[ "$(PERMALINK)" == "latest" ]]; then \
		az storage blob upload-batch -d porter/$(VERSION) -s bin/$(VERSION); \
	fi
	az storage blob upload-batch -d porter/$(PERMALINK) -s bin/$(VERSION)

publish-mixins:
	$(MAKE) $(MAKE_OPTS) publish MIXIN=exec -f mixin.mk

	# Generate the mixin feed
	az storage blob download -c porter -n atom.xml -f bin/atom.xml
	bin/porter mixins feed generate -d bin/mixins -f bin/atom.xml -t build/atom-template.xml
	az storage blob upload -c porter -n atom.xml -f bin/atom.xml

publish-images:
	VERSION=$(VERSION) PERMALINK=$(PERMALINK) ./scripts/publish-images.sh

start-local-docker-registry:
	@docker run -d -p 5000:5000 --name registry registry:2

stop-local-docker-registry:
	@if $$(docker inspect registry > /dev/null 2>&1); then \
		docker rm -f registry ; \
	fi

# all-bundles loops through all items under the dir provided by the first argument
# and if the item is a sub-directory containing a porter.yaml file,
# runs the make target(s) provided by the second argument
define all-bundles
	@for dir in $$(ls -1 $(1)); do \
		if [[ -e "$(1)/$$dir/porter.yaml" ]]; then \
			BUNDLE=$$dir make $(MAKE_OPTS) $(2) || exit $$? ; \
		fi ; \
	done
endef

EXAMPLES_DIR := examples

.PHONY: build-bundle
build-bundle:
ifndef BUNDLE
	$(call all-bundles,$(EXAMPLES_DIR),build-bundle)
else
	cd $(EXAMPLES_DIR)/$(BUNDLE) && ../../bin/porter build
endif

.PHONY: publish-bundle
publish-bundle:
ifndef BUNDLE
	$(call all-bundles,$(EXAMPLES_DIR),publish-bundle)
else
	cd $(EXAMPLES_DIR)/$(BUNDLE) && ../../bin/porter publish
endif

SCHEMA_VERSION     := cnab-core-1.0.1
BUNDLE_SCHEMA      := bundle.schema.json
DEFINITIONS_SCHEMA := definitions.schema.json

define fetch-schema
	@curl -L --fail --silent --show-error -o /tmp/$(1) \
		https://cnab.io/schema/$(SCHEMA_VERSION)/$(1)
endef

fetch-schemas: fetch-bundle-schema fetch-definitions-schema

fetch-bundle-schema:
	$(call fetch-schema,$(BUNDLE_SCHEMA))

fetch-definitions-schema:
	$(call fetch-schema,$(DEFINITIONS_SCHEMA))

HAS_AJV := $(shell command -v ajv)
ajv:
ifndef HAS_AJV
	npm install -g ajv-cli
endif

.PHONY: validate-bundle
validate-bundle: fetch-schemas ajv
ifndef BUNDLE
	$(call all-bundles,$(EXAMPLES_DIR),validate-bundle)
else
	cd $(EXAMPLES_DIR)/$(BUNDLE) && \
		ajv test -s /tmp/$(BUNDLE_SCHEMA) -r /tmp/$(DEFINITIONS_SCHEMA) -d .cnab/bundle.json --valid
endif

install: install-porter install-mixins

install-porter:
	mkdir -p $(HOME)/.porter
	cp bin/porter* $(HOME)/.porter/
	ln -f -s $(HOME)/.porter/porter /usr/local/bin/porter

install-mixins:
	cp -R bin/mixins $(HOME)/.porter/

clean: clean-mixins clean-last-testrun

clean-mixins:
	-rm -fr bin/

clean-last-testrun: stop-local-docker-registry
	-rm -fr cnab/ porter.yaml Dockerfile bundle.json

clean-packr: packr2
	cd cmd/porter && packr2 clean
	cd pkg/porter && packr2 clean
	$(foreach MIXIN, $(INT_MIXINS), \
		`cd pkg/$(MIXIN) && packr2 clean`; \
	)
