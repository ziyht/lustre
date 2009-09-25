#!/bin/bash
#
# Run select tests by setting ONLY, or as arguments to the script.
# Skip specific tests by setting EXCEPT.
#
# Run test by setting NOSETUP=true when ltest has setup env for us
set -e

#kernel 2.4.x doesn't support quota
K_VER=`uname --kernel-release | cut -b 1-3`
if [ $K_VER = "2.4" ]; then
    echo "Kernel 2.4 doesn't support quota"
    exit 0
fi

SRCDIR=`dirname $0`
export PATH=$PWD/$SRCDIR:$SRCDIR:$PWD/$SRCDIR/../utils:$PATH:/sbin

ONLY=${ONLY:-"$*"}
# test_11 has been used to protect a kernel bug(bz10912), now it isn't
# useful any more. Then add it to ALWAYS_EXCEPT. b=19835
ALWAYS_EXCEPT="10 $SANITY_QUOTA_EXCEPT"
# UPDATE THE COMMENT ABOVE WITH BUG NUMBERS WHEN CHANGING ALWAYS_EXCEPT!

case `uname -r` in
2.6*) FSTYPE=${FSTYPE:-ldiskfs};;
*) error "unsupported kernel" ;;
esac

[ "$ALWAYS_EXCEPT$EXCEPT" ] && \
	echo "Skipping tests: `echo $ALWAYS_EXCEPT $EXCEPT`"

TMP=${TMP:-/tmp}

ORIG_PWD=${PWD}
TSTID=${TSTID:-60000}
TSTID2=${TSTID2:-60001}
TSTUSR=${TSTUSR:-"quota_usr"}
TSTUSR2=${TSTUSR2:-"quota_2usr"}
BLK_SZ=1024
BUNIT_SZ=${BUNIT_SZ:-1024}	# min block quota unit(kB)
IUNIT_SZ=${IUNIT_SZ:-10}	# min inode quota unit
MAX_DQ_TIME=604800
MAX_IQ_TIME=604800

TRACE=${TRACE:-""}
LUSTRE=${LUSTRE:-`dirname $0`/..}
. $LUSTRE/tests/test-framework.sh
init_test_env $@
. ${CONFIG:=$LUSTRE/tests/cfg/$NAME.sh}
DIRECTIO=${DIRECTIO:-$LUSTRE/tests/directio}

[ $MDSCOUNT -gt 1 ] && skip "CMD case" && exit 0

unset ENABLE_QUOTA

remote_mds_nodsh && skip "remote MDS with nodsh" && exit 0
remote_ost_nodsh && skip "remote OST with nodsh" && exit 0

[ "$SLOW" = "no" ] && EXCEPT_SLOW="9 10 11 18b 21 29"

QUOTALOG=${TESTSUITELOG:-$TMP/$(basename $0 .sh).log}

[ "$QUOTALOG" ] && rm -f $QUOTALOG || true

DIR=${DIR:-$MOUNT}
DIR2=${DIR2:-$MOUNT2}

check_and_setup_lustre

if [ x"$(som_check)" = x"enabled" ]; then
        echo "Som is enabled, Quota is temporary conflicts with it"
        check_and_cleanup_lustre
        exit 0
fi

LOVNAME=`lctl get_param -n llite.*.lov.common_name | tail -n 1`
OSTCOUNT=`lctl get_param -n lov.$LOVNAME.numobd`

SHOW_QUOTA_USER="$LFS quota -v -u $TSTUSR $DIR"
SHOW_QUOTA_USERID="$LFS quota -v -u $TSTID $DIR"
SHOW_QUOTA_USER2="$LFS quota -v -u $TSTUSR2 $DIR"
SHOW_QUOTA_GROUP="$LFS quota -v -g $TSTUSR $DIR"
SHOW_QUOTA_GROUPID="$LFS quota -v -g $TSTID $DIR"
SHOW_QUOTA_GROUP2="$LFS quota -v -g $TSTUSR2 $DIR"
SHOW_QUOTA_INFO_USER="$LFS quota -t -u $DIR"
SHOW_QUOTA_INFO_GROUP="$LFS quota -t -g $DIR"

# control the time of tests
cycle=30
[ "$SLOW" = "no" ] && cycle=10

build_test_filter

# set_blk_tunables(btune_sz)
set_blk_tunesz() {
	local btune=$(($1 * BLK_SZ))
	# set btune size on all obdfilters
	do_facet ost1 "lctl set_param lquota.${FSNAME}-OST*.quota_btune_sz=$btune"
	# set btune size on mds
	do_facet $SINGLEMDS "lctl set_param lquota.mdd_obd-${FSNAME}-MDT*.quota_btune_sz=$btune"
}

# set_blk_unitsz(bunit_sz)
set_blk_unitsz() {
	local bunit=$(($1 * BLK_SZ))
	# set bunit size on all obdfilters
	do_facet ost1 "lctl set_param lquota.${FSNAME}-OST*.quota_bunit_sz=$bunit"
	# set bunit size on mds
	do_facet $SINGLEMDS "lctl set_param lquota.mdd_obd-${FSNAME}-MDT*.quota_bunit_sz=$bunit"
}

# set_file_tunesz(itune_sz)
set_file_tunesz() {
	local itune=$1
	# set itune size on all obdfilters
	do_facet ost1 "lctl set_param lquota.${FSNAME}-OST*.quota_itune_sz=$itune"
	# set itune size on mds
	do_facet $SINGLEMDS "lctl set_param lquota.mdd_obd-${FSNAME}-MDT*.quota_itune_sz=$itune"
}

# set_file_unitsz(iunit_sz)
set_file_unitsz() {
	local iunit=$1
	# set iunit size on all obdfilters
	do_facet ost1 "lctl set_param lquota.${FSNAME}-OST*.quota_iunit_sz=$iunit"
	# set iunit size on mds
	do_facet $SINGLEMDS "lctl set_param lquota.mdd_obd-${FSNAME}-MDT*.quota_iunit_sz=$iunit"
}

lustre_fail() {
        local fail_node=$1
	local fail_loc=$2
	local fail_val=${3:-0}

	if [ $fail_node == "mds" ] || [ $fail_node == "mds_ost" ]; then
	    if [ $((fail_loc & 0x10000000)) -ne 0  -a $fail_val -gt 0 ] || \
		[ $((fail_loc)) -eq 0 ]; then
		do_facet $SINGLEMDS "lctl set_param fail_val=$fail_val"
	    fi
	    do_facet $SINGLEMDS "lctl set_param fail_loc=$fail_loc"
	fi
	if [ $fail_node == "ost" ] || [ $fail_node == "mds_ost" ]; then
	    for num in `seq $OSTCOUNT`; do
		if [ $((fail_loc & 0x10000000)) -ne 0 -a $fail_val -gt 0 ] || \
		    [ $((fail_loc)) -eq 0 ]; then
		    do_facet ost$num "lctl set_param fail_val=$fail_val"
		fi
		do_facet ost$num "lctl set_param fail_loc=$fail_loc"
	    done
	fi
}

RUNAS="runas -u $TSTID -g $TSTID"
RUNAS2="runas -u $TSTID2 -g $TSTID2"
FAIL_ON_ERROR=true check_runas_id $TSTID $TSTID $RUNAS
FAIL_ON_ERROR=true check_runas_id $TSTID2 $TSTID2 $RUNAS2

FAIL_ON_ERROR=false

