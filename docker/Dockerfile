# TWRP build container for warhol.
#
# Runs as linux/amd64. On Apple Silicon the x86_64 instructions are translated by
# Rosetta (via colima --vz-rosetta), not emulated by QEMU — that is the difference
# between "a few hours" and "overnight". Verify with:
#     docker run --rm --platform linux/amd64 ubuntu uname -m   -> x86_64
#     ls /proc/sys/fs/binfmt_misc/rosetta                      -> must exist in the VM
FROM --platform=linux/amd64 ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      bc bison build-essential ccache curl flex g++-multilib gcc-multilib git \
      git-lfs gnupg gperf imagemagick lib32readline-dev lib32z1-dev libelf-dev \
      liblz4-tool libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop pngcrush \
      rsync schedtool squashfs-tools xsltproc zip zlib1g-dev \
      python3 python3-pip python-is-python3 openjdk-11-jdk-headless \
      unzip zstd file nano less ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

# repo
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo \
    && chmod a+x /usr/local/bin/repo

# AOSP's build servers reject the default 'ubuntu' git identity.
RUN git config --system user.email "twrp@warhol.local" \
    && git config --system user.name "warhol builder" \
    && git config --system --add safe.directory '*'

# ccache pays for itself the moment you rebuild once.
ENV USE_CCACHE=1 CCACHE_EXEC=/usr/bin/ccache CCACHE_DIR=/ccache
ENV LC_ALL=C.UTF-8

WORKDIR /aosp
CMD ["/bin/bash"]
