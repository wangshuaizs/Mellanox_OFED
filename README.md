# MLNX_OFED for collecting throughput

This MLNX_OFED is based on [MLNX_OFED_SRC-debian-4.1-1.0.2.0.tgz](http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.1-1.0.2.0/MLNX_OFED_SRC-debian-4.1-1.0.2.0.tgz). To collect throughput information, some codes, creating a new thread to poll completion queue, are added in libmlx4-41mlnx1/src/verbs.c.

(Note: only the traffic received by the host is collected.)


# Usage

You can choose to install from the [source codes](./MLNX_OFED_SRC-4.1-1.0.2.0) in this repository, or patch the source codes from [Mellanox website](http://www.mellanox.com/downloads/ofed/MLNX_OFED-4.1-1.0.2.0/MLNX_OFED_SRC-debian-4.1-1.0.2.0.tgz).

```
sudo ./install.pl
```

Some environment variables have to be set before establishing RDMA connection:

+ __DUMP_LOG__ : The path to be used to log outputs;
+ __DUMP__ : The flag to signal whether or not to print;

# Additions

The file [untar.sh](./tool/untar.sh) is also offered to extract files from all archives.