run_test_with_stat() {
	(($# != 2)) && error "the number of arguments is wrong"

	do_facet $SINGLEMDS "lctl set_param lquota.mdd_obd-${FSNAME}-MDT*.stats=0" > /dev/null
	for j in `seq $OSTCOUNT`; do
	    do_facet ost$j "lctl set_param lquota.${FSNAME}-OST*.stats=0" > /dev/null
	done
	run_test "$@"
	if [ ${STAT:-"yes"} != "no" -a -z "$LAST_SKIPPED" ]; then
	    echo "statistics info begin ***************************************"
	    do_facet $SINGLEMDS "lctl get_param lquota.mdd_obd-${FSNAME}-MDT*.stats"
	    for j in `seq $OSTCOUNT`; do
		do_facet ost$j "lctl get_param lquota.${FSNAME}-OST*.stats"
	    done
	    echo "statistics info end   ***************************************"
	fi
}

#
# clear quota limits for a user or a group
# usage: resetquota -u username
#        resetquota -g groupname

resetquota() {
        [ "$#" != 2 ] && error "resetquota: wrong number of arguments: $#"
        [ "$1" != "-u" -a "$1" != "-g" ] && error "resetquota: wrong specifier $1 passed"

        count=0
        if at_is_enabled; then
	    timeout=$(at_max_get mds)
        else
	    timeout=$(lctl get_param -n timeout)
        fi

        while [ $((count++)) -lt $timeout ]; do
                $LFS setquota "$1" "$2" -b 0 -B 0 -i 0 -I 0 $MOUNT
                RC=$?
                if [ $RC -ne 0 ]; then
                        if [ $RC -eq 240 ]; then # 240 means -EBUSY
                                log "resetquota is blocked for quota master recovery, retry after 1 sec"
                                sleep 1
                                continue
                        else
                                error "resetquota failed: $RC"
                        fi
                fi
                break
        done

        [ $count -lt $timeout ] || error "resetquota timeout: $timeout"
}

quota_scan() {
        LOCAL_UG=$1
        LOCAL_ID=$2

        if [ "$LOCAL_UG" == "a" -o "$LOCAL_UG" == "u" ]; then
                log "Files for user ($LOCAL_ID):"
                ($LFS find -user $LOCAL_ID $DIR | xargs stat 2>/dev/null)
        fi

        if [ "$LOCAL_UG" == "a" -o "$LOCAL_UG" == "g" ]; then
                log "Files for group ($LOCAL_ID):"
                ($LFS find -group $LOCAL_ID $DIR | xargs stat 2>/dev/null)
        fi
}

quota_error() {
        quota_scan $1 $2
        shift 2
        error "$*"
}

quota_log() {
        quota_scan $1 $2
        shift 2
        log "$*"
}

quota_show_check() {
        LOCAL_BF=$1
        LOCAL_UG=$2
        LOCAL_ID=$3
	PATTERN="`echo $DIR | sed 's/\//\\\\\//g'`"

        $LFS quota -v -$LOCAL_UG $LOCAL_ID $DIR

        if [ "$LOCAL_BF" == "a" -o "$LOCAL_BF" == "b" ]; then
	        USAGE="`$LFS quota -$LOCAL_UG $LOCAL_ID $DIR | awk '/^.*'$PATTERN'.*[[:digit:]+][[:space:]+]/ { print $2 }'`"
                if [ -z $USAGE ]; then
                        quota_error $LOCAL_UG $LOCAL_ID "System is error when query quota for block ($LOCAL_UG:$LOCAL_ID)."
                else
                        [ $USAGE -ne 0 ] && quota_log $LOCAL_UG $LOCAL_ID "System is not clean for block ($LOCAL_UG:$LOCAL_ID:$USAGE)."
                fi
        fi

        if [ "$LOCAL_BF" == "a" -o "$LOCAL_BF" == "f" ]; then
	        USAGE="`$LFS quota -$LOCAL_UG $LOCAL_ID $DIR | awk '/^.*'$PATTERN'.*[[:digit:]+][[:space:]+]/ { print $5 }'`"
                if [ -z $USAGE ]; then
                        quota_error $LOCAL_UG $LOCAL_ID "System is error when query quota for file ($LOCAL_UG:$LOCAL_ID)."
                else
                        [ $USAGE -ne 0 ] && quota_log $LOCAL_UG $LOCAL_ID "System is not clean for file ($LOCAL_UG:$LOCAL_ID:$USAGE)."
                fi
        fi
}

# set quota
quota_init() {
	$LFS quotacheck -ug $DIR

 	resetquota -u $TSTUSR
 	resetquota -g $TSTUSR

        do_nodes $(comma_list $(nodes_list)) "lctl set_param debug=+quota"
}
quota_init

# test for specific quota limitation, qunit, qtune $1=block_quota_limit
test_1_sub() {
        LIMIT=$1
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
        TESTFILE="$DIR/$tdir/$tfile-0"

	wait_delete_completed

        # test for user
        log "  User quota (limit: $LIMIT kbytes)"
        $LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
	sleep 3
	quota_show_check b u $TSTUSR

        $LFS setstripe $TESTFILE -c 1
        chown $TSTUSR.$TSTUSR $TESTFILE

        log "    Write ..."
        stime=`date +%s`
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$(($LIMIT/2)) || quota_error u $TSTUSR "(usr) write failure, but expect success"
        etime=`date +%s`
        delta=$((etime - stime))
        if [ $delta -gt 0 ]; then
                rate=$((BLK_SZ * LIMIT / 2 / delta / 1024))
                [ $rate -gt 1024 ] || error "SLOW IO for $TSTUSR (user): $rate KB/sec"
        fi
        log "    Done"
        log "    Write out of block quota ..."
	# this time maybe cache write,  ignore it's failure
        $RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$(($LIMIT/2)) seek=$(($LIMIT/2)) || true
	# flush cache, ensure noquota flag is setted on client
        cancel_lru_locks osc
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$BUNIT_SZ seek=$LIMIT && quota_error u $TSTUSR "(usr) write success, but expect EDQUOT"

        rm -f $TESTFILE
	sync; sleep 1; sync;
	OST0_UUID=`do_facet ost1 $LCTL dl | grep -m1 obdfilter | awk '{print $((NF-1))}'`
	OST0_QUOTA_USED=`$LFS quota -o $OST0_UUID -u $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`
	echo $OST0_QUOTA_USED
	[ $OST0_QUOTA_USED -ne 0 ] && \
	    ($SHOW_QUOTA_USER; quota_error u $TSTUSR "(usr) quota deleted isn't released")
	$SHOW_QUOTA_USER
        resetquota -u $TSTUSR

        # test for group
	log "--------------------------------------"
        log "  Group quota (limit: $LIMIT kbytes)"
        $LFS setquota -g $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
	sleep 3
        quota_show_check b g $TSTUSR
        TESTFILE="$DIR/$tdir/$tfile-1"

        $LFS setstripe $TESTFILE -c 1
        chown $TSTUSR.$TSTUSR $TESTFILE

        log "    Write ..."
        stime=`date +%s`
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$(($LIMIT/2)) || quota_error g $TSTUSR "(grp) write failure, but expect success"
        etime=`date +%s`
        delta=$((etime - stime))
        rate=$((BLK_SZ * LIMIT / 2 / delta / 1024))
        [ $rate -gt 1024 ] || error "SLOW IO for $TSTUSR (group): $rate KB/sec"
        log "    Done"
        log "    Write out of block quota ..."
	# this time maybe cache write, ignore it's failure
        $RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$(($LIMIT/2)) seek=$(($LIMIT/2)) || true
        cancel_lru_locks osc
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$BUNIT_SZ seek=$LIMIT && quota_error g $TSTUSR "(grp) write success, but expect EDQUOT"

	# cleanup
        rm -f $TESTFILE
	sync; sleep 1; sync;
	OST0_UUID=`do_facet ost1 $LCTL dl | grep -m1 obdfilter | awk '{print $((NF-1))}'`
	OST0_QUOTA_USED=`$LFS quota -o $OST0_UUID -g $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`
	echo $OST0_QUOTA_USED
	[ $OST0_QUOTA_USED -ne 0 ] && \
	    ($SHOW_QUOTA_GROUP; quota_error g $TSTUSR "(grp) quota deleted isn't released")
	$SHOW_QUOTA_GROUP
        resetquota -g $TSTUSR
}

# block hard limit (normal use and out of quota)
test_1() {
	for i in `seq 1 $cycle`; do
	    # define blk_qunit is between 1M and 4M
	    blk_qunit=$(( $RANDOM % 3072 + 1024 ))
	    blk_qtune=$(( $RANDOM % $blk_qunit ))
	    # other osts and mds will occupy at 1M blk quota
	    b_limit=$(( ($RANDOM - 16384) / 8 +  ($OSTCOUNT + 1) * $blk_qunit * 4 ))
	    set_blk_tunesz $blk_qtune
	    set_blk_unitsz $blk_qunit
	    echo "cycle: $i(total $cycle) bunit:$blk_qunit, btune:$blk_qtune, blimit:$b_limit"
	    test_1_sub $b_limit
	    echo "=================================================="
	    set_blk_unitsz $((128 * 1024))
	    set_blk_tunesz $((128 * 1024 / 2))
        done
}
run_test_with_stat 1 "Block hard limit (normal use and out of quota) ==="

# test for specific quota limitation, qunit, qtune $1=block_quota_limit
test_2_sub() {
        LIMIT=$1
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
        TESTFILE="$DIR/$tdir/$tfile-0"

	wait_delete_completed

        # test for user
        log "  User quota (limit: $LIMIT files)"
        $LFS setquota -u $TSTUSR -b 0 -B 0 -i 0 -I $LIMIT $DIR
	sleep 3
        quota_show_check f u $TSTUSR

	log "    Create $LIMIT files ..."
	$RUNAS createmany -m ${TESTFILE} $LIMIT || \
		quota_error u $TSTUSR "(usr) create failure, but expect success"
	log "    Done"
	log "    Create out of file quota ..."
	$RUNAS touch ${TESTFILE}_xxx && \
		quota_error u $TSTUSR "(usr) touch success, but expect EDQUOT"

	unlinkmany ${TESTFILE} $LIMIT
	rm -f ${TESTFILE}_xxx
	sync; sleep 1; sync;

	MDS_UUID=`do_facet $SINGLEMDS $LCTL dl | grep -m1 " mdt " | awk '{print $((NF-1))}'`
	MDS_QUOTA_USED=`$LFS quota -o $MDS_UUID -u $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $4 }'`
	echo $MDS_QUOTA_USED
	[ $MDS_QUOTA_USED -ne 0 ] && \
	    ($SHOW_QUOTA_USER; quota_error u $TSTUSR "(usr) quota deleted isn't released")
	$SHOW_QUOTA_USER
	resetquota -u $TSTUSR

        # test for group
	log "--------------------------------------"
        log "  Group quota (limit: $LIMIT FILE)"
        $LFS setquota -g $TSTUSR -b 0 -B 0 -i 0 -I $LIMIT $DIR
	sleep 3
        quota_show_check f g $TSTUSR
        TESTFILE=$DIR/$tdir/$tfile-1

	log "    Create $LIMIT files ..."
	$RUNAS createmany -m ${TESTFILE} $LIMIT || \
		quota_error g $TSTUSR "(grp) create failure, but expect success"
	log "    Done"
	log "    Create out of file quota ..."
	$RUNAS touch ${TESTFILE}_xxx && \
		quota_error g $TSTUSR "(grp) touch success, but expect EDQUOT"

	unlinkmany ${TESTFILE} $LIMIT
	rm -f ${TESTFILE}_xxx
	sync; sleep 1; sync;

	MDS_UUID=`do_facet $SINGLEMDS $LCTL dl | grep -m1 " mdt " | awk '{print $((NF-1))}'`
	MDS_QUOTA_USED=`$LFS quota -o $MDS_UUID -g $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $4 }'`
	echo $MDS_QUOTA_USED
	[ $MDS_QUOTA_USED -ne 0 ] && \
	    ($SHOW_QUOTA_GROUP; quota_error g $TSTUSR "(grp) quota deleted isn't released")
	$SHOW_QUOTA_GROUP
        resetquota -g $TSTUSR
}

# file hard limit (normal use and out of quota)
test_2() {
	for i in `seq 1 $cycle`; do
	    if [ $i -eq 1 ]; then
		ino_qunit=52
		ino_qtune=41
		i_limit=11
	    else
		# define ino_qunit is between 10 and 100
		ino_qunit=$(( $RANDOM % 90 + 10 ))
		ino_qtune=$(( $RANDOM % $ino_qunit ))
                # RANDOM's maxium is 32767
		i_limit=$(( $RANDOM % 990 + 10 ))
	    fi

            set_file_tunesz $ino_qtune
	    set_file_unitsz $ino_qunit
	    echo "cycle: $i(total $cycle) iunit:$ino_qunit, itune:$ino_qtune, ilimit:$i_limit"
	    test_2_sub $i_limit
	    echo "=================================================="
	    set_file_unitsz 5120
	    set_file_tunesz 2560
        done
}
run_test_with_stat 2 "File hard limit (normal use and out of quota) ==="

test_block_soft() {
	TESTFILE=$1
	TIMER=$(($2 * 3 / 2))
	OFFSET=0

	wait_delete_completed

	echo "    Write to exceed soft limit"
	RUNDD="$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ"
	$RUNDD count=$((BUNIT_SZ+1)) || \
		quota_error a $TSTUSR "write failure, but expect success"
	OFFSET=$((OFFSET + BUNIT_SZ + 1))
        cancel_lru_locks osc

	$SHOW_QUOTA_USER
	$SHOW_QUOTA_GROUP
	$SHOW_QUOTA_INFO_USER
	$SHOW_QUOTA_INFO_GROUP

	echo "    Write before timer goes off"
	$RUNDD count=$BUNIT_SZ seek=$OFFSET || \
		quota_error a $TSTUSR "write failure, but expect success"
	OFFSET=$((OFFSET + BUNIT_SZ))
        cancel_lru_locks osc
	echo "    Done"

        echo "    Sleep $TIMER seconds ..."
        sleep $TIMER

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP
        $SHOW_QUOTA_INFO_USER
        $SHOW_QUOTA_INFO_GROUP

	echo "    Write after timer goes off"
	# maybe cache write, ignore.
	$RUNDD count=$BUNIT_SZ seek=$OFFSET || true
	OFFSET=$((OFFSET + BUNIT_SZ))
        cancel_lru_locks osc
	$RUNDD count=$BUNIT_SZ seek=$OFFSET && \
		quota_error a $TSTUSR "write success, but expect EDQUOT"

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP
        $SHOW_QUOTA_INFO_USER
        $SHOW_QUOTA_INFO_GROUP

	echo "    Unlink file to stop timer"
	rm -f $TESTFILE
	sync; sleep 1; sync
	echo "    Done"

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP
        $SHOW_QUOTA_INFO_USER
        $SHOW_QUOTA_INFO_GROUP

	echo "    Write ..."
	$RUNDD count=$BUNIT_SZ || quota_error a $TSTUSR "write failure, but expect success"
	echo "    Done"

	# cleanup
	rm -f $TESTFILE
	sync; sleep 3; sync;
}

# block soft limit (start timer, timer goes off, stop timer)
test_3() {
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir

        # 1 bunit on mds and 1 bunit on every ost
	LIMIT=$(( $BUNIT_SZ * ($OSTCOUNT + 1) ))
	GRACE=10

	echo "  User quota (soft limit: $LIMIT kbytes  grace: $GRACE seconds)"
	TESTFILE=$DIR/$tdir/$tfile-0

	$LFS setstripe $TESTFILE -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE

	$LFS setquota -t -u --block-grace $GRACE --inode-grace $MAX_IQ_TIME $DIR
	$LFS setquota -u $TSTUSR -b $LIMIT -B 0 -i 0 -I 0 $DIR

	test_block_soft $TESTFILE $GRACE
	resetquota -u $TSTUSR

	echo "  Group quota (soft limit: $LIMIT kbytes  grace: $GRACE seconds)"
	TESTFILE=$DIR/$tdir/$tfile-1

	$LFS setstripe $TESTFILE -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE

	$LFS setquota -t -g --block-grace $GRACE --inode-grace $MAX_IQ_TIME $DIR
	$LFS setquota -g $TSTUSR -b $LIMIT -B 0 -i 0 -I 0 $DIR

	test_block_soft $TESTFILE $GRACE
	resetquota -g $TSTUSR
}
run_test_with_stat 3 "Block soft limit (start timer, timer goes off, stop timer) ==="

test_file_soft() {
	TESTFILE=$1
	LIMIT=$2
	TIMER=$(($3 * 3 / 2))

	wait_delete_completed

	echo "    Create files to exceed soft limit"
	$RUNAS createmany -m ${TESTFILE}_ $((LIMIT + 1)) || \
		quota_error a $TSTUSR "create failure, but expect success"
	sync; sleep 1; sync
	echo "    Done"

	echo "    Create file before timer goes off"
	$RUNAS touch ${TESTFILE}_before || \
		quota_error a $TSTUSR "failed create before timer expired, but expect success"
	sync; sleep 1; sync
	echo "    Done"

	echo "    Sleep $TIMER seconds ..."
	sleep $TIMER

	$SHOW_QUOTA_USER
	$SHOW_QUOTA_GROUP
	$SHOW_QUOTA_INFO_USER
	$SHOW_QUOTA_INFO_GROUP

	echo "    Create file after timer goes off"
	# the least of inode qunit is 2, so there are at most 3(qunit:2+qtune:1)
        # inode quota left here
	$RUNAS touch ${TESTFILE}_after ${TESTFILE}_after1 ${TESTFILE}_after2 || true
	sync; sleep 1; sync
	$RUNAS touch ${TESTFILE}_after3 && \
		quota_error a $TSTUSR "create after timer expired, but expect EDQUOT"
	sync; sleep 1; sync

	$SHOW_QUOTA_USER
	$SHOW_QUOTA_GROUP
	$SHOW_QUOTA_INFO_USER
	$SHOW_QUOTA_INFO_GROUP

	echo "    Unlink files to stop timer"
	find `dirname $TESTFILE` -name "`basename ${TESTFILE}`*" | xargs rm -f
	echo "    Done"

	echo "    Create file"
	$RUNAS touch ${TESTFILE}_xxx || \
		quota_error a $TSTUSR "touch after timer stop failure, but expect success"
	sync; sleep 1; sync
	echo "    Done"

	# cleanup
	rm -f ${TESTFILE}_xxx
	sync; sleep 3; sync;
}

# file soft limit (start timer, timer goes off, stop timer)
test_4a() {	# was test_4
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
	LIMIT=$(($IUNIT_SZ * 10))	# 10 iunits on mds
	TESTFILE=$DIR/$tdir/$tfile-0

	GRACE=5

	echo "  User quota (soft limit: $LIMIT files  grace: $GRACE seconds)"
	$LFS setquota -t -u --block-grace $MAX_DQ_TIME --inode-grace $GRACE $DIR
	$LFS setquota -u $TSTUSR -b 0 -B 0 -i $LIMIT -I 0 $DIR
        quota_show_check f u $TSTUSR

	test_file_soft $TESTFILE $LIMIT $GRACE
	resetquota -u $TSTUSR

	echo "  Group quota (soft limit: $LIMIT files  grace: $GRACE seconds)"
	$LFS setquota -t -g --block-grace $MAX_DQ_TIME --inode-grace $GRACE $DIR
	$LFS setquota -g $TSTUSR -b 0 -B 0 -i $LIMIT -I 0 $DIR
        quota_show_check f g $TSTUSR
	TESTFILE=$DIR/$tdir/$tfile-1

	test_file_soft $TESTFILE $LIMIT $GRACE
	resetquota -g $TSTUSR

	# cleanup
	$LFS setquota -t -u --block-grace $MAX_DQ_TIME --inode-grace $MAX_IQ_TIME $DIR
	$LFS setquota -t -g --block-grace $MAX_DQ_TIME --inode-grace $MAX_IQ_TIME $DIR
}
run_test_with_stat 4a "File soft limit (start timer, timer goes off, stop timer) ==="

test_4b() {	# was test_4a
        GR_STR1="1w3d"
        GR_STR2="1000s"
        GR_STR3="5s"
        GR_STR4="1w2d3h4m5s"
        GR_STR5="5c"
        GR_STR6="1111111111111111"

	wait_delete_completed

        # test of valid grace strings handling
        echo "  Valid grace strings test"
        $LFS setquota -t -u --block-grace $GR_STR1 --inode-grace $GR_STR2 $DIR
        $LFS quota -u -t $DIR | grep "Block grace time: $GR_STR1"
        $LFS setquota -t -g --block-grace $GR_STR3 --inode-grace $GR_STR4 $DIR
        $LFS quota -g -t $DIR | grep "Inode grace time: $GR_STR4"

        # test of invalid grace strings handling
        echo "  Invalid grace strings test"
        ! $LFS setquota -t -u --block-grace $GR_STR4 --inode-grace $GR_STR5 $DIR
        ! $LFS setquota -t -g --block-grace $GR_STR4 --inode-grace $GR_STR6 $DIR

        # cleanup
        $LFS setquota -t -u --block-grace $MAX_DQ_TIME --inode-grace $MAX_IQ_TIME $DIR
        $LFS setquota -t -g --block-grace $MAX_DQ_TIME --inode-grace $MAX_IQ_TIME $DIR
}
run_test_with_stat 4b "Grace time strings handling ==="

# chown & chgrp (chown & chgrp successfully even out of block/file quota)
test_5() {
	mkdir -p $DIR/$tdir
	BLIMIT=$(( $BUNIT_SZ * $((OSTCOUNT + 1)) * 10)) # 10 bunits on each server
	ILIMIT=$(( $IUNIT_SZ * 10 )) # 10 iunits on mds

	wait_delete_completed

	echo "  Set quota limit (0 $BLIMIT 0 $ILIMIT) for $TSTUSR.$TSTUSR"
	$LFS setquota -u $TSTUSR -b 0 -B $BLIMIT -i 0 -I $ILIMIT $DIR
	$LFS setquota -g $TSTUSR -b 0 -B $BLIMIT -i 0 -I $ILIMIT $DIR
        quota_show_check a u $TSTUSR
        quota_show_check a g $TSTUSR

	echo "  Create more than $ILIMIT files and more than $BLIMIT kbytes ..."
	createmany -m $DIR/$tdir/$tfile-0_ $((ILIMIT + 1)) || \
		error "touch failure, expect success"
	dd if=/dev/zero of=$DIR/$tdir/$tfile-0_1 bs=$BLK_SZ count=$((BLIMIT+1)) || error "write failure, expect success"

	echo "  Chown files to $TSTUSR.$TSTUSR ..."
	for i in `seq 0 $ILIMIT`; do
	chown $TSTUSR.$TSTUSR $DIR/$tdir/$tfile-0_$i || \
			quota_error a $TSTUSR "chown failure, but expect success"
	done

	# cleanup
	unlinkmany $DIR/$tdir/$tfile-0_ $((ILIMIT + 1))
	sync; sleep 3; sync;

	resetquota -u $TSTUSR
	resetquota -g $TSTUSR
}
run_test_with_stat 5 "Chown & chgrp successfully even out of block/file quota ==="

# block quota acquire & release
test_6() {
	if [ $OSTCOUNT -lt 2 ]; then
		skip "$OSTCOUNT < 2, too few osts"
		return 0;
	fi

	wait_delete_completed

	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir

	LIMIT=$((BUNIT_SZ * (OSTCOUNT + 1) * 5)) # 5 bunits per server
	FILEA="$DIR/$tdir/$tfile-0_a"
	FILEB="$DIR/$tdir/$tfile-0_b"

	echo "  Set block limit $LIMIT kbytes to $TSTUSR.$TSTUSR"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
	$LFS setquota -g $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
        quota_show_check b u $TSTUSR
        quota_show_check b g $TSTUSR

	echo "  Create filea on OST0 and fileb on OST1"
	$LFS setstripe $FILEA -i 0 -c 1
	$LFS setstripe $FILEB -i 1 -c 1
	chown $TSTUSR.$TSTUSR $FILEA
	chown $TSTUSR.$TSTUSR $FILEB

	echo "  Exceed quota limit ..."
        RUNDD="$RUNAS dd if=/dev/zero of=$FILEA bs=$BLK_SZ"
        $RUNDD count=$((LIMIT - BUNIT_SZ * OSTCOUNT)) || \
		quota_error a $TSTUSR "write filea failure, but expect success"

        cancel_lru_locks osc
        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP
        $RUNDD seek=$LIMIT count=$((BUNIT_SZ * OSTCOUNT)) && \
		quota_error a $TSTUSR "write filea success, but expect EDQUOT"
        cancel_lru_locks osc
	echo "  Write to OST1 return EDQUOT"
	# this write maybe cache write, ignore it's failure
        RUNDD="$RUNAS dd if=/dev/zero of=$FILEB bs=$BLK_SZ"
        $RUNDD count=$(($BUNIT_SZ * 2)) || true
        cancel_lru_locks osc
        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP
        $RUNDD count=$((BUNIT_SZ * 2)) seek=$((BUNIT_SZ *2)) && \
		quota_error a $TSTUSR "write fileb success, but expect EDQUOT"

	echo "  Remove filea to let OST0 release quota"
	rm -f $FILEA

        if at_is_enabled; then
	    timeout=$(at_max_get mds)
        else
	    timeout=$(lctl get_param -n timeout)
        fi
        count=$((timeout / 5))
        OST0_UUID=`do_facet ost1 $LCTL dl | grep -m1 obdfilter | awk '{print $((NF-1))}'`

        while [ $((count--)) -gt 0 ]; do
                sync && sleep 5

	        OST0_QUOTA_HOLD=`$LFS quota -o $OST0_UUID -u $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $3 }'`
                if [ -z $OST0_QUOTA_HOLD ]; then
                        error "System is error when query quota for block (U:$TSTUSR)."
                else
                        [ $OST0_QUOTA_HOLD -gt $BUNIT_SZ ] && continue
                fi

                break
        done

        [ ! $count -gt 0 ] && error "Release quota for block timeout (U:$TSTUSR)."
        $SHOW_QUOTA_USER

        while [ $((count--)) -gt 0 ]; do
                sync && sleep 5

	        OST0_QUOTA_HOLD=`$LFS quota -o $OST0_UUID -g $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $3 }'`
                if [ -z $OST0_QUOTA_HOLD ]; then
                        error "System is error when query quota for block (G:$TSTUSR)."
                else
                        [ $OST0_QUOTA_HOLD -gt $BUNIT_SZ ] && continue
                fi

                break
        done

        [ ! $count -gt 0 ] && error "Release quota for block timeout (G:$TSTUSR)."
        $SHOW_QUOTA_GROUP

	echo "  Write to OST1"
	$RUNDD count=$((LIMIT - BUNIT_SZ * OSTCOUNT)) || \
		quota_error a $TSTUSR "write fileb failure, expect success"
	echo "  Done"

	# cleanup
	rm -f $FILEB
	sync; sleep 3; sync;

	resetquota -u $TSTUSR
	resetquota -g $TSTUSR
	return 0
}
run_test_with_stat 6 "Block quota acquire & release ========="

# quota recovery (block quota only by now)
test_7()
{
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir

	wait_delete_completed

	LIMIT=$(( $BUNIT_SZ * $(($OSTCOUNT + 1)) ))
	TESTFILE="$DIR/$tdir/$tfile-0"

	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR

	$LFS setstripe $TESTFILE -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE

	echo "  Write to OST0..."
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$BUNIT_SZ || \
		quota_error u $TSTUSR "write failure, but expect success"

	#define OBD_FAIL_OBD_DQACQ               0x604
	lustre_fail mds  0x604
	echo "  Remove files on OST0"
	rm -f $TESTFILE
	lustre_fail mds  0

	echo "  Trigger recovery..."
	OSC0_UUID="`$LCTL dl | awk '$3 ~ /osc/ { print $1 }'`"
	for i in $OSC0_UUID; do
		$LCTL --device $i activate || error "activate osc failed!"
	done

	# sleep a while to wait for recovery done
	sleep 20

	# check limits
	PATTERN="`echo $DIR | sed 's/\//\\\\\//g'`"
	TOTAL_LIMIT="`$LFS quota -v -u $TSTUSR $DIR | awk '/^.*'$PATTERN'.*[[:digit:]+][[:space:]+]/ { print $4 }'`"
	[ $TOTAL_LIMIT -eq $LIMIT ] || error "total limits not recovery!"
	echo "  total limits = $TOTAL_LIMIT"

        OST0_UUID=`do_facet ost1 "$LCTL dl | grep -m1 obdfilter" | awk '{print $((NF-1))}'`
        [ -z "$OST0_UUID" ] && OST0_UUID=`do_facet ost1 "$LCTL dl | grep -m1 obdfilter" | awk '{print $((NF-1))}'`
	OST0_LIMIT="`$LFS quota -o $OST0_UUID -u $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $3 }'`"
	[ $OST0_LIMIT -eq $BUNIT_SZ ] || error "high limits not released!"
	echo "  limits on $OST0_UUID = $OST0_LIMIT"

	# cleanup
	resetquota -u $TSTUSR
}
run_test_with_stat 7 "Quota recovery (only block limit) ======"

# run dbench with quota enabled
test_8() {
	mkdir -p $DIR/$tdir
	BLK_LIMIT=$((100 * 1024 * 1024)) # 100G
	FILE_LIMIT=1000000

	wait_delete_completed

	echo "  Set enough high limit for user: $TSTUSR"
	$LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $DIR
	echo "  Set enough high limit for group: $TSTUSR"
	$LFS setquota -g $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $DIR

	chmod 0777 $DIR/$tdir
	local duration=""
	[ "$SLOW" = "no" ] && duration=" -t 120"
	$RUNAS bash rundbench -D $DIR/$tdir 3 $duration || quota_error a $TSTUSR "dbench failed!"

        rm -rf $DIR/$tdir
	sync; sleep 3; sync;

	return 0
}
run_test_with_stat 8 "Run dbench with quota enabled ==========="

# run for fixing bug10707, it needs a big room. test for 64bit
KB=1024
GB=$((KB * 1024 * 1024))
# Use this as dd bs to decrease time
# inode->i_blkbits = min(PTLRPC_MAX_BRW_BITS+1, LL_MAX_BLKSIZE_BITS);
blksize=$((1 << 21)) # 2Mb
size_file=$((GB * 9 / 2))
# this check is just for test9 and test10
OST0_MIN=4900000 #4.67G
check_whether_skip () {
    OST0_SIZE=`$LFS df $DIR | awk '/\[OST:0\]/ {print $4}'`
    log "OST0_SIZE: $OST0_SIZE  required: $OST0_MIN"
    if [ $OST0_SIZE -lt $OST0_MIN ]; then
	echo "WARN: OST0 has less than $OST0_MIN free, skip this test."
	return 0
    else
	return 1
    fi
}

test_9() {
	check_whether_skip && return 0

	wait_delete_completed

	set_blk_tunesz 512
	set_blk_unitsz 1024

	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
        TESTFILE="$DIR/$tdir/$tfile-0"

        BLK_LIMIT=$((100 * KB * KB)) # 100G
        FILE_LIMIT=1000000
        echo "  Set block limit $BLK_LIMIT kbytes to $TSTUSR.$TSTUSR"

        log "  Set enough high limit(block:$BLK_LIMIT; file: $FILE_LIMIT) for user: $TSTUSR"
        $LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $DIR
        log "  Set enough high limit(block:$BLK_LIMIT; file: $FILE_LIMIT) for group: $TSTUSR"
        $LFS setquota -g $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $DIR

        quota_show_check a u $TSTUSR
        quota_show_check a g $TSTUSR

        echo "  Set stripe"
	$LFS setstripe $TESTFILE -c 1
        touch $TESTFILE
        chown $TSTUSR.$TSTUSR $TESTFILE

        log "    Write the big file of 4.5G ..."
        $RUNAS dd if=/dev/zero of=$TESTFILE  bs=$blksize count=$((size_file / blksize)) || \
	       quota_error a $TSTUSR "(usr) write 4.5G file failure, but expect success"

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP

        log "    delete the big file of 4.5G..."
        $RUNAS rm -f $TESTFILE
	sync; sleep 3; sync;

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP

        RC=$?

	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))

        return $RC
}
run_test_with_stat 9 "run for fixing bug10707(64bit) ==========="

