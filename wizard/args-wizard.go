package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"

	"github.com/AlecAivazis/survey/v2"
	"gopkg.in/yaml.v2"
)

type Prompt struct {
	Message string      `yaml:",omitempty"`
	Type    string      `yaml:",omitempty"`
	Help    string      `yaml:",omitempty"`
	Default interface{} `yaml:",omitempty"`
}

type Arg struct {
	Name    string   `yaml:",omitempty"`
	Var     string   `yaml:",omitempty"`
	Default string   `yaml:",omitempty"`
	Prompt  Prompt   `yaml:",omitempty"`
	Options []string `yaml:",omitempty"`
	Help    string   `yaml:",omitempty"`
}

type InstallerConf struct {
	OutputFilename string `yaml:"output-file,omitempty"`
	Args           []Arg  `yaml:",omitempty"`
}

func divideArgs(args []string) ([]string, []string) {
	numArgs := len(args)
	for i := 0; i < numArgs; i++ {
		if args[i] == "--" {
			var secondArgs []string
			if i+1 < numArgs {
				secondArgs = args[i+1:]
			}
			return args[0:i], secondArgs
		}
	}

	return args, nil
}

func main() {
	ownFlags := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	confFilePath := ownFlags.String("config", "./args.yaml", "path to the configuration file")

	ownArgs, secondArgs := divideArgs(os.Args[1:])

	err := ownFlags.Parse(ownArgs)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	t := InstallerConf{}

	data, err := ioutil.ReadFile(*confFilePath)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	err = yaml.Unmarshal(data, &t)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	argsMap := make(map[string]Arg)
	answers := make(map[string]interface{})

	questions := []*survey.Question{}

	flags := flag.NewFlagSet("", flag.ExitOnError)

	for _, arg := range t.Args {
		var p survey.Prompt

		switch arg.Prompt.Type {
		case "multi-select":
			p = &survey.MultiSelect{
				Message: arg.Prompt.Message,
				Options: arg.Options,
				Default: arg.Default,
				Help:    arg.Help,
			}
			answers[arg.Name] = flags.String(arg.Name, arg.Default, arg.Help)
		case "select":
			p = &survey.Select{
				Message: arg.Prompt.Message,
				Options: arg.Options,
				Default: arg.Default,
				Help:    arg.Help,
			}
			answers[arg.Name] = flags.String(arg.Name, arg.Default, arg.Help)
		default:
			p = &survey.Input{
				Message: arg.Prompt.Message,
				Default: arg.Default,
				Help:    arg.Help,
			}
			answers[arg.Name] = flags.String(arg.Name, arg.Default, arg.Help)
		}

		questions = append(questions, &survey.Question{
			Name:   arg.Name,
			Prompt: p,
		})

		argsMap[arg.Name] = arg
	}

	usedFlags := false
	if len(secondArgs) > 0 {
		if err = flags.Parse(secondArgs); err != nil {
			flags.PrintDefaults()
			log.Fatal(err)
		}
		usedFlags = true
	} else {
		err = survey.Ask(questions, &answers, survey.WithStdio(os.Stdin, os.Stderr, os.Stderr))
		if err != nil {
			log.Fatal(err)
			return
		}
	}

	results := ""

	for key, val := range answers {
		s, ok := val.(string)
		if !ok {
			if usedFlags {
				sPtr, ok := val.(*string)
				if ok {
					s = *sPtr
				} else {
					log.Fatalf("Cannot get type for %s: %v\n", key, val)
				}
			} else {
				ans, ok := val.(survey.OptionAnswer)
				if !ok {
					ans, ok := val.([]survey.OptionAnswer)
					if !ok {
						flags.PrintDefaults()
						log.Fatalf("Cannot get type for %s: %v\n", key, val)
					}

					for i, val := range ans {
						s += val.Value
						if i != len(ans)-1 {
							s += ","
						}
					}
				} else {
					s = ans.Value
				}
			}
		}

		results += fmt.Sprintf("%s=%s\n", argsMap[key].Var, s)
	}

	fmt.Print(results)
}
