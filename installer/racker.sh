#/bin/sh -e

RUN_SCRIPT=racker-run.sh

docker run -it racker:latest > $RUN_SCRIPT

# Replace carriage return, which confuses the interpreter.
sed -i 's/\r//g' $RUN_SCRIPT

chmod a+x $RUN_SCRIPT
./$RUN_SCRIPT