# run for fixing bug10707, it need a big room. test for 32bit
# 2.0 version does not support 32 bit qd_count, so such test is obsolete.
test_10() {
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
	check_whether_skip && return 0

	wait_delete_completed

	set_blk_tunesz 512
	set_blk_unitsz 1024

	# make qd_count 32 bit
	lustre_fail mds_ost 0xA00

	TESTFILE="$DIR/$tdir/$tfile-0"

	BLK_LIMIT=$((100 * KB * KB)) # 100G
	FILE_LIMIT=1000000

	log "  Set enough high limit(block:$BLK_LIMIT; file: $FILE_LIMIT) for user: $TSTUSR"
	$LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $DIR
	log "  Set enough high limit(block:$BLK_LIMIT; file: $FILE_LIMIT) for group: $TSTUSR"
	$LFS setquota -g $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $DIR

        quota_show_check a u $TSTUSR
        quota_show_check a g $TSTUSR

	echo "  Set stripe"
	$LFS setstripe $TESTFILE -c 1
	touch $TESTFILE
	chown $TSTUSR.$TSTUSR $TESTFILE

        log "    Write the big file of 4.5 G ..."
        $RUNAS dd if=/dev/zero of=$TESTFILE  bs=$blksize count=$((size_file / blksize)) || \
		quota_error a $TSTUSR "(usr) write 4.5 G file failure, but expect success"

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP

        log "    delete the big file of 4.5 G..."
        $RUNAS rm -f $TESTFILE
	sync; sleep 3; sync;

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP

	RC=$?

	# make qd_count 64 bit
	lustre_fail mds_ost 0

	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))

	return $RC
}
#run_test_with_stat 10 "run for fixing bug10707(32bit) ==========="

