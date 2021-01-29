all: installer/racker.tar.gz

installer/build: installer/build.go
	cd ./installer && go build -o ./build ./build.go

installer/racker.tar.gz: installer/build installer/Dockerfile
	cd installer/ && ./build -force

PHONY: clean
clean:
	rm -rf installer/build installer/racker.tar.gz installer/.racker-build/
