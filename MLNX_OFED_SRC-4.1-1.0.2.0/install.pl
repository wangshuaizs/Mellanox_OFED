#!/usr/bin/perl
#
# Copyright (c) 2013 Mellanox Technologies. All rights reserved.
#
# This Software is licensed under one of the following licenses:
#
# 1) under the terms of the "Common Public License 1.0" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/cpl.php.
#
# 2) under the terms of the "The BSD License" a copy of which is
#    available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/bsd-license.php.
#
# 3) under the terms of the "GNU General Public License (GPL) Version 2" a
#    copy of which is available from the Open Source Initiative, see
#    http://www.opensource.org/licenses/gpl-license.php.
#
# Licensee has the right to choose one of the above licenses.
#
# Redistributions of source code must retain the above copyright
# notice and one of the license notices.
#
# Redistributions in binary form must reproduce both the above copyright
# notice, one of the license notices in the documentation
# and/or other materials provided with the distribution.

use strict;
use File::Basename;
use File::Path;
use File::Find;
use File::Copy;
use Cwd;
use Term::ANSIColor qw(:constants);

my $PREREQUISIT = "172";
my $MST_START_FAIL = "173";
my $NO_HARDWARE = "171";
my $SUCCESS = "0";
my $DEVICE_INI_MISSING = "2";
my $ERROR = "1";
my $EINVAL = "22";
my $ENOSPC = "28";
my $NONOFEDRPMS = "174";

$ENV{"LANG"} = "C";

if ($<) {
	print RED "Only root can run $0", RESET "\n";
	exit $PREREQUISIT;
}
$| = 1;

my $WDIR    = dirname(`readlink -f $0`);
chdir $WDIR;
require("$WDIR/common.pl");
my $CWD     = getcwd;
my $DPKG = "/usr/bin/dpkg";
my $DPKG_QUERY = "/usr/bin/dpkg-query";
my $DPKG_BUILDPACKAGE = "/usr/bin/dpkg-buildpackage";
my $MODINFO = "/sbin/modinfo";
my $DPKG_FLAGS = "--force-confmiss";
my $DPKG_DEB = "/usr/bin/dpkg-deb";
my $BUILD_ENV = '';
my $enable_mlnx_tune = 0;
my $check_linux_deps = 1;

my $ifconf = "/etc/network/interfaces";
my $ib_udev_rules = "/etc/udev/rules.d/90-ib.rules";
my $config_net_given = 0;
my $config_net = "";
my %ifcfg = ();
my $umad_dev_rw = 0;
my $umad_dev_na = 0;
my $config_given = 0;
my $conf_dir = $CWD;
my $config = $conf_dir . '/ofed.conf';
chomp $config;
my $install_option = 'all';
if (-e "$CWD/.def_option" ) {
	$install_option = `cat $CWD/.def_option 2>/dev/null`;
	chomp $install_option;
}
my $user_space_only = 0;
my $with_vma = 0;
my $print_available = 0;
my $force = 0;
my %disabled_packages;
my %force_enable_packages;
my %packages_deps = ();
my %modules_deps = ();
my $with_memtrack = 0;
my $with_dkms = 1;
my $force_dkms = 0;
my $build_only = 0;
my $uninstall = 1;

# list of scripts to run for each package
my %package_pre_build_script = ();
my %package_post_build_script = ();
my %package_pre_install_script = ();
my %package_post_install_script = ();

$ENV{"DEBIAN_FRONTEND"} = "noninteractive";

my $fca_prefix = '/opt/mellanox/fca';

my $CMD = "$0 " . join(' ', @ARGV);

my $LOCK_EXCLUSIVE = 2;
my $UNLOCK         = 8;

my $PACKAGE     = 'OFED';
my $TMPDIR = "/tmp";
my $ofedlogs = "$TMPDIR/$PACKAGE.$$.logs";

my $quiet = 0;
my $verbose = 1;
my $verbose2 = 0;
my $verbose3 = 0;
my $log;
my %selected_for_uninstall;
my @dependant_packages_to_uninstall = ();
my %non_ofed_for_uninstall = ();

my $builddir = "/var/tmp/";

my %main_packages = ();
my @selected_packages = ();
my @selected_modules_by_user = ();
my @selected_kernel_modules = ();
my $kernel_configure_options = '';
# list of the packages that will be installed (selected by user)
my @selected_by_user = ();
my @selected_to_install = ();

my $distro = "";
my $arch = `uname -m`;
chomp $arch;
my $kernel = `uname -r`;
chomp $kernel;
my $kernel_sources = "/lib/modules/$kernel/build";
chomp $kernel_sources;
my $kernel_given = 0;
my $kernel_source_given = 0;
my $cross_compiling = 0;
my $check_deps_only = 0;

if ($ENV{"ARCH"} ne "" and $ENV{"ARCH"} ne "$arch") {
	print "Detected cross compiling (local: $arch, target: $ENV{ARCH})\n\n";
	$arch = $ENV{"ARCH"};
	$arch =~ s/arm64/aarch64/g;
	$DPKG_BUILDPACKAGE = "$DPKG_BUILDPACKAGE -a$ENV{ARCH}";
	$cross_compiling = 1;
}

#
# parse options
#
while ( $#ARGV >= 0 ) {
	my $cmd_flag = shift(@ARGV);

	if ( $cmd_flag eq "--all" ) {
		$install_option = 'all';
	} elsif ( $cmd_flag eq "--hpc" ) {
		$install_option = 'hpc';
	} elsif ( $cmd_flag eq "--basic" ) {
		$install_option = 'basic';
	} elsif ( $cmd_flag eq "--msm" ) {
		$install_option = 'msm';
	} elsif ( $cmd_flag eq "--with-vma" ) {
		$with_vma = 1;
	} elsif ( $cmd_flag eq "--vma" ) {
		$install_option = 'vma';
		$with_vma = 1;
	} elsif ( $cmd_flag eq "--vma-eth" ) {
		$install_option = 'vmaeth';
		$with_vma = 1;
	} elsif ( $cmd_flag eq "--vma-vpi" ) {
		$install_option = 'vmavpi';
		$with_vma = 1;
	} elsif ( $cmd_flag eq "--guest" ) {
		$install_option = 'guest';
	} elsif ( $cmd_flag eq "--hypervisor" ) {
		$install_option = 'hypervisor';
	} elsif ( $cmd_flag eq "--kernel-only" ) {
		$install_option = 'kernel-only';
	} elsif ( $cmd_flag eq "--user-space-only" ) {
		$user_space_only = 1;
	} elsif ( $cmd_flag eq "--eth-only" ) {
		$install_option = 'eth-only';
	} elsif ( $cmd_flag eq "--dpdk" ) {
		$install_option = 'dpdk';
	} elsif ( $cmd_flag eq "--umad-dev-rw" ) {
		$umad_dev_rw = 1;
	} elsif ( $cmd_flag eq "--umad-dev-na" ) {
		$umad_dev_na = 1;
	} elsif ( $cmd_flag eq "-q" ) {
		$quiet = 1;
		$verbose = 0;
		$verbose2 = 0;
		$verbose3 = 0;
	} elsif ( $cmd_flag eq "-v" ) {
		$verbose = 1;
	} elsif ( $cmd_flag eq "-vv" ) {
		$verbose = 1;
		$verbose2 = 1;
	} elsif ( $cmd_flag eq "-vvv" ) {
		$verbose = 1;
		$verbose2 = 1;
		$verbose3 = 1;
	} elsif ( $cmd_flag eq "--force" ) {
		$force = 1;
	} elsif ( $cmd_flag eq "-n" or $cmd_flag eq "--net" ) {
		$config_net = shift(@ARGV);
		$config_net_given = 1;
	} elsif ( $cmd_flag eq "--with-memtrack" ) {
		$with_memtrack = 1;
	} elsif ($cmd_flag eq "--conf-dir") {
		$conf_dir = shift(@ARGV);
		mkpath([$conf_dir]) unless -d "$conf_dir";
		if (not $config_given) {
			$config = $conf_dir . '/ofed.conf';
		}
	} elsif ( $cmd_flag eq "-c" or $cmd_flag eq "--config" ) {
		$config = shift(@ARGV);
		$config_given = 1;
	} elsif ( $cmd_flag eq "-p" or $cmd_flag eq "--print-available" ) {
		$print_available = 1;
	} elsif ( $cmd_flag eq "--builddir" ) {
		$builddir = shift(@ARGV);
	} elsif ( $cmd_flag eq "--tmpdir" ) {
		$TMPDIR = shift(@ARGV);
	} elsif ( $cmd_flag eq "--enable-mlnx_tune" ) {
		$enable_mlnx_tune = 1;
	} elsif ( $cmd_flag eq "--without-depcheck" ) {
		$check_linux_deps = 0;
	} elsif ( $cmd_flag eq "--check-deps-only" ) {
		$check_deps_only = 1;
	} elsif ( $cmd_flag eq "--without-dkms" ) {
		$with_dkms = 0;
		$force_dkms = 0;
	} elsif ( $cmd_flag eq "--force-dkms" ) {
		$with_dkms = 1;
		$force_dkms = 1;
	} elsif ( $cmd_flag eq "-k" or $cmd_flag eq "--kernel" ) {
		$kernel = shift(@ARGV);
		$kernel_given = 1;
	} elsif ( $cmd_flag eq "-b" or $cmd_flag eq "--build-only" ) {
		$build_only = 1;
		$uninstall = 0;
	} elsif ( $cmd_flag eq "-s" or $cmd_flag eq "--kernel-sources" ) {
		$kernel_sources = shift(@ARGV);
		$kernel_source_given = 1;
	} elsif ( $cmd_flag =~ /--without|--disable/ ) {
		my $pckg = $cmd_flag;
		$pckg =~ s/--without-|--disable-//;
		$disabled_packages{$pckg} = 1;
	} elsif ( $cmd_flag =~ /--with-|--enable-/ ) {
		my $pckg = $cmd_flag;
		$pckg =~ s/--with-|--enable-//;
		$force_enable_packages{$pckg} = 1;
	} elsif ( $cmd_flag eq "--distro" ) {
		$distro = shift(@ARGV);
	} elsif ( $cmd_flag =~ /--pre-build-/) {
		my $pckg = $cmd_flag;
		$pckg =~ s/--pre-build-//;
		my $script = shift(@ARGV);
		$package_pre_build_script{$pckg} = $script;
	} elsif ( $cmd_flag =~ /--post-build-/) {
		my $pckg = $cmd_flag;
		$pckg =~ s/--post-build-//;
		my $script = shift(@ARGV);
		$package_post_build_script{$pckg} = $script;
	} elsif ( $cmd_flag =~ /--pre-install-/) {
		my $pckg = $cmd_flag;
		$pckg =~ s/--pre-install-//;
		my $script = shift(@ARGV);
		$package_pre_install_script{$pckg} = $script;
	} elsif ( $cmd_flag =~ /--post-install-/) {
		my $pckg = $cmd_flag;
		$pckg =~ s/--post-install-//;
		my $script = shift(@ARGV);
		$package_post_install_script{$pckg} = $script;
	} elsif ( $cmd_flag eq "--package-install-options" ) {
		my $install_opt = shift(@ARGV);
		$install_opt =~ s/,/ /g;
		$DPKG_FLAGS .= " $install_opt";
	} elsif ( $cmd_flag eq "--help" or $cmd_flag eq "-h" ) {
		usage();
		exit 0;
	} else {
		print RED "\nUnsupported installation option: '$cmd_flag'", RESET "\n";
		print "To see list of supported options, run: $0 --help\n";
		exit $EINVAL;
	}
}


# packages to remove
my @remove_debs = qw(ar_mgr ar-mgr cc_mgr cc-mgr compat-dapl1 compat-dapl-dev dapl1 dapl1-utils dapl2-utils dapl-dev dump_pr dump-pr ibacm ibacm-dev ibsim ibsim-utils ibutils ibutils2 ibverbs-utils infiniband-diags libdapl2 libdapl-dev libibcm libibcm1 libibcm-dev libibdm1 libibdm-dev libibmad libibmad1 libibmad-dev libibmad-devel libibmad-static libibumad libibumad1 libibumad-dev libibumad-devel libibumad-static libibverbs libibverbs1 libibverbs1-dbg libibverbs-dev libipathverbs1 libipathverbs1-dbg libipathverbs-dev libmlx4 libmlx4-1 libmlx4-1-dbg libmlx4-dev libmlx5 libmlx5-1 libmlx5-1-dbg libmlx5-dev librxe-1 librxe-dev librxe-1-dbg libopensm libopensm2 libopensm2-dev libopensm-dev libopensm-devel librdmacm librdmacm1 librdmacm1-dbg librdmacm-dev libsdp1 libsdp-dev libumad2sim0 mlnx-ofed-kernel-dkms mlnx-ofed-kernel-modules mlnx-ofed-kernel-utils ofed-docs ofed-scripts opensm opensm-libs opensm-doc perftest rdmacm-utils rds-tools sdpnetstat srptools mft kernel-mft-dkms mft-compat mft-devel mft-devmon mft-devmondb mft-int mft-tests mstflint mxm ucx fca openmpi openshmem mpitests knem knem-dkms ummunotify ummunotify-dkms libvma libvma-utils libvma-dev libvma-dbg sockperf srptools iser-dkms isert-dkms srp-dkms libmthca-dev libmthca1 libmthca1-dbg ibdump mlnx-ethtool mlnx-fw-updater knem-modules iser-modules isert-modules srp-modules ummunotify-modules kernel-mft-modules libosmvendor libosmvendor4 libosmcomp libosmcomp3 mlnx-en mlnx-en-utils mlnx-en-dkms mlnx-en-modules mlnx-sdp-dkms mlnx-sdp-modules mlnx-rds-dkms mlnx-rds-modules mlnx-nfsrdma-dkms mlnx-nfsrdma-modules mlnx-nvme-dkms mlnx-nvme-modules mlnx-rdma-rxe-dkms mlnx-rdma-rxe-modules);

# required packages (will be always installed)
my @required_debs = qw(dpkg autotools-dev autoconf automake m4 debhelper chrpath swig graphviz dpatch libltdl-dev build-essential);

if ($kernel_given and not $kernel_source_given) {
    if (-d "/lib/modules/$kernel/build") {
        $kernel_sources = "/lib/modules/$kernel/build";
    }
    else {
        print RED "Provide path to the kernel sources for $kernel kernel.", RESET "\n";
        exit 1;
    }
}

# disable DKMS if given kernel was not installed from deb package
if (not $force_dkms and $with_dkms and -d "$kernel_sources/scripts") {
	my $src_path = `readlink -f $kernel_sources/scripts 2>/dev/null`;
	chomp $src_path;
	if ($src_path eq "") {
		$src_path = "$kernel_sources/scripts";
	}
	system("$DPKG -S $src_path >/dev/null 2>&1");
	my $res = $? >> 8;
	my $sig = $? & 127;
	if ($sig or $res) {
		print "DKMS is not supported for kernels which were not installed as DEB.\n" if ($verbose2);
		$with_dkms = 0;
	}
}

#
# set kernel packages names
#
my $mlnX_ofed_kernel = "mlnx-ofed-kernel-dkms";
my $kernel_mft = "kernel-mft-dkms";
my $knem = "knem-dkms";
my $iser = "iser-dkms";
my $isert = "isert-dkms";
my $srp = "srp-dkms";
my $ummunotify = "ummunotify-dkms";
my $mlnx_en = "mlnx-en-dkms";
my $mlnx_sdp = "mlnx-sdp-dkms";
my $mlnx_rds = "mlnx-rds-dkms";
my $mlnx_nfsrdma = "mlnx-nfsrdma-dkms";
my $mlnx_nvme = "mlnx-nvme-dkms";
my $mlnx_rdma_rxe = "mlnx-rdma-rxe-dkms";

