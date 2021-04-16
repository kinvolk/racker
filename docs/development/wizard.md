---
title: Arguments Wizard
linkTitle: Wizard
weight: 60
---

Racker's project has an `args-wizard` module which is a command line tool to conveniently show a set of questions/options to the user through in either a guided/wizard way, or as command-line flags as an alternative (e.g. for automation).
This means that each argument can be set up as a **prompt** (a question that is shown to the user, with help text, options, etc.), a **flag** (simply passed as a CLI option `-example=value` that receives a string value), or both.

The `args-wizard` doesn't run any logic as a result of the user's answers (except for choosing the next question based on some answers). The idea is that the wizard can guide the user through a set of questions, and then have the answers be printed in the standard output as assigned in following fashion:

```bash
MY_VARIABLE=user-answer1
MY_OTHER_VARIABLE=user-answer2
```

This gives the flexibility we need to create configuration from the user's answers, and run scripts accordingly.

## Wizard arguments configuration

The `args-wizard` tool reads the configured arguments as a YAML file and then it creates the answers graph (using the golang's [survey project](https://github.com/AlecAivazis/survey)) as well as command-line flags (using golang's flag module).

This section describes the different options that the `args-wizard` supports.

### Basic module configuration

The minimal `args-wizard` configuration is just a list of arguments:

```yaml
args:
- ...
- ...
- ...
```

Every element in the `args` list will have the needed configuration for that arg's flag and prompt.

### Arguments' configuration

Each entry in the args' list can have the following members:

  * **name**: The name for the argument (this will be used for the flag's name as well, and should have no spaces)
  * **var**: The name of the variable that this argument's value will be printed as assigned to (usually it's an uppercase name).
  * **default**: The default value for the variable (if the argument has options, the default value should be one of them).
  * **prompt**: Configuration for the prompt.
  * **flag**: Configuration for the flag.
  * **options**: Options configuration.
  * **help**: Help text for the flag and the prompt (unless specific help texts are assigned to them).

### Prompt's configuration

A *prompt* is a question that's shown to the user, with a type, message, help text, etc.

Here are the members it supports:

  * **message**: The text to show as the question for the user.
  * **type**: One of the following:
    * **select**: Allows the user to select from the options defined at the argument's level.
    * **multi-select**: Same as above but allows multiple selection. The resulting variable will have the values assigned to it and comma separated.
    * **confirm**: Allows the user to choose yes or no (`Y/n`) and will assigned the resulting variable to **true** or **false** respectively.
    * **editor**: Opens the default editor for the user to edit its contents (which will be given by the argument's **default**)
  * **default**: Same the argument's default concept, but specific to the prompt. Use in case there's a need to differentiate between the flag and the prompt's defaults.
  * **next**: List of the next prompts, depending on the answers given to this one. If not configured, then the next question will be the one sequentially after it in the list of arguments. Each entry can have:
    * **prompt**: The name of the prompt to shown next (if the answer's condition is satisfied).
    * **if-value**: The value for the answer's, meaning that if the user answers this value, then the next question is the one indicated by the **prompt** line above.
    * **if-value-not**: If the user does **not** answer this value, then the next question is the one indicated by the **prompt** line above.
  * **skip**: Whether to skip this prompt (meaning the question needs to be linked to by another question -- using the **next** field -- as it will not be shown directly).

### Flag's configuration

  * **skip**: Do not use this argument as a flag.
  * **help**: The help/description text for the flag (so it supports different texts for the flag and the prompts).
  * **ignored**: Set to `true` if the flag should be ignored when processing the CLI arguments. This is needed when we know that a flag is likely to be set in the CLI arguments but we don't want the flag parser to report we have an unknown argument and halt the program.

## Example configuration

TBD
