/*
Copyright 2021 Kinvolk GmbH

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/AlecAivazis/survey/v2"
	"gopkg.in/yaml.v2"
)

type NextPrompt struct {
	Prompt         string  `yaml:",omitempty"`
	ConditionValue *string `yaml:"if-value,omitempty"`
	Negate         bool    `yaml:"not,omitempty"`
}

type Prompt struct {
	Message string       `yaml:",omitempty"`
	Type    string       `yaml:",omitempty"`
	Help    string       `yaml:",omitempty"`
	Default interface{}  `yaml:",omitempty"`
	Skip    bool         `yaml:",omitempty"`
	Next    []NextPrompt `yaml:",omitempty"`
}

type ArgOption struct {
	Display string `yaml:",omitempty"`
	Value   string `yaml:",omitempty"`
}

type Flag struct {
	Skip         bool   `yaml:",omitempty"`
	Help         string `yaml:",omitempty"`
	AllowPrompts bool   `yaml:"allow-other-prompts,omitempty"`
}

type Arg struct {
	Name    string      `yaml:",omitempty"`
	Var     string      `yaml:",omitempty"`
	Default string      `yaml:",omitempty"`
	Prompt  Prompt      `yaml:",omitempty"`
	Flag    Flag        `yaml:",omitempty"`
	Options []ArgOption `yaml:",omitempty"`
	Help    string      `yaml:",omitempty"`
	Ignore  bool        `yaml:",omitempty"`
}

type ArgQuestion struct {
	Arg    Arg
	Prompt *survey.Prompt
	Next   *ArgQuestion
}

type ArgsWizardConf struct {
	IgnoreUnknownFlags bool  `yaml:"ignore-unknown-flags,omitempty"`
	Args               []Arg `yaml:",omitempty"`
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

func (o *NextPrompt) UnmarshalYAML(unmarshal func(interface{}) error) error {
	var m map[string]string
	if err := unmarshal(&m); err != nil {
		return err
	}
	o.Prompt = m["prompt"]
	if cond, present := m["if-value"]; present {
		o.ConditionValue = &cond
		o.Negate = false
	}
	if cond, present := m["if-value-not"]; present {
		o.ConditionValue = &cond
		o.Negate = true
	}

	return nil
}

func argOptionsToSurveyOption(opts []ArgOption) []string {
	sOpts := make([]string, len(opts))
	for i, opt := range opts {
		sOpts[i] = opt.Display
	}
	return sOpts
}

func getDefaultOptionValue(opts []ArgOption, defaultValue string) string {
	for _, opt := range opts {
		if opt.Value == defaultValue {
			return opt.Display
		}
	}
	return defaultValue
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
	s, ok := anserIface.(string)
	if ok {
		return s, nil
	}

	b, ok := anserIface.(bool)
	if ok {
		if b {
			return "true", nil
		}
		return "false", nil
	}

	s = ""
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

func cleanArgs(args []string, c ArgsWizardConf) []string {
	argsToIgnore := make(map[string]bool)
	knownArgs := make(map[string]bool)

	for _, arg := range c.Args {
		if arg.Ignore {
			argsToIgnore[arg.Name] = true
			continue
		}
		knownArgs[arg.Name] = true
	}

	shouldIgnore := func(arg string) bool {
		return argsToIgnore[arg] || (c.IgnoreUnknownFlags && !knownArgs[arg])
	}

	var cleanedArgs []string

	i := 0
	for i < len(args) {
		flag := args[i]
		flagSplit := strings.Split(flag, "=")
		flag = flagSplit[0]
		flagUsesEqual := len(flagSplit) > 1

		i++

		if !shouldIgnore(strings.TrimPrefix(flag, "-")) {
			cleanedArgs = append(cleanedArgs, flag)
			if flagUsesEqual {
				cleanedArgs = append(cleanedArgs, flagSplit[1])
			} else if i < len(args) {
				// Add positional argument
				cleanedArgs = append(cleanedArgs, args[i])
			}
		}

		// Jump to after the positional argument.
		if !flagUsesEqual {
			i++
		}
	}
	return cleanedArgs
}

func isFlagSet(flagSet *flag.FlagSet, flagName string) bool {
	isSet := false
	flagSet.Visit(func(f *flag.Flag) {
		if f.Name == flagName {
			isSet = true
		}
	})

	return isSet
}

func main() {
	ownFlags := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	confFilePath := ownFlags.String("config", "./args.yaml", "path to the configuration file")
	showHelp := ownFlags.Bool("show-help", false, "show the help/usage associated with the given configuration")

	ownArgs, secondArgs := divideArgs(os.Args[1:])

	err := ownFlags.Parse(ownArgs)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	c := ArgsWizardConf{}

	data, err := ioutil.ReadFile(*confFilePath)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	err = yaml.Unmarshal(data, &c)
	if err != nil {
		log.Fatalf("error: %v", err)
	}

	argsMap := make(map[string]*ArgQuestion)
	answers := make(map[string]interface{})
	results := make(map[string]string)

	flags := flag.NewFlagSet("", flag.ExitOnError)

	var firstQuestion *ArgQuestion
	var lastQuestion *ArgQuestion

	for _, arg := range c.Args {
		if arg.Ignore {
			continue
		}

		var p survey.Prompt

		help := arg.Prompt.Help
		if help == "" {
			help = arg.Help
		}

		switch arg.Prompt.Type {
		case "multi-select":
			p = &survey.MultiSelect{
				Message: arg.Prompt.Message,
				Options: argOptionsToSurveyOption(arg.Options),
				Default: getDefaultOptionValue(arg.Options, arg.Default),
				Help:    help,
			}
		case "select":
			p = &survey.Select{
				Message: arg.Prompt.Message,
				Options: argOptionsToSurveyOption(arg.Options),
				Default: getDefaultOptionValue(arg.Options, arg.Default),
				Help:    help,
			}
		case "confirm":
			p = &survey.Confirm{
				Message: arg.Prompt.Message,
				Help:    help,
			}
		case "editor":
			p = &survey.Editor{
				Message:       arg.Prompt.Message,
				Help:          help,
				Default:       arg.Default,
				AppendDefault: true,
				HideDefault:   true,
			}
		default:
			p = &survey.Input{
				Message: arg.Prompt.Message,
				Default: arg.Default,
				Help:    help,
			}
		}

		if !arg.Flag.Skip {
			help := arg.Flag.Help
			if help == "" {
				help = arg.Help
			}
			answers[arg.Name] = flags.String(arg.Name, arg.Default, help)
		}

		a := ArgQuestion{arg, &p, nil}
		if firstQuestion == nil && !a.Arg.Prompt.Skip {
			firstQuestion = &a
			lastQuestion = &a
		} else if !a.Arg.Prompt.Skip {
			lastQuestion.Next = &a
			lastQuestion = &a
		}

		argsMap[arg.Name] = &a
	}

	if *showHelp {
		flags.PrintDefaults()
		os.Exit(0)
	}

	secondArgs = cleanArgs(secondArgs, c)

	promptMode := true

	if len(secondArgs) > 0 {
		if err = flags.Parse(secondArgs); err != nil {
			flags.PrintDefaults()
			log.Fatal(err)
		}

		for _, q := range argsMap {
			argName := q.Arg.Name

			if q.Arg.Flag.Skip {
				continue
			}

			// Some flags may be used while still letting prompts
			// be shown to the user, but by default the use of a flag
			// enfoces the flag-mode.
			if isFlagSet(flags, q.Arg.Name) && !q.Arg.Flag.AllowPrompts {
				promptMode = false
			}

			resultVar := q.Arg.Var

			if resultVar == "" {
				continue
			}

			ans, ok := answers[argName]

			// Flags that are skipped will not be present on answers.
			if !ok {
				continue
			}

			s := ""
			sPtr, ok := ans.(*string)
			if ok {
				s = *sPtr
			} else {
				log.Fatalf("Cannot get type for %s: %v\n", argName, ans)
			}

			if s == "" && results[resultVar] != "" {
				continue
			}

			results[argsMap[argName].Arg.Var] = s
		}

	}

	if promptMode {
		arg := firstQuestion
		for arg != nil {
			q := survey.Question{
				Name:   arg.Arg.Name,
				Prompt: *arg.Prompt,
			}
			err = survey.Ask([]*survey.Question{&q}, &answers, survey.WithStdio(os.Stdin, os.Stderr, os.Stderr))
			if err != nil {
				log.Fatal(err)
				return
			}

			val := answers[arg.Arg.Name]
			s, err := getValueFromAnswer(val, arg.Arg.Options)
			if err != nil {
				log.Fatalf("Failed to get value for %s: %v \n", arg.Arg.Name, err)
			}

			if arg.Arg.Var != "" {
				results[arg.Arg.Var] = s
			}

			nextArg := arg.Next

			for _, nextPrompt := range arg.Arg.Prompt.Next {
				if nextPrompt.ConditionValue != nil && ((*nextPrompt.ConditionValue == s) != nextPrompt.Negate) {
					nextArg = argsMap[nextPrompt.Prompt]
					break
				}
			}

			arg = nextArg
		}
	}

	for key, value := range results {
		fmt.Printf("%s=\"%s\"\n", key, value)
	}
}
