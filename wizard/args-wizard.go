package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"strconv"

	"github.com/AlecAivazis/survey/v2"
	"gopkg.in/yaml.v2"
)

type Prompt struct {
	Message string      `yaml:",omitempty"`
	Type    string      `yaml:",omitempty"`
	Help    string      `yaml:",omitempty"`
	Default interface{} `yaml:",omitempty"`
}

type ArgOption struct {
	Display string `yaml:",omitempty"`
	Value   string `yaml:",omitempty"`
}

type Arg struct {
	Name    string      `yaml:",omitempty"`
	Var     string      `yaml:",omitempty"`
	Default string      `yaml:",omitempty"`
	Prompt  Prompt      `yaml:",omitempty"`
	Options []ArgOption `yaml:",omitempty"`
	Help    string      `yaml:",omitempty"`
}

type InstallerConf struct {
	Args []Arg `yaml:",omitempty"`
}

func (o *ArgOption) UnmarshalYAML(unmarshal func(interface{}) error) error {
	var optString string
	if err := unmarshal(&optString); err != nil {
		var optInt int
		if err := unmarshal(&optInt); err != nil {
			var m map[string]string
			if err := unmarshal(&m); err != nil {
				return err
			}
			o.Value = m["value"]
			o.Display = m["display"]
			return nil
		}

		optString = strconv.Itoa(optInt)
	}

	o.Display = optString
	o.Value = optString

	return nil
}

func argOptionsToSurveyOption(opts []ArgOption) []string {
	sOpts := make([]string, len(opts))
	for i, opt := range opts {
		sOpts[i] = opt.Display
	}
	return sOpts
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

func getValueFromAnswer(anserIface interface{}, options []ArgOption) (string, error) {
	s := ""
	ans, ok := anserIface.(survey.OptionAnswer)

	if !ok {
		ans, ok := anserIface.([]survey.OptionAnswer)
		if !ok {
			return "", fmt.Errorf("cannot get type for option: %v\n", anserIface)
		}

		for i, val := range ans {
			s += options[val.Index].Value
			if i != len(ans)-1 {
				s += ","
			}
		}
	} else {
		s = options[ans.Index].Value
	}

	return s, nil
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
				Options: argOptionsToSurveyOption(arg.Options),
				Default: arg.Default,
				Help:    arg.Help,
			}
			answers[arg.Name] = flags.String(arg.Name, arg.Default, arg.Help)
		case "select":
			p = &survey.Select{
				Message: arg.Prompt.Message,
				Options: argOptionsToSurveyOption(arg.Options),
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
				s, err = getValueFromAnswer(val, argsMap[key].Options)
				if err != nil {
					flags.PrintDefaults()
					log.Fatalf("Failed to get value from answer %s: %v\n", key, err)
				}
			}
		}

		results += fmt.Sprintf("%s=%s\n", argsMap[key].Var, s)
	}

	fmt.Print(results)
}