if (not $with_dkms) {
	$mlnX_ofed_kernel = "mlnx-ofed-kernel-modules";
	$kernel_mft = "kernel-mft-modules";
	$knem = "knem-modules";
	$iser = "iser-modules";
	$isert = "isert-modules";
	$srp = "srp-modules";
	$ummunotify = "ummunotify-modules";
	$mlnx_en = "mlnx-en-modules";
	$mlnx_sdp = "mlnx-sdp-modules";
	$mlnx_rds = "mlnx-rds-modules";
	$mlnx_nfsrdma = "mlnx-nfsrdma-modules";
	$mlnx_nvme = "mlnx-nvme-modules";
	$mlnx_rdma_rxe = "mlnx-rdma-rxe-modules";
}

my $kernel_escaped = $kernel;
$kernel_escaped =~ s/\+/\\\+/g;

# custom packages
my @all_packages = (
				"ofed-scripts",
				"mlnx-ofed-kernel-utils", "$mlnX_ofed_kernel",
				"$iser",
				"$isert",
				"$srp",
				"$mlnx_sdp",
				"$mlnx_rds",
				"$mlnx_nfsrdma",
				"$mlnx_nvme",
				"$mlnx_rdma_rxe",
				"libibverbs1", "ibverbs-utils", "libibverbs-dev", "libibverbs1-dbg",
				"libmlx4-1", "libmlx4-dev", "libmlx4-1-dbg",
				"libmlx5-1", "libmlx5-dev", "libmlx5-1-dbg",
				"librxe-1", "librxe-dev", "librxe-1-dbg",
				"libibumad", "libibumad-static", "libibumad-devel",
				"ibacm", "ibacm-dev",
				"librdmacm1", "librdmacm-utils", "librdmacm-dev",
				"mstflint",
				"ibdump",
				"libibmad", "libibmad-static", "libibmad-devel",
				"opensm", "libopensm", "opensm-doc", "libopensm-devel",
				"infiniband-diags", "infiniband-diags-compat",
				"mft", "$kernel_mft",
				"libibcm1", "libibcm-dev",
				"ibacm", "ibacm-dev",
				"perftest",
				"ibutils2",
				"libibdm1", "ibutils",
				"cc-mgr",
				"ar-mgr",
				"dump-pr",
				"ibsim", "ibsim-doc",
				"mxm",
				"ucx",
				"sharp",
				"fca",
				"hcoll",
				"openmpi",
				"openshmem",
				"mpitests",
				"knem", "$knem",
				"ummunotify", "$ummunotify",
				"rds-tools",
				"libdapl2", "dapl2-utils", "libdapl-dev",
				"libvma", "libvma-utils", "libvma-dev",
				"sockperf",
				"srptools",
				"mlnx-ethtool",
				"libsdp1", "libsdp-dev",
				"sdpnetstat",
);

my @basic_packages = (
				"ofed-scripts",
				"mlnx-ofed-kernel-utils", "$mlnX_ofed_kernel",
				"$iser",
				"$isert",
				"$srp",
				"$mlnx_sdp",
				"$mlnx_rds",
				"$mlnx_nfsrdma",
				"$mlnx_nvme",
				"$mlnx_rdma_rxe",
				"libibverbs1", "ibverbs-utils", "libibverbs-dev", "libibverbs1-dbg",
				"libmlx4-1", "libmlx4-dev", "libmlx4-1-dbg",
				"libmlx5-1", "libmlx5-dev", "libmlx5-1-dbg",
				"librxe-1", "librxe-dev", "librxe-1-dbg",
				"libibumad", "libibumad-static", "libibumad-devel",
				"ibacm", "ibacm-dev",
				"librdmacm1", "librdmacm-utils", "librdmacm-dev",
				"mstflint",
				"ibdump",
				"libibmad", "libibmad-static", "libibmad-devel",
				"opensm", "libopensm", "opensm-doc", "libopensm-devel",
				"infiniband-diags", "infiniband-diags-compat",
				"mft", "$kernel_mft",
				"srptools",
				"ibdump",
				"mlnx-ethtool",
);

my @hpc_packages = (
				@basic_packages,
				"libibcm1", "libibcm-dev",
				"ibacm", "ibacm-dev",
				"perftest",
				"ibutils2",
				"ibutils", "libibdm1",
				"cc-mgr",
				"ar-mgr",
				"dump-pr",
				"ibsim", "ibsim-doc",
				"mxm",
				"ucx",
				"sharp",
				"fca",
				"hcoll",
				"openmpi",
				"openshmem",
				"mpitests",
				"knem", "$knem",
				"ummunotify", "$ummunotify",
				"rds-tools",
				"libdapl2", "dapl2-utils", "libdapl-dev",
);

my @vma_packages = (
				@basic_packages,
				"libibcm1", "libibcm-dev",
				"perftest",
				"ibutils2",
				"libibdm1", "ibutils",
				"cc-mgr",
				"ar-mgr",
				"dump-pr",
				"ibsim", "ibsim-doc",
				"libvma", "libvma-utils", "libvma-dev",
				"sockperf",
);

my @vmavpi_packages = (
				@basic_packages,
				"libibcm1", "libibcm-dev",
				"perftest",
				"ibutils2",
				"libibdm1", "ibutils",
				"cc-mgr",
				"ar-mgr",
				"dump-pr",
				"ibsim", "ibsim-doc",
				"libvma", "libvma-utils", "libvma-dev",
				"sockperf",
);

my @vmaeth_packages = (
				"ofed-scripts",
				"mlnx-ofed-kernel-utils", "$mlnX_ofed_kernel",
				"$iser",
				"$isert",
				"$srp",
				"$mlnx_sdp",
				"$mlnx_rds",
				"$mlnx_nfsrdma",
				"$mlnx_nvme",
				"$mlnx_rdma_rxe",
				"libibverbs1", "ibverbs-utils", "libibverbs-dev", "libibverbs1-dbg",
				"libmlx4-1", "libmlx4-dev", "libmlx4-1-dbg",
				"libmlx5-1", "libmlx5-dev", "libmlx5-1-dbg",
				"librxe-1", "librxe-dev", "librxe-1-dbg",
				"libibumad", "libibumad-static", "libibumad-devel",
				"ibacm", "ibacm-dev",
				"librdmacm1", "librdmacm-utils", "librdmacm-dev",
				"mstflint",
				"ibdump",
				"mft", "$kernel_mft",
				"libvma", "libvma-utils", "libvma-dev",
				"sockperf",
				"mlnx-ethtool",
);

my @guest_packages = (
				@basic_packages,
				"ibacm", "ibacm-dev",
				"perftest",
				"libdapl2", "dapl2-utils", "libdapl-dev",
				"rds-tools",
				"mxm",
				"ucx",
				"sharp",
				"fca",
				"hcoll",
				"openmpi",
				"openshmem",
				"mpitests",
				"knem", "$knem",
				"ummunotify", "$ummunotify",
);

my @hypervisor_packages = (
				@basic_packages,
				"ibacm", "ibacm-dev",
				"perftest",
				"libdapl2", "dapl2-utils", "libdapl-dev",
				"rds-tools",
				"fca",
				"ibutils2",
				"libibdm1", "ibutils",
);

my @eth_packages = (
				"$mlnx_en",
				"mlnx-en-utils",
				"mstflint",
);

my @dpdk_packages = (
				"ofed-scripts",
				"mlnx-ofed-kernel-utils", "$mlnX_ofed_kernel",
				"libibverbs1", "ibverbs-utils", "libibverbs-dev",
				"libmlx4-1", "libmlx4-dev",
				"libmlx5-1", "libmlx5-dev",
				"librdmacm1", "librdmacm-utils", "librdmacm-dev",
);

##
my %kernel_packages = ("$mlnX_ofed_kernel" => {'ko' => ["mlx4_ib", "mlx4_core"]},
			"$knem" => {'ko' => ["knem"]},
			"$kernel_mft" => {'ko' => ["mst_pci", "mst_pciconf"]},
			"$ummunotify" => {'ko' => ["ummunotify"]},
			"$iser" => {'ko' => ["ib_iser"]},
			"$isert" => {'ko' => ["ib_isert"]},
			"$srp" => {'ko' => ["ib_srp"]},
			"$mlnx_sdp" => {'ko' => ["ib_sdp"]},
			"$mlnx_rds" => {'ko' => ["rds"]},
			"$mlnx_nfsrdma" => {'ko' => ["rpcrdma"]},
			"$mlnx_nvme" => {'ko' => ["nvme_rdma"]},
			"$mlnx_rdma_rxe" => {'ko' => ["rdma_rxe"]},
			);

## set OS, arch
# don't auto-detect distro if it's provided by the user.
if (not -x "/usr/bin/lsb_release") {
	print "lsb_release is required to continue\n";
	$distro = "unsupported";
}
if ($distro eq "") {
	print "Distro was not provided, trying to auto-detect the current distro...\n" if ($verbose2);
	my $dist_os  = `lsb_release -s -i | tr '[:upper:]' '[:lower:]'`;
	chomp $dist_os;
	my $dist_ver = `lsb_release -s -r`;
	chomp $dist_ver;
	$distro = "$dist_os$dist_ver";
	print "Auto-detected $distro distro.\n" if ($verbose2);
} else {
	$distro = lc($distro);
	print "Using provided distro: $distro\n" if ($verbose2);
}
chomp $distro;
##

if ($distro =~ m/unsupported/ or ($distro !~ m/ubuntu/ and $distro !~ m/debian/)) {
	print_red("Current operation system is not supported!");
	exit 1;
}

my $DEBS  = "$CWD/DEBS/$distro/$arch";
chomp $DEBS;
if (not -d $DEBS) {
	mkpath([$DEBS]);
}

# OS specific package names
my $module_tools = "kmod";
my $libssl = "libssl1.0.0";
my $libssl_devel = "libssl-dev";
if ( $distro =~ /debian6|ubuntu1[0-2]/) {
	$module_tools = "module-init-tools";
}
if ( $distro =~ /debian6\.0/) {
	$libssl = "libssl0.9.8";
}

###############

# define kernel modules
my @basic_kernel_modules = ("core", "mthca", "mlx4", "mlx4_en", "mlx4_vnic", "mlx4_fc", "mlx5", "ipoib");
my @ulp_modules = ("sdp", "srp", "srpt", "rds", "iser", "e_ipoib", "nfsrdma", 'isert');
my @kernel_modules = (@basic_kernel_modules, @ulp_modules);
my @hpc_kernel_modules = (@basic_kernel_modules);
my @vma_kernel_modules = (@basic_kernel_modules);
my @dpdk_kernel_modules = (@basic_kernel_modules);
my @hypervisor_kernel_modules = ("core","mlx4","mlx4_en","mlx4_vnic","mlx5","ipoib","srp","iser", 'isert');
my @guest_kernel_modules = ("core","mlx4","mlx5","mlx4_en","ipoib","srp","iser", 'isert');
my @eth_kernel_modules = ("core", "mlx4", "mlx4_en", "mlx5");

# which modules are required for the standalone module rpms
my %standalone_kernel_modules_info = (
		"$iser" => ["core", "ipoib"],
		"$isert" => ["core", "ipoib"],
		"$srp" => ["core", "ipoib"],
		"$mlnx_sdp" => ["core"],
		"$mlnx_rds" => ["core"],
		"$mlnx_nfsrdma" => ["core"],
		"$mlnx_nvme" => ["core"],
		"$mlnx_rdma_rxe" => ["core"],
);

