all: installer/racker.tar.gz

installer/build: installer/build.go
	cd ./installer && go build -o ./build ./build.go

installer/racker.tar.gz: installer/build installer/Dockerfile
	cd installer/ && ./build -force

PHONY: clean
clean:
	rm -rf installer/build installer/racker.tar.gz installer/.racker-build/

VERSION := $(shell grep -m 1 '^version:' installer/conf.yaml | cut -d : -f 2 | sed 's/ //g')

PHONY: image-push
image-push:
	docker tag racker:${VERSION} quay.io/kinvolk/racker:${VERSION}
	docker push quay.io/kinvolk/racker:${VERSION}
	docker tag racker:${VERSION} quay.io/kinvolk/racker:latest
	docker push quay.io/kinvolk/racker:latest