# test a deadlock between quota and journal b=11693
test_12() {
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir

	[ "$(grep $DIR2 /proc/mounts)" ] || mount_client $DIR2 || \
		{ skip "Need lustre mounted on $MOUNT2 " && retutn 0; }

	LIMIT=$(( $BUNIT_SZ * $(($OSTCOUNT + 1)) * 10)) # 10 bunits each sever
	TESTFILE="$DIR/$tdir/$tfile-0"
	TESTFILE2="$DIR2/$tdir/$tfile-1"

	wait_delete_completed

	echo "   User quota (limit: $LIMIT kbytes)"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR

	$LFS setstripe $TESTFILE -i 0 -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE
	$LFS setstripe $TESTFILE2 -i 0 -c 1
        chown $TSTUSR2.$TSTUSR2 $TESTFILE2

	#define OBD_FAIL_OST_HOLD_WRITE_RPC      0x21f
	#define OBD_FAIL_SOME        0x10000000 /* fail N times */
	lustre_fail ost $((0x0000021f | 0x10000000)) 1

	echo "   step1: write out of block quota ..."
	$RUNAS2 dd if=/dev/zero of=$TESTFILE2 bs=$BLK_SZ count=102400 &
	DDPID1=$!
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$(($LIMIT*2)) &
	DDPID=$!

	echo  "   step2: testing ......"
	count=0
	while [ true ]; do
	    if ! ps -p ${DDPID1} > /dev/null 2>&1; then break; fi
	    count=$[count+1]
	    if [ $count -gt 64 ]; then
		lustre_fail ost 0
		quota_error u $TSTUSR2 "dd should be finished!"
	    fi
	    sleep 1
	done
	echo "(dd_pid=$DDPID1, time=$count)successful"

	#Recover fail_loc and dd will finish soon
	lustre_fail ost 0

	echo  "   step3: testing ......"
	count=0
	while [ true ]; do
	    if ! ps -p ${DDPID} > /dev/null 2>&1; then break; fi
	    count=$[count+1]
	    if [ $count -gt 150 ]; then
		quota_error u $TSTUSR "dd should be finished!"
	    fi
	    sleep 1
	done
	echo "(dd_pid=$DDPID, time=$count)successful"

	rm -f $TESTFILE $TESTFILE2
        sync; sleep 3; sync;

        resetquota -u $TSTUSR
}
run_test_with_stat 12 "test a deadlock between quota and journal ==="

