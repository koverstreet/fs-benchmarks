#!/bin/bash

set -o nounset
set -o errexit
set -o errtrace
set -o pipefail

BENCHDIR=$(dirname "$(readlink -f "$0")")

FILESYSTEMS="bcache ext4 ext4-no-journal xfs btrfs"
DEVS="/dev/rssda /dev/sdb /dev/sda5"
BENCHES="					\
    dio-randread				\
    dio-randread-multithreaded			\
    dio-randwrite				\
    dio-randwrite-multithreaded			\
    dio-randwrite-unwritten			\
    dio-randwrite-multithreaded-unwritten	\
    dio-randrw					\
    dio-randrw-multithreaded			\
    dio-append					\
    dio-append-one-cpu				\
    buffered-sync-append"
OUT=""
MNT=/mnt/run-benchmark

while getopts "hd:f:b:m:o:" arg; do
    case $arg in
	h)
	    usage
	    exit 0
	    ;;
	d)
	    DEVS=$OPTARG
	    ;;
	f)
	    FILESYSTEMS=$OPTARG
	    ;;
	b)
	    BENCHES=$OPTARG
	    ;;
	m)
	    MNT=$OPTARG
	    ;;
	o)
	    OUT=$OPTARG
	    ;;
    esac
done
shift $(( OPTIND - 1 ))

if [[ -z $DEVS ]]; then
    echo "Required parameter -d missing: device(s) to test"
    exit 1
fi

if [[ -z $OUT ]]; then
    for i in `seq -w 0 100`; do
	OUT=/root/results/$(date -I)_$i
	[[ ! -e $OUT ]] && break
    done
fi

mkdir $OUT
terse=$OUT/terse
full=$OUT/full

truncate --size 0 $terse
truncate --size 0 $full

echo "Test output in $OUT:"

for dev in $DEVS; do
    devname=$(basename $dev)
    model=$(hdparm -i $dev |tr ',' '\n'|sed -n 's/.*Model=\(.*\)/\1/p')

    echo "Device $devname ($model):" |tee -a $terse

    for bench in $BENCHES; do
	benchname=$(basename $bench)
	echo "    $benchname:" |tee -a $terse

	for fs in $FILESYSTEMS; do
	    out=$OUT/$devname-$benchname-$fs
	    printf "        %-16s" $fs: |tee -a $terse

	    $BENCHDIR/prep-benchmark-fs.sh -d $dev -m $MNT -f $fs >/dev/null 2>&1
	    sleep 30 # quiesce
	    (cd $MNT; "$BENCHDIR/benches/$bench") > $out
	    umount $dev

	    echo "**** Device $devname ($model) filesystem $fs benchmark $benchname:" >> $full
	    cat $out >> $full
	    echo >> $full

	    sed -rne '/iops/ s/ +([[:alpha:]]+) ?:.*iops=([0-9]+).*/\1 \2/ p' $out|
		awk '{printf("%8s %8d iops", $1, $2)} END {printf("\n")}'|
		tee -a $terse
	done
    done
done