my %kernel_modules_info = (
			'core' =>
			{ name => "core", available => 1, selected => 0,
			included_in_rpm => 0, requires => [], },
			'mthca' =>
			{ name => "mthca", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core"], },
			'mlx4' =>
			{ name => "mlx4", available => 1, selected => 0,
			included_in_rpm => 0, requires => ["core"], },
			'mlx5' =>
			{ name => "mlx5", available => 1, selected => 0,
			included_in_rpm => 0, requires => ["core"], },
			'mlx4_en' =>
			{ name => "mlx4_en", available => 1, selected => 0,
			included_in_rpm => 0, requires => ["core","mlx4"], },
			'mlx4_vnic' =>
			{ name => "mlx4_vnic", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core","mlx4"], },
			'mlx4_fc' =>
			{ name => "mlx4_fc", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core","mlx4_en"], },
			'ipoib' =>
			{ name => "ipoib", available => 1, selected => 0,
			included_in_rpm => 0, requires => ["core"], },
			'sdp' =>
			{ name => "sdp", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core", "ipoib"], },
			'srp' =>
			{ name => "srp", available => 1, selected => 0,
			included_in_rpm => 0, requires => ["core", "ipoib"], },
			'srpt' =>
			{ name => "srpt", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core"], },
			'rds' =>
			{ name => "rds", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core", "ipoib"], },
			'e_ipoib' =>
			{ name => "e_ipoib", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core", "ipoib"], },
			'iser' =>
			{ name => "iser", available => 1, selected => 0,
			included_in_rpm => 0, requires => ["core", "ipoib"], ofa_req_inst => [] },
			'isert' =>
			{ name => "isert", available => 0, selected => 0,
			included_in_rpm => 0, requires => ["core", "ipoib"], ofa_req_inst => [] },
			'nfsrdma' =>
			{ name => "nfsrdma", available => 1, selected => 0,
			included_in_rpm => 0, requires => ["core", "ipoib"], },
);

# define packages
my %packages_info = (
			'ar-mgr' =>
				{ name => "ar-mgr", parent => "ar-mgr",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libstdc++6"],
				dist_req_inst => ["libstdc++6"],
				ofa_req_build => ["libopensm", "libopensm-devel", "ibutils2"],
				ofa_req_inst => ["opensm", "ibutils2"],
				configure_options => '' },
			'cc-mgr' =>
				{ name => "cc-mgr", parent => "cc-mgr",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libstdc++6"],
				dist_req_inst => ["libstdc++6"],
				ofa_req_build => ["libopensm", "libopensm-devel", "ibutils2"],
				ofa_req_inst => ["opensm", "ibutils2"],
				configure_options => '' },
			'dump-pr' =>
				{ name => "dump-pr", parent => "dump-pr",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libstdc++6"],
				dist_req_inst => ["libstdc++6"],
				ofa_req_build => ["libopensm", "libopensm-devel"],
				ofa_req_inst => ["opensm"],
				configure_options => '' },
			'fca' =>
				{ name => "fca", parent => "fca",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["gcc", "libstdc++6", "libcurl4-gnutls-dev"],
				dist_req_inst => ["curl"],
				ofa_req_build => ["librdmacm-dev", "libibverbs-dev", "libibmad-devel", "libibumad-devel", "libopensm-devel", "infiniband-diags-compat"],
				ofa_req_inst => ["librdmacm1", "infiniband-diags-compat", "mlnx-ofed-kernel-utils"],
				configure_options => '' },
			'ibacm-dev' =>
				{ name => "ibacm-dev", parent => "ibacm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "libibumad-devel", "$mlnX_ofed_kernel"],
				ofa_req_inst => ["ibacm"],
				configure_options => '' },
			'ibacm' =>
				{ name => "ibacm", parent => "ibacm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "libibumad-devel", "$mlnX_ofed_kernel"],
				ofa_req_inst => ["libibverbs1", "libibumad"],
				configure_options => '' },
			'ibsim-doc' =>
				{ name => "ibsim-doc", parent => "ibsim",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibmad-devel", "libibumad-devel"],
				ofa_req_inst => ["libibmad", "libibumad"],
				configure_options => '' },
			'ibsim' =>
				{ name => "ibsim", parent => "ibsim",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibmad-devel", "libibumad-devel"],
				ofa_req_inst => ["libibmad", "libibumad"],
				configure_options => '' },
			'ibutils2' =>
				{ name => "ibutils2", parent => "ibutils2",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["tcl-dev", "tk-dev", "libstdc++6"],
				dist_req_inst => ["tcl", "tk", "libstdc++6"],
				ofa_req_build => ["libibumad-devel"],
				ofa_req_inst => ["libibumad"],
				configure_options => '' },
			'ibutils' =>
				{ name => "ibutils", parent => "ibutils",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["tcl-dev", "tk-dev", "libstdc++6"],
				dist_req_inst => ["tcl", "tk", "libstdc++6"],
				ofa_req_build => ["libopensm", "libopensm-devel", "libibumad-devel", "libibverbs-dev"],
				ofa_req_inst => ["libibdm1", "libibumad", "libopensm"],
				configure_options => '' },
			'libibdm1' =>
				{ name => "libibdm1", parent => "ibutils",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["tk", "tk-dev", "libstdc++6"],
				dist_req_inst => ["tk", "libstdc++6"],
				ofa_req_build => ["libopensm", "libopensm-devel", "libibumad-devel", "libibverbs-dev"],
				ofa_req_inst => ["libibumad", "libopensm"],
				configure_options => '' },
			'infiniband-diags' =>
				{ name => "infiniband-diags", parent => "infiniband-diags",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libglib2.0-dev"],
				dist_req_inst => ["libglib2.0-0"],
				ofa_req_build => ["libopensm", "libopensm-devel", "libibumad-devel", "libibmad-devel"],
				ofa_req_inst => ["libibumad", "libopensm", "libibmad"],
				configure_options => '' },
			'infiniband-diags-compat' =>
				{ name => "infiniband-diags-compat", parent => "infiniband-diags",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libglib2.0-dev"],
				dist_req_inst => ["libglib2.0-0"],
				ofa_req_build => ["libopensm", "libopensm-devel", "libibumad-devel", "libibmad-devel"],
				ofa_req_inst => ["infiniband-diags", "libibumad", "libopensm", "libibmad"],
				configure_options => '' },
			'infiniband-diags-guest' =>
				{ name => "infiniband-diags-guest", parent => "infiniband-diags",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => ["libglib2.0-dev"],
				dist_req_inst => ["libglib2.0-0"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'kernel-mft-dkms' =>
				{ name => "kernel-mft-dkms", parent => "kernel-mft",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'kernel-mft' =>
				{ name => "kernel-mft", parent => "kernel-mft",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'kernel-mft-modules' =>
				{ name => "kernel-mft-modules", parent => "kernel-mft",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'knem-dkms' =>
				{ name => "knem-dkms", parent => "knem",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make", "pkg-config"],
				dist_req_inst => ["dkms", "gcc", "make", "pkg-config"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'knem-modules' =>
				{ name => "knem-modules", parent => "knem",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make", "pkg-config"],
				dist_req_inst => ["gcc", "make", "pkg-config"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'knem' =>
				{ name => "knem", parent => "knem",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make", "pkg-config"],
				dist_req_inst => ["gcc", "make", "pkg-config"],
				ofa_req_build => [],
				ofa_req_inst => ["knem-dkms"],
				configure_options => '' },
			'dapl' =>
				{ name => "dapl", parent => "dapl",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm-dev", "libibverbs-dev", "fca"],
				ofa_req_inst => ["libibverbs1", "librdmacm1", "fca"],
				soft_req => ["fca"],
				configure_options => '' },
			'dapl2-utils' =>
				{ name => "dapl2-utils", parent => "dapl",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm-dev", "libibverbs-dev", "fca"],
				ofa_req_inst => ["libibverbs1", "fca", "librdmacm1"],
				soft_req => ["fca"],
				configure_options => '' },
			'libdapl-dev' =>
				{ name => "libdapl-dev", parent => "dapl",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm-dev", "libibverbs-dev", "fca"],
				ofa_req_inst => ["libdapl2", "fca", "librdmacm1"],
				soft_req => ["fca"],
				configure_options => '' },
			'libdapl2' =>
				{ name => "libdapl2", parent => "dapl",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm-dev", "libibverbs-dev", "fca"],
				ofa_req_inst => ["libibverbs1", "fca", "librdmacm1"],
				soft_req => ["fca"],
				configure_options => '' },
			'libibcm' =>
				{ name => "libibcm", parent => "libibcm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libibcm1"],
				configure_options => '' },
			'libibcm-dev' =>
				{ name => "libibcm-dev", parent => "libibcm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libibcm1"],
				configure_options => '' },
			'libibcm1' =>
				{ name => "libibcm1", parent => "libibcm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'libibmad-devel' =>
				{ name => "libibmad-devel", parent => "libibmad",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibumad-devel"],
				ofa_req_inst => ["libibmad"],
				configure_options => '' },
			'libibmad-static' =>
				{ name => "libibmad-static", parent => "libibmad",
				selselected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibumad-devel"],
				ofa_req_inst => ["libibmad"],
				configure_options => '' },
			'libibmad' =>
				{ name => "libibmad", parent => "libibmad",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libtool"],
				dist_req_inst => [],
				ofa_req_build => ["libibumad-devel"],
				ofa_req_inst => ["libibumad"],
				configure_options => '' },
			'libibumad-devel' =>
				{ name => "libibumad-devel", parent => "libibumad",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libtool"],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => ["libibumad"],
				configure_options => '' },
			'libibumad-static' =>
				{ name => "libibumad-static", parent => "libibumad",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libtool"],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => ["libibumad"],
				configure_options => '' },
			'libibumad' =>
				{ name => "libibumad", parent => "libibumad",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libtool"],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'libibverbs' =>
				{ name => "libibverbs", parent => "libibverbs",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => ["gcc", "libglib2.0-dev"],
				dist_req_inst => ["libglib2.0-0"],
				ofa_req_build => [],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'ibverbs-utils' =>
				{ name => "ibverbs-utils", parent => "libibverbs",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["gcc", "libglib2.0-dev"],
				dist_req_inst => ["libglib2.0-0"],
				ofa_req_build => [],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'libibverbs-dev' =>
				{ name => "libibverbs-dev", parent => "libibverbs",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["gcc", "libglib2.0-dev"],
				dist_req_inst => ["libglib2.0-0"],
				ofa_req_build => [],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'libibverbs1-dbg' =>
				{ name => "libibverbs1-dbg", parent => "libibverbs",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["gcc", "libglib2.0-dev"],
				dist_req_inst => ["libglib2.0-0"],
				ofa_req_build => [],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'libibverbs1' =>
				{ name => "libibverbs1", parent => "libibverbs",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["gcc", "libglib2.0-dev", "pkg-config"],
				dist_req_inst => ["libglib2.0-0", "pkg-config"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'libmlx4' =>
				{ name => "libmlx4", parent => "libmlx4",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => [],
				configure_options => '' },
			'libmlx4-1' =>
				{ name => "libmlx4-1", parent => "libmlx4",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'libmlx4-dev' =>
				{ name => "libmlx4-dev", parent => "libmlx4",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libmlx4-1"],
				configure_options => '' },
			'libmlx4-1-dbg' =>
				{ name => "libmlx4-1-dbg", parent => "libmlx4",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libmlx4-1"],
				configure_options => '' },
			'libmlx5' =>
				{ name => "libmlx5", parent => "libmlx5",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => ["libnuma-dev"],
				dist_req_inst => ["libnuma1"],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => [],
				configure_options => '' },
			'libmlx5-1-dbg' =>
				{ name => "libmlx5-1-dbg", parent => "libmlx5",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libnuma-dev"],
				dist_req_inst => ["libnuma1"],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libmlx5-1"],
				configure_options => '' },
			'libmlx5-1' =>
				{ name => "libmlx5-1", parent => "libmlx5",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libnuma-dev"],
				dist_req_inst => ["libnuma1"],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'libmlx5-dev' =>
				{ name => "libmlx5-dev", parent => "libmlx5",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libnuma-dev"],
				dist_req_inst => ["libnuma1"],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libmlx5-1"],
				configure_options => '' },

			'librxe' =>
				{ name => "librxe", parent => "librxe",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "$mlnX_ofed_kernel"],
				ofa_req_inst => [],
				configure_options => '' },
			'librxe-1' =>
				{ name => "librxe-1", parent => "librxe",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "$mlnX_ofed_kernel"],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'librxe-dev' =>
				{ name => "librxe-dev", parent => "librxe",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "$mlnX_ofed_kernel"],
				ofa_req_inst => ["librxe-1"],
				configure_options => '' },
			'librxe-1-dbg' =>
				{ name => "librxe-1-dbg", parent => "librxe",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "$mlnX_ofed_kernel"],
				ofa_req_inst => ["librxe-1"],
				configure_options => '' },

			'librdmacm' =>
				{ name => "librdmacm", parent => "librdmacm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => [],
				configure_options => '' },
			'librdmacm-dev' =>
				{ name => "librdmacm-dev", parent => "librdmacm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["librdmacm1"],
				configure_options => '' },
			'librdmacm-utils' =>
				{ name => "librdmacm-utils", parent => "librdmacm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["librdmacm1"],
				configure_options => '' },
			'librdmacm1' =>
				{ name => "librdmacm1", parent => "librdmacm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev"],
				ofa_req_inst => ["libibverbs1"],
				configure_options => '' },
			'libvma' =>
				{ name => "libvma", parent => "libvma",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm1", "librdmacm-dev", "libibverbs1", "libibverbs-dev"],
				ofa_req_inst => ["librdmacm1", "libibverbs1"],
				configure_options => '' },
			'libvma-utils' =>
				{ name => "libvma-utils", parent => "libvma",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm1", "librdmacm-dev", "libibverbs1", "libibverbs-dev"],
				ofa_req_inst => ["librdmacm1", "libibverbs1", "libvma"],
				configure_options => '' },
			'libvma-dev' =>
				{ name => "libvma-dev", parent => "libvma",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm1", "librdmacm-dev", "libibverbs1", "libibverbs-dev"],
				ofa_req_inst => ["librdmacm1", "libibverbs1", "libvma"],
				configure_options => '' },

			'sockperf' =>
				{ name => "sockperf", parent => "sockperf",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["doxygen"],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },

			'mft' =>
				{ name => "mft", parent => "mft",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibmad-devel"],
				ofa_req_inst => ["libibmad"],
				configure_options => '' },
			'mlnx-ofed-kernel' =>
				{ name => "mlnx-ofed-kernel", parent => "mlnx-ofed-kernel",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["dkms", "quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["dkms", "quilt", "python-libxml2", "make", "gcc", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => ["$mlnX_ofed_kernel", "mlnx-ofed-kernel-utils"],
				ofa_req_inst => ["$mlnX_ofed_kernel", "mlnx-ofed-kernel-utils"],
				soft_req => ["ofed-scripts"],
				configure_options => '' },
			'mlnx-ofed-kernel-dkms' =>
				{ name => "mlnx-ofed-kernel-dkms", parent => "mlnx-ofed-kernel",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["dkms", "quilt", "python-libxml2", "make", "gcc", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => [],
				ofa_req_inst => ["ofed-scripts", "mlnx-ofed-kernel-utils"],
				soft_req => ["ofed-scripts"],
				configure_options => '' },
			'mlnx-ofed-kernel-modules' =>
				{ name => "mlnx-ofed-kernel-modules", parent => "mlnx-ofed-kernel",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["quilt", "python-libxml2", "make", "gcc", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => [],
				ofa_req_inst => ["ofed-scripts", "mlnx-ofed-kernel-utils"],
				soft_req => ["ofed-scripts"],
				configure_options => '' },
			'mlnx-ofed-kernel-utils' =>
				{ name => "mlnx-ofed-kernel-utils", parent => "mlnx-ofed-kernel",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["ethtool", "python-libxml2", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => [],
				ofa_req_inst => ["ofed-scripts"],
				soft_req => ["ofed-scripts"],
				configure_options => '' },

			# eth only
			'mlnx-en' =>
				{ name => "mlnx-en", parent => "mlnx-en",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["dkms", "quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["dkms", "quilt", "python-libxml2", "make", "gcc", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => ["$mlnx_en", "mlnx-en-utils"],
				ofa_req_inst => ["$mlnx_en", "mlnx-en-utils"],
				soft_req => ["ofed-scripts"],
				configure_options => '' },
			'mlnx-en-dkms' =>
				{ name => "mlnx-en-dkms", parent => "mlnx-en",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["dkms", "quilt", "python-libxml2", "make", "gcc", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => [],
				ofa_req_inst => ["mlnx-en-utils"],
				soft_req => ["ofed-scripts"],
				configure_options => '' },
			'mlnx-en-modules' =>
				{ name => "mlnx-en-modules", parent => "mlnx-en",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["quilt", "python-libxml2", "make", "gcc", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => [],
				ofa_req_inst => ["mlnx-en-utils"],
				soft_req => ["ofed-scripts"],
				configure_options => '' },
			'mlnx-en-utils' =>
				{ name => "mlnx-en-utils", parent => "mlnx-en",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["quilt", "python-libxml2", "make", "gcc"],
				dist_req_inst => ["quilt", "python-libxml2", "make", "gcc", "coreutils", "pciutils", "grep", "perl", "procps", "$module_tools", "lsof"],
				ofa_req_build => [],
				ofa_req_inst => ['ofed-scripts'],
				soft_req => ["ofed-scripts"],
				configure_options => '' },

			'mpitests' =>
				{ name => "mpitests", parent => "mpitests",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libgfortran3"],
				dist_req_inst => ["libgfortran3", "gfortran"],
				ofa_req_build => ["openmpi", "libibumad-devel", "librdmacm-dev", "libibmad-devel"],
				ofa_req_inst => ["openmpi", "libibumad", "librdmacm1", "libibmad"],
				configure_options => '' },
			'mstflint' =>
				{ name => "mstflint", parent => "mstflint",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'mxm' =>
				{ name => "mxm", parent => "mxm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libstdc++6", "pkg-config"],
				dist_req_inst => ["libstdc++6", "pkg-config"],
				ofa_req_build => ["libibverbs-dev","librdmacm-dev","libibmad-devel","libibumad-devel","$knem"],
				ofa_req_inst => ["libibumad", "libibverbs1", "$knem"],
				soft_req => ["$knem"],
				configure_options => '' },
			'ucx' =>
				{ name => "ucx", parent => "ucx",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libstdc++6", "pkg-config"],
				dist_req_inst => ["libstdc++6", "pkg-config"],
				ofa_req_build => ["libibverbs-dev", "libibcm-dev"],
				ofa_req_inst => ["libibverbs1", "libibcm1"],
				configure_options => '' },

			'ofed-scripts' =>
				{ name => "ofed-scripts", parent => "ofed-scripts",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'openmpi' =>
				{ name => "openmpi", parent => "openmpi",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["libstdc++6", "libgfortran3"],
				dist_req_inst => ["libstdc++6", "libgfortran3", "gfortran"],
				ofa_req_build => ["libibverbs-dev", "librdmacm-dev", "fca", "hcoll", "mxm", "ucx", "$knem", "libibmad-devel", "sharp"],
				ofa_req_inst => ["libibverbs1", "fca", "hcoll", "mxm", "ucx", "$knem", "libibmad", "sharp"],
				soft_req => ["fca", "hcoll", "mxm", "ucx", "$knem", "sharp"],
				configure_options => '' },
			'openshmem' =>
				{ name => "openshmem", parent => "openshmem",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["fca", "libopensm-devel", "$knem", "mxm", "libibmad-devel", "librdmacm-dev"],
				ofa_req_inst => ["fca", "libopensm", "$knem", "mxm", "libibmad", "librdmacm1", "libopensm"],
				configure_options => '' },
			'opensm' =>
				{ name => "opensm", parent => "opensm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["bison", "flex"],
				dist_req_inst => ["bison", "flex"],
				ofa_req_build => ["libopensm"],
				ofa_req_inst => ["libopensm"],
				configure_options => '' },
			'opensm-doc' =>
				{ name => "opensm-doc", parent => "opensm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["bison", "flex"],
				dist_req_inst => ["bison", "flex"],
				ofa_req_build => ["opensm"],
				ofa_req_inst => ["opensm"],
				configure_options => '' },
			'libopensm-devel' =>
				{ name => "libopensm-devel", parent => "opensm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["bison", "flex"],
				dist_req_inst => ["bison", "flex"],
				ofa_req_build => [],
				ofa_req_inst => ["opensm", "libopensm"],
				configure_options => '' },
			'libopensm' =>
				{ name => "libopensm", parent => "opensm",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["bison", "flex"],
				dist_req_inst => ["bison", "flex"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'perftest' =>
				{ name => "perftest", parent => "perftest",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "librdmacm-dev"],
				ofa_req_inst => ["libibverbs1", "librdmacm1"],
				configure_options => '' },
			'rds-tools' =>
				{ name => "rds-tools", parent => "rds-tools",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'ummunotify-dkms' =>
				{ name => "ummunotify-dkms", parent => "ummunotify",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'ummunotify-modules' =>
				{ name => "ummunotify-modules", parent => "ummunotify",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'ummunotify' =>
				{ name => "ummunotify", parent => "ummunotify",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "kernel",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'srptools' =>
				{ name => "srptools", parent => "srptools",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => ["librdmacm-dev", "libibverbs-dev", "libibumad-devel"],
				ofa_req_inst => ["librdmacm1", "libibumad", "libibverbs1"],
				configure_options => '' },

			'iser' =>
				{ name => "iser", parent => "iser",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'iser-dkms' =>
				{ name => "iser-dkms", parent => "iser",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'iser-modules' =>
				{ name => "iser-modules", parent => "iser",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'isert' =>
				{ name => "isert", parent => "isert",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'isert-dkms' =>
				{ name => "isert-dkms", parent => "isert",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'isert-modules' =>
				{ name => "isert-modules", parent => "isert",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'srp' =>
				{ name => "srp", parent => "srp",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'srp-dkms' =>
				{ name => "srp-dkms", parent => "srp",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'srp-modules' =>
				{ name => "srp-modules", parent => "srp",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'mlnx-sdp' =>
				{ name => "mlnx-sdp", parent => "mlnx-sdp",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'mlnx-sdp-dkms' =>
				{ name => "mlnx-sdp-dkms", parent => "mlnx-sdp",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'mlnx-sdp-modules' =>
				{ name => "mlnx-sdp-modules", parent => "mlnx-sdp",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'mlnx-rds' =>
				{ name => "mlnx-rds", parent => "mlnx-rds",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'mlnx-rds-dkms' =>
				{ name => "mlnx-rds-dkms", parent => "mlnx-rds",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'mlnx-rds-modules' =>
				{ name => "mlnx-rds-modules", parent => "mlnx-rds",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'mlnx-nfsrdma' =>
				{ name => "mlnx-nfsrdma", parent => "mlnx-nfsrdma",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'mlnx-nfsrdma-dkms' =>
				{ name => "mlnx-nfsrdma-dkms", parent => "mlnx-nfsrdma",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'mlnx-nfsrdma-modules' =>
				{ name => "mlnx-nfsrdma-modules", parent => "mlnx-nfsrdma",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'mlnx-nvme' =>
				{ name => "mlnx-nvme", parent => "mlnx-nvme",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'mlnx-nvme-dkms' =>
				{ name => "mlnx-nvme-dkms", parent => "mlnx-nvme",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'mlnx-nvme-modules' =>
				{ name => "mlnx-nvme-modules", parent => "mlnx-nvme",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'mlnx-rdma-rxe' =>
				{ name => "mlnx-rdma-rxe", parent => "mlnx-rdma-rxe",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 0, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => [],
				ofa_req_inst => [], configure_options => '' },
			'mlnx-rdma-rxe-dkms' =>
				{ name => "mlnx-rdma-rxe-dkms", parent => "mlnx-rdma-rxe",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["dkms", "gcc", "make"],
				dist_req_inst => ["dkms", "gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },
			'mlnx-rdma-rxe-modules' =>
				{ name => "mlnx-rdma-rxe-modules", parent => "mlnx-rdma-rxe",
				selected => 0, installed => 0, deb_exist => 0, deb_exist32 => 0,
				available => 1, mode => "kernel",
				dist_req_build => ["gcc", "make"],
				dist_req_inst => ["gcc", "make"],
				ofa_req_build => ["$mlnX_ofed_kernel"],
				ofa_req_inst => ["ofed-scripts","$mlnX_ofed_kernel","mlnx-ofed-kernel-utils"], configure_options => '' },

			'ibdump' =>
				{ name => "ibdump", parent => "ibdump",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => ["libstdc++6"],
				dist_req_inst => ["libstdc++6"],
				ofa_req_build => ["libibverbs-dev", "mstflint"],
				ofa_req_inst => ["libibverbs1", "mstflint"],
				configure_options => '' },

			'mlnx-ethtool' =>
				{ name => "mlnx-ethtool", parent => "mlnx-ethtool",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },

			'libsdp' =>
				{ name => "libsdp", parent => "libsdp",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'libsdp1' =>
				{ name => "libsdp1", parent => "libsdp",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => ["logrotate"],
				dist_req_inst => ["logrotate"],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },
			'libsdp-dev' =>
				{ name => "libsdp-dev", parent => "libsdp",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => ["logrotate"],
				dist_req_inst => ["logrotate"],
				ofa_req_build => [],
				ofa_req_inst => ["libsdp1"],
				configure_options => '' },

			'sdpnetstat' =>
				{ name => "sdpnetstat", parent => "sdpnetstat",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },

			# this package is listed here only for uninstall and --without.. flag support
			'mlnx-fw-updater' =>
				{ name => "mlnx-fw-updater", parent => "mlnx-fw-updater",
				selected => 0, installed => 0, deb_exist => 0,
				available => 0, mode => "user",
				dist_req_build => [],
				dist_req_inst => [],
				ofa_req_build => [],
				ofa_req_inst => [],
				configure_options => '' },

			'hcoll' =>
				{ name => "hcoll", parent => "hcoll",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["gcc", "libstdc++6", "$libssl_devel"],
				dist_req_inst => ["$libssl"],
				ofa_req_build => ["libibverbs-dev", "librdmacm-dev", "libibmad-devel", "libibumad-devel", "sharp", "libibcm-dev"],
				ofa_req_inst => ["libibverbs1", "librdmacm1", "libibmad", "sharp", "libibcm1"],
				configure_options => '',
				soft_req => ["sharp"] },
			'sharp' =>
				{ name => "sharp", parent => "sharp",
				selected => 0, installed => 0, deb_exist => 0,
				available => 1, mode => "user",
				dist_req_build => ["gcc", "libstdc++6"],
				dist_req_inst => [],
				ofa_req_build => ["libibverbs-dev", "libibumad-devel", "librdmacm-dev", "libibmad-devel", "ucx"],
				ofa_req_inst => ["libibverbs1", "libibumad", "librdmacm1", "libibmad", "ucx"],
				soft_req => ["ucx"],
				configure_options => '' },
);

###############


sub print_red
{
	print RED @_, RESET "\n";
}

sub print_green
{
	print GREEN @_, RESET "\n";
}

sub print_and_log
{
	my $msg = shift @_;
	print LOG $msg . "\n";
	print $msg . "\n" if ($verbose2);
}

sub getch
{
	my $c;
	system("stty -echo raw");
	$c=getc(STDIN);
	system("stty echo -raw");
	# Exit on Ctrl+c or Esc
	if ($c eq "\cC" or $c eq "\e") {
		print "\n";
		exit 1;
	}
	print "$c\n";
	return $c;
}

sub is_installed_deb
{
	my $name = shift @_;

	my $installed_deb = `$DPKG_QUERY -l $name 2> /dev/null | awk '/^[rhi][iU]/{print \$2}'`;
	return ($installed_deb) ? 1 : 0;
}

sub get_all_matching_installed_debs
{
	my $name = shift @_;

	my $installed_debs = `dpkg-query -l "*$name*" 2> /dev/null | awk '/^[rhi][iU]/{print \$2}'`;
	return (split "\n", $installed_debs);
}

sub mark_for_uninstall
{
	my $package = shift @_;

	return if ($package =~ /^xen|ovsvf-config/);
	if (not $selected_for_uninstall{$package}) {
		if (is_installed_deb $package) {
			print_and_log "$package will be removed.";
			push (@dependant_packages_to_uninstall, "$package");
			$selected_for_uninstall{$package} = 1;
			if (not (exists $packages_info{$package} or $package =~ /mlnx-ofed-/)) {
				$non_ofed_for_uninstall{$package} = 1;
			}
		}
	}
}

sub get_requires
{
	my $package = shift @_;

	chomp $package;

	if ($package eq "rdma") {
		# don't remove packages that needs rdma package
		return;
	}

	my @what_requires = `/usr/bin/dpkg --purge --dry-run $package 2>&1 | grep "depends on" 2> /dev/null`;

	for my $pack_req (@what_requires) {
		chomp $pack_req;
		$pack_req =~ s/\s*(.+) depends.*/$1/g;
		print_and_log "get_requires: $package is required by $pack_req\n";
		get_requires($pack_req);
		mark_for_uninstall($pack_req);
	}
}

sub is_configured_deb
{
	my $name = shift @_;

	my $installed_deb = `$DPKG_QUERY -l $name 2> /dev/null | awk '/^rc/{print \$2}'`;
	return ($installed_deb) ? 1 : 0;
}

sub ex
{
	my $cmd = shift @_;
	my $sig;
	my $res;

	print_and_log "Running: $cmd";
	system("$cmd >> $log 2>&1");
	$res = $? >> 8;
	$sig = $? & 127;
	if ($sig or $res) {
		print_red "Failed command: $cmd";
		exit 1;
	}
}

sub ex_deb_build
{
	my $name = shift @_;
	my $cmd = shift @_;
	my $sig;
	my $res;

	print "Running $cmd\n" if ($verbose);
	system("echo $cmd > $ofedlogs/$name.debbuild.log 2>&1");
	system("$cmd >> $ofedlogs/$name.debbuild.log 2>&1");
	$res = $? >> 8;
	$sig = $? & 127;
	if ($sig or $res) {
		print RED "Failed to build $name DEB", RESET "\n";
		addSetupInfo ("$ofedlogs/$name.debbuild.log");
		print RED "See $ofedlogs/$name.debbuild.log", RESET "\n";
		exit 1;
	}
}

sub ex_deb_install
{
	my $name = shift @_;
	my $cmd = shift @_;
	my $sig;
	my $res;

	return 0 if ($build_only);

	if (exists $package_pre_install_script{$name}) {
		print "Running $name pre install script: $package_pre_install_script{$name}\n" if ($verbose);
		ex1("$package_pre_install_script{$name}");
	}

	print "Running $cmd\n" if ($verbose);
	system("echo $cmd > $ofedlogs/$name.debinstall.log 2>&1");
	system("$cmd >> $ofedlogs/$name.debinstall.log 2>&1");
	$res = $? >> 8;
	$sig = $? & 127;
	if ($sig or $res) {
		print RED "Failed to install $name DEB", RESET "\n";
		addSetupInfo ("$ofedlogs/$name.debinstall.log");
		print RED "See $ofedlogs/$name.debinstall.log", RESET "\n";
		exit 1;
	}

	if (exists $package_post_install_script{$name}) {
		print "Running $name post install script: $package_post_install_script{$name}\n" if ($verbose);
		ex1("$package_post_install_script{$name}");
	}
}

sub check_linux_dependencies
{
	my $kernel_dev_missing = 0;
	my %missing_packages = ();

	if (! $check_linux_deps) {
		return 0;
	}

	print "Checking SW Requirements...\n" if (not $quiet);
	foreach my $req_name (@required_debs) {
		my $is_installed_flag = is_installed_deb($req_name);
		if (not $is_installed_flag) {
			print RED "$req_name deb is required", RESET "\n" if ($verbose2);
			$missing_packages{"$req_name"} = 1;
		}
	}

	foreach my $package (@selected_packages) {
		my $pname = $packages_info{$package}{'parent'};
	        for my $ver (keys %{$main_packages{$pname}}) {
			if ($package =~ /kernel|knem|ummunotify|mlnx-en/) {
				# kernel sources are required to build mlnx-ofed-kernel
				# require only if with_dkms=1 or (with_dkms=0 and deb is not built)
				if ( not -d "$kernel_sources/scripts" and
				     ($with_dkms or (not $with_dkms and not is_deb_available("$package")))) {
					print RED "$kernel_sources/scripts is required to build $package package.", RESET "\n" if ($verbose2);
					$missing_packages{"linux-headers-$kernel"} = 1;
					$kernel_dev_missing = 1;
				}
			}

			# Check rpmbuild requirements
			if (not $packages_info{$package}{$ver}{'deb_exist'}) {
				for my $req_name ( @{ $packages_info{$package}{'dist_req_build'} } ) {
					next if not $req_name;
					print "check_linux_dependencies: $req_name  is required to build $package $ver\n" if ($verbose3);
					my $is_installed_flag = is_installed_deb($req_name);
					if (not $is_installed_flag) {
						print RED "$req_name deb is required to build $package $ver", RESET "\n" if ($verbose2);
						$missing_packages{"$req_name"} = 1;
					}
				}
			}

			# Check installation requirements
			for my $req_name ( @{ $packages_info{$package}{'dist_req_inst'} } ) {
				next if not $req_name;
				my $is_installed_flag = is_installed_deb($req_name);
				if (not $is_installed_flag) {
					print RED "$req_name deb is required to install $package $ver", RESET "\n" if ($verbose2);
					$missing_packages{"$req_name"} = 1;
				}
			}
		}
	}

	# display a summary of missing packages
	if (keys %missing_packages) {
		print RED "One or more required packages for installing OFED-internal are missing.", RESET "\n";
		if ($kernel_dev_missing) {
			print RED "$kernel_sources/scripts is required for the Installation.", RESET "\n";
		}
		if ($check_deps_only) {
			print "Run:\napt-get install " . join(' ', (keys %missing_packages)) . "\n";
			exit $PREREQUISIT;
		} else {
			print RED "Attempting to install the following missing packages:\n" . join(' ', (keys %missing_packages)), RESET "\n";
			my $cmd = "apt-get install -y " . join(' ', (keys %missing_packages));
			print_and_log "Running: apt-get update";
			system("apt-get update >> $log 2>&1");
			ex "$cmd";
		}
	}

	exit 0 if ($check_deps_only);
}

sub get_module_list_from_dkmsConf
{
	my $conf = shift;

	my @modules = ();
	open(IN, "$conf") or print_red "Error: cannot open file: $conf";
	while(<IN>) {
		my $mod = $_;
		chomp $mod;
		if ($mod =~ /BUILT_MODULE_NAME/) {
			$mod =~ s/BUILT_MODULE_NAME\[[0-9]*\]=//g;
			$mod =~ s@^ib_@@g;
			if ($mod =~ /eth_ipoib/) {
				$mod =~ s/eth_ipoib/e_ipoib/g;
			}
			push(@modules, $mod);
		}
	}
	close(IN);
	return @modules;
}

sub is_module_in_deb
{
	my $name = shift;
	my $module = shift;

	my $ret = 0;
	my $deb = "";

	if ($name =~ /mlnx-ofed-kernel/) {
		($deb) = glob ("$DEBS/$mlnX_ofed_kernel*.deb");
	} elsif ($name =~ /mlnx-en/) {
		($deb) = glob ("$DEBS/$mlnx_en*.deb");
	} else {
		($deb) = glob ("$DEBS/$name*.deb");
	}

	if ($deb) {
		if ($module =~ /srp|iser|sdp|rds|nfsrdma|mlnx-nvme|mlnx-rdma-rxe/) {
			return 1;
		}
		rmtree "$builddir/$name\_module-check";
		mkpath "$builddir/$name\_module-check";
		ex "$DPKG_DEB -x $deb $builddir/$name\_module-check 2>/dev/null";
		if (basename($deb) =~ /dkms/) {
			my $conf = `find $builddir/$name\_module-check -name dkms.conf 2>/dev/null | grep -vE "drivers/|net/"`;
			chomp $conf;
			if (grep( /^$module.*$/, get_module_list_from_dkmsConf($conf))) {
				print_and_log "is_module_in_deb: $module is in $deb";
				$ret = 1;
			} else {
				print_and_log "is_module_in_deb: $module is NOT in $deb";
				$ret = 0;
			}
		} else {
			my $modpath = `find $builddir/$name\_module-check -name ${module}.ko 2>/dev/null`;
			chomp $modpath;
			if ($modpath ne "") {
				print_and_log "is_module_in_deb: $module is in $deb";
				$ret = 1;
			} else {
				print_and_log "is_module_in_deb: $module is NOT in $deb";
				$ret = 0;
			}
		}
		rmtree "$builddir/$name\_module-check";
	} else {
		print_and_log "deb file was not found for pacakge: $name";
	}

	return $ret;
}

#
# print usage message
#
sub usage
{
   print GREEN;
   print "\n";
   print "Usage: $0 [-c <packages config_file>|--all|--hpc|--vma|--basic] [OPTIONS]\n";

   print "\n";
   print "Installation control:\n";
   print "    --force              Force installation\n";
   print "    --tmpdir             Change tmp directory. Default: $TMPDIR\n";
   print "    -k|--kernel <version>      Default on this system: $kernel (relevant if --without-dkms is given)\n";
   print "    -s|--kernel-sources <path> Default on this system: $kernel_sources (relevant if --without-dkms is given)\n";
   print "    -b|--build-only      Build binary DEBs without installing them (relevant if --without-dkms is given)\n";
   print "    --distro             Set Distro name for the running OS (e.g: ubuntu14.04). Default: Use auto-detection.\n";
   print "    --without-depcheck   Skip Distro's libraries check\n";
   print "    --check-deps-only    Check Linux dependencies and exit.\n";
   print "    --force-dkms         Force installing kernel packages with DKMS support\n";
   print "    --without-dkms       Don't install kernel packages with DKMS support\n";
   print "    --builddir           Change build directory. Default: $builddir\n";
   print "    --umad-dev-rw        Grant non root users read/write permission for umad devices instead of default\n";
   print "    --umad-dev-na        Prevent from non root users read/write access for umad devices. Overrides '--umad-dev-rw'\n";
   print "    -n|--net <network config_file>      Example of the config file can be found under docs (ofed_net.conf-example)\n";
   print "    --enable-mlnx_tune         Enable Running the mlnx_tune utility\n";
   print "\n";
   print "    --package-install-options                      DPKG install options to use when installing DEB packages (comma separated list)\n";
   print "    --pre-build-<package>    <path to script>      Run given script before given package's build\n";
   print "    --post-build-<package>   <path to script>      Run given script after given package's build\n";
   print "    --pre-install-<package>  <path to script>      Run given script before given package's install\n";
   print "    --post-install-<package> <path to script>      Run given script after given package's install\n";
   print "\n";
   print "Package selection:\n";
   print "    -c|--config <packages config_file>      Example of the config file can be found under docs (ofed.conf-example)\n";
if (not $install_option eq 'eth-only') {
   print "\n";
   print "    --all                Install all available packages\n";
   print "    --hpc                Install minimum packages required for HPC\n";
   print "    --basic              Install minimum packages for basic functionality\n";
} else {
   print "    --eth-only           Install Ethernet drivers only\n";
}
   print "    --dpdk               Install minimum packages required for DPDK\n";
   print "    --with-vma           Enable installing and configuring VMA package (to be used with any of the above installation options)\n";
   print "    --vma|--vma-vpi      Install minimum packages required by VMA to support VPI\n";
   print "    --vma-eth            Install minimum packages required by VMA to work over Ethernet\n";
if (not $install_option eq 'eth-only') {
   print "    --guest              Install minimum packages required by guest OS\n";
   print "    --hypervisor         Install minimum packages required by hypervisor OS\n";
}
   print "Extra package filtering:\n";
if (not $install_option eq 'eth-only') {
   print "    --kernel-only        Install kernel space packages only\n";
   print "    --user-space-only    Filter selected packages and install only User Space packages\n";
}
   print "    --without-<package>  Do not install package\n";
   print "    --with-<package>     Force installing package\n";
   print "    --with-memtrack      Build ofa_kernel RPM with memory tracking enabled for debugging\n";
   print "\n";
   print "Miscellaneous:\n";
   print "    -h|--help            Display this help message and exit\n";
   print "    -p|--print-available Print available packages for current platform\n";
   print "                         And create corresponding ofed.conf file\n";
   print "    --conf-dir           Destination directory to save the configuration file. Default: $CWD\n";
   print "\n";
   print "Output control:\n";
   print "    -v|-vv|-vvv          Set verbosity level\n";
   print "    -q                   Set quiet - no messages will be printed\n";
   print RESET "\n\n";
}

sub count_ports
{
	my $cnt = 0;
	open(LSPCI, "/usr/bin/lspci -n|");

	while (<LSPCI>) {
		if (/15b3:6282/) {
			$cnt += 2;  # infinihost iii ex mode
		}
		elsif (/15b3:5e8c|15b3:6274/) {
			$cnt ++;    # infinihost iii lx mode
		}
		elsif (/15b3:5a44|15b3:6278/) {
			$cnt += 2;  # infinihost mode
		}
		elsif (/15b3:6340|15b3:634a|15b3:6354|15b3:6732|15b3:673c|15b3:6746|15b3:6750|15b3:1003/) {
			$cnt += 2;  # connectx
		}
	}
	close (LSPCI);

	return $cnt;
}

# removes the settings for a given interface from /etc/network/interfaces
sub remove_interface_settings
{
	my $interface = shift @_;

	open(IFCONF, $ifconf) or die "Can't open $ifconf: $!";
	my @ifconf_lines;
	while (<IFCONF>) {
		push @ifconf_lines, $_;
	}
	close(IFCONF);

	open(IFCONF, ">$ifconf") or die "Can't open $ifconf: $!";
	my $remove = 0;
	foreach my $line (@ifconf_lines) {
		chomp $line;
		if ($line =~ /(iface|mapping|auto|allow-|source) $interface/) {
			$remove = 1;
		}
		if ($remove and $line =~ /(iface|mapping|auto|allow-|source)/ and $line !~ /$interface/) {
			$remove = 0;
		}
		next if ($remove);
		print IFCONF "$line\n";
	}
	close(IFCONF);
}

sub get_net_config
{
	my $interface = shift @_;

	open(IFCONFIG, "/sbin/ifconfig $interface |") or die "Failed to run /sbin/ifconfig $interface: $!";
	while (<IFCONFIG>) {
	next if (not m/inet addr:/);
		my $line = $_;
		chomp $line;
		$ifcfg{$interface}{'IPADDR'} = (split (' ', $line))[1];
		$ifcfg{$interface}{'IPADDR'} =~ s/addr://g;
		$ifcfg{$interface}{'BROADCAST'} = (split (' ', $line))[2];
		$ifcfg{$interface}{'BROADCAST'} =~ s/Bcast://g;
		$ifcfg{$interface}{'NETMASK'} = (split (' ', $line))[3];
		$ifcfg{$interface}{'NETMASK'} =~ s/Mask://g;
	}
	close(IFCONFIG);
}

sub is_carrier
{
	my $ifcheck = shift @_;
	open(IFSTATUS, "ip link show dev $ifcheck |");
	while ( <IFSTATUS> ) {
		next unless m@(\s$ifcheck).*@;
		if( m/NO-CARRIER/ or not m/UP/ ) {
			close(IFSTATUS);
			return 0;
		}
	}
	close(IFSTATUS);
	return 1;
}

sub config_interface
{
	my $interface = shift @_;
	my $ans;
	my $dev = "ib$interface";
	my $ret;
	my $ip;
	my $nm;
	my $nw;
	my $bc;
	my $onboot = 1;
	my $found_eth_up = 0;
	my $eth_dev;

	if (not $config_net_given) {
		return;
	}
	print "Going to update $dev in $ifconf\n" if ($verbose2);
	if ($ifcfg{$dev}{'LAN_INTERFACE'}) {
		$eth_dev = $ifcfg{$dev}{'LAN_INTERFACE'};
		if (not -e "/sys/class/net/$eth_dev") {
			print "Device $eth_dev is not present\n" if (not $quiet);
			return;
		}
		if ( is_carrier ($eth_dev) ) {
			$found_eth_up = 1;
		}
	}
	else {
		# Take the first existing Eth interface
		my @eth_devs = </sys/class/net/eth*>;
		for my $tmp_dev ( @eth_devs ) {
			$eth_dev = $tmp_dev;
			$eth_dev =~ s@/sys/class/net/@@g;
			if ( is_carrier ($eth_dev) ) {
				$found_eth_up = 1;
				last;
			}
		}
	}

	if ($found_eth_up) {
		get_net_config("$eth_dev");
	}

	if (not $ifcfg{$dev}{'IPADDR'}) {
		print "IP address is not defined for $dev\n" if ($verbose2);
		print "Skipping $dev configuration...\n" if ($verbose2);
		return;
	}
	if (not $ifcfg{$dev}{'NETMASK'}) {
		print "Netmask is not defined for $dev\n" if ($verbose2);
		print "Skipping $dev configuration...\n" if ($verbose2);
		return;
	}
	if (not $ifcfg{$dev}{'NETWORK'}) {
		print "Network is not defined for $dev\n" if ($verbose2);
		print "Skipping $dev configuration...\n" if ($verbose2);
		return;
	}
	if (not $ifcfg{$dev}{'BROADCAST'}) {
		print "Broadcast address is not defined for $dev\n" if ($verbose2);
		print "Skipping $dev configuration...\n" if ($verbose2);
		return;
	}

	my @ipib = (split('\.', $ifcfg{$dev}{'IPADDR'}));
	my @nmib = (split('\.', $ifcfg{$dev}{'NETMASK'}));
	my @nwib = (split('\.', $ifcfg{$dev}{'NETWORK'}));
	my @bcib = (split('\.', $ifcfg{$dev}{'BROADCAST'}));

	my @ipeth = (split('\.', $ifcfg{$eth_dev}{'IPADDR'}));
	my @nmeth = (split('\.', $ifcfg{$eth_dev}{'NETMASK'}));
	my @nweth = (split('\.', $ifcfg{$eth_dev}{'NETWORK'}));
	my @bceth = (split('\.', $ifcfg{$eth_dev}{'BROADCAST'}));

	for (my $i = 0; $i < 4 ; $i ++) {
		if ($ipib[$i] =~ m/\*/) {
			if ($ipeth[$i] =~ m/(\d\d?\d?)/) {
				$ipib[$i] = $ipeth[$i];
			}
			else {
				print "Cannot determine the IP address of the $dev interface\n" if (not $quiet);
				return;
			}
		}
		if ($nmib[$i] =~ m/\*/) {
			if ($nmeth[$i] =~ m/(\d\d?\d?)/) {
				$nmib[$i] = $nmeth[$i];
			}
			else {
				print "Cannot determine the netmask of the $dev interface\n" if (not $quiet);
				return;
			}
		}
		if ($bcib[$i] =~ m/\*/) {
			if ($bceth[$i] =~ m/(\d\d?\d?)/) {
				$bcib[$i] = $bceth[$i];
			}
			else {
				print "Cannot determine the broadcast address of the $dev interface\n" if (not $quiet);
				return;
			}
		}
		if ($nwib[$i] !~ m/(\d\d?\d?)/) {
			$nwib[$i] = $nweth[$i];
		}
	}

	$ip = "$ipib[0].$ipib[1].$ipib[2].$ipib[3]";
	$nm = "$nmib[0].$nmib[1].$nmib[2].$nmib[3]";
	$nw = "$nwib[0].$nwib[1].$nwib[2].$nwib[3]";
	$bc = "$bcib[0].$bcib[1].$bcib[2].$bcib[3]";

	print GREEN "IPoIB configuration for $dev\n";
	if ($onboot) {
		print "auto $dev\n";
	}
	print "iface $dev inet static\n";
	print "address $ip\n";
	print "netmask $nm\n";
	print "network $nw\n";
	print "broadcast $bc\n";
	print RESET "\n";

	# Remove old interface's settings
	remove_interface_settings($dev);

	# append the new interface's settings to the interfaces file
	open(IF, ">>$ifconf") or die "Can't open $ifconf: $!";
	print IF "\n";
	if ($onboot) {
		print IF "auto $dev\n";
	}
	print IF "iface $dev inet static\n";
	print IF "\taddress $ip\n";
	print IF "\tnetmask $nm\n";
	print IF "\tnetwork $nw\n";
	print IF "\tbroadcast $bc\n";
	close(IF);
}

sub ipoib_config
{
	if (not $config_net_given) {
		return;
	}

	my $ports_num = count_ports();
	for (my $i = 0; $i < $ports_num; $i++ ) {
		config_interface($i);
	}
}

sub is_tarball_available
{
	my $name = shift;

	for my $ver (keys %{$main_packages{$name}}) {
		if ($main_packages{$name}{$ver}{'tarballpath'}) {
			return 1;
		}
	}

	return 0;
}

sub is_deb_available
{
	my $name = shift;
	for my $ver (keys %{$main_packages{$name}}) {
		if ($main_packages{$name}{$ver}{'debpath'}) {
			return 1;
		}
	}

	return 0;
}

# select packages to install
sub select_packages
{
	my $cnt = 0;
	if ($config_given) {
		open(CONFIG, "$config") || die "Can't open $config: $!";;
		while(<CONFIG>) {
			next if (m@^\s+$|^#.*@);
			my ($package,$selected) = (split '=', $_);
			chomp $package;
			chomp $selected;

			# fix kernel packages names
			# DKMS enabled
			if ($with_dkms) {
				if ($package =~ /-modules/) {
					$package =~ s/-modules/-dkms/g;;
				}
			} else {
			# DKMS disabled
				if ($package =~ /-dkms/) {
					$package =~ s/-dkms/-modules/g;;
				}
			}

			print "$package=$selected\n" if ($verbose2);

			if (not $packages_info{$package}{'parent'} or $package =~ /iser|srp$/) {
				my $modules = "@kernel_modules";
				chomp $modules;
				$modules =~ s/ /|/g;
				if ($package =~ m/$modules/) {
					if ( $selected eq 'y' ) {
						if (not $kernel_modules_info{$package}{'available'}) {
							print "$package is not available on this platform\n" if (not $quiet);
						}
						else {
							push (@selected_modules_by_user, $package);
						}
						next if ($package !~ /iser|srp/);
					}
				}
				else {
					print "Unsupported package: $package\n" if (not $quiet);
					next;
				}
			}

			if (not $packages_info{$package}{'available'} and $selected eq 'y') {
				print "$package is not available on this platform\n" if (not $quiet);
				next;
			}

			if ( $selected eq 'y' ) {
				my $parent = $packages_info{$package}{'parent'};
				if (not is_tarball_available($parent)) {
					print "Unsupported package: $package\n" if (not $quiet);
					next;
				}
				push (@selected_by_user, $package);
				print "select_package: selected $package\n" if ($verbose2);
				$cnt ++;
			}
		}
	}
	else {
		$config = $conf_dir . "/ofed-$install_option.conf";
		chomp $config;
		open(CONFIG, ">$config") || die "Can't open $config: $!";
		flock CONFIG, $LOCK_EXCLUSIVE;
		if ($install_option eq 'all') {
			for my $package ( @all_packages ) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option eq 'hpc') {
			for my $package ( @hpc_packages ) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @hpc_kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option =~ m/vma/) {
			my @list = ();
			if ($install_option eq 'vma') {
				@list = (@vma_packages);
			} elsif ($install_option eq 'vmavpi') {
				@list = (@vmavpi_packages);
			} elsif ($install_option eq 'vmaeth') {
				@list = (@vmaeth_packages);
			}
			for my $package ( @list ) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @vma_kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option eq 'basic') {
			for my $package (@basic_packages) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @basic_kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option eq 'hypervisor') {
			for my $package ( @hypervisor_packages ) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @hypervisor_kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option eq 'guest') {
			for my $package ( @guest_packages ) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @guest_kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option eq 'kernel-only') {
			for my $package ( @all_packages ) {
				next if (not $packages_info{$package}{'available'});
				next if (not $packages_info{$package}{'mode'} eq 'kernel');
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option eq 'eth-only') {
			for my $package (@eth_packages) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @eth_kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		elsif ($install_option =~ m/dpdk/) {
			for my $package ( @dpdk_packages ) {
				next if (not $packages_info{$package}{'available'});
				my $parent = $packages_info{$package}{'parent'};
				next if (not is_tarball_available($parent));
				push (@selected_by_user, $package);
				print CONFIG "$package=y\n";
				$cnt ++;
			}
			for my $module ( @dpdk_kernel_modules ) {
				next if (not $kernel_modules_info{$module}{'available'});
				push (@selected_modules_by_user, $module);
				print CONFIG "$module=y\n";
			}
		}
		else {
			print RED "\nUnsupported installation option: $install_option", RESET "\n" if (not $quiet);
			exit 1;
		}
	}

	flock CONFIG, $UNLOCK;
	close(CONFIG);

	return $cnt;
}

#
# install selected packages by the user (@selected_packages)
#
sub install_selected
{
	if ($build_only) {
		print "Installing new packages\n";
	} else {
		print "Building packages\n";
	}
	my $i = 0;

	chdir $CWD;
	foreach my $name (@selected_packages) {
		delete $ENV{"DEB_CONFIGURE_EXTRA_FLAGS"};
		delete $ENV{"configure_options"};
		delete $ENV{"PACKAGE_VERSION"};
		delete $ENV{"MPI_HOME"};
		delete $ENV{"KNEM_PATH"};
		delete $ENV{"DESTDIR"};
		delete $ENV{"libpath"};
		delete $ENV{"rdmascript"};
		delete $ENV{"CONFIG_ARGS"};
		delete $ENV{"WITH_DKMS"};
		delete $ENV{"kernelver"};
		delete $ENV{"kernel_source_dir"};
		delete $ENV{"KVER"};
		delete $ENV{"K_BUILD"};
		delete $ENV{"MLX4"};
		delete $ENV{"MLX5"};
		delete $ENV{"mellanox_autodetect"};
		$BUILD_ENV = '';

		my $parent = $packages_info{$name}{'parent'};
		my ($gz) = glob ("SOURCES/${parent}_*gz");
		my $version = $gz;
		$version =~ s/^SOURCES\/${parent}_//;
		$version =~ s/(.orig).*//;
		my @debs = glob ("$DEBS/${name}[-_]${version}*.deb");
		if ($name =~ /dapl/ or (not @debs and $name =~ /fca|mxm|ucx|openmpi|mpitests|openshmem/)) {
			# TODO: this is neeeded only because of the bad version number in changelog
			@debs = glob ("$DEBS/${name}[-_]*.deb");
		} elsif ($parent =~ /mlnx-ofed-kernel/) {
			if ($with_dkms) {
				@debs = glob ("$DEBS/${name}[-_]${version}*OFED*.deb");
			} else {
				@debs = glob ("$DEBS/${name}[-_]${version}-*.kver.${kernel}_*.deb");
				if (not @debs) {
					@debs = glob ("$DEBS/${name}[-_]${version}-${kernel}_*.deb");
				}
			}
		} elsif (not $with_dkms and $parent =~ /iser|srp$|knem|ummunotify|kernel-mft|mlnx-en|mlnx-sdp|mlnx-rds|mlnx-nfsrdma|mlnx-nvme|mlnx-rdma-rxe/) {
			@debs = glob ("$DEBS/${name}[-_]${version}-*.kver.${kernel}_*.deb");
			if (not @debs) {
				@debs = glob ("$DEBS/${name}[-_]${version}-${kernel}_*.deb");
			}
		}

		if (not $gz and not @debs) {
			print "Tarball for $parent and DEBs for $name are missing\n";
			next;
		}

		# check if selected modules are in the found deb file
		if (@debs and ($name =~ /$mlnX_ofed_kernel/)) {
			my $kernel_rpm = "$mlnX_ofed_kernel";
			my $pname = $packages_info{$kernel_rpm}{'parent'};
			for my $ver (keys %{$main_packages{$pname}}) {
				for my $module (@selected_kernel_modules) {
					if (not is_module_in_deb($kernel_rpm, "$module")) {
						@debs = ();
						last;
					}
				}
				if ($with_memtrack) {
					if (not is_module_in_deb($kernel_rpm, "memtrack")) {
						@debs = ();
						last;
					}
				}
			}
		}

		if (not @debs) {
			print "Building DEB for ${name}-${version} ($parent)...\n" if (not $quiet);
			# Build debs from source
			rmtree "$builddir/$parent";
			mkpath "$builddir/$parent";
			if ($parent =~ /mpitests/) {
				# MPI_HOME directory should be set to corresponding MPI before package build.
				my $openmpiVer = glob ("SOURCES/openmpi_*gz");
				$openmpiVer =~ s/^SOURCES\/openmpi_//;
				$openmpiVer =~ s/(.orig).*//;
				$ENV{"MPI_HOME"} = "/usr/mpi/gcc/openmpi-$openmpiVer";
				$ENV{"DESTDIR"} = "$builddir/$parent/$parent-$version";
			} elsif ($parent =~ /openmpi/) {
				my $config_args = "$packages_info{'openmpi'}{'configure_options'} ";
				my $openmpiVer = glob ("SOURCES/openmpi_*gz");
				$openmpiVer =~ s/^SOURCES\/openmpi_//;
				$openmpiVer =~ s/(.orig).*//;
				$config_args .= " --prefix=/usr/mpi/gcc/openmpi-$openmpiVer";
				$config_args .= " --with-platform=contrib/platform/mellanox/optimized";
				$ENV{"CONFIG_ARGS"} = "$config_args";
				# Let openmpi automatically find plugins and use them
				$ENV{"mellanox_autodetect"} = "yes";
				$BUILD_ENV .= " mellanox_autodetect='yes'";
			} elsif ($parent =~ /openshmem/) {
				my $knemVer = glob ("SOURCES/knem_*gz");
				$knemVer =~ s/^SOURCES\/knem_//;
				$knemVer =~ s/(.orig).*//;
				$ENV{"KNEM_PATH"} = "/opt/knem-$knemVer/";
			} elsif ($parent =~ /hcoll/) {
				my $config_args = "";
				$config_args .= " --with-sharp=/opt/mellanox/sharp" if (-d "/opt/mellanox/sharp");
				$ENV{"CONFIG_ARGS"} = "$config_args";
			} elsif ($parent =~ /mlnx-ofed-kernel/) {
				$kernel_configure_options = "";
				for my $module ( @selected_kernel_modules ) {
					if ($module eq "core") {
						$kernel_configure_options .= " --with-core-mod --with-user_mad-mod --with-user_access-mod --with-addr_trans-mod";
					}
					elsif ($module eq "ipath") {
						$kernel_configure_options .= " --with-ipath_inf-mod";
					}
					elsif ($module eq "qib") {
						$kernel_configure_options .= " --with-qib-mod";
					}
					elsif ($module eq "srpt") {
						$kernel_configure_options .= " --with-srp-target-mod";
					}
					else {
						$kernel_configure_options .= " --with-$module-mod";
					}
				}
				if ($with_memtrack) {
					$kernel_configure_options .= " --with-memtrack";
				}
				$ENV{"configure_options"} = $kernel_configure_options;
				$ENV{"PACKAGE_VERSION"} = "$version";
			} elsif ($parent eq "ibacm") {
				$ENV{"rdmascript"} = " openibd";
			} elsif ($parent eq "librdmacm") {
				$ENV{"DEB_CONFIGURE_EXTRA_FLAGS"} = " --with-ib_acm";
			} elsif ($parent eq "ibsim") {
				$ENV{"libpath"} = "/usr/lib";
			} elsif ($parent =~ /mlnx-en/) {
				$ENV{"MLX4"} = (grep( /^mlx4$/, @selected_kernel_modules )) ? "1" : "0";
				$ENV{"MLX5"} = (grep( /^mlx5$/, @selected_kernel_modules )) ? "1" : "0";
			} elsif ($parent =~ /mstflint/) {
				$ENV{"DEB_CONFIGURE_EXTRA_FLAGS"} = '--disable-inband';
			}

			if ($parent =~ /^lib/) {
				$BUILD_ENV = " DEB_CFLAGS_SET=\"-g -O3\" DEB_LDFLAGS_SET=\"-g -O3\" DEB_CPPFLAGS_SET=\"-g -O3\" DEB_CXXFLAGS_SET=\"-g -O3\" DEB_FFLAGS_SET=\"-g -O3\" DEB_LDLIBS_SET=\"-g -O3\"";
			}

			chdir  "$builddir/$parent";
			ex "cp $CWD/$gz .";
			ex "tar xzf $CWD/$gz";
			chdir "$parent-$version";

			if (not $with_dkms and $parent =~ /mlnx-ofed-kernel|iser|srp$|knem|ummunotify|kernel-mft|mlnx-en|mlnx-sdp|mlnx-rds|mlnx-nfsrdma|mlnx-nvme|mlnx-rdma-rxe/) {
				$ENV{"WITH_DKMS"} = "0";
				$ENV{"kernelver"} = "$kernel";
				$ENV{"kernel_source_dir"} = "$kernel_sources";
				$ENV{"KVER"} = "$kernel";
				$ENV{"K_BUILD"} = "$kernel_sources";
				ex "/bin/mv -f debian/control.no_dkms debian/control";
			}

			if (exists $package_pre_build_script{$name}) {
				print "Running $name pre build script: $package_pre_build_script{$name}\n" if ($verbose);
				ex1("$package_pre_build_script{$name}");
			}

			ex_deb_build($parent, "$BUILD_ENV $DPKG_BUILDPACKAGE -us -uc");
			ex "cp ../*.deb $DEBS";

			if (exists $package_post_build_script{$name}) {
				print "Running $name post build script: $package_post_build_script{$name}\n" if ($verbose);
				ex1("$package_post_build_script{$name}");
			}

			@debs = glob ("$DEBS/${name}[-_]${version}*.deb");
			if ($name =~ /dapl/ or (not @debs and $name =~ /fca|mxm|ucx|openmpi|mpitests|openshmem/)) {
				# TODO: this is neeeded only because of the bad version number in changelog
				@debs = glob ("$DEBS/${name}[-_]*.deb");
			} elsif ($parent =~ /mlnx-ofed-kernel/) {
				if ($with_dkms) {
					@debs = glob ("$DEBS/${name}[-_]${version}*OFED*.deb");
				} else {
					@debs = glob ("$DEBS/${name}[-_]${version}-*.kver.${kernel}_*.deb");
					if (not @debs) {
						@debs = glob ("$DEBS/${name}[-_]${version}-${kernel}_*.deb");
					}
				}
			} elsif (not $with_dkms and $parent =~ /iser|srp$|knem|ummunotify|kernel-mft|mlnx-en|mlnx-sdp|mlnx-rds|mlnx-nfsrdma|mlnx-nvme|mlnx-rdma-rxe/) {
				@debs = glob ("$DEBS/${name}[-_]${version}-*.kver.${kernel}_*.deb");
				if (not @debs) {
					@debs = glob ("$DEBS/${name}[-_]${version}-${kernel}_*.deb");
				}
			}
			chdir $CWD;
			rmtree "$builddir/$parent";

			if (not @debs) {
				print_red "Error: DEB for $name was not created !";
				exit 1;
			}
		}

		print "Installing ${name}-${version}...\n" if (not $quiet and not $build_only);
		if ($parent =~ /mlnx-ofed-kernel|libvma/) {
			$ENV{"PACKAGE_VERSION"} = "$version";
			ex_deb_install($name, "$DPKG -i --force-confnew $DPKG_FLAGS @debs");
		} else {
			ex_deb_install($name, "$DPKG -i $DPKG_FLAGS @debs");
		}

		if ($build_only and $name eq "mlnx-ofed-kernel-modules") {
			my $ofa_src = "$builddir/ofed_src";
			print "Extracting mlnx-ofed-kernel sources to $ofa_src ...\n";
			system("mkdir -p $ofa_src >/dev/null 2>&1");
			my ($kdeb) = glob ("$DEBS/mlnx-ofed-kernel-modules[-_]${version}-*.kver.${kernel}_*.deb");
			if (not -e "$kdeb") {
				($kdeb) = glob ("$DEBS/mlnx-ofed-kernel-modules[-_]${version}-${kernel}_*.deb");
			}
			print "dpkg -x $kdeb $ofa_src >/dev/null \n";
			system("dpkg -x $kdeb $ofa_src >/dev/null");
			$ENV{"OFA_DIR"} = "$ofa_src/usr/src/ofa_kernel";
		}

		# verify that kernel packages were successfuly installed
		if (not $build_only and exists $kernel_packages{"$name"}) {
			system("/sbin/depmod $kernel >/dev/null 2>&1");
			for my $object (@{$kernel_packages{"$name"}{"ko"}}) {
				my $file = `$MODINFO -k $kernel $object 2> /dev/null | grep filename | cut -d ":" -f 2 | sed -s 's/\\s//g'`;
				chomp $file;
				my $origin;
				if (-f $file) {
					$origin = `$DPKG -S $file 2> /dev/null | cut -d ":" -f 1`;
					chomp $origin;
				}
				if (not $file or $origin =~ /$kernel_escaped/) {
					print_red "\nError: $name installation failed!";
					addSetupInfo ("$ofedlogs/$name.debinstall.log");
					print_red "See:\n\t$ofedlogs/$name.debinstall.log";
					my $makelog = `grep "make.log" $ofedlogs/$name.debinstall.log 2>/dev/null`;
					if ($makelog =~ /.*\s(.*make.log)\s.*/) {
						$makelog = $1;
					}
					if (not -f $makelog) {
						my $path = `grep -Ei "/var/lib/dkms/.*build.*for more information" $ofedlogs/$name.debinstall.log 2>/dev/null`;
						if ($path =~ /.*(\/var\/lib\/dkms\/.*build).*/) {
							$makelog = "$1/$makelog";
						}
					}
					if (-f $makelog) {
						system("cp $makelog $ofedlogs/$name.make.log");
						print_red "\t$ofedlogs/$name.make.log";
					}
					print_red "Removing newly installed packages...\n";
					ex "/usr/sbin/ofed_uninstall.sh --force";
					exit 1;
				}
			}
		}
	}
}

sub get_tarball_name_version
{
	my $tarname = shift @_;
	$tarname =~ s@.*/@@g;
	my $name = $tarname;
	$name =~ s/_.*//;
	my $version = $tarname;
	$version =~ s/${name}_//;
	$version =~ s/(.orig).*//;

	return ($name, $version);
}

sub get_deb_name_version
{
	my $debname = shift @_;
	$debname =~ s@.*/@@g;
	my $name = $debname;
	$name =~ s/_.*//;
	my $version = $debname;
	$version =~ s/${name}_//;
	$version =~ s/_.*//;
	$version =~ s/-.*//;# remove release if available

	# W/A for mft
	if ($debname =~ /^mft/) {
		$name = (split ('-',$debname))[0];
		$version = (split ('-',$debname))[1];
	}

	return ($name, $version);
}

sub set_existing_debs
{
	for my $deb ( <$DEBS/*.deb> ) {
		my ($deb_name, $ver) = get_deb_name_version($deb);
		# skip unrelevnt debs
		if ($deb_name =~ /-modules/ and $deb !~ /-${kernel_escaped}_|\.kver\.${kernel_escaped}_/) {
			next;
		}
		$main_packages{$deb_name}{$ver}{'debpath'} = $deb;
		$packages_info{$deb_name}{$ver}{'deb_exist'} = 1;
		print "set_existing_debs: $deb_name $ver DEB exist\n" if ($verbose2);
	}
}

sub set_cfg
{
	my $tarball_full_path = shift @_;

	my ($name, $version) = get_tarball_name_version($tarball_full_path);

	$main_packages{$name}{$version}{'name'} = $name;
	$main_packages{$name}{$version}{'version'} = $version;
	$main_packages{$name}{$version}{'tarballpath'} = $tarball_full_path;

	print "set_cfg: " .
	"name: $name, " .
	"version: $main_packages{$name}{$version}{'version'}, " .
	"tarballpath: $main_packages{$name}{$version}{'tarballpath'}\n" if ($verbose3);
}

# return 0 if pacakge not selected
# return 1 if pacakge selected
sub select_dependent
{
	my $package = shift @_;

	if ($user_space_only and ($packages_info{$package}{'mode'} eq 'kernel')) {
		print "select_dependent: in user-space-only mode, skipping kernel package: $package\n" if ($verbose2);
		return 0;
	}

	my $scanned = 0;
	my $pname = $packages_info{$package}{'parent'};
	for my $ver (keys %{$main_packages{$pname}}) {
		$scanned = 1;
		if ( not $packages_info{$package}{$ver}{'deb_exist'} ) {
			for my $req ( @{ $packages_info{$package}{'ofa_req_build'} } ) {
				next if not $req;
				print "resolve_dependencies: $package requires $req for deb build\n" if ($verbose2);
				my $req_selected = 0;
				if ($packages_info{$req}{'available'}) {
					if (not $packages_info{$req}{'selected'}) {
						$req_selected = select_dependent($req);
					} else {
						$req_selected = 1;
					}
				}
				# Check if this is a strict requirment
				if (not $req_selected and not grep( /^$req$/, @{ $packages_info{$package}{'soft_req'} } )) {
					print "select_dependent: $req requiement not satisfied for $package, skipping it\n" if ($verbose2);
					$packages_info{$package}{'available'} = 0;
					$packages_info{$pname}{'available'} = 0;
					return 0;
				}
			}
		}

		for my $req ( @{ $packages_info{$package}{'ofa_req_inst'} } ) {
			next if not $req;
			print "resolve_dependencies: $package requires $req for deb install\n" if ($verbose2);
			my $req_selected = 0;
			if ($packages_info{$req}{'available'}) {
				if (not $packages_info{$req}{'selected'}) {
					$req_selected = select_dependent($req);
				} else {
					$req_selected = 1;
				}
			}
			if (not $req_selected and not grep( /^$req$/, @{ $packages_info{$package}{'soft_req'} } )) {
				print "select_dependent: $req requiement not satisfied for $package, skipping it\n" if ($verbose2);
				$packages_info{$package}{'available'} = 0;
				$packages_info{$pname}{'available'} = 0;
				return 0;
			}
		}

		if (not $packages_info{$package}{'selected'}) {
			return 0 if (not $packages_info{$package}{'available'});
			my $parent = $packages_info{$package}{'parent'};
			return 0 if (not is_tarball_available($parent));
			$packages_info{$package}{'selected'} = 1;
			push (@selected_packages, $package);
			print "select_dependent: Selected package $package\n" if ($verbose2);
			return 1;
		}
	}
	if ($scanned eq "0") {
		print "resolve_dependencies: $package does not exist. Skip dependencies check\n" if ($verbose2);
	}
	# if we get here, then nothing got selected.
	return 0;
}

sub select_dependent_module
{
	my $module = shift @_;

	if (not $kernel_modules_info{$module}{'available'}) {
		print "select_dependent_module: $module is not available, skipping it\n" if ($verbose2);
		return;
	}

	for my $req ( @{ $kernel_modules_info{$module}{'requires'} } ) {
		print "select_dependent_module: $module requires $req for deb build\n" if ($verbose2);
		if (not $kernel_modules_info{$req}{'selected'}) {
			select_dependent_module($req);
		}
	}
	if (not $kernel_modules_info{$module}{'selected'}) {
		$kernel_modules_info{$module}{'selected'} = 1;
		push (@selected_kernel_modules, $module);
		print "select_dependent_module: Selected module $module\n" if ($verbose2);
	}
}

sub resolve_dependencies
{
	for my $package ( @selected_by_user ) {
		# Get the list of dependencies
		select_dependent($package);
		if (exists $standalone_kernel_modules_info{$package}) {
			for my $mod (@{$standalone_kernel_modules_info{$package}}) {
				if ($kernel_modules_info{$mod}{'available'}) {
					push (@selected_modules_by_user, $mod);
				}
			}
		}
	}

	for my $module ( @selected_modules_by_user ) {
		select_dependent_module($module);
	}

	my $kernel_rpm = "$mlnX_ofed_kernel";
	my $pname = $packages_info{$kernel_rpm}{'parent'};
	for my $ver (keys %{$main_packages{$pname}}) {
		if ($packages_info{$kernel_rpm}{$ver}{'deb_exist'}) {
			for my $module (@selected_kernel_modules) {
				if (not is_module_in_deb($kernel_rpm, "$module")) {
					$packages_info{$kernel_rpm}{$ver}{'deb_exist'} = 0;
					$packages_info{'mlnx-ofed-kernel'}{$ver}{'deb_exist'} = 0;
					last;
				}
			}
			if ($with_memtrack) {
				if (not is_module_in_deb($kernel_rpm, "memtrack")) {
					$packages_info{$kernel_rpm}{$ver}{'deb_exist'} = 0;
					$packages_info{'mlnx-ofed-kernel'}{$ver}{'deb_exist'} = 0;
					last;
				}
			}
		}
	}
}

#
# set vma flags in /etc/modprobe.d/mlnx.conf
#
sub set_vma_flags
{
	return if ($user_space_only);
	my $mlnx_conf = "/etc/modprobe.d/mlnx.conf";
    if ($with_vma and -e "$mlnx_conf") {
        my @lines;
        open(FD, "$mlnx_conf");
        while (<FD>) {
            push @lines, $_;
        }
        close (FD);
        open(FD, ">$mlnx_conf");
        foreach my $line (@lines) {
            chomp $line;
            print FD "$line\n" unless ($line =~ /disable_raw_qp_enforcement|fast_drop|log_num_mgm_entry_size/);
        }
        print FD "options ib_uverbs disable_raw_qp_enforcement=1\n";
        print FD "options mlx4_core fast_drop=1\n";
        print FD "options mlx4_core log_num_mgm_entry_size=-1\n";
        close (FD);
    }

    if (-f "/etc/infiniband/openib.conf") {
        my @lines;
        open(FD, "/etc/infiniband/openib.conf");
        while (<FD>) {
            push @lines, $_;
        }
        close (FD);
        # Do not start SDP
        # Do not start QIB to prevent http://bugs.openfabrics.org/bugzilla/show_bug.cgi?id=2262
        open(FD, ">/etc/infiniband/openib.conf");
        foreach my $line (@lines) {
            chomp $line;
            if ($line =~ m/(^SDP_LOAD=|^QIB_LOAD=).*/) {
                    print FD "${1}no\n";
            } elsif ($line =~ m/(^SET_IPOIB_CM=).*/ and $with_vma) {
                # Set IPoIB Datagram mode in case of VMA installation
                print FD "SET_IPOIB_CM=no\n";
            } else {
                    print FD "$line\n";
            }
        }
        close (FD);
    }
}

sub print_selected
{
	print GREEN "\nBelow is the list of ${PACKAGE} packages that you have chosen
	\r(some may have been added by the installer due to package dependencies):\n", RESET "\n";
	for my $package ( @selected_packages ) {
		print "$package\n";
	}
	print "\n";
}

sub disable_package
{
    my $key = shift;

    if (exists $packages_info{$key}) {
        $packages_info{$key}{'available'} = 0;
        for my $requester (@{$packages_deps{$key}{'required_by'}}) {
            disable_package($requester);
        }
    }
    # modules
    if (exists $kernel_modules_info{$key}) {
        $kernel_modules_info{$key}{'available'} = 0;
        for my $requester (@{$modules_deps{$key}{'required_by'}}) {
            disable_package($requester);
        }
    }

    if (not (exists $packages_info{$key} or exists $kernel_modules_info{$key})) {
        print YELLOW "Unsupported package: $key", RESET "\n" if (not $quiet);
    }
}

sub enable_package
{
    my $key = shift;

    if (exists $packages_info{$key}) {
        $packages_info{$key}{'available'} = 1;
        for my $req ( @{ $packages_info{$key}{'ofa_req_inst'} } ) {
            enable_package($req);
        }
    }
}

sub enable_module
{
    my $key = shift;

    if (exists $kernel_modules_info{$key}) {
        $kernel_modules_info{$key}{'available'} = 1;
        for my $req ( @{ $kernel_modules_info{$key}{'requires'} } ) {
            enable_module($req);
        }
    }
}

sub add_enabled_pkgs_by_user
{
    ##############
    # handle with/enable flags
    for my $key ( keys %force_enable_packages ) {
	# fix kernel packages names
	# DKMS enabled
	if ($with_dkms) {
		if ($key =~ /-modules/) {
			$key =~ s/-modules/-dkms/g;;
		}
	} else {
	# DKMS disabled
		if ($key =~ /-dkms/) {
			$key =~ s/-dkms/-modules/g;;
		}
	}

        if (exists $packages_info{$key}) {
            enable_package($key);
            push (@selected_by_user, $key);
        }
        if (exists $kernel_modules_info{$key}) {
            enable_module($key);
            push (@selected_modules_by_user , $key);
        }

        if (not (exists $packages_info{$key} or exists $kernel_modules_info{$key})) {
            print YELLOW "Unsupported package: $key", RESET "\n" if (not $quiet);
        }
    }
}

sub check_autofconf
{
	my $VAR = shift;

	my $value = `tac ${kernel_sources}/include/*/autoconf.h 2>/dev/null | grep -m1 ${VAR} 2>/dev/null | sed -ne 's/.*\\\([01]\\\)\$/\\1/gp' 2>/dev/null`;
	chomp $value;
	if ($value eq "") {
		$value = 0;
	}

	return $value;
}

sub set_availability
{
	if ( $distro =~ /debian6/) {
		$packages_info{'openshmem'}{'available'} = 0; # compilation error
	}

	if ($arch !~ /arm|aarch|ppc/i) {
		push(@required_debs, "libcr-dev");
	}

	# some special deps
	my $libnl = "libnl1";
	my $libnl_dev = "libnl-dev";
	my $libnl_route = "";
	my $libnl_route_dev = "";

	if ($distro =~ /debian8|ubuntu1[5-9]/) {
		$libnl = "libnl-3-200";
		$libnl_dev = "libnl-3-dev";
		$libnl_route = "libnl-route-3-200";
		$libnl_route_dev = "libnl-route-3-dev";
	} else {
		my $tcl = "tcl8.4";
		my $tcl_dev = "tcl8.4";
		my $tk = "tk8.4";
		my $tk_dev = "tk8.4-dev";

		push(@{$packages_info{'ibutils2'}{'dist_req_build'}}, "$tcl_dev");
		push(@{$packages_info{'ibutils2'}{'dist_req_build'}}, "$tk_dev");
		push(@{$packages_info{'ibutils'}{'dist_req_build'}}, "$tcl_dev");
		push(@{$packages_info{'ibutils'}{'dist_req_build'}}, "$tk_dev");
		push(@{$packages_info{'libibdm1'}{'dist_req_build'}}, "$tcl_dev");

		push(@{$packages_info{'ibutils2'}{'dist_req_inst'}}, "$tcl");
		push(@{$packages_info{'ibutils2'}{'dist_req_inst'}}, "$tk");
		push(@{$packages_info{'ibutils'}{'dist_req_inst'}}, "$tcl");
		push(@{$packages_info{'ibutils'}{'dist_req_inst'}}, "$tk");
		push(@{$packages_info{'libibdm1'}{'dist_req_inst'}}, "$tcl");
	}

	push(@{$packages_info{'libvma'}{'dist_req_build'}}, "$libnl_dev");
	push(@{$packages_info{'libibverbs1'}{'dist_req_build'}}, "$libnl_dev");
	push(@{$packages_info{'libibverbs1'}{'dist_req_build'}}, "$libnl_route_dev") if ($libnl_route_dev ne "");

	push(@{$packages_info{'libvma'}{'dist_req_inst'}}, "$libnl");
	push(@{$packages_info{'libibverbs1'}{'dist_req_inst'}}, "$libnl");
	push(@{$packages_info{'libibverbs1'}{'dist_req_inst'}}, "$libnl_route") if ($libnl_route ne "");

	if ($arch =~ /arm|aarch/i) {
		$packages_info{'dalp'}{'available'} = 0;
		$packages_info{'libdapl2'}{'available'} = 0;
		$packages_info{'dapl2-utils'}{'available'} = 0;
		$packages_info{'libdapl-dev'}{'available'} = 0;
		$packages_info{'fca'}{'available'} = 0;

		$packages_info{'hcoll'}{'available'} = 0;
	}

	if ($kernel =~ /fbk/ or $arch =~ /arm|aarch/) {
		$kernel_modules_info{'sdp'}{'available'} = 0;
		$packages_info{'libsdp1'}{'available'} = 0;
		$packages_info{'libsdp-dev'}{'available'} = 0;
		$packages_info{'sdpnetstat'}{'available'} = 0;
		$packages_info{'mlnx-sdp'}{'available'} = 0;
		$packages_info{"$mlnx_sdp"}{'available'} = 0;
	}

	if ($arch =~ /ppc/i) {
		$kernel_modules_info{'srp'}{'available'} = 0;
	}

	if ( not $with_vma or $arch !~ m/x86_64|ppc64|arm|aarch/) {
		$packages_info{'libvma'}{'available'} = 0;
		$packages_info{'libvma-utils'}{'available'} = 0;
		$packages_info{'libvma-dev'}{'available'} = 0;
		$packages_info{'sockperf'}{'available'} = 0;
	}

	if ( $distro =~ /ubuntu16|ubuntu15.04|ubuntu14.04/ and $kernel =~ /^4\.[4-9]|^4\.1[0-9]\.|^3\.1[3-9]/ ) {
		$kernel_modules_info{'isert'}{'available'} = 1;
		$packages_info{'isert-dkms'}{'available'} = 1;
		$packages_info{'isert-modules'}{'available'} = 1;
	}

	if (not $with_dkms) {
		# we use only knem-modules when not working with dkms
		$packages_info{'knem'}{'available'} = 0;
	}
	if ($cross_compiling) {
		$packages_info{'knem'}{'available'} = 0;
		$packages_info{'knem-dkms'}{'available'} = 0;
		$packages_info{'knem-modules'}{'available'} = 0;
	}

	if ($distro =~ /ubuntu16.10|ubuntu1[7-8]/) {
		$packages_info{'ibutils'}{'available'} = 0; #compilation failed with GCC6
	}

	if (not $kernel =~ /^4\.11/) {
		$kernel_modules_info{'nfsrdma'}{'available'} = 0;
		$packages_info{"$mlnx_nfsrdma"}{'available'} = 0;
	}

	if ($kernel !~ /^4\.[8-9]|^4\.1[0-9]/) {
		$packages_info{"$mlnx_nvme"}{'available'} = 0;
	}

	my $CONFIG_NET_UDP_TUNNEL = check_autofconf('CONFIG_NET_UDP_TUNNEL');
	if ($kernel !~ /^4\.[8-9]|^4\.1[0-9]\./ or $CONFIG_NET_UDP_TUNNEL ne "1") {
		$packages_info{"$mlnx_rdma_rxe"}{'available'} = 0;
	}

	if (not ($kernel =~ /^4\.[0-9]|^3.1[6-9]/) ) {
		$kernel_modules_info{'srp'}{'available'} = 0;
		$packages_info{'srp'}{'available'} = 0;
		$packages_info{'srp-modules'}{'available'} = 0;
		$packages_info{'srp-dkms'}{'available'} = 0;
	}

    ##############
    # handle without/disable flags
    if (keys %disabled_packages) {
        # build deps list
        for my $pkg (keys %packages_info) {
            for my $req ( @{ $packages_info{$pkg}{'ofa_req_inst'}} , @{ $packages_info{$pkg}{'ofa_req_build'}} ) {
                next if not $req;
                push (@{$packages_deps{$req}{'required_by'}}, $pkg);
            }
        }
        for my $mod (keys %kernel_modules_info) {
            for my $req ( @{ $kernel_modules_info{$mod}{'requires'} } ) {
                next if not $req;
                push (@{$modules_deps{$req}{'required_by'}}, $mod);
            }
        }
        # disable packages
        for my $key ( keys %disabled_packages ) {
            disable_package($key);
        }
    }
    # end of handle without/disable flags

	# keep this at the end of the function.
	add_enabled_pkgs_by_user();
}

sub set_mlnx_tune
{
	# Enable/disable mlnx_tune
	if ( -e "/etc/infiniband/openib.conf") {
		my @lines;
		open(FD, "/etc/infiniband/openib.conf");
		while (<FD>) {
			push @lines, $_;
		}
		close (FD);

		open(FD, ">/etc/infiniband/openib.conf");
		foreach my $line (@lines) {
			chomp $line;
			if ($line =~ m/(^RUN_MLNX_TUNE=).*/) {
				if ($enable_mlnx_tune) {
					print FD "${1}yes\n";
				} else {
					print FD "${1}no\n";
				}
			} else {
					print FD "$line\n";
			}
		}
		close (FD);
	}
}

sub set_umad_permissions
{
	if (-f $ib_udev_rules) {
		open(IB_UDEV_RULES, $ib_udev_rules) or die "Can't open $ib_udev_rules: $!";
		my @ib_udev_rules_lines;
		while (<IB_UDEV_RULES>) {
			push @ib_udev_rules_lines, $_;
		}
		close(IB_UDEV_RULES);

		open(IB_UDEV_RULES, ">$ib_udev_rules") or die "Can't open $ib_udev_rules: $!";
		foreach my $line (@ib_udev_rules_lines) {
			chomp $line;
			if ($line =~ /umad/) {
				if ($umad_dev_na) {
					print IB_UDEV_RULES "KERNEL==\"umad*\", NAME=\"infiniband/%k\", MODE=\"0660\"\n";
				} else {
					print IB_UDEV_RULES "KERNEL==\"umad*\", NAME=\"infiniband/%k\", MODE=\"0666\"\n";
				}
			} else {
				print IB_UDEV_RULES "$line\n";
			}
		}
		close(IB_UDEV_RULES);
	}
}

sub addSetupInfo
{
	my $log = shift @_;

	print "Collecting debug info...\n" if (not $quiet);

	if (not open (LOG, ">> $log")) {
		print "-E- Can't open $log for appending!\n";
		return;
	}

	print LOG "\n\n\n---------------- START OF DEBUG INFO -------------------\n";
	print LOG "Install command: $CMD\n";

	print LOG "\nVars dump:\n";
	print LOG "- ofedlogs: $ofedlogs\n";
	print LOG "- distro: $distro\n";
	print LOG "- arch: $arch\n";
	print LOG "- kernel: $kernel\n";
	print LOG "- config: $config\n";

	print LOG "\nSetup info:\n";
	print LOG "\n- uname -r: " . `uname -r 2>&1`;
	print LOG "\n- uname -m: " . `uname -m 2>&1`;
	print LOG "\n- lsb_release -a: " . `lsb_release -a 2>&1`;
	print LOG "\n- cat /etc/issue: " . `cat /etc/issue 2>&1`;
	print LOG "\n- cat /proc/version: " . `cat /proc/version 2>&1`;
	print LOG "\n- gcc --version: " . `gcc --version 2>&1`;
	print LOG "\n- lspci -n | grep 15b3: " . `lspci -n 2>&1 | grep 15b3`;
	print LOG "\n- dpkg --list: " . `dpkg --list 2>&1`;

	print LOG "---------------- END OF DEBUG INFO -------------------\n";
	close (LOG);
}

sub ex1
{
    my $cmd = shift @_;

    system("$cmd 2>&1");
    my $res = $? >> 8;
    my $sig = $? & 127;
    if ($sig or $res) {
        print RED "Command execution failed: $cmd", RESET "\n";
        exit 1;
    }
}

sub uninstall
{
	return 0 if (not $uninstall);

	print "Removing old packages\n";
	my $ofed_uninstall = `which ofed_uninstall.sh 2> /dev/null`;
	chomp $ofed_uninstall;
	if (-f "$ofed_uninstall") {
		print "Uninstalling the previous version of $PACKAGE\n" if (not $quiet);
		if ($force) {
				system("yes | ofed_uninstall.sh --force >> $ofedlogs/ofed_uninstall.log 2>&1");
		} else {
				system("yes | ofed_uninstall.sh >> $ofedlogs/ofed_uninstall.log 2>&1");
		}
		my $res = $? >> 8;
		my $sig = $? & 127;
		if ($sig or $res) {
			if ($res == 174) {
				print "Error: One or more packages depends on MLNX_OFED.\nThese packages should be removed before uninstalling MLNX_OFED:\n";
				system("cat $ofedlogs/ofed_uninstall.log | perl -ne '/Those packages should be/ && do {\$a=1; next}; /To force uninstallation use/ && do {\$a=0}; print if \$a'");
				print "To force uninstallation use '--force' flag.\n";
				addSetupInfo ("$ofedlogs/ofed_uninstall.log");
				print RED "See $ofedlogs/ofed_uninstall.log", RESET "\n";
				exit $NONOFEDRPMS;
			}
			print RED "Failed to uninstall the previous installation", RESET "\n";
			addSetupInfo ("$ofedlogs/ofed_uninstall.log");
			print RED "See $ofedlogs/ofed_uninstall.log", RESET "\n";
			exit $ERROR;
		}
	}
	my @list_to_remove;
	foreach (@remove_debs){
		next if ($_ =~ /^xen|ovsvf-config/);
		foreach (get_all_matching_installed_debs($_)) {
			next if ($_ =~ /^xen|ovsvf-config/);
			if (not $selected_for_uninstall{$_}) {
				push (@list_to_remove, $_);
				$selected_for_uninstall{$_} = 1;
				if (not (exists $packages_info{$_} or $_ =~ /mlnx-ofed-/)) {
					$non_ofed_for_uninstall{$_} = 1;
				}
				get_requires($_);
			}
		}
	}

	if (not $force and keys %non_ofed_for_uninstall) {
		print "\nError: One or more packages depends on MLNX_OFED.\nThose packages should be removed before uninstalling MLNX_OFED:\n\n";
		print join(" ", (keys %non_ofed_for_uninstall)) . "\n\n";
		print "To force uninstallation use '--force' flag.\n";
		exit $NONOFEDRPMS;
	}

	# verify that dpkg DB is ok
	print_and_log "Running: dpkg --configure -a --force-all";
	system("dpkg --configure -a --force-all >> $log 2>&1");
	print_and_log "Running: apt-get install -f";
	system("apt-get install -f -y >> $log 2>&1");

	ex "apt-get remove -y @list_to_remove @dependant_packages_to_uninstall" if (scalar(@list_to_remove) or scalar(@dependant_packages_to_uninstall));
	foreach (@list_to_remove, @dependant_packages_to_uninstall){
		if (is_configured_deb($_)) {
			if (not /^opensm/) {
				ex "apt-get remove --purge -y $_";
			} else {
				system("apt-get remove --purge -y $_");
			}
		}
	}
	system ("/bin/rm -rf /usr/src/mlnx-ofed-kernel* > /dev/null 2>&1");
}

########
# MAIN #
########
sub main
{
	$ofedlogs = "$TMPDIR/$PACKAGE.$$.logs";
	mkpath([$ofedlogs]);

	$log = "$TMPDIR/ofed.build.log";
	rmtree $log;
	open (LOG, ">$log") or die "Can't open $log: $!\n";

	if (!$install_option) {
		$install_option = 'all';
	}

	if ($config_net_given) {
		if (not -e $config_net) {
			print_red "Error: network config_file '$config_net' does not exist!", RESET "\n";
			exit 1;
		}

		open(NET, "$config_net") or die "Can't open $config_net: $!";
		while (<NET>) {
			my ($param, $value) = split('=');
			chomp $param;
			chomp $value;
			my $dev = $param;
			$dev =~ s/(.*)_(ib[0-9]+)/$2/;
			chomp $dev;

			if ($param =~ m/IPADDR/) {
				$ifcfg{$dev}{'IPADDR'} = $value;
			}
			elsif ($param =~ m/NETMASK/) {
				$ifcfg{$dev}{'NETMASK'} = $value;
			}
			elsif ($param =~ m/NETWORK/) {
				$ifcfg{$dev}{'NETWORK'} = $value;
			}
			elsif ($param =~ m/BROADCAST/) {
				$ifcfg{$dev}{'BROADCAST'} = $value;
			}
			elsif ($param =~ m/ONBOOT/) {
				$ifcfg{$dev}{'ONBOOT'} = $value;
			}
			elsif ($param =~ m/LAN_INTERFACE/) {
				$ifcfg{$dev}{'LAN_INTERFACE'} = $value;
			}
			else {
				print_red "Unsupported parameter '$param' in $config_net\n" if ($verbose2);
			}
		}
		close(NET);
	}

	set_availability();
	for my $tarball ( <$CWD/SOURCES/*> ) {
		set_cfg ($tarball);
	}

	my $num_selected = select_packages();
	set_existing_debs();
	resolve_dependencies();

	${kernel_packages}{$mlnx_en}{'ko'} = [];
	if (grep( /^mlx4$/, @selected_kernel_modules )) {
		push(@{${kernel_packages}{$mlnx_en}{'ko'}}, "mlx4_core");
		push(@{${kernel_packages}{$mlnx_en}{'ko'}}, "mlx4_en");
	}
	if (grep( /^mlx5$/, @selected_kernel_modules )) {
		push(@{${kernel_packages}{$mlnx_en}{'ko'}}, "mlx5_core");
	}

	if (not $num_selected) {
		print RED "$num_selected packages selected. Exiting...", RESET "\n";
		exit 1;
	}

	if ($print_available) {
		open(CONFIG, ">$config") || die "Can't open $config: $!";
		flock CONFIG, $LOCK_EXCLUSIVE;
		print "\nOFED packages: ";
		for my $package ( @selected_packages ) {
			my $parent = $packages_info{$package}{'parent'};
			next if (not $packages_info{$package}{'available'} or not is_tarball_available($parent));
			print("$package available: $packages_info{$package}{'available'}\n") if ($verbose2);
			if ($package =~ /$mlnX_ofed_kernel/) {
				print "\nKernel modules: ";
				for my $module ( @selected_kernel_modules ) {
					next if (not $kernel_modules_info{$module}{'available'});
					print $module . ' ';
					print CONFIG "$module=y\n";
				}
				print "\nRPMs: ";
			}
			print $package . ' ';
			print CONFIG "$package=y\n";
		}
		flock CONFIG, $UNLOCK;
		close(CONFIG);
		print GREEN "\nCreated $config", RESET "\n";
		exit $SUCCESS;
	}

	warn("Log: $log\n");
	warn("Logs dir: $ofedlogs\n");
	if (not $quiet and not $check_deps_only) {
		print_selected();
	}

	# install required packages
	check_linux_dependencies();

	print "This program will install the $PACKAGE package on your machine.\n"
	    . "Note that all other Mellanox, OEM, OFED, RDMA or Distribution IB packages will be removed.\n"
	    . "Those packages are removed due to conflicts with $PACKAGE, do not reinstall them.\n\n" if (not $quiet);

	uninstall();

	# install new packages chosen by the user
	install_selected();

	if ($build_only) {
		print_green "Build passed successfully" if (not $quiet);
		return 0;
	}

	if (is_module_in_deb("mlnx-ofed-kernel", "ipoib")) {
		ipoib_config();
	}

	# set vma flags in /etc/modprobe.d/mlnx.conf in case the user chosen to enable vma
	set_vma_flags();

	set_mlnx_tune();

	if ($umad_dev_rw or $umad_dev_na) {
		set_umad_permissions();
	}

        if ( not $quiet ) {
            check_pcie_link();
        }

	close(LOG);

	print_green "Installation passed successfully" if (not $quiet);
}

main();

exit $SUCCESS;

