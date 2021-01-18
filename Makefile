all: build-installer

build-installer:
	cd ./installer && go build -o ./build ./build.go
