#!/bin/bash

cp_to_path="/var/lib/ceph/osd/ceph-6/_combine_3ceec238e1f29"

readarray zero_file_list < /tmp/zero/list


for i in ${zero_file_list[@]}; do

    echo "    generate zero file ${i}"
    dd if=/dev/zero of=${cp_to_path}/${i} bs=4194304 count=1

done