# test multiple clients write block quota b=11693
test_13() {
	mkdir -p $DIR/$tdir
	wait_delete_completed

	# one OST * 10 + (mds + other OSTs)
	LIMIT=$((BUNIT_SZ * 10 + (BUNIT_SZ * OSTCOUNT)))
	TESTFILE="$DIR/$tdir/$tfile"

	echo "   User quota (limit: $LIMIT kbytes)"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
        quota_show_check b u $TSTUSR

	$LFS setstripe $TESTFILE -i 0 -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE
	$LFS setstripe $TESTFILE.2 -i 0 -c 1
        chown $TSTUSR.$TSTUSR $TESTFILE.2

	echo "   step1: write out of block quota ..."
	# one bunit will give mds
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$[($LIMIT - $BUNIT_SZ) / 2] &
	DDPID=$!
	$RUNAS dd if=/dev/zero of=$TESTFILE.2 bs=$BLK_SZ count=$[($LIMIT - $BUNIT_SZ) / 2] &
	DDPID1=$!

	echo  "   step2: testing ......"
	count=0
	while [ true ]; do
	    if ! ps -p ${DDPID} > /dev/null 2>&1; then break; fi
	    count=$[count+1]
	    if [ $count -gt 64 ]; then
		quota_error u $TSTUSR "dd should be finished!"
	    fi
	    sleep 1
	done
	echo "(dd_pid=$DDPID, time=$count)successful"

	count=0
	while [ true ]; do
	    if ! ps -p ${DDPID1} > /dev/null 2>&1 ; then break; fi
	    count=$[count+1]
	    if [ $count -gt 64 ]; then
		quota_error u $TSTUSR "dd should be finished!"
	    fi
	    sleep 1
	done
	echo "(dd_pid=$DDPID1, time=$count)successful"

	sync; sleep 5; sync;

	echo  "   step3: checking ......"
	fz=`stat -c %s $TESTFILE`
	fz2=`stat -c %s $TESTFILE.2`
	$SHOW_QUOTA_USER
	[ $((fz + fz2)) -lt $((BUNIT_SZ * BLK_SZ * 10)) ] && \
                quota_error u $TSTUSR "files too small $fz + $fz2 < $((BUNIT_SZ * BLK_SZ * 10))"

	rm -f $TESTFILE $TESTFILE.2
	sync; sleep 3; sync;

	resetquota -u $TSTUSR
}
run_test_with_stat 13 "test multiple clients write block quota ==="

check_if_quota_zero(){
        line=`$LFS quota -v -$1 $2 $DIR | wc -l`
	for i in `seq 3 $line`; do
	    if [ $i -eq 3 ]; then
		field="3 4 6 7"
	    else
		field="3 5"
	    fi
	    for j in $field; do
		tmp=`$LFS quota -v -$1 $2 $DIR | sed -n ${i}p |
                     awk  '{print $'"$j"'}'`
		[ -n "$tmp" ] && [ $tmp -ne 0 ] && $LFS quota -v -$1 $2 $DIR && \
		    error "quota on $2 isn't clean"
	    done
	done
	echo "pass check_if_quota_zero"
}

test_14a() {	# was test_14 b=12223 -- setting quota on root
	TESTFILE="$DIR/$tdir/$tfile"

        # reboot the lustre
        sync; sleep 5; sync
        cleanup_and_setup_lustre
        quota_init

	mkdir -p $DIR/$tdir

	# out of root's file and block quota
	$LFS setquota -u root -b 10 -B 10 -i 10 -I 10 $DIR
	createmany -m ${TESTFILE} 20 || \
	    quota_error u root "unexpected: user(root) create files failly!"
	dd if=/dev/zero of=$TESTFILE bs=4k count=4096 || \
	    quota_error u root "unexpected: user(root) write files failly!"
	chmod 666 $TESTFILE
	$RUNAS dd if=/dev/zero of=${TESTFILE} seek=4096 bs=4k count=4096 && \
	    quota_error u root "unexpected: user(quota_usr) write a file successfully!"

	# trigger the llog
	chmod 777 $DIR
	for i in `seq 1 10`; do $RUNAS touch ${TESTFILE}a_$i; done
	for i in `seq 1 10`; do $RUNAS rm -f ${TESTFILE}a_$i; done

	# do the check
	dmesg | tail | grep "\-122" |grep llog_obd_origin_add && error "err -122 not found in dmesg"
	resetquota -u root
	#check_if_quota_zero u root

	# clean
	unlinkmany ${TESTFILE} 15
	rm -f $TESTFILE
	sync; sleep 3; sync;
}
run_test_with_stat 14a "test setting quota on root ==="

test_15(){
        LIMIT=$((24 * 1024 * 1024 * 1024 * 1024)) # 24 TB
        PATTERN="`echo $DIR | sed 's/\//\\\\\//g'`"

	wait_delete_completed

        # test for user
        $LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
        TOTAL_LIMIT="`$LFS quota -v -u $TSTUSR $DIR | awk '/^.*'$PATTERN'.*[[:digit:]+][[:space:]+]/ { print $4 }'`"
        [ $TOTAL_LIMIT -eq $LIMIT ] || error "  (user)total limits = $TOTAL_LIMIT; limit = $LIMIT, failed!"
        echo "  (user)total limits = $TOTAL_LIMIT; limit = $LIMIT, successful!"
        resetquota -u $TSTUSR

        # test for group
        $LFS setquota -g $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
        TOTAL_LIMIT="`$LFS quota -v -g $TSTUSR $DIR | awk '/^.*'$PATTERN'.*[[:digit:]+][[:space:]+]/ { print $4 }'`"
        [ $TOTAL_LIMIT -eq $LIMIT ] || error "  (group)total limits = $TOTAL_LIMIT; limit = $LIMIT, failed!"
        echo "  (group)total limits = $TOTAL_LIMIT; limit = $LIMIT, successful!"
        resetquota -g $TSTUSR
        $LFS quotaoff -ug $DIR
        do_facet $SINGLEMDS "lctl set_param lquota.mdd_obd-${FSNAME}-MDT*.quota_type=ug" | grep "error writing" && \
                error "fail to set version for $SINGLEMDS"
        for j in `seq $OSTCOUNT`; do
                do_facet ost$j "lctl set_param lquota.${FSNAME}-OST*.quota_type=ug" | grep "error writing" && \
                        error "fail to set version for ost$j"
        done

        echo "invalidating quota files"
        $LFS quotainv -ug $DIR
        $LFS quotainv -ugf $DIR
        $LFS quotacheck -ug $DIR
}
run_test_with_stat 15 "set block quota more than 4T ==="

# $1=u/g $2=with qunit adjust or not
test_16_tub() {
	LIMIT=$(( $BUNIT_SZ * $(($OSTCOUNT + 1)) * 4))
	TESTFILE="$DIR/$tdir/$tfile"
	mkdir -p $DIR/$tdir

	wait_delete_completed

	echo "  User quota (limit: $LIMIT kbytes)"
	if [ $1 == "u" ]; then
	    $LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
            quota_show_check b u $TSTUSR
	else
	    $LFS setquota -g $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
            quota_show_check b g $TSTUSR
	fi

	$LFS setstripe $TESTFILE -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE

	echo "    Write ..."
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$((BUNIT_SZ * 4)) || \
	    quota_error a $TSTUSR "(usr) write failure, but expect success"
	echo "    Done"
	echo "    Write out of block quota ..."
	# this time maybe cache write,  ignore it's failure
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$BUNIT_SZ seek=$((BUNIT_SZ * 4)) || true
	# flush cache, ensure noquota flag is setted on client
        cancel_lru_locks osc
	if [ $2 -eq 1 ]; then
	    $RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$BUNIT_SZ seek=$((BUNIT_SZ * 4)) || \
		quota_error a $TSTUSR "(write failure, but expect success"
	else
	    $RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$BUNIT_SZ seek=$((BUNIT_SZ * 4)) && \
		quota_error a $TSTUSR "(write success, but expect EDQUOT"
	fi

	rm -f $TESTFILE
	sync; sleep 3; sync;
	resetquota -$1 $TSTUSR
}

# test without adjusting qunit
# 2.0 version does not support WITHOUT_CHANGE_QS, so such test is obsolete
test_16 () {
	set_blk_tunesz $((BUNIT_SZ * 2))
	set_blk_unitsz $((BUNIT_SZ * 4))
	for i in u g; do
	    for j in 0 1; do
                # define OBD_FAIL_QUOTA_WITHOUT_CHANGE_QS    0xA01
		echo " grp/usr: $i, adjust qunit: $j"
		echo "-------------------------------"
		[ $j -eq 1 ] && lustre_fail mds_ost 0
		[ $j -eq 0 ] && lustre_fail mds_ost 0xA01
		test_16_tub $i $j
	    done
	done
	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))
}
#run_test_with_stat 16 "test without adjusting qunit"

