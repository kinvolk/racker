package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"

	"github.com/mitchellh/mapstructure"

	"gopkg.in/yaml.v2"
)

const (
	BuildDir         = ".racker-build"
	AssetsDir        = ".racker-build/assets"
	InstallerTarball = "racker.tar.gz"
)

type FileAsset struct {
	URL          string   `yaml:"url,omitempty"`
	Path         string   `yaml:",omitempty"`
	Sha256       string   `yaml:",omitempty"`
	Shell        []string `yaml:",omitempty"`
	DestFilename string   `yaml:"dest-filename,omitempty"`
}

type Asset struct {
	Type string `yaml:",omitempty"`
}

type GitAsset struct {
	Asset
	URL    string `yaml:",omitempty"`
	Branch string `yaml:",omitempty"`
	Name   string `yaml:",omitempty"`
}

type Module struct {
	Asset
	Name          string
	Assets        []map[string]interface{} `yaml:",omitempty"`
	BuildCommands []string                 `yaml:"build-commands,omitempty"`
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

func copyFileOrDir(src string, dst string) {
	cmd := exec.Command("cp", "-rf", src, dst)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		log.Fatalf("Failed to copy file or dir %v -> %v: %v", src, dst, err)
	}
}

func fetchAssetFromURL(asset FileAsset) string {
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

	return dest
}

func fetchFileAsset(moduleDir string, assetIface interface{}) {
	asset := FileAsset{}
	if err := decodeAsset(assetIface, &asset); err != nil {
		log.Fatalf("Failed to decode module: %v", err)
	}

	destfileName := asset.DestFilename
	if destfileName == "" {
		p := asset.Path
		if p == "" {
			p = asset.URL
		}
		destfileName = path.Base(p)
	}

	dest := asset.Path

	if asset.URL != "" {
		if dest != "" {
			log.Println("Please use either 'path' or 'url' in a file type module")
			reportIncompatibleModule(assetIface)
		}
		dest = fetchAssetFromURL(asset)
	}

	copyFileOrDir(dest, path.Join(moduleDir, destfileName))
}

func gitClone(url string, branch string, repoFolder string) error {
	cmd := exec.Command("git", "clone", url, "--branch", branch, "--depth", "1", "--single-branch", repoFolder)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	return cmd.Run()
}

func fetchGitAsset(moduleDir string, assetIface interface{}) {
	asset := GitAsset{}
	if err := decodeAsset(assetIface, &asset); err != nil {
		log.Fatalf("Failed to decode module: %v", err)
	}

	parsedURL, err := url.Parse(asset.URL)
	if err != nil {
		log.Fatal(err)
	}

	branch := asset.Branch
	if branch == "" {
		branch = "main"
	}

	name := asset.Name
	if name == "" {
		name = strings.Split(path.Base(parsedURL.Path), ".")[0]
	}

	if err := gitClone(asset.URL, branch, path.Join(moduleDir, name)); err != nil {
		log.Fatal(err)
	}
}

func reportIncompatibleModule(asset interface{}) {
	d, err := yaml.Marshal(asset)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	log.Fatalf("Module not compatible:\n%v", string(d))
}

func decodeAsset(assetIface interface{}, asset interface{}) error {
	decoder, err := mapstructure.NewDecoder(&mapstructure.DecoderConfig{
		TagName: "yaml",
		Result:  asset,
	})
	if err != nil {
		return err
	}

	err = decoder.Decode(assetIface)
	if err != nil {
		return err
	}

	return nil
}

func runModule(moduleDir string, module Module) {
	for _, assetIface := range module.Assets {
		typeName, _ := assetIface["type"].(string)
		switch typeName {
		case "file":
			fetchFileAsset(moduleDir, assetIface)
		case "git":
			fetchGitAsset(moduleDir, assetIface)
		default:
			reportIncompatibleModule(assetIface)
		}
	}
}

func build(data InstallerConf) error {
	dir, err := ioutil.TempDir(BuildDir, "build-")
	if err != nil {
		return err
	}

	defer os.RemoveAll(dir)

	if err := os.Chmod(dir, 0755); err != nil {
		return err
	}

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

	copyFileOrDir(entryScript, path.Join(dir, "run.sh"))

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

func buildRunnerImage() {
	cmd := exec.Command("docker", "build", "-t", "racker-runner:latest", "-f", "Dockerfile", ".")
	cmd.Dir = "./racker-runner"
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	err := cmd.Run()
	if err != nil {
		log.Fatalf("Failed to create racker-runner image: %v", err)
	}
}

func main() {
	forceBuild := flag.Bool("force", false, "build even if there's already a tarball")
	onlyBuild := flag.String("only", "", "build only these options: tarball, image, or runner")
	confFilePath := flag.String("config", "./conf.yaml", "path to the configuration file")
	flag.Parse()

	buildTarball := *onlyBuild == "" || *onlyBuild == "tarball"
	buildImg := *onlyBuild == "" || *onlyBuild == "image"
	buildRunner := *onlyBuild == "" || *onlyBuild == "runner"

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

	if !buildTarball && !buildImg && !buildRunner {
		log.Fatal("error: '-only' option not recognized, please use tarball, image, or runner.")
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

		buildImage(t)
	}

	if buildRunner {
		buildRunnerImage()
	}
}
