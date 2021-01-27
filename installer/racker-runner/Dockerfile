ARG BASE_IMAGE=alpine:3.13.0
FROM $BASE_IMAGE as racker-runner-build

ENV RACKER_DIR=/racker

RUN mkdir -p $RACKER_DIR/

ADD --chown=1000:1000 ./racker-run.sh $RACKER_DIR/

CMD cat $RACKER_DIR/racker-run.sh