# run for fixing bug14526, failed returned quota reqs shouldn't ruin lustre.
test_17() {
	set_blk_tunesz 512
	set_blk_unitsz 1024

	wait_delete_completed

        #define OBD_FAIL_QUOTA_RET_QDATA | OBD_FAIL_ONCE
	lustre_fail ost 0x80000A02

	TESTFILE="$DIR/$tdir/$tfile-a"
	TESTFILE2="$DIR/$tdir/$tfile-b"
	mkdir -p $DIR/$tdir

	BLK_LIMIT=$((100 * 1024)) # 100M

	log "  Set enough high limit(block:$BLK_LIMIT) for user: $TSTUSR"
	$LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I 0 $DIR
	log "  Set enough high limit(block:$BLK_LIMIT) for group: $TSTUSR"
	$LFS setquota -g $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I 0 $DIR

        quota_show_check b u $TSTUSR
        quota_show_check b g $TSTUSR

	touch $TESTFILE
	chown $TSTUSR.$TSTUSR $TESTFILE
	touch $TESTFILE2
	chown $TSTUSR.$TSTUSR $TESTFILE2

	log "    Write the test file1 ..."
	$RUNAS dd if=/dev/zero of=$TESTFILE  bs=$BLK_SZ count=$(( 10 * 1024 )) \
	    || quota_error a $TSTUSR "write 10M file failure"

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP

	log "    write the test file2 ..."
	$RUNAS dd if=/dev/zero of=$TESTFILE2  bs=$BLK_SZ count=$(( 10 * 1024 )) \
	    || quota_error a $TSTUSR "write 10M file failure"

        $SHOW_QUOTA_USER
        $SHOW_QUOTA_GROUP

	rm -f $TESTFILE $TESTFILE2
	RC=$?
	sync; sleep 3; sync;

	# make qd_count 64 bit
	lustre_fail ost 0

	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))

	resetquota -u $TSTUSR
	resetquota -g $TSTUSR

	return $RC
}
run_test_with_stat 17 "run for fixing bug14526 ==========="

# test when mds takes a long time to handle a quota req so that
# the ost has dropped it, the ost still could work well b=14840
test_18() {
	LIMIT=$((100 * 1024 * 1024)) # 100G
	TESTFILE="$DIR/$tdir/$tfile"
	mkdir -p $DIR/$tdir

	wait_delete_completed

	set_blk_tunesz 512
	set_blk_unitsz 1024

	log "   User quota (limit: $LIMIT kbytes)"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $MOUNT
        quota_show_check b u $TSTUSR

	$LFS setstripe $TESTFILE -i 0 -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE

	#define OBD_FAIL_MDS_BLOCK_QUOTA_REQ      0x13c
	lustre_fail mds 0x13c

	log "   step1: write 100M block ..."
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$((1024 * 100)) &
	DDPID=$!

        sleep 5
        lustre_fail mds 0

	echo  "   step2: testing ......"
	count=0
	if at_is_enabled; then
	    timeout=$(at_max_get mds)
	else
	    timeout=$(lctl get_param -n timeout)
	fi
	while [ true ]; do
	    if ! ps -p ${DDPID} > /dev/null 2>&1; then break; fi
	    count=$[count+1]
	    if [ $count -gt $((4 * $timeout)) ]; then
		quota_error u $TSTUSR "count=$count dd should be finished!"
	    fi
	    sleep 1
	done
        log "(dd_pid=$DDPID, time=$count, timeout=$timeout)"
        sync
        cancel_lru_locks mdc
        cancel_lru_locks osc

        testfile_size=$(stat -c %s $TESTFILE)
        [ $testfile_size -ne $((BLK_SZ * 1024 * 100)) ] && \
	    quota_error u $TSTUSR "expect $((BLK_SZ * 1024 * 100)), got ${testfile_size}. Verifying file failed!"
        $SHOW_QUOTA_USER
        rm -f $TESTFILE
        sync

	resetquota -u $TSTUSR
	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))
}
run_test_with_stat 18 "run for fixing bug14840 ==========="

# test when mds drops a quota req, the ost still could work well b=14840
test_18a() {
        LIMIT=$((100 * 1024 * 1024)) # 100G
	TESTFILE="$DIR/$tdir/$tfile-a"
	mkdir -p $DIR/$tdir

	wait_delete_completed

	set_blk_tunesz 512
	set_blk_unitsz 1024

	log "   User quota (limit: $LIMIT kbytes)"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $MOUNT
        quota_show_check b u $TSTUSR

	$LFS setstripe $TESTFILE -i 0 -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE

	#define OBD_FAIL_MDS_DROP_QUOTA_REQ | OBD_FAIL_ONCE   0x8000013d
	lustre_fail mds 0x8000013d

	log "   step1: write 100M block ..."
	$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ count=$((1024 * 100)) &
	DDPID=$!

	echo  "   step2: testing ......"
	count=0
	if at_is_enabled; then
	    timeout=$(at_max_get mds)
	else
	    timeout=$(lctl get_param -n timeout)
	fi
	while [ true ]; do
	    if ! ps -p ${DDPID} > /dev/null 2>&1; then break; fi
	    count=$[count+1]
	    if [ $count -gt $((6 * $timeout)) ]; then
		lustre_fail mds 0
		quota_error u $TSTUSR "count=$count dd should be finished!"
	    fi
	    sleep 1
	done
        log "(dd_pid=$DDPID, time=$count, timeout=$timeout)"

        lustre_fail mds 0
	rm -f $TESTFILE
	sync

	resetquota -u $TSTUSR
	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))
}
run_test_with_stat 18a "run for fixing bug14840 ==========="

# test when mds do failover, the ost still could work well without trigger
# watchdog b=14840
test_18bc_sub() {
        type=$1

        LIMIT=$((110 * 1024 )) # 110M
        TESTFILE="$DIR/$tdir/$tfile"
        mkdir -p $DIR/$tdir

        wait_delete_completed

        set_blk_tunesz 512
        set_blk_unitsz 1024

        log "   User quota (limit: $LIMIT kbytes)"
        $LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $MOUNT
        quota_show_check b u $TSTUSR

        $LFS setstripe $TESTFILE -i 0 -c 1
        chown $TSTUSR.$TSTUSR $TESTFILE

        timeout=$(sysctl -n lustre.timeout)

	if [ $type = "directio" ]; then
	    log "   write 100M block(directio) ..."
	    $RUNAS $DIRECTIO write $TESTFILE 0 100 $((BLK_SZ * 1024)) &
	else
	    log "   write 100M block(normal) ..."
	    $RUNAS dd if=/dev/zero of=$TESTFILE bs=$((BLK_SZ * 1024)) count=100 &
	fi

        DDPID=$!
        do_facet $SINGLEMDS "$LCTL conf_param ${FSNAME}-MDT*.mdd.quota_type=ug"

	log "failing mds for $((2 * timeout)) seconds"
        fail $SINGLEMDS $((2 * timeout))

        # check if quotaon successful
        $LFS quota -u $TSTUSR $MOUNT 2>&1 | grep -q "quotas are not enabled"
        if [ $? -eq 0 ]; then
            error "quotaon failed!"
            rm -rf $TESTFILE
            return
        fi

        count=0
	if at_is_enabled; then
	    timeout=$(at_max_get mds)
        else
	    timeout=$(lctl get_param -n timeout)
        fi
        while [ true ]; do
	    if ! ps -p ${DDPID} > /dev/null 2>&1; then break; fi
            if [ $((++count % (2 * timeout) )) -eq 0 ]; then
                log "it took $count second"
            fi
            sleep 1
        done
        log "(dd_pid=$DDPID, time=$count, timeout=$timeout)"
        sync
        cancel_lru_locks mdc
        cancel_lru_locks osc

        testfile_size=$(stat -c %s $TESTFILE)
        [ $testfile_size -ne $((BLK_SZ * 1024 * 100)) ] && \
	    quota_error u $TSTUSR "expect $((BLK_SZ * 1024 * 100)), got ${testfile_size}. Verifying file failed!"
        $SHOW_QUOTA_USER
        rm -f $TESTFILE
        sync

	resetquota -u $TSTUSR
	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))
}

# test when mds does failover, the ost still could work well
# this test shouldn't trigger watchdog b=14840
test_18b() {
	test_18bc_sub normal
	test_18bc_sub directio
	# check if watchdog is triggered
	do_facet ost1 dmesg > $TMP/lustre-log-${TESTNAME}.log
	watchdog=`awk '/test 18b/ {start = 1;}
	               /Watchdog triggered/ {
			       if (start) {
				       print;
			       }
		       }' $TMP/lustre-log-${TESTNAME}.log`
	[ `echo "$watchdog" | wc -l` -ge 3 ] && error "$watchdog"
	rm -f $TMP/lustre-log-${TESTNAME}.log
}
run_test_with_stat 18b "run for fixing bug14840(mds failover, no watchdog) ==========="

# test when mds does failover, the ost still could work well
# this test will prevent OST_DISCONNET from happening b=14840
test_18c() {
	# define OBD_FAIL_OST_DISCONNECT_NET 0x202(disable ost_disconnect for osts)
	lustre_fail ost  0x202
	test_18bc_sub normal
	test_18bc_sub directio
	lustre_fail ost  0
}
run_test_with_stat 18c "run for fixing bug14840(mds failover, OST_DISCONNECT is disabled) ==========="

run_to_block_limit() {
	local LIMIT=$((($OSTCOUNT + 1) * $BUNIT_SZ))
	local TESTFILE=$1
	wait_delete_completed

	# set 1 Mb quota unit size
	set_blk_tunesz 512
	set_blk_unitsz 1024

	# bind file to a single OST
	$LFS setstripe -c 1 $TESTFILE
	chown $TSTUSR.$TSTUSR $TESTFILE

	echo "  User quota (limit: $LIMIT kbytes)"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $MOUNT
        quota_show_check b u $TSTUSR
	echo "  Updating quota limits"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $MOUNT
        quota_show_check b u $TSTUSR

	RUNDD="$RUNAS dd if=/dev/zero of=$TESTFILE bs=$BLK_SZ"
	$RUNDD count=$BUNIT_SZ || quota_error u $TSTUSR "(usr) write failure, but expect success"
	# for now page cache of TESTFILE may still be dirty,
	# let's push it to the corresponding OST, this will also
	# cache NOQUOTA on the client from OST's reply
	cancel_lru_locks osc
	$RUNDD seek=$BUNIT_SZ && quota_error u $TSTUSR "(usr) write success, should be EDQUOT"
}

test_19() {
	# 1 Mb bunit per each MDS/OSS
	local TESTFILE="$DIR/$tdir/$tfile"
	mkdir -p $DIR/$tdir

	run_to_block_limit $TESTFILE
	$SHOW_QUOTA_USER

	# cleanup
	rm -f $TESTFILE
	resetquota -u $TSTUSR

	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))

}
run_test_with_stat 19 "test if administrative limits updates do not zero operational limits (14790) ==="

