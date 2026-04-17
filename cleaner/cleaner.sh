#!/bin/bash

export LANG=C
export PATH=/sbin:/bin:/usr/local/sbin:/usr/sbin:/usr/local/bin:/usr/bin:/bin

readonly BASE_DIR=/home/ec2-user
readonly LOGS_DIR=${BASE_DIR}/logs
readonly CONF_FILE=${BASE_DIR}/cleaner.conf
readonly RESERVE=14
DELETE_FLAG='-delete'
DEBUG=''
CHUNK_SIZE=''
INTERACTIVE=0
CLEANER_DIGEST="${LOGS_DIR}/cleaner.log.$(date +%F)"


{
    readonly CLEANER_OK=1    
    readonly CLEANER_CRUSH=2
    readonly CLEANER_ERROR=3
    readonly CLEANER_IGNORE=4
}

[[ ! -d $LOGS_DIR ]] && exit

CMD_PREFIX=''
if command -v ionice &>/dev/null; then
    CMD_PREFIX="ionice -c3 "
fi
if command -v nice &>/dev/null; then
    CMD_PREFIX="nice -n 19 $CMD_PREFIX"
fi
FIND_CMD="${CMD_PREFIX}find"
RM_CMD="${CMD_PREFIX}rm"

TRUNCATE_CMD=''
if command -v truncate &>/dev/null; then
    TRUNCATE_CMD="${CMD_PREFIX}truncate"
fi

LSOF_CMD=''
if command -v lsof &>/dev/null; then
    LSOF_CMD="lsof"
fi

LSOF_FILE=/tmp/cleaner_lsof.out
if [[ -d /dev/shm && -k /dev/shm ]]; then
    LSOF_FILE=/dev/shm/cleaner_lsof.out
fi

prepare_lsof() {
    if [[ -n $LSOF_CMD ]]; then
        local cur_limit
        cur_limit=$(ulimit -n)
        if [[ $cur_limit != 'unlimited' && $cur_limit -lt 65536 ]]; then
            ulimit -n 65536 2>/dev/null || true
        fi
        $LSOF_CMD +D "$LOGS_DIR" 2>/dev/null > "$LSOF_FILE"
    fi
}

delete_lsof() {
    $RM_CMD -rf $LSOF_FILE
}

