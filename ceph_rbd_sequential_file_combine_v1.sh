#!/bin/bash


# rbd prefix string
rbd_prefix="3ceec238e1f29"

# source of sequential files directory
fragment_dir="/var/lib/ceph/osd/ceph-6/_combine_3ceec238e1f29"

# output of combined directory
combine_dir="/var/lib/ceph/osd/ceph-9"

# sequential number range
start_num=0
last_num=262143 # 1TB



# combine function
# ----------------------------------------------------------------
function seq_combine() {

    local part_name=$1
    local start_num=$2
    local last_num=$3

    rm -rf ${combine_dir}/${rbd_prefix}/${part_name}
    touch ${combine_dir}/${rbd_prefix}/${part_name}

    for i in `seq ${start_num} ${last_num}`; do

        file_size=`ls -l ${fragment_dir}/${i} | awk '{print $5}'`
        if [[ ${file_size} -eq "4194304" ]]; then
            echo "    combine ${i}"
            cat ${fragment_dir}/${i} >> ${combine_dir}/${rbd_prefix}/${part_name}
        else
            echo "    ${i} file size not equal 4194304 ${file_size}"
            exit
        fi

    done
}

function part_combine() {
    local parts="$@"
    cd ${combine_dir}/${rbd_prefix}
    cat "${parts}" >> ${combine_dir}/${rbd_prefix}_all
}

# Main
# ----------------------------------------------------------------


# run single combine
seq_combine all 0 262143


# run multiple parallel partical combine
seq_combine part0 0 32767 &
seq_combine part1 32768 65535 &
seq_combine part2 65536 98303  &
seq_combine part3 98304 131071 &
seq_combine part4 131072 163839 &
seq_combine part5 163840 196607 &
seq_combine part6 196608 229375 &
seq_combine part7 229376 262143 &



# have to wait all parallel partical combine finished
#part_combine part0 part1 part2 part3 part4 part5 part6 part7
