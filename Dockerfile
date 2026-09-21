# Builder image with QNAP QDK (qbuild) on Ubuntu. The package is
# architecture-independent shell and HTML, so no cross toolchain is needed.
#
# Both the base image and QDK are pinned: qbuild decides what goes into
# the .qpkg, so a moving build tool would change packages without any
# change in this repository. QDK_REF must match the one in
# .github/workflows/build.yml (scripts/check-ci-pins.sh enforces it).

FROM ubuntu:25.10@sha256:7cc5e35f6567ee8c66d2abb4aab0fd866669e6207c237c3a8f0947a5c7f17092

ARG QDK_REF=b7b5f4c86ebe95b10a62d64725515e7cdcf4bb35

ENV DEBIAN_FRONTEND=noninteractive

# gcc is required: QDK's InstallToUbuntu.sh compiles qpkg_encrypt, and
# qbuild encrypts the payload with it. Without it qbuild still produces a
# .qpkg, which App Center then rejects with "file format error".
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates make gcc libc6-dev rsync xz-utils curl dos2unix \
        python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

RUN git init -q /tmp/QDK \
    && cd /tmp/QDK \
    && git remote add origin https://github.com/qnap-dev/QDK.git \
    && git fetch -q --depth 1 origin "$QDK_REF" \
    && git checkout -q FETCH_HEAD \
    && ./InstallToUbuntu.sh install \
    && rm -rf /tmp/QDK

ENV PATH="/usr/share/QDK/bin:${PATH}"

WORKDIR /src
CMD ["qbuild", "--build-arch", "x86_64"]
