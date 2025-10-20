#!/bin/bash

set -o nounset
set -o errexit
set -o errtrace
set -o pipefail

BENCHDIR=$(dirname "$(readlink -f "$0")")

FILESYSTEMS="bcachefs bcachefs-no-checksum ext4 ext4-no-journal xfs btrfs"

#DEVS="/dev/rssda /dev/sdb /dev/sda5"

DEVS="/dev/nvme1n1p4"

BENCHES=$(cd $BENCHDIR/benches; echo *)
OUT=""
MNT=/mnt/run-benchmark

usage()
{
    echo "run-benchmark.sh - run benchmarks"
    echo "  -d devices to test"
    echo "  -f filesystems to test"
    echo "  -b benchmarks to run"
    echo "  -m mountpoint to use (default /mnt/run-benchmark)"
    echo "  -o benchmark output directory (default /root/results/<date>_\$i/"
    echo "  -h display this help and exit"
    exit 0
}

while getopts "hd:f:b:m:o:" arg; do
    case $arg in
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
  h)
      usage
      exit 0
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

mkdir -p $OUT
terse=$OUT/terse
full=$OUT/full

truncate --size 0 $terse
truncate --size 0 $full

echo "Test output in $OUT"

function cleanup {
    umount $MNT > /dev/null 2>&1 || true
}
trap cleanup SIGINT SIGHUP SIGTERM EXIT

for dev in $DEVS; do
  partname=$(basename $dev)
  devname=$(lsblk -no pkname $dev)
  #model=$(hdparm -i $dev |tr ',' '\n'|sed -n 's/.*Model=\(.*\)/\1/p')
  model=$(cat /sys/block/$devname/device/model)

  echo "Device $partname ($model):" |tee -a $terse

  for bench in $BENCHES; do
    benchname=$(basename $bench)
    echo "    $benchname:" |tee -a $terse

    for fs in $FILESYSTEMS; do
      out=$OUT/$partname-$benchname-$fs
      printf "        %-24s" $fs: |tee -a $terse

      $BENCHDIR/prep-benchmark-fs.sh -d $dev -m $MNT -f $fs >/dev/null 2>&1
      sleep 10 # quiesce - SSDs are annoying
      (cd $MNT; "$BENCHDIR/benches/$bench") > $out
      umount $dev

      echo "**** Device $partname ($model) filesystem $fs benchmark $benchname:" >> $full
      cat $out >> $full

      echo >> $full

      for metric in read write; do
        val=$(jq .jobs[0].$metric.iops $out)
        if (( $(echo "$val != 0.0" | bc -l) )); then
          echo | awk "{printf(\"%8s %12.0f iops\", \"$metric\", $val)}" | tee -a $terse
        fi
      done
      echo | tee -a $terse
    done
  done
done
