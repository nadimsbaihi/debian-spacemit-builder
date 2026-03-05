FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    debootstrap \
    qemu-user-static \
    binfmt-support \
    dosfstools \
    e2fsprogs \
    mtools \
    fdisk \
    util-linux \
    wget \
    curl \
    kmod \
    uuid-runtime \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY build.sh /build/build.sh
RUN chmod +x /build/build.sh

ENTRYPOINT ["/build/build.sh"]
