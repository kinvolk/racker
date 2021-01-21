package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"path"
	"path/filepath"

	"gopkg.in/yaml.v2"
)

const (
	BuildDir         = ".racker-build"
	AssetsDir        = ".racker-build/assets"
	InstallerTarball = "racker.tar.gz"
)

type Asset struct {
	URL          string   `yaml:"url,omitempty"`
	Sha256       string   `yaml:",omitempty"`
	Shell        []string `yaml:",omitempty"`
	DestFilename string   `yaml:"dest-filename,omitempty"`
}

type Module struct {
	Name          string
	Assets        []Asset  `yaml:",omitempty"`
	BuildCommands []string `yaml:"build-commands,omitempty"`
}

type InstallerConf struct {
	Modules []Module
}

func verifyChecksum(filePath string, checksum string) error {
	f, err := os.Open(filePath)
	if err != nil {
		return err
	}

	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return err
	}

	if hex.EncodeToString(h.Sum(nil)) != checksum {
		return fmt.Errorf("checksum for %v does not match", filePath)
	}

	return nil
}

func runBuildCommands(moduleDir string, module Module) {
	for _, cmdLine := range module.BuildCommands {
		cmd := exec.Command("sh", "-c", cmdLine)
		cmd.Dir = moduleDir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr

		err := cmd.Run()
		if err != nil {
			log.Fatalf("Failed to run command %v: %v", cmdLine, err)
		}
	}
}

func downloadFile(url string, filename string) {
	cmd := exec.Command("curl", "-o", filename, "-L", "-C", "-", url)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		log.Fatalf("Failed to download the file from %v: %v", url, err)
	}
}

func copyFile(src string, dst string) {
	cmd := exec.Command("cp", src, dst)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		log.Fatalf("Failed to copy file %v -> %v: %v", src, dst, err)
	}
}

func fetchAssetFromURL(moduleDir string, asset Asset) {
	destfileName := asset.DestFilename
	if destfileName == "" {
		destfileName = path.Base(asset.URL)
	}

	dest, err := filepath.Abs(path.Join(AssetsDir, path.Base(asset.URL)+"-"+asset.Sha256))
	if err != nil {
		log.Fatal(err)
	}

	// Skip download if it's cached
	err = verifyChecksum(dest, asset.Sha256)

	switch {
	case err == nil:
		log.Printf("Got cached %v file (checksum matches); skipping downloading it again", dest)
	case os.IsNotExist(err):
		downloadFile(asset.URL, dest)
	default:
		log.Fatal(err)
	}

	if err := verifyChecksum(dest, asset.Sha256); err != nil {
		log.Fatal(err)
	}

	copyFile(dest, path.Join(moduleDir, destfileName))
}

func runModule(moduleDir string, module Module) {
	for _, asset := range module.Assets {
		if asset.URL != "" {
			fetchAssetFromURL(moduleDir, asset)
		} else {
			d, err := yaml.Marshal(asset)
			if err != nil {
				log.Fatalf("error: %v", err)
			}
			log.Fatalf("Module not compatible:\n%v", string(d))
		}
	}
}

func build(data InstallerConf) error {
	dir, err := ioutil.TempDir(BuildDir, "build-")
	if err != nil {
		return err
	}

	defer os.RemoveAll(dir)

	for _, module := range data.Modules {
		moduleDir, err := filepath.Abs(path.Join(dir, module.Name))
		if err != nil {
			return err
		}

		err = os.MkdirAll(moduleDir, os.ModePerm)
		if err != nil {
			return fmt.Errorf("failed to create directory %v: %v", moduleDir, err)
		}

		runModule(moduleDir, module)
		runBuildCommands(moduleDir, module)
	}

	// Add the run.sh file
	entryScript, err := filepath.Abs("./run.sh")
	if err != nil {
		return err
	}

	copyFile(entryScript, path.Join(dir, "run.sh"))

	cmd := exec.Command("tar", "-C", dir, "-cvzf", InstallerTarball, ".")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err = cmd.Run()
	if err != nil {
		return fmt.Errorf("failed to create archive: %v", err)
	}

	return nil
}

func buildImage() {
	cmd := exec.Command("docker", "build", "-t", "racker:latest", "-f", "./Dockerfile", ".")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		log.Fatalf("Failed to create image: %v", err)
	}
}

func main() {
	forceBuild := flag.Bool("force", false, "build even if there's already a tarball")
	onlyBuild := flag.String("only", "", "build only these options: tarball or image")
	confFilePath := flag.String("config", "./conf.yaml", "path to the configuration file")
	flag.Parse()

	buildTarball := *onlyBuild == "" || *onlyBuild == "tarball"
	buildImg := *onlyBuild == "" || *onlyBuild == "image"

	t := InstallerConf{}

	if !*forceBuild && buildTarball {
		if _, err := os.Stat(InstallerTarball); err == nil {
			log.Fatalf("error: The file %v exists!", InstallerTarball)
		}
	}

	err := os.MkdirAll(AssetsDir, os.ModePerm)
	if err != nil {
		log.Fatalf("Failed to create dir %v: %v", AssetsDir, err)
	}

	data, err := ioutil.ReadFile(*confFilePath)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	err = yaml.Unmarshal(data, &t)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	if !buildTarball && !buildImg {
		log.Fatal("error: '-only' option not recognized, please use tarball or image.")
	}

	if buildTarball {
		if err := build(t); err != nil {
			log.Fatal(err)
		}
	}

	if buildImg {
		if _, err := os.Stat(InstallerTarball); os.IsNotExist(err) {
			log.Fatalf("error: The file %v does not exist!", InstallerTarball)
		}

		buildImage()
	}
}
