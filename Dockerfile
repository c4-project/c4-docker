# This Dockerfile builds a minimal C4 environment with c4f, c4t, c4-corpora,
# herdtools7, and the Debian stock gcc and clang compilers.
#
# A lot of this file is specific to maintaining a Docker build, but comments
# marked [!] are useful notes for setting up your own C4 environment outside
# Docker.

##
## Stage 1: OCaml: Building herdtools7 and c4f
##

# To build the various OCaml dependencies, we need OPAM.  There is already an
# OPAM image set in Docker Hub, so it's easiest to use that.
#
# [!] If building yourself, you'll need OPAM installed too.  See your local
#     package manager.
#
# The Linux distro used here should line up with the one used in stage 2.
FROM ocaml/opam:debian-ocaml-4.12 as c4fbuild

# Copying across parts of the builder stage to the runner stage requires that
# we know where OPAM has put its built binaries and shared files.  For now,
# we hardcode the path to the specific switch below; this is fairly inelegant,
# so any better ideas on how to do this are appreciated.
ENV opam_root /home/opam/.opam/4.12

#
# Preamble
#

# Installing prerequisites for the OCaml builds.
# [!] You might need to do this if building c4 yourself.
USER root
RUN apt-get update && apt-get install -y m4

# Dropping to a less privileged user.
USER opam
WORKDIR /home/opam

#
# Herdtools7
#

# [!] herdtools7 can be installed using OPAM, which we do here, or from the
#     github.com/herd/herdtools7.
#
# Note that the `herdtools7` binaries, `herd7` and `litmus7`, will have
# hardcoded references to ${opam_root}.  This means we'll need to be creative
# when we copy them to the final stage.
RUN opam update && opam install herdtools7

#
# c4f
#

RUN mkdir /home/opam/c4f
WORKDIR /home/opam/c4f

# First, acquire the dependencies for the c4f OCaml binaries.
# Do this _before_ gulping down the source trees, so that a cache invalidation
# on the source doesn't force a rebuild of all of ACT's dependencies.
COPY --chown=opam c4f/c4f.opam c4f/dune-project c4f/Makefile /home/opam/c4f/
RUN opam update && opam install --deps-only .

# Then, get the source trees, in rough increasing order of likelihood of change.
COPY --chown=opam c4f/bin /home/opam/c4f/bin
COPY --chown=opam c4f/regress_tests /home/opam/c4f/regress_tests
COPY --chown=opam c4f/lib /home/opam/c4f/lib

# Now, build the c4f OCaml binaries.
#
# [!] If building c4f yourself, running `opam install .` in a working copy of
#     c4f should work (and will install c4f into your OPAM path).
RUN opam update && opam install .

##
## Stage 2: Building c4t
##

# Get an environment which has Go installed in it already.
#
# [!] If building c4t yourself, you'll need Go, with at least the version
#     referenced below.
FROM golang:1.16-buster AS c4tbuild

# Copy the c4t source from its subdir...
WORKDIR /go/src/c4t
COPY c4t .

# ...get its dependencies, and build it.
#
# [!] Similar commands should work if you're building c4t yourself, as long as
#     you're in a c4t working copy.
RUN go get -d -v ./...
RUN go install -v ./...

##
## Stage 3: Building the running environment
##

# We no longer need OCaml or Go toolchains at this point.
FROM debian

# Start as root - we'll make an unprivileged user eventually, but need to do
# some work first.
USER root

# Installing the compilers we want to test.  These won't change when we rebuild
# c4, so we do them in an early layer.
#
# [!] Remember to have compilers installed that you can test with C4.
#     c4t will search for `gcc` and `clang` as part of its config generation,
#     but any other compilers will need to be configured manually.
RUN apt-get update && apt-get install -y build-essential gcc clang

# We need to make the unprivileged user _before_ pointing symlinks into its
# home directory.
RUN useradd -ms /bin/bash c4

# `herdtools7` binaries expect various files in `${opam_root}/share/herdtools7`.
# There doesn't seem to be an elegant way to fix this, so what we do is point a
# symlink into `/home/act/share/herdtools7`, and later copy the files into
# there.
#
# [!] You won't need to do this if setting up C4 yourself.
ENV opam_root /home/opam/.opam/4.12
RUN mkdir -p ${opam_root}/share && \
    mkdir -p /home/c4/share/herdtools7 && \
    ln -s /home/c4/share/herdtools7 ${opam_root}/share/herdtools7

# We can now step down to an unprivileged user; C4 shouldn't need root!
USER c4
WORKDIR /home/c4

# Put local binaries on PATH.
ENV PATH "/home/c4/bin:${PATH}"

# Make the scratch and config directories.
#
# [!] If setting up C4 yourself, you'll need to make thes directories too;
#     you can choose wherever the scratch directory will go, but the config
#     directory should be that referenced by `c4t-config -G` on your system.
#     It isn't always .config/c4t, eg on macOS or Windows.
RUN mkdir out && mkdir -p .config/c4t

# Copy over the part of configuration that isn't dependent on the Docker image.
#
# [!] If setting up C4 yourself, we recommend doing the same;
#     `c4t-config` only generates the parts of configuration that are dependent
#     on the machine, and doesn't add in things like sample sizes and timeouts
#     that are necessary to make c4t efficient.
COPY --chown=c4 conf.in.toml conf.in.toml
# Copy over the corpora (a snapshot of github.com/c4-project/c4-corpora).
COPY --chown=c4 c4-corpora corpora

# Copy over herdtools and their run-time data from the previous stage.
#
# [!] You won't need to do this if you're setting up C4 yourself.
COPY --from=c4fbuild --chown=c4 \
 ${opam_root}/bin/herd7 \
 ${opam_root}/bin/litmus7 \
 bin/
COPY --from=c4fbuild --chown=c4 ${opam_root}/share/herdtools7 share/herdtools7

# Copy over the c4f and c4t binaries, which should *hopefully* work.
#
# [!] You shouldn't need to do this if you're setting up C4 yourself.
COPY --from=c4fbuild --chown=c4 ${opam_root}/bin/c4f* bin/
COPY --from=c4tbuild --chown=c4 /go/bin/* bin/

# Generate a configuration file, glue some hand-written configuration onto it,
# then put it where c4t expects to see global configuration.
#
# [!] You'll need to do something similar to this if you're setting up C4
#     yourself (or write the configuration from scratch).  Remember to make
#     sure c4t's configuration directory is present before writing into it.
RUN c4t-config | cat conf.in.toml - > `c4t-config -G`

# We now have a working minimal C4 setup.