test_20()
{
        LSTR=(1t 2g 3m 4k) # limits strings
        LVAL=($[1*1024*1024*1024] $[2*1024*1024] $[3*1024*1024] $[4*1024]) # limits values

        $LFS setquota -u $TSTUSR --block-softlimit ${LSTR[0]} \
                                 $MOUNT || error "could not set quota limits"

        $LFS setquota -u $TSTUSR --block-hardlimit ${LSTR[1]} \
                                 --inode-softlimit ${LSTR[2]} \
                                 --inode-hardlimit ${LSTR[3]} \
                                 $MOUNT || error "could not set quota limits"

        ($LFS quota -v -u $TSTUSR $MOUNT  | \
            grep -E '^ *'$MOUNT' *[0-9]+\** *'${LVAL[0]}' *'${LVAL[1]}' *[0-9]+\** *'${LVAL[2]}' *'${LVAL[3]}) \
                 || error "lfs quota output is unexpected"

        resetquota -u $TSTUSR
}
run_test_with_stat 20 "test if setquota specifiers work properly (15754)"

test_21_sub() {
	local testfile=$1
	local blk_number=$2
	local seconds=$3

	time=$(($(date +%s) + seconds))
	while [ $(date +%s) -lt $time ]; do
	    $RUNAS dd if=/dev/zero of=$testfile  bs=$BLK_SZ count=$blk_number > /dev/null 2>&1
	    rm -f $testfile
	done
}

# run for fixing bug16053, setquota shouldn't fail when writing and
# deleting are happening
test_21() {
	set_blk_tunesz 512
	set_blk_unitsz 1024

	wait_delete_completed

	TESTFILE="$DIR/$tdir/$tfile"

	BLK_LIMIT=$((10 * 1024 * 1024)) # 10G
	FILE_LIMIT=1000000

	log "  Set enough high limit(block:$BLK_LIMIT; file: $FILE_LIMIT) for user: $TSTUSR"
	$LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $MOUNT
	log "  Set enough high limit(block:$BLK_LIMIT; file: $FILE_LIMIT) for group: $TSTUSR"
	$LFS setquota -g $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I $FILE_LIMIT $MOUNT

	# repeat writing on a 1M file
	test_21_sub ${TESTFILE}_1 1024 30 &
	DDPID1=$!
	# repeat writing on a 128M file
	test_21_sub ${TESTFILE}_2 $((1024 * 128)) 30 &
	DDPID2=$!

	time=$(($(date +%s) + 30))
	i=1
	while [ $(date +%s) -lt $time ]; do
	    log "  Set quota for $i times"
	    $LFS setquota -u $TSTUSR -b 0 -B $((BLK_LIMIT + 1024 * i)) -i 0 -I $((FILE_LIMIT + i)) $MOUNT
	    $LFS setquota -g $TSTUSR -b 0 -B $((BLK_LIMIT + 1024 * i)) -i 0 -I $((FILE_LIMIT + i)) $MOUNT
	    i=$((i+1))
	    sleep 1
	done

	count=0
	while [ true ]; do
	    if ! ps -p ${DDPID1} > /dev/null 2>&1; then break; fi
	    count=$[count+1]
	    if [ $count -gt 60 ]; then
		quota_error a $TSTUSR "dd should be finished!"
	    fi
	    sleep 1
	done
	echo "(dd_pid=$DDPID1, time=$count)successful"

	count=0
	while [ true ]; do
	    if ! ps -p ${DDPID2} > /dev/null 2>&1; then break; fi
	    count=$[count+1]
	    if [ $count -gt 60 ]; then
		quota_error a $TSTUSR "dd should be finished!"
	    fi
	    sleep 1
	done
	echo "(dd_pid=$DDPID2, time=$count)successful"

	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))
	resetquota -u $TSTUSR
	resetquota -g $TSTUSR

	return $RC
}
run_test_with_stat 21 "run for fixing bug16053 ==========="

test_22() {
        quota_save_version "ug3"

        stopall
        mount
        setupall

        echo "checking parameters"

        do_facet $SINGLEMDS "lctl get_param mdd.${FSNAME}-MDT*.quota_type" | grep "ug3" || error "admin failure"
        do_facet ost1 "lctl get_param obdfilter.*.quota_type" | grep "ug3" || error "op failure"

        quota_init
}

test_23_sub() {
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
	TESTFILE="$DIR/$tdir/$tfile-0"
	rm -f $TESTFILE
	local bs_unit=$((1024*1024))
	LIMIT=$1

	wait_delete_completed

	# test for user
	log "  User quota (limit: $LIMIT kbytes)"
	$LFS setquota -u $TSTUSR -b 0 -B $LIMIT -i 0 -I 0 $DIR
	sleep 3
        quota_show_check b u $TSTUSR

	$LFS setstripe $TESTFILE -c 1
	chown $TSTUSR.$TSTUSR $TESTFILE

	log "    Step1: trigger quota with 0_DIRECT"
	log "      Write half of file"
	$RUNAS $DIRECTIO write $TESTFILE 0 $(($LIMIT/1024/2)) $bs_unit || \
                quota_error u $TSTUSR "(1) write failure, but expect success: $LIMIT"
	log "      Write out of block quota ..."
	$RUNAS $DIRECTIO write $TESTFILE $(($LIMIT/1024/2)) $(($LIMIT/1024/2)) $bs_unit && \
                quota_error u $TSTUSR "(2) write success, but expect EDQUOT: $LIMIT"
	log "    Step1: done"

	log "    Step2: rewrite should succeed"
	$RUNAS $DIRECTIO write $TESTFILE 0 1 $bs_unit || \
                quota_error u $TSTUSR "(3) write failure, but expect success: $LIMIT"
	log "    Step2: done"

	rm -f $TESTFILE
	wait_delete_completed
	OST0_UUID=`do_facet ost1 $LCTL dl | grep -m1 obdfilter | awk '{print $((NF-1))}'`
	OST0_QUOTA_USED=`$LFS quota -o $OST0_UUID -u $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`
	echo $OST0_QUOTA_USED
	[ $OST0_QUOTA_USED -ne 0 ] && \
	    ($SHOW_QUOTA_USER; quota_error u $TSTUSR "quota deleted isn't released")
	$SHOW_QUOTA_USER
	resetquota -u $TSTUSR
}

test_23() {
	log "run for $((OSTCOUNT * 4))MB test file"
	test_23_sub $((OSTCOUNT * 4 * 1024))

	OST0_MIN=120000
	check_whether_skip && return 0
	log "run for $((OSTCOUNT * 40))MB test file"
	test_23_sub $((OSTCOUNT * 40 * 1024))
}
run_test_with_stat 23 "run for fixing bug16125 ==========="

test_24() {
	local TESTFILE="$DIR/$tdir/$tfile"
	mkdir -p $DIR/$tdir

	run_to_block_limit $TESTFILE
	$SHOW_QUOTA_USER | grep '*' || error "no matching *"

	# cleanup
	rm -f $TESTFILE
	resetquota -u $TSTUSR

	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))
        
}
run_test_with_stat 24 "test if lfs draws an asterix when limit is reached (16646) ==========="

show_quota() {
        if [ $1 = "-u" ]; then
                if [ $2 = "$TSTUSR" ]; then
	                $SHOW_QUOTA_USER
                else
                        $SHOW_QUOTA_USER2
                fi
        else
                if [ $2 = "$TSTUSR" ]; then
                        $SHOW_QUOTA_GROUP
                else
                        $SHOW_QUOTA_GROUP2
                fi
        fi
}

test_25_sub() {
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
	TESTFILE="$DIR/$tdir/$tfile-0"
	rm -f $TESTFILE
	LIMIT=$(( $BUNIT_SZ * ($OSTCOUNT + 1) + 4096 ))

	wait_delete_completed

        # set quota for $TSTUSR
        log "setquota for $TSTUSR"
	$LFS setquota $1 $TSTUSR -b $LIMIT -B $LIMIT -i 10 -I 10 $DIR
	sleep 3
        if [ "$1" == "-u" ]; then
                quota_show_check a u $TSTUSR
        else
                quota_show_check a g $TSTUSR
        fi

        # set quota for $TSTUSR2
        log "setquota for $TSTUSR2"
	$LFS setquota $1 $TSTUSR2 -b $LIMIT -B $LIMIT -i 10 -I 10 $DIR
	sleep 3
        if [ "$1" == "-u" ]; then
                quota_show_check a u $TSTUSR2
        else
                quota_show_check a g $TSTUSR2
        fi

        # set stripe index to 0
        log "setstripe for $DIR/$tdir to 0"
	$LFS setstripe $DIR/$tdir -c 1 -i 0
	MDS_UUID=`do_facet $SINGLEMDS $LCTL dl | grep -m1 " mdt " | awk '{print $((NF-1))}'`
	OST0_UUID=`do_facet ost1 $LCTL dl | grep -m1 obdfilter | awk '{print $((NF-1))}'`
	MDS_QUOTA_USED_OLD=`$LFS quota -o $MDS_UUID $1 $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $4 }'`
	OST0_QUOTA_USED_OLD=`$LFS quota -o $OST0_UUID $1 $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`
	MDS_QUOTA_USED2_OLD=`$LFS quota -o $MDS_UUID $1 $TSTUSR2 $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $4 }'`
	OST0_QUOTA_USED2_OLD=`$LFS quota -o $OST0_UUID $1 $TSTUSR2 $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`

        # TSTUSR write 4M
        log "$TSTUSR write 4M to $TESTFILE"
        $RUNAS dd if=/dev/zero of=$TESTFILE bs=4K count=1K || quota_error a $TSTUSR "dd failed"
        sync
	show_quota $1 $TSTUSR
	show_quota $1 $TSTUSR2
	MDS_QUOTA_USED_NEW=`$LFS quota -o $MDS_UUID $1 $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $4 }'`
        [ $MDS_QUOTA_USED_NEW -ne $((MDS_QUOTA_USED_OLD + 1)) ] && \
                quota_error a $TSTUSR "$TSTUSR inode quota usage error: [$MDS_QUOTA_USED_OLD|$MDS_QUOTA_USED_NEW]"
	OST0_QUOTA_USED_NEW=`$LFS quota -o $OST0_UUID $1 $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`
        OST0_QUOTA_USED_DELTA=$((OST0_QUOTA_USED_NEW - OST0_QUOTA_USED_OLD))
        [ $OST0_QUOTA_USED_DELTA -lt 4096 ] && \
                quota_error a $TSTUSR "$TSTUSR block quota usage error: [$OST0_QUOTA_USED_OLD|$OST0_QUOTA_USED_NEW]"

        # chown/chgrp from $TSTUSR to $TSTUSR2
        if [ $1 = "-u" ]; then
                log "chown from $TSTUSR to $TSTUSR2"
                chown $TSTUSR2 $TESTFILE || quota_error u $TSTUSR2 "chown failed"
        else
                log "chgrp from $TSTUSR to $TSTUSR2"
                chgrp $TSTUSR2 $TESTFILE || quota_error g $TSTUSR2 "chgrp failed"
        fi
        sync
	show_quota $1 $TSTUSR
	show_quota $1 $TSTUSR2
	MDS_QUOTA_USED2_NEW=`$LFS quota -o $MDS_UUID $1 $TSTUSR2 $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $4 }'`
        [ $MDS_QUOTA_USED2_NEW -ne $((MDS_QUOTA_USED2_OLD + 1)) ] && \
                quota_error a $TSTUSR2 "$TSTUSR2 inode quota usage transfer from $TSTUSR to $TSTUSR2 failed: [$MDS_QUOTA_USED2_OLD|$MDS_QUOTA_USED2_NEW]"
	OST0_QUOTA_USED2_NEW=`$LFS quota -o $OST0_UUID $1 $TSTUSR2 $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`
	# when chown, the quota on ost could be displayed out of quota temporarily. Delete the '*' in this situation. b=20433
	OST0_QUOTA_USED2_NEW=${OST0_QUOTA_USED2_NEW%\*}
        OST0_QUOTA_USED2_DELTA=$((OST0_QUOTA_USED2_NEW - OST0_QUOTA_USED2_OLD))
        [ $OST0_QUOTA_USED2_DELTA -ne $OST0_QUOTA_USED_DELTA ] && \
                quota_error a $TSTUSR2 "$TSTUSR2 block quota usage transfer from $TSTUSR to $TSTUSR2 failed: [$OST0_QUOTA_USED2_OLD|$OST0_QUOTA_USED2_NEW]"
	MDS_QUOTA_USED_NEW=`$LFS quota -o $MDS_UUID $1 $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $4 }'`
        [ $MDS_QUOTA_USED_NEW -ne $MDS_QUOTA_USED_OLD ] && \
                quota_error a $TSTUSR "$TSTUSR inode quota usage transfer from $TSTUSR to $TSTUSR2 failed: [$MDS_QUOTA_USED_OLD|$MDS_QUOTA_USED_NEW]"
	OST0_QUOTA_USED_NEW=`$LFS quota -o $OST0_UUID $1 $TSTUSR $DIR | awk '/^.*[[:digit:]+][[:space:]+]/ { print $1 }'`
        [ $OST0_QUOTA_USED_NEW -ne $OST0_QUOTA_USED_OLD ] && \
                quota_error a $TSTUSR "$TSTUSR block quota usage transfer from $TSTUSR to $TSTUSR2 failed: [$OST0_QUOTA_USED_OLD|$OST0_QUOTA_USED_NEW]"

	rm -f $TESTFILE
	wait_delete_completed
	resetquota $1 $TSTUSR
	resetquota $1 $TSTUSR2
}