# only return true when all ready
file_in_lsof() {
    local fpath=$1
    if [[ -n $LSOF_CMD && -f $LSOF_FILE ]]; then
        grep -qF "$fpath" "$LSOF_FILE"
        return $?
    fi
    # fallback: check /proc/*/fd when lsof is unavailable
    local fd_link
    for fd_link in /proc/*/fd/*; do
        [[ $(readlink "$fd_link" 2>/dev/null) == "$fpath" ]] && return 0
    done
    return 1
}

log_error() {
    echo "$(date +"%F %T") [ERROR] $*" >> "$CLEANER_DIGEST"
}

log_info() {
    echo "$(date +"%F %T") [INFO] $*" >> "$CLEANER_DIGEST"
}

log_warn() {
    echo "$(date +"%F %T") [WARN] $*" >> "$CLEANER_DIGEST"
}

log_debug() {
    [[ $DEBUG != '-debug' ]] && return
    echo "$(date +"%F %T") [DEBUG] $*" >> "$CLEANER_DIGEST"
}

delete_files() {
    [[ $DELETE_FLAG != '-delete' ]] && return
    $RM_CMD -rf "$@" &>/dev/null
}

crush_files() {
    [[ $DELETE_FLAG != '-delete' ]] && return
    for f in "$@"; do
        > $f
    done
}

clean_file() {
    # eliminates file in a low-speed way (default: 20MB/S)
    local fpath=$1
    local fsize=$2
    local chunksize=${CHUNK_SIZE:-20}

    if [[ $DELETE_FLAG != '-delete' || ! -f $fpath ]]; then
        return $CLEANER_ERROR
    fi

    local is_open=0
    if file_in_lsof "$fpath" &>/dev/null; then
        is_open=1
    fi

    if [[ $is_open -eq 1 && $fsize -eq 0 ]]; then
        log_debug "ignore $fpath(+) size $fsize"
        return $CLEANER_IGNORE
    fi

    if [[ $chunksize -eq 0 || -z $TRUNCATE_CMD ]]; then
        # fast delete
        if [[ $is_open -eq 1 ]]; then
            crush_files $fpath
            log_debug "removed $fpath(+) size $fsize directly"
        else
            delete_files $fpath
            log_debug "removed $fpath size $fsize directly"
        fi
    else
        # slow delete
        local tstart=$SECONDS
        local tstake=$((1+tstart))
        local loop=$((fsize/(1048576*chunksize)+1))
        local tdiff
        if [[ $fsize -eq 0 ]]; then
            loop=0
        fi
        for ((i=0; i<loop; ++i)); do
            $TRUNCATE_CMD -s "-${chunksize}M" $fpath
            tdiff=$((tstake-SECONDS))
            if [[ $tdiff -gt 0 ]]; then
                sleep $tdiff
            fi
            tstake=$((tstake+1))
        done
        if [[ $is_open -eq 1 ]]; then
            log_debug \
                "removed $fpath(+) size $fsize in $((SECONDS-tstart)) seconds"
        else
            log_debug \
                "removed $fpath size $fsize in $((SECONDS-tstart)) seconds"
        fi
    fi
    # here a time delta between lsof and remove
    if [[ -n $LSOF_CMD && $is_open -eq 0 ]]; then
        delete_files $fpath
        return $CLEANER_OK
    else
        return $CLEANER_CRUSH
    fi
}

get_home_usage() {
    local usage
    usage=$(df -P "$LOGS_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ -z $usage ]]; then
        log_error "can't get home partition usage"
        exit 1
    fi
    echo "$usage"
}

sleep_dif()
{
    local secs idc index
    if [[ $HOSTNAME =~ ^[a-z0-9]+-[0-9]+-[0-9]+$ ]]; then
        idc=$(echo $HOSTNAME|awk -F- '{print $2}')
        index=$(echo $HOSTNAME|awk -F- '{print $3}')
        secs=$(( (index*19 +idc*7)%233 ))
    else
        secs=$((RANDOM%133))
    fi
    sleep $secs
    log_info slept $secs seconds
}

clean_expired() {
    local keep_days=$((RESERVE-1))
    local fpath fsize fmtime how_long expired
    local ret_code=$CLEANER_OK
    $FIND_CMD $LOGS_DIR \
        -type f \
        -name '*log*' \
        ! -name '*\.[0-9]dt\.log*' \
        ! -name '*\.[0-9][0-9]dt\.log*' \
        ! -name '*\.[0-9][0-9][0-9]dt\.log*' \
        -mtime +$keep_days \
        -printf '%p %s\n' | \
    while read fpath fsize; do
        clean_file $fpath $fsize
        ret_code=$?
        if [[ $ret_code -eq $CLEANER_OK || $ret_code -eq $CLEANER_CRUSH ]]; then
            log_info "deleted expired file $fpath size $fsize"
        fi
    done
    
    $FIND_CMD $LOGS_DIR \
        -type f \
        \( -name '*\.[0-9]dt\.log*' -o \
        -name '*\.[0-9][0-9]dt\.log*' -o \
        -name '*\.[0-9][0-9][0-9]dt\.log*' \) \
        -printf '%p %s %TY-%Tm-%Td\n' | \
    while read fpath fsize fmtime; do
        how_long=$(echo $fpath | grep -o '[0-9]\+dt' | tr -d '[a-z]')
        expired=$(date -d"$how_long days ago" +"%F")
        if [[ $fmtime > $expired ]]; then
            continue
        else
            clean_file $fpath $fsize
            ret_code=$?
            if [[ $ret_code -eq $CLEANER_OK || $ret_code -eq $CLEANER_CRUSH ]]; then
                log_info "deleted expired file $fpath size $fsize"
            fi
        fi
    done
}

clean_huge() {
    local blocks big_size fpath fsize
    blocks=$(df -P /home -k | awk 'NR==2 {print $2}')
    if [[ $? -ne 0 || -z $blocks ]]; then
        log_error "can't get home partition total size"
        exit 1
    fi
    # 120G
    if [[ $blocks -ge 125829120 ]]; then
        big_size=50G
    else
        big_size=30G
    fi
    $FIND_CMD $LOGS_DIR \
        -type f \
        -name '*log*' \
        -size +$big_size \
        -printf '%p %s\n' | \
    while read fpath fsize; do
        crush_files "$fpath"
        log_warn "deleted huge file $fpath size $fsize"
    done
}

clean_by_day() {
    local how_long=$1
    local ret_code=$CLEANER_OK
    $FIND_CMD $LOGS_DIR \
        -type f \
        -name '*log*' \
        -mtime "+${how_long}" \
        -printf '%p %s\n' | \
    while read fpath fsize; do
        clean_file $fpath $fsize
        ret_code=$?
        if [[ $ret_code -eq $CLEANER_OK || $ret_code -eq $CLEANER_CRUSH ]]; then
            log_info "deleted $((how_long+1)) days ago file $fpath size $fsize"
        fi
    done
}

clean_by_hour() {
    local how_long=$1
    local ret_code=$CLEANER_OK
    $FIND_CMD $LOGS_DIR \
        -type f \
        -name '*log*' \
        -mmin "+$((how_long*60))" \
        -printf '%p %s\n' | \
    while read fpath fsize; do
        clean_file $fpath $fsize
        ret_code=$?
        if [[ $ret_code -eq $CLEANER_OK || $ret_code -eq $CLEANER_CRUSH ]]; then
            log_info "deleted $how_long hours ago file $fpath size $fsize"
        fi
    done
}

clean_largest() {
    local fsize fpath fblock
    local ret_code=$CLEANER_OK

    $FIND_CMD $LOGS_DIR \
        -type f \
        -printf '%b %s %p\n' | \
    sort -nr | head -1 | \
    while read fblock fsize fpath ; do
        # 10G
        if [[ $fsize -gt 10737418240 ]]; then
            crush_files $fpath
        else
            clean_file $fpath $fsize
        fi
        ret_code=$?
        if [[ $ret_code -eq $CLEANER_OK || $ret_code -eq $CLEANER_CRUSH ]]; then
            log_info "deleted largest file $fpath size $fsize"
        fi
    done
}

in_low_traffic() {
    local now=$(date '+%R')
    if [[ "$now" > "04:00" && "$now" < "04:30" ]]; then
        return 0
    else
        return 1
    fi
}


clean_until() {
    local from_rate to_rate cur_usage old_usage how_long count force
    how_long=$((RESERVE-1))
    from_rate=$1
    to_rate=$2
    force=$3
    count=0

    cur_usage=$(get_home_usage)

    # should exist some huge files
    if [[ $cur_usage -ge 97 ]]; then
        clean_huge
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    fi

    if ! in_low_traffic; then
        [[ $cur_usage -lt $from_rate ]] && return
    fi

    prepare_lsof

    clean_expired
    old_usage=$cur_usage
    cur_usage=$(get_home_usage)
    if [[ $cur_usage -ne $old_usage ]]; then
        log_info "usage from $old_usage to $cur_usage"
    fi

    # now we have to remove recent logs by date
    while [[ $cur_usage -gt $to_rate ]]; do
        if [[ $how_long -lt 1 ]]; then
            break
        else
            how_long=$((how_long-1))
        fi
        clean_by_day $how_long
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    done

    # in hours
    how_long=24
    while [[ $cur_usage -gt $to_rate ]]; do
        if [[ $how_long -lt 2 ]]; then
            break
        else
            how_long=$((how_long-1))
        fi
        clean_by_hour $how_long
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    done

    [[ $force -ne 1 ]] && return
    # last resort, find top size logs to deleted

    if [[ ${CHUNK_SIZE:-1} -ne 0 ]]; then
        CHUNK_SIZE=100
    fi
    while [[ $cur_usage -gt $to_rate ]]; do
        if [[ $count -gt 5 ]]; then
            log_error "give up deleting largest files"
            break
        fi
        count=$((count+1))
        clean_largest
        old_usage=$cur_usage
        cur_usage=$(get_home_usage)
        if [[ $cur_usage -ne $old_usage ]]; then
            log_info "usage from $old_usage to $cur_usage"
        fi
    done

    delete_lsof
}

ensure_unique() {
    local pgid
    pgid=$(ps -p $$ -o pgid=)
    local pids
    pids=$(ps -e -o pid,pgid,cmd | \
                    grep '[c]leaner' | \
                    awk "\$2 != $pgid {print \$1}")
    if [[ -n $pids ]]; then
        if [[ $INTERACTIVE -eq 1 ]]; then
            kill $pids
        else
            log_info "$0 is running, wait for another round of dispatch"
            exit 0
        fi
    fi
}

_main() {
    local to_rate=90
    local from_rate=$to_rate
    local do_sleep=0
    local force=0

    # load config
    if [[ -f $CONF_FILE && ! "$*" =~ --noconf ]]; then
        while IFS='=' read -r key value; do
            [[ -z $key || $key == \#* ]] && continue
            case $key in
                to)
                    to_rate=$value;;
                block)
                    CHUNK_SIZE=$value;;
                fast)
                    CHUNK_SIZE=0;;
                from)
                    from_rate=$value;;
                sleep)
                    do_sleep=1;;
                debug)
                    DEBUG='-debug';;
                force)
                    force=1;;
                *)
                    ;;
            esac
        done < $CONF_FILE
    fi

    # option help
    # -r clean to this ratio
    # -b wipe this blocksize each time
    # -t start cleaning when above this ratio
    # -n fast delete (use rm -rf)
    # -s random sleep awhile in a app clusters
    # -d extra debug logging
    # -f force delete largest file
    while getopts ":r:b:t:nsdfi" opt; do
        case $opt in
        r)
            if [[ ! $OPTARG =~ ^[0-9]+$ ]]; then
                echo "$0: rate $OPTARG is an invalid number" >&2
                exit 1;
            fi
            if [[ $OPTARG -le 1 || $OPTARG -ge 99 ]]; then
                echo "$0: rate $OPTARG out of range (1, 99)" >&2
                exit 1;
            fi
            to_rate=$OPTARG ;;
        b)
            if [[ ! $OPTARG =~ ^[0-9]+[mMgG]?$ ]]; then
                echo "$0: block size $OPTARG is invalid" >&2
                exit 1;
            fi
            if [[ $OPTARG =~ [gG]$ ]]; then
                CHUNK_SIZE=$(echo $OPTARG|tr -d 'gG')
                CHUNK_SIZE=$((CHUNK_SIZE*1024))
            else
                CHUNK_SIZE=$(echo $OPTARG|tr -d 'mM')
            fi ;;
        t)
            if [[ ! $OPTARG =~ ^[0-9]+$ ]]; then
                echo "$0: rate $OPTARG is an invalid number" >&2
                exit 1;
            fi
            if [[ $OPTARG -le 1 || $OPTARG -ge 99 ]]; then
                echo "$0: rate $OPTARG out of range (1, 99)" >&2
                exit 1;
            fi
            from_rate=$OPTARG ;;
        n)
            CHUNK_SIZE=0 ;;
        s)
            do_sleep=1 ;;
        d)
            DEBUG='-debug' ;;
        f)
            force=1 ;;
        i)
            INTERACTIVE=1 ;;

        \?)
            echo "$0: invalid option: -$OPTARG" >&2
            exit 1;;
        :)
            echo "$0: option -$OPTARG requires an argument" >&2
            exit 1 ;;
        esac
    done

    if [[ $to_rate -ge $from_rate ]]; then
        to_rate=$from_rate
    fi

    ensure_unique
    [[ $do_sleep -eq 1 ]] && sleep_dif
    clean_until $from_rate $to_rate $force
}

# TODO make a decision whether /home/admin is innocent
# TODO deamonize

_main "$@"