ARG BASE_IMAGE=debian:stable-slim
FROM $BASE_IMAGE as racker-build

ARG RACKER_VERSION=

RUN apt-get update
RUN apt-get -y install arp-scan ipmitool nano

ARG RACKER_TARBALL=racker.tar.gz
ENV RACKER_TARBALL=$RACKER_TARBALL

ENV RACKER_DIR=/racker

RUN mkdir -p $RACKER_DIR/
COPY --chown=1000:1000 $RACKER_TARBALL $RACKER_DIR/

ADD --chown=1000:1000 ./racker-run.sh $RACKER_DIR/

RUN echo $RACKER_VERSION > $RACKER_DIR/RACKER_VERSION

CMD $RACKER_DIR/racker-run.sh
