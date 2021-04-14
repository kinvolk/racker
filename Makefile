.PHONY: all
all: image

installer/build: installer/build.go
	cd ./installer && go build -o ./build ./build.go

.PHONY: image
image: installer/build
	docker pull debian:stable-slim
	rm -f installer/racker.tar.gz
	cd installer/ && ./build -force

.PHONY: clean
clean:
	rm -rf installer/build installer/racker.tar.gz installer/.racker-build/

VERSION := $(shell grep -m 1 '^version:' installer/conf.yaml | cut -d : -f 2 | sed 's/ //g')

.PHONY: image-push
image-push:
	docker tag racker:${VERSION} quay.io/kinvolk/racker:${VERSION}
	docker push quay.io/kinvolk/racker:${VERSION}
	docker tag racker:${VERSION} quay.io/kinvolk/racker:latest
	docker push quay.io/kinvolk/racker:latest

.PHONY: build-docs-docker-image
build-docs-docker-image:
	docker build -t weasy docs/

.PHONY: generate-docs-pdf
generate-docs-pdf:
	echo "Using Docker/Podman, if this fails, ensure to run make build-docs-docker-image first"
	DOCKER="docker run -i --rm -v ${PWD}/docs:/work -v ${PWD}:${PWD} -w /work weasy" ./gen-pdf docs output.pdf

.PHONY: wizard
wizard:
	cd wizard && go build -o args-wizard args-wizard.go
