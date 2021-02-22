##
## Stage 1: OCaml: Building herdtools7 and c4f
##

# To build the various OCaml dependencies, we need OPAM.  There is already an
# OPAM image set in Docker Hub, so it's easiest to use that.
#
# The Linux distro used here should line up with the one used in stage 2.
FROM ocaml/opam:debian-ocaml-4.12 as builder

# Copying across parts of the builder stage to the runner stage requires that
# we know where OPAM has put its built binaries and shared files.  For now,
# we hardcode the path to the specific switch below; this is fairly inelegant,
# so any better ideas on how to do this are appreciated.
ENV opam_root /home/opam/.opam/4.12

#
# Preamble
#

# Installing prerequisites for the OCaml builds.
USER root
RUN apt-get update && apt-get install -y m4

# Dropping to a less privileged user.
USER opam
WORKDIR /home/opam

#
# Herdtools7
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

# Then, get the source trees, in rough increasing order of likelihood of
# change.
COPY --chown=opam c4f/bin /home/opam/c4f/bin
COPY --chown=opam c4f/regress_tests /home/opam/c4f/regress_tests
COPY --chown=opam c4f/lib /home/opam/c4f/lib

# Now, build the c4f OCaml binaries.
RUN opam update && opam install .

##
## Stage 2: Building the running environment
##

FROM debian

# Start as root - we'll make an unprivileged user eventually, but need to do
# some work first.
USER root

# Installing the compilers we want to test.  These won't change when we rebuild
# c4, so we do them in an early layer.
RUN apt-get update && apt-get install -y build-essential gcc clang

# We need to make the unprivileged user _before_ pointing symlinks into its
# home directory.
RUN useradd -ms /bin/bash c4

# `herdtools7` binaries expect various files in `${opam_root}/share/herdtools7`.
# There doesn't seem to be an elegant way to fix this, so what we do is point a
# symlink into `/home/act/share/herdtools7`, and later copy the files into
# there.
ENV opam_root /home/opam/.opam/4.12
RUN mkdir -p ${opam_root}/share && \
    mkdir -p /home/c4/share/herdtools7 && \
    ln -s /home/c4/share/herdtools7 ${opam_root}/share/herdtools7

# We can now step down to an unprivileged user; C4 shouldn't need root!
USER c4
WORKDIR /home/c4

# Copy over herdtools and their run-time data.
COPY --from=builder --chown=c4 \
 ${opam_root}/bin/herd7 \
 ${opam_root}/bin/litmus7 \
 bin/
COPY --from=builder --chown=c4 ${opam_root}/share/herdtools7 share/herdtools7

# Copy over the c4f binaries, which should *hopefully* work.
COPY --from=builder --chown=c4 ${opam_root}/bin/c4f* bin/

# Put the newly copied-over binaries on PATH.
ENV PATH "/home/c4/bin:${PATH}"