test_25() {
	log "run for chown case"
	test_25_sub -u

	log "run for chgrp case"
	test_25_sub -g
}
run_test_with_stat 25 "test whether quota usage is transfered when chown/chgrp (18081) ==========="

test_26() {
	mkdir -p $DIR/$tdir
	chmod 0777 $DIR/$tdir
	TESTFILE="$DIR/$tdir/$tfile-0"
	TESTFILE2="$DIR/$tdir/$tfile-1"
	set_blk_tunesz 512
	set_blk_unitsz 1024

	wait_delete_completed

	# every quota slave gets 20MB
	b_limit=$(((OSTCOUNT + 1) * 20 * 1024))
	log "limit: ${b_limit}KB"
	$LFS setquota -u $TSTUSR -b 0 -B $b_limit -i 0 -I 0 $DIR
	sleep 3
	quota_show_check b u $TSTUSR

	$LFS setstripe $TESTFILE  -c 1 -i 0
	$LFS setstripe $TESTFILE2 -c 1 -i 0
	chown $TSTUSR.$TSTUSR $TESTFILE
	chown $TSTUSR.$TSTUSR $TESTFILE2

	#define OBD_FAIL_QUOTA_DELAY_REL         0xA03
	lustre_fail ost 0xA03

	log "    Write the first file..."
	$RUNAS $DIRECTIO write $TESTFILE 0 10 $((BLK_SZ * 1024)) || quota_error u $TSTUSR "write failure, but expect success"
	log "    Delete the first file..."
	rm -f $TESTFILE


	wait_delete_completed

	log "    Write the second file..."
	$RUNAS $DIRECTIO write $TESTFILE2 0 10 $((BLK_SZ * 1024)) || quota_error u $TSTUSR "write failure, but expect success"
	log "    Delete the second file..."
	rm -f $TESTFILE2

	lustre_fail ost 0
	set_blk_unitsz $((128 * 1024))
	set_blk_tunesz $((128 * 1024 / 2))
	resetquota -u $TSTUSR
}
run_test_with_stat 26 "test for false quota error(bz18491) ======================================"

test_27a() {
        $LFS quota $TSTUSR $DIR && error "lfs succeeded with no type, but should have failed"
        $LFS setquota $TSTUSR $DIR && error "lfs succeeded with no type, but should have failed"
        return 0
}
run_test_with_stat 27a "lfs quota/setquota should handle wrong arguments (19612) ================="

test_27b() {
        $LFS setquota -u $TSTID -b 1000 -B 1000 -i 1000 -I 1000 $DIR || \
                error "lfs setquota failed with uid argument"
        $LFS setquota -g $TSTID -b 1000 -B 1000 -i 1000 -I 1000 $DIR || \
                error "lfs stequota failed with gid argument"
        $SHOW_QUOTA_USERID || error "lfs quota failed with uid argument"
        $SHOW_QUOTA_GROUPID || error "lfs quota failed with gid argument"
        resetquota -u $TSTUSR
        resetquota -g $TSTUSR
        return 0
}
run_test 27b "lfs quota/setquota should handle user/group ID (20200) ================="

test_28() {
        BLK_LIMIT=$((100 * 1024 * 1024)) # 100G
        echo "Step 1: set enough high limit for user [$TSTUSR:$BLK_LIMIT]"
        $LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I 0 $DIR
        $SHOW_QUOTA_USER

        echo "Step 2: reset system ..."
        cleanup_and_setup_lustre
        quota_init

        echo "Step 3: change qunit for user [$TSTUSR:512:1024]"
        set_blk_tunesz 512
        set_blk_unitsz 1024

        wait_delete_completed

        #define OBD_FAIL_QUOTA_RET_QDATA | OBD_FAIL_ONCE
        lustre_fail ost 0x80000A02

        TESTFILE="$DIR/$tdir/$tfile"
        mkdir -p $DIR/$tdir

        BLK_LIMIT=$((100 * 1024)) # 100M
        echo "Step 4: set enough high limit for user [$TSTUSR:$BLK_LIMIT]"
        $LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I 0 $DIR
        $SHOW_QUOTA_USER

        touch $TESTFILE
        chown $TSTUSR.$TSTUSR $TESTFILE

        echo "Step 5: write the test file1 [10M] ..."
        $RUNAS dd if=/dev/zero of=$TESTFILE  bs=$BLK_SZ count=$(( 10 * 1024 )) \
	    || quota_error a $TSTUSR "write 10M file failure"
        $SHOW_QUOTA_USER

        rm -f $TESTFILE
        sync; sleep 3; sync;

        # make qd_count 64 bit
        lustre_fail ost 0

        set_blk_unitsz $((128 * 1024))
        set_blk_tunesz $((128 * 1024 / 2))

        resetquota -u $TSTUSR
}
run_test_with_stat 28 "test for consistency for qunit when setquota (18574) ==========="

test_30()
{
        local output
        local LIMIT=1024
        local TESTFILE="$DIR/$tdir/$tfile"
        local GRACE=10

        mkdir -p $DIR/$tdir
        chmod 0777 $DIR/$tdir

        $LFS setquota -t -u --block-grace $GRACE --inode-grace $MAX_IQ_TIME $DIR
        $LFS setquota -u $TSTUSR -b $LIMIT -B 0 -i 0 -I 0 $DIR
        $RUNAS dd if=/dev/zero of=$TESTFILE bs=1024 count=$((LIMIT * 2)) || true
        cancel_lru_locks osc
        sleep 5
        $LFS setquota -u $TSTUSR -B 0 $DIR
        output=`$SHOW_QUOTA_USER | grep $MOUNT | awk '{ print $5 }' | tr -d s`
        [ "$output" -le "$((GRACE - 5))" ] || error "grace times were reset or unexpectedly high latency"
        rm -f $TESTFILE
        resetquota -u $TSTUSR
        $LFS setquota -t -u --block-grace $MAX_DQ_TIME --inode-grace $MAX_IQ_TIME $DIR
}
run_test_with_stat 30 "hard limit updates should not reset grace times ================"

test_29()
{
        local BLK_LIMIT=$((100 * 1024 * 1024)) # 100G
        local timeout
        local pid
        local resends

        if at_is_enabled; then
                timeout=$(at_max_get client)
                at_max_set 10 client
        else
                timeout=$(lctl get_param -n timeout)
                lctl set_param timeout=10
        fi

        resends=$(lctl get_param -n mdc.${FSNAME}-*.quota_resend_count | head -1)

        #define OBD_FAIL_MDS_QUOTACTL_NET 0x12e
        lustre_fail mds 0x12e

        $LFS setquota -u $TSTUSR -b 0 -B $BLK_LIMIT -i 0 -I 0 $DIR & pid=$!

        echo "sleeping for $((10 * resends + 5)) seconds"
        sleep $((10 * resends + 5))
        ps -p $pid && error "lfs hadn't finished by timeout"
        wait $pid && error "succeeded, but should have failed"

        lustre_fail mds 0

        if at_is_enabled; then
                at_max_set $timeout client
        else
                lctl set_param timeout=$timeout
        fi

        resetquota -u $TSTUSR
}
run_test_with_stat 29 "unhandled quotactls must not hang lustre client (19778) ========"

# turn off quota
quota_fini()
{
	$LFS quotaoff $DIR
        do_nodes $(comma_list $(nodes_list)) "lctl set_param debug=-quota"
}
quota_fini

log "cleanup: ======================================================"
cd $ORIG_PWD
check_and_cleanup_lustre
echo '=========================== finished ==============================='
[ -f "$QUOTALOG" ] && cat $QUOTALOG && grep -q FAIL $QUOTALOG && exit 1 || true
echo "$0: completed"